package com.player.player

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject
import soulseek.wrapper.ISoulseekEventSink
import soulseek.wrapper.SoulseekBridge
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.min

/**
 * Очередь и управление трансферами Soulseek.
 *
 * Архитектура ответственности:
 *  - C# [SoulseekBridge] выполняет саму передачу: `.part`-файл, resume по offset,
 *    atomic rename, progress-события с throttle 250ms.
 *  - Этот менеджер управляет: лимитом параллельных загрузок (Semaphore),
 *    retry с экспоненциальным backoff, pause/resume/cancel, объединением
 *    одновременных запросов одного cacheKey, persist состояний в БД и
 *    throttled-обновлением notification.
 */
class SoulseekTransferManager(
    private val bridge: SoulseekBridge,
    private val database: SoulseekDatabase,
    private val cacheManager: SoulseekCacheManager,
    private val eventSink: (String) -> Unit,
    private val onActiveTransfersChanged: () -> Unit = {}
) {
    companion object {
        private const val TAG = "SoulseekTransferMgr"

        /** Лимит параллельных transfer (2-3, настраивается). */
        private const val DEFAULT_MAX_CONCURRENT = 3

        /** Максимальное число попыток для retryable-ошибок. */
        private const val MAX_RETRY_ATTEMPTS = 3

        /** Базовая задержка retry, мс (экспоненциальный backoff: base * 2^attempt). */
        private const val RETRY_BASE_DELAY_MS = 2_000L

        /** Throttle обновления БД-чекпоинта прогресса, мс. */
        private const val CHECKPOINT_THROTTLE_MS = 1_000L

        /** Throttle обновления notification о прогрессе, мс. */
        private const val NOTIFICATION_THROTTLE_MS = 500L
    }

    /** Внутреннее состояние одного трансфера. */
    private data class TransferContext(
        val downloadId: String,
        val cacheKey: String,
        val peerUsername: String,
        val remoteFilename: String,
        @Volatile var sizeBytes: Long = 0L,
        val fileExtension: String,
        @Volatile var state: TransferState,
        @Volatile var bytesReceived: Long = 0L,
        @Volatile var bytesPerSecond: Long = 0L,
        @Volatile var localPath: String? = null,
        @Volatile var retryCount: Int = 0,
        @Volatile var lastCheckpointAt: Long = 0L,
        @Volatile var lastNotificationAt: Long = 0L,
        /** Управляет retry-loop корутины. */
        @Volatile var pauseRequested: Boolean = false,
        @Volatile var cancelRequested: Boolean = false
    )

    /** Все известные трансферы (активные + paused + завершённые до перечитывания БД). */
    private val transfers = ConcurrentHashMap<String, TransferContext>()

    /** cacheKey → downloadId — объединение одновременных запросов одного файла. */
    private val cacheKeyToDownloadId = ConcurrentHashMap<String, String>()

    /** Лимит параллельных активных загрузок. */
    private val semaphore = Semaphore(DEFAULT_MAX_CONCURRENT)

    /** Scope для transfer-корутин; отменяется при shutdown. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Текущее состояние соединения (для восстановления после дисконнекта + notification). */
    @Volatile
    var connectionState: ConnectionState = ConnectionState.DISCONNECTED
        private set

    /** Признак shutdown для отказа в новых загрузках. */
    @Volatile
    private var shutdown = false

    // ───────────────────────────────────────────────────────────────────
    //  Public API (вызывается из SoulseekForegroundService)
    // ───────────────────────────────────────────────────────────────────

    /**
     * Запускает загрузку (или присоединяется к уже идущей).
     *
     * Проверяет кэш: если файл уже скачан (complete) — сразу возвращает его путь.
     * Если cacheKey уже загружается — возвращает тот же downloadId (dedupe).
     * Иначе — создаёт transfer, ставит в очередь, запускает корутину.
     *
     * Возвращает: downloadId (загрузка запущена/уже идёт) или путь к готовому файлу.
     */
    fun startDownload(
        downloadId: String,
        peerUsername: String,
        remoteFilename: String,
        sizeBytes: Long,
        cacheKey: String,
        fileExtension: String
    ): String {
        if (shutdown) {
            throw SoulseekServiceException(
                "SERVICE_SHUTDOWN", "Transfer manager is shutting down", retryable = false
            )
        }

        // 1. Cache hit: файл уже полностью скачан.
        cacheManager.getCacheEntry(cacheKey)?.let { entry ->
            Log.i(TAG, "startDownload: cache hit for $cacheKey -> ${entry.localPath}")
            // Фиксируем завершённый трансфер и шлём событие немедленно.
            emitTransferEvent(downloadId, TransferState.COMPLETED, entry.sizeBytes, sizeBytes, 0L, entry.localPath)
            return entry.localPath
        }

        // 2. Dedupe: этот cacheKey уже загружается/в очереди — тот же downloadId.
        val existingId = cacheKeyToDownloadId[cacheKey]
        if (existingId != null && transfers.containsKey(existingId)) {
            val ctx = transfers[existingId]!!
            if (!ctx.state.isTerminal) {
                Log.i(TAG, "startDownload: dedupe, joining existing transfer $existingId")
                return existingId
            }
        }

        // 3. Новая загрузка (или resume по .part файлу — C# bridge продолжит с offset).
        val ctx = TransferContext(
            downloadId = downloadId,
            cacheKey = cacheKey,
            peerUsername = peerUsername,
            remoteFilename = remoteFilename,
            sizeBytes = sizeBytes,
            fileExtension = fileExtension,
            state = TransferState.QUEUED
        )
        transfers[downloadId] = ctx
        cacheKeyToDownloadId[cacheKey] = downloadId

        // Persist в БД.
        persistTransfer(ctx)

        emitTransferEvent(downloadId, TransferState.QUEUED, ctx.bytesReceived, sizeBytes)
        onActiveTransfersChanged()

        // Запуск корутины-обработчика.
        scope.launch {
            processTransfer(ctx)
        }

        return downloadId
    }

    /**
     * Пауза: отмена текущей C#-загрузки + сохранение checkpoint.
     * .part файл остаётся — resume продолжит с offset.
     */
    fun pauseDownload(downloadId: String) {
        val ctx = transfers[downloadId] ?: throw notFound(downloadId)
        ctx.pauseRequested = true
        // Отменяем активную C#-передачу; .part остаётся на диске.
        cancelBridgeTransfer(downloadId)
        ctx.state = TransferState.PAUSED
        ctx.bytesPerSecond = 0L
        // Checkpoint: фиксируем фактический размер .part файла.
        checkpointFromPartFile(ctx)
        persistTransfer(ctx)
        emitTransferEvent(downloadId, TransferState.PAUSED, ctx.bytesReceived, ctx.sizeBytes)
        onActiveTransfersChanged()
    }

    /** Resume: перезапуск загрузки с checkpoint-offset (.part файл). */
    fun resumeDownload(downloadId: String) {
        val ctx = transfers[downloadId] ?: throw notFound(downloadId)
        if (ctx.state.isTerminal) {
            throw SoulseekServiceException(
                "TRANSFER_TERMINAL",
                "Transfer is in terminal state ${ctx.state}",
                retryable = false
            )
        }
        ctx.pauseRequested = false
        ctx.cancelRequested = false
        ctx.state = TransferState.QUEUED
        persistTransfer(ctx)
        emitTransferEvent(downloadId, TransferState.QUEUED, ctx.bytesReceived, ctx.sizeBytes)
        scope.launch {
            processTransfer(ctx)
        }
    }

    /** Cancel: отмена + удаление .part файла. */
    fun cancelDownload(downloadId: String) {
        val ctx = transfers[downloadId] ?: throw notFound(downloadId)
        ctx.cancelRequested = true
        ctx.pauseRequested = false
        cancelBridgeTransfer(downloadId)
        ctx.state = TransferState.CANCELLED
        // Удаляем .part (загрузка отменена окончательно).
        val partFile = cacheManager.getPartFile(ctx.cacheKey)
        partFile?.delete()
        emitTransferEvent(
            downloadId, TransferState.CANCELLED, ctx.bytesReceived, ctx.sizeBytes,
            message = "Download cancelled by user"
        )
        persistTransfer(ctx)
        cleanupMappings(ctx)
        onActiveTransfersChanged()
    }

    /** Снимок всех активных (незавершённых) трансферов — для восстановления UI. */
    fun getActiveTransfers(): List<SoulseekTransferEvent> =
        transfers.values
            .filter { !it.state.isTerminal }
            .map { it.toEvent() }

    /** Снимок всех известных трансферов (включая терминальные) — для getActiveTransfers на Flutter-стороне. */
    fun getAllTransfers(): List<SoulseekTransferEvent> =
        transfers.values.map { it.toEvent() }

    fun getTransfer(downloadId: String): SoulseekTransferEvent? =
        transfers[downloadId]?.toEvent()

    /** Устанавливает текущее состояние соединения (для retry-логики). */
    fun setConnectionState(state: ConnectionState) {
        connectionState = state
    }

    // ───────────────────────────────────────────────────────────────────
    //  Core: обработка трансфера (retry-loop)
    // ───────────────────────────────────────────────────────────────────

    private suspend fun processTransfer(ctx: TransferContext) {
        var attempt = ctx.retryCount

        while (!ctx.cancelRequested && !ctx.pauseRequested) {
            // Ждём слот очереди.
            ctx.state = TransferState.QUEUED
            emitTransferEvent(ctx)
            semaphore.withPermit {
                if (ctx.cancelRequested || ctx.pauseRequested) return@withPermit

                ctx.state = TransferState.DOWNLOADING
                emitTransferEvent(ctx)
                onActiveTransfersChanged()

                try {
                    // Актуализируем bytesReceived из .part файла перед стартом (resume offset).
                    checkpointFromPartFile(ctx)

                    val requestJson = JSONObject().apply {
                        put("downloadId", ctx.downloadId)
                        put("peerUsername", ctx.peerUsername)
                        put("remoteFilename", ctx.remoteFilename)
                        put("sizeBytes", ctx.sizeBytes)
                        put("cacheKey", ctx.cacheKey)
                        put("localDirectory", cacheDirectoryPath)
                        put("fileExtension", ctx.fileExtension)
                    }

                    // downloadToFileAsync — блокирующий вызов C# bridge.
                    // Возвращает немедленно (fire-and-forget внутри C#); прогресс
                    // приходит через event sink.
                    val result = runCatching { bridge.downloadToFileAsync(requestJson.toString()) }
                        .getOrElse { e ->
                            Log.e(TAG, "downloadToFileAsync JNI call failed", e)
                            "{\"success\":false,\"errorCode\":\"JNI_ERROR\",\"errorMessage\":\"${e.message?.replace("\"", "'")}\"}"
                        }

                    val parsed = BridgeCallResult.parse(result)
                    if (!parsed.success) {
                        throw SoulseekServiceException(
                            parsed.errorCode ?: "BRIDGE_ERROR",
                            parsed.errorMessage ?: "Bridge download call failed",
                            parsed.retryable
                        )
                    }

                    // Ожидаем завершения: C# шлёт downloadComplete / downloadFailed
                    // через event sink. Ждём, пока state не станет терминальным.
                    awaitTerminalState(ctx)
                } catch (e: SoulseekServiceException) {
                    handleTransferFailure(ctx, e, attempt)
                    return@withPermit
                } catch (e: Exception) {
                    handleTransferFailure(
                        ctx,
                        SoulseekServiceException(
                            "INTERNAL_ERROR",
                            e.message ?: "Unexpected transfer error",
                            retryable = false
                        ),
                        attempt
                    )
                    return@withPermit
                } finally {
                    onActiveTransfersChanged()
                }
            }

            // Если terminal — выходим из retry-loop.
            if (ctx.state.isTerminal) break

            // Пауза/отмена — выходим.
            if (ctx.pauseRequested || ctx.cancelRequested) break

            attempt++
            ctx.retryCount = attempt
            if (attempt >= MAX_RETRY_ATTEMPTS) {
                ctx.state = TransferState.FAILED
                emitTransferEvent(
                    ctx.downloadId, TransferState.FAILED, ctx.bytesReceived, ctx.sizeBytes,
                    errorCode = "RETRIES_EXHAUSTED",
                    message = "Retry attempts exhausted after $attempt tries"
                )
                persistTransfer(ctx)
                cleanupMappings(ctx)
                break
            }

            // Экспоненциальный backoff перед следующей попыткой.
            val delayMs = RETRY_BASE_DELAY_MS * (1L shl min(attempt, 4))
            Log.i(TAG, "Retrying ${ctx.downloadId} in ${delayMs}ms (attempt $attempt)")
            delay(delayMs)
        }
    }

    /**
     * Ожидает терминального состояния, пока C# качает. Периодически проверяет
     * pause/cancel флаги. Возвращает когда: state terminal, pauseRequested
     * или cancelRequested.
     */
    private suspend fun awaitTerminalState(ctx: TransferContext) {
        while (!ctx.state.isTerminal && !ctx.pauseRequested && !ctx.cancelRequested) {
            delay(200)
        }
    }

    private fun handleTransferFailure(ctx: TransferContext, e: SoulseekServiceException, attempt: Int) {
        Log.w(TAG, "Transfer ${ctx.downloadId} failed (attempt $attempt): ${e.code} — ${e.message}")
        ctx.state = TransferState.FAILED
        emitTransferEvent(
            ctx.downloadId, TransferState.FAILED, ctx.bytesReceived, ctx.sizeBytes,
            errorCode = e.code, retryable = e.retryable, message = e.message
        )
        persistTransfer(ctx)
        if (ctx.state.isTerminal) cleanupMappings(ctx)
    }

    // ───────────────────────────────────────────────────────────────────
    //  Bridge event sink — приём событий из C#
    // ───────────────────────────────────────────────────────────────────

    /**
     * Создаёт ISoulseekEventSink, который маршрутизирует события из C# bridge
     * в этот менеджер. Вызывается один раз из SoulseekForegroundService.
     */
    fun createBridgeEventSink(): ISoulseekEventSink = object : ISoulseekEventSink {
        override fun onEvent(json: String?) {
            if (json.isNullOrBlank()) return
            try {
                handleBridgeEvent(json)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to handle bridge event", e)
            }
        }
    }

    private fun handleBridgeEvent(json: String) {
        val obj = JSONObject(json)
        val eventType = obj.optString("eventType", "")
        val downloadId = obj.optString("downloadId", null)

        when (eventType) {
            SoulseekEvents.BRIDGE_CLIENT_STATE_CHANGED,
            SoulseekEvents.BRIDGE_DISCONNECTED -> {
                val rawState = obj.optString("state", null)
                val state = BridgeStateMapper.mapConnectionState(rawState)
                connectionState = state
                eventSink(
                    SoulseekConnectionEvent(
                        state = state,
                        message = obj.optString("message", null).takeUnless { it.isNullOrEmpty() }
                    ).toJson().toString()
                )
            }

            SoulseekEvents.BRIDGE_TRANSFER_PROGRESS -> {
                val ctx = transfers[downloadId] ?: return
                ctx.bytesReceived = obj.optLong("bytesReceived", ctx.bytesReceived)
                ctx.bytesPerSecond = obj.optLong("bytesPerSecond", 0L)
                val totalBytes = obj.optLong("totalBytes", ctx.sizeBytes)
                if (totalBytes > 0) ctx.sizeBytes = totalBytes

                // Throttle БД-checkpoint (не чаще раза в секунду).
                val now = System.currentTimeMillis()
                if (now - ctx.lastCheckpointAt >= CHECKPOINT_THROTTLE_MS) {
                    ctx.lastCheckpointAt = now
                    database.updateTransferProgress(ctx.downloadId, ctx.state.name, ctx.bytesReceived)
                }
                // Throttle notification-обновления.
                if (now - ctx.lastNotificationAt >= NOTIFICATION_THROTTLE_MS) {
                    ctx.lastNotificationAt = now
                    onActiveTransfersChanged()
                }
                emitTransferEvent(ctx)
            }

            SoulseekEvents.BRIDGE_TRANSFER_STATE_CHANGED -> {
                val ctx = transfers[downloadId] ?: return
                val mapped = BridgeStateMapper.mapTransferState(obj.optString("state", null))
                if (!mapped.isTerminal) {
                    ctx.state = mapped
                    ctx.bytesReceived = obj.optLong("bytesReceived", ctx.bytesReceived)
                    emitTransferEvent(ctx)
                }
                // Терминальные не-Failed состояния прилетят отдельным
                // downloadComplete/downloadFailed событием.
            }

            SoulseekEvents.BRIDGE_DOWNLOAD_COMPLETE -> {
                val ctx = transfers[downloadId] ?: return
                val localPath = obj.optString("localPath", null)
                val bytes = obj.optLong("bytesReceived", ctx.bytesReceived)
                val total = obj.optLong("totalBytes", ctx.sizeBytes)
                ctx.bytesReceived = bytes
                if (total > 0) ctx.sizeBytes = total
                ctx.localPath = localPath
                ctx.state = TransferState.COMPLETED
                ctx.bytesPerSecond = 0L

                // Регистрируем завершённый файл в кэше.
                val finalFile = cacheManager.completeTransfer(ctx.cacheKey, ctx.fileExtension)
                if (finalFile != null) ctx.localPath = finalFile.absolutePath

                emitTransferEvent(ctx)
                persistTransfer(ctx)
                cleanupMappings(ctx)
                onActiveTransfersChanged()
            }

            SoulseekEvents.BRIDGE_DOWNLOAD_FAILED -> {
                val ctx = transfers[downloadId] ?: return
                val errorCode = obj.optString("errorCode", null)
                val retryable = obj.optBoolean("retryable", false)
                ctx.state = TransferState.FAILED
                emitTransferEvent(
                    ctx.downloadId, TransferState.FAILED, ctx.bytesReceived, ctx.sizeBytes,
                    errorCode = errorCode, retryable = retryable,
                    message = obj.optString("message", null).takeUnless { it.isNullOrEmpty() }
                        ?: obj.optString("exceptionMessage", null).takeUnless { it.isNullOrEmpty() }
                )
                persistTransfer(ctx)
                cleanupMappings(ctx)
                onActiveTransfersChanged()
            }

            else -> {
                Log.w(TAG, "Unknown bridge event type: $eventType")
            }
        }
    }

    // ───────────────────────────────────────────────────────────────────
    //  Restore / Persist / Shutdown
    // ───────────────────────────────────────────────────────────────────

    /**
     * Восстановление после перезапуска сервиса: читает незавершённые transfers
     * из БД, проверяет .part файлы. Ничего не запускает автоматически —
     * Flutter-сторона решит, что resume (Фаза 3).
     */
    fun restoreFromDatabase() {
        val unfinished = database.getUnfinishedTransfers()
        for (row in unfinished) {
            val hasPart = cacheManager.getPartFile(row.cacheKey) != null
            val state = if (hasPart) TransferState.PAUSED else TransferState.FAILED
            val ctx = TransferContext(
                downloadId = row.downloadId,
                cacheKey = row.cacheKey,
                peerUsername = row.peerUsername,
                remoteFilename = row.remoteFilename,
                sizeBytes = row.sizeBytes,
                fileExtension = row.fileExtension ?: "dat",
                state = state,
                bytesReceived = if (hasPart) {
                    cacheManager.getPartFile(row.cacheKey)?.length() ?: 0L
                } else 0L,
                localPath = row.localPath,
                retryCount = row.retryCount
            )
            transfers[row.downloadId] = ctx
            cacheKeyToDownloadId[row.cacheKey] = row.downloadId
            database.updateTransferProgress(row.downloadId, state.name, ctx.bytesReceived)
        }
        if (unfinished.isNotEmpty()) {
            Log.i(TAG, "Restored ${unfinished.size} unfinished transfers from database")
        }
    }

    /** Сохраняет checkpoint всех активных трансферов (onTaskRemoved / onDestroy). */
    fun saveCheckpoints() {
        for (ctx in transfers.values) {
            if (!ctx.state.isTerminal) {
                checkpointFromPartFile(ctx)
            }
            persistTransfer(ctx)
        }
    }

    /** Отмена всех активных трансферов (без удаления .part — для restore). */
    fun cancelAllForShutdown() {
        shutdown = true
        for (ctx in transfers.values) {
            if (!ctx.state.isTerminal) {
                cancelBridgeTransfer(ctx.downloadId)
                checkpointFromPartFile(ctx)
                ctx.state = TransferState.PAUSED
                persistTransfer(ctx)
            }
        }
        scope.cancel()
    }

    private fun persistTransfer(ctx: TransferContext) {
        runCatching {
            database.upsertTransfer(
                SoulseekDatabase.TransferRow(
                    downloadId = ctx.downloadId,
                    cacheKey = ctx.cacheKey,
                    peerUsername = ctx.peerUsername,
                    remoteFilename = ctx.remoteFilename,
                    sizeBytes = ctx.sizeBytes,
                    state = ctx.state.name,
                    bytesReceived = ctx.bytesReceived,
                    localPath = ctx.localPath,
                    fileExtension = ctx.fileExtension,
                    retryCount = ctx.retryCount,
                    createdAt = 0L, // upsertTransfer подставит now при createdAt=0
                    updatedAt = 0L
                )
            )
        }.onFailure { Log.w(TAG, "persistTransfer failed: ${it.message}") }
    }

    /** Актуализирует bytesReceived по фактическому размеру .part файла. */
    private fun checkpointFromPartFile(ctx: TransferContext) {
        cacheManager.getPartFile(ctx.cacheKey)?.let { partFile ->
            ctx.bytesReceived = partFile.length()
        }
    }

    private fun cancelBridgeTransfer(downloadId: String) {
        // cancelTransferSync на C# делает JsonSerializer.Deserialize<string>(transferId).
        // Ожидается JSON-строка в кавычках: "abc" → Deserialize вернёт "abc".
        // JSONObject.quote экранирует и оборачивает в двойные кавычки.
        val jsonId = JSONObject.quote(downloadId)
        runCatching {
            bridge.cancelTransferAsync(jsonId)
        }.onFailure { Log.w(TAG, "cancelBridgeTransfer failed: ${it.message}") }
    }

    private fun cleanupMappings(ctx: TransferContext) {
        cacheKeyToDownloadId.remove(ctx.cacheKey, ctx.downloadId)
    }

    // ───────────────────────────────────────────────────────────────────
    //  Events
    // ───────────────────────────────────────────────────────────────────

    private fun emitTransferEvent(
        downloadId: String,
        state: TransferState,
        bytesReceived: Long,
        totalBytes: Long,
        bytesPerSecond: Long = 0L,
        localPath: String? = null,
        errorCode: String? = null,
        retryable: Boolean = false,
        message: String? = null
    ) {
        eventSink(
            SoulseekTransferEvent(
                downloadId = downloadId,
                state = state,
                bytesReceived = bytesReceived,
                totalBytes = totalBytes,
                bytesPerSecond = bytesPerSecond,
                localPath = localPath,
                errorCode = errorCode,
                retryable = retryable,
                message = message
            ).toJson().toString()
        )
    }

    private fun emitTransferEvent(ctx: TransferContext) {
        emitTransferEvent(
            downloadId = ctx.downloadId,
            state = ctx.state,
            bytesReceived = ctx.bytesReceived,
            totalBytes = ctx.sizeBytes,
            bytesPerSecond = ctx.bytesPerSecond,
            localPath = ctx.localPath
        )
    }

    private fun TransferContext.toEvent() = SoulseekTransferEvent(
        downloadId = downloadId,
        state = state,
        bytesReceived = bytesReceived,
        totalBytes = sizeBytes,
        bytesPerSecond = bytesPerSecond,
        localPath = localPath
    )

    private fun notFound(downloadId: String) = SoulseekServiceException(
        "TRANSFER_NOT_FOUND",
        "Transfer $downloadId not found",
        retryable = false
    )

    // Путь к директории кэша передаётся в C# как localDirectory.
    private val cacheDirectoryPath: String
        get() = cacheManager.cacheDirAbsolutePath
}
