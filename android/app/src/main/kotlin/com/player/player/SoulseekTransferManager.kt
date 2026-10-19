package com.player.player

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import org.json.JSONObject
import soulseek.wrapper.ISoulseekEventSink
import soulseek.wrapper.SoulseekBridge
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.min
import kotlin.random.Random

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
    private val onActiveTransfersChanged: () -> Unit = {},
    /** Дефект №1: уведомление о смене connection state — сервис по нему
     *  обновляет notification (тот же источник состояния, что и Flutter-событие). */
    private val onConnectionStateChanged: (ConnectionState) -> Unit = {},
    /** Фаза B (разрыв №3): лимит параллельных загрузок из soulseek.db
     *  (max_concurrent_downloads; синкается из Dart-настроек). Semaphore
     *  не ресайзится на лету — значение фиксируется при создании менеджера
     *  и подхватывается при следующем старте сервиса. */
    maxConcurrentDownloads: Int = DEFAULT_MAX_CONCURRENT
) {
    companion object {
        private const val TAG = "SoulseekTransferMgr"

        /** Лимит параллельных transfer (2-3, настраивается). */
        private const val DEFAULT_MAX_CONCURRENT = 3

        /** Фаза B: верхняя граница параллелизма (защита от кривых значений БД). */
        private const val MAX_CONCURRENT_CAP = 8

        /**
         * Максимальное число попыток для retryable-ошибок. 5 — повторы через
         * ~4, 8, 16 с покрывают переподключение Soulseek после обрыва сети
         * (падение/переподключение VPN — ~25–30 с), пока плеер ещё ждёт
         * прироста `.part` (stallTimeout 45 с в GrowingFileReader).
         */
        private const val MAX_RETRY_ATTEMPTS = 5

        /** Базовая задержка retry, мс (экспоненциальный backoff: base * 2^attempt). */
        private const val RETRY_BASE_DELAY_MS = 2_000L

        /** Предел задержки retry, мс (план 5.5: backoff с пределом 30 секунд). */
        private const val RETRY_MAX_DELAY_MS = 30_000L

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
        /** NEW-3: человекочитаемые метаданные из поисковой выдачи —
         *  фиксируются в cache_entries при завершении загрузки. var:
         *  загрузку без них (prefetch, restore) дополняет следующий
         *  startDownload того же файла. */
        @Volatile var title: String? = null,
        @Volatile var artist: String? = null,
        @Volatile var durationSeconds: Int? = null,
        @Volatile var state: TransferState,
        @Volatile var bytesReceived: Long = 0L,
        @Volatile var bytesPerSecond: Long = 0L,
        @Volatile var localPath: String? = null,
        @Volatile var retryCount: Int = 0,
        /** Очередь у пира (QUEUED_REMOTELY): последний опрос моста. */
        @Volatile var placeInQueue: Int? = null,
        @Volatile var queueStatus: String? = null,
        @Volatile var lastCheckpointAt: Long = 0L,
        @Volatile var lastNotificationAt: Long = 0L,
        /** Слот параллельных загрузок текущей попытки (null — вне попытки). */
        @Volatile var lease: PermitLease? = null,
        /** Управляет retry-loop корутины. */
        @Volatile var pauseRequested: Boolean = false,
        @Volatile var cancelRequested: Boolean = false,
        /** Сигнал промежуточной retryable-неудачи от bridge: выводит
         *  [awaitTerminalState], retry-loop продолжает с backoff
         *  (терминальным для Dart это не является). */
        @Volatile var retrySignal: Boolean = false,
        /** Поколение retry-loop ([processTransfer]): после resume / retry
         *  прежний цикл (ждущий слот, backoff или терминального состояния)
         *  выходит, а не запускает вторую загрузку. */
        @Volatile var loopGeneration: Int = 0
    )

    /**
     * Слот [semaphore], взятый попыткой загрузки. Пока пир держит файл в
     * своей очереди, слот отпускается ([release]) — иначе такие загрузки
     * (очередь у пира бывает многоминутной) занимают все слоты и новые
     * загрузки стоят в локальной очереди. Когда пир начинает отдавать файл,
     * слот берётся снова, если свободен ([tryReacquire]); если нет —
     * загрузка идёт сверх лимита, не прерываясь.
     */
    class PermitLease(private val semaphore: Semaphore) {
        private var held = true

        @Synchronized
        fun release() {
            if (!held) return
            held = false
            semaphore.release()
        }

        @Synchronized
        fun tryReacquire() {
            if (!held && semaphore.tryAcquire()) held = true
        }
    }

    /** Все известные трансферы (активные + paused + завершённые до перечитывания БД). */
    private val transfers = ConcurrentHashMap<String, TransferContext>()

    /** cacheKey → downloadId — объединение одновременных запросов одного файла. */
    private val cacheKeyToDownloadId = ConcurrentHashMap<String, String>()

    /** Лимит параллельных активных загрузок (клэмпится в 1…MAX_CONCURRENT_CAP). */
    private val semaphore = Semaphore(maxConcurrentDownloads.coerceIn(1, MAX_CONCURRENT_CAP))

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
        fileExtension: String,
        title: String? = null,
        artist: String? = null,
        durationSeconds: Int? = null
    ): String {
        if (shutdown) {
            throw SoulseekServiceException(
                "SERVICE_SHUTDOWN", "Transfer manager is shutting down", retryable = false
            )
        }

        // 1. Cache hit: файл уже полностью скачан.
        cacheManager.getCacheEntry(cacheKey)?.let { entry ->
            Log.i(TAG, "startDownload: cache hit for $cacheKey -> ${entry.localPath}")
            // Файл, докачанный без метаданных (prefetch), получает их сейчас.
            cacheManager.fillMissingMetadata(cacheKey, title, artist, durationSeconds)
            // Фиксируем завершённый трансфер и шлём событие немедленно.
            emitTransferEvent(
                downloadId, TransferState.COMPLETED, entry.sizeBytes, sizeBytes, 0L, entry.localPath,
                title = title ?: entry.title,
                artist = artist ?: entry.artist,
                remoteFilename = remoteFilename
            )
            return entry.localPath
        }

        // 2. Dedupe: этот cacheKey уже загружается/в очереди — тот же downloadId.
        val existingId = cacheKeyToDownloadId[cacheKey]
        if (existingId != null && transfers.containsKey(existingId)) {
            val ctx = transfers[existingId]!!
            if (!ctx.state.isTerminal) {
                Log.i(TAG, "startDownload: dedupe, joining existing transfer $existingId")
                if (ctx.title.isNullOrBlank() && !title.isNullOrBlank()) {
                    ctx.title = title
                    ctx.artist = artist
                    ctx.durationSeconds = durationSeconds
                    emitTransferEvent(ctx)
                }
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
            title = title,
            artist = artist,
            durationSeconds = durationSeconds,
            state = TransferState.QUEUED
        )
        transfers[downloadId] = ctx
        cacheKeyToDownloadId[cacheKey] = downloadId

        // Persist в БД.
        persistTransfer(ctx)

        emitTransferEvent(downloadId, TransferState.QUEUED, ctx.bytesReceived, sizeBytes)
        onActiveTransfersChanged()

        // Запуск корутины-обработчика.
        launchTransfer(ctx)

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
        ctx.retrySignal = false
        ctx.state = TransferState.QUEUED
        persistTransfer(ctx)
        emitTransferEvent(downloadId, TransferState.QUEUED, ctx.bytesReceived, ctx.sizeBytes)
        launchTransfer(ctx)
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

    /**
     * Повтор упавшей / отменённой загрузки тем же пиром и файлом: сброс
     * счётчика попыток и ошибки, затем тот же путь, что у [startDownload]
     * (слот semaphore, retry-loop). `.part`, если остался, bridge продолжит
     * с offset; после отмены он удалён — загрузка начнётся с нуля.
     *
     * false — трансфер неизвестен, не FAILED / CANCELLED, или тот же файл
     * уже качает другой трансфер.
     */
    fun retryDownload(downloadId: String): Boolean {
        if (shutdown) return false
        val ctx = transfers[downloadId] ?: return false
        if (ctx.state != TransferState.FAILED && ctx.state != TransferState.CANCELLED) return false
        // Второй трансфер того же cacheKey писал бы в тот же .part.
        val otherId = cacheKeyToDownloadId[ctx.cacheKey]
        if (otherId != null && otherId != downloadId &&
            transfers[otherId]?.state?.isTerminal == false
        ) return false

        // Файл тем временем докачан (другим трансфером того же cacheKey).
        cacheManager.getCacheEntry(ctx.cacheKey)?.let { entry ->
            ctx.state = TransferState.COMPLETED
            ctx.localPath = entry.localPath
            ctx.bytesReceived = entry.sizeBytes
            ctx.bytesPerSecond = 0L
            emitTransferEvent(ctx)
            persistTransfer(ctx)
            onActiveTransfersChanged()
            return true
        }

        ctx.pauseRequested = false
        ctx.cancelRequested = false
        ctx.retrySignal = false
        ctx.retryCount = 0
        ctx.bytesPerSecond = 0L
        ctx.localPath = null
        ctx.bytesReceived = 0L
        checkpointFromPartFile(ctx)
        ctx.state = TransferState.QUEUED
        cacheKeyToDownloadId[ctx.cacheKey] = downloadId
        persistTransfer(ctx)
        emitTransferEvent(ctx)
        onActiveTransfersChanged()
        launchTransfer(ctx)
        return true
    }

    /**
     * Убирает завершённые (COMPLETED / FAILED / CANCELLED) трансферы из
     * списка. Файлы кэша не трогает. Строки COMPLETED в БД остаются: по ним
     * кэш берёт исходное имя файла у пира (название записи без title, запрос
     * обложки), а [restoreFromDatabase] их и так не поднимает. Событий не
     * шлёт — Flutter перечитывает список после вызова. Возвращает число
     * убранных.
     */
    fun clearFinished(): Int {
        var removed = 0
        for (ctx in transfers.values.toList()) {
            if (!ctx.state.isTerminal) continue
            // Запись мог уже занять новый трансфер того же downloadId.
            if (!transfers.remove(ctx.downloadId, ctx)) continue
            cleanupMappings(ctx)
            if (ctx.state != TransferState.COMPLETED) {
                runCatching { database.deleteTransfer(ctx.downloadId) }
                    .onFailure { Log.w(TAG, "deleteTransfer failed: ${it.message}") }
            }
            removed++
        }
        return removed
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

    /**
     * Смена состояния соединения не от моста: намеренный disconnect
     * (dispose моста clientStateChanged не присылает). Как и событие моста,
     * обновляет notification и шлёт connection-событие во Flutter — иначе
     * Flutter (фильтр поиска) продолжал бы видеть CONNECTED.
     */
    fun setConnectionState(state: ConnectionState) {
        if (connectionState == state) return
        setConnectionStateInternal(state)
        eventSink(SoulseekConnectionEvent(state = state).toJson().toString())
    }

    /**
     * Единая точка смены connection state: нормализованное состояние manager'а
     * питает и Flutter-событие, и notification (через [onConnectionStateChanged]).
     * Callback срабатывает только при фактическом изменении состояния.
     */
    private fun setConnectionStateInternal(state: ConnectionState) {
        if (connectionState == state) return
        connectionState = state
        onConnectionStateChanged(state)
    }

    // ───────────────────────────────────────────────────────────────────
    //  Core: обработка трансфера (retry-loop)
    // ───────────────────────────────────────────────────────────────────

    /** Запуск retry-loop нового поколения: прежний цикл этого трансфера выйдет. */
    private fun launchTransfer(ctx: TransferContext) {
        val generation = ++ctx.loopGeneration
        scope.launch {
            processTransfer(ctx, generation)
        }
    }

    private suspend fun processTransfer(ctx: TransferContext, generation: Int) {
        fun stale() = generation != ctx.loopGeneration
        var attempt = ctx.retryCount

        while (!ctx.cancelRequested && !ctx.pauseRequested && !stale()) {
            // Ждём слот очереди.
            ctx.state = TransferState.QUEUED
            emitTransferEvent(ctx)
            semaphore.acquire()
            val lease = PermitLease(semaphore)
            ctx.lease = lease
            try {
                run attempt@{
                    if (ctx.cancelRequested || ctx.pauseRequested || stale()) return@attempt

                    ctx.state = TransferState.DOWNLOADING
                    emitTransferEvent(ctx)
                    onActiveTransfersChanged()

                    try {
                        // Новая попытка: сбрасываем сигнал прошлой промежуточной неудачи.
                        ctx.retrySignal = false

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
                        awaitTerminalState(ctx, generation)
                    } catch (e: SoulseekServiceException) {
                        if (!stale()) handleTransferFailure(ctx, e, attempt)
                        return@attempt
                    } catch (e: Exception) {
                        if (!stale()) handleTransferFailure(
                            ctx,
                            SoulseekServiceException(
                                "INTERNAL_ERROR",
                                e.message ?: "Unexpected transfer error",
                                retryable = false
                            ),
                            attempt
                        )
                        return@attempt
                    } finally {
                        onActiveTransfersChanged()
                    }
                }
            } finally {
                if (ctx.lease === lease) ctx.lease = null
                lease.release()
            }

            // Если terminal или цикл устарел (resume / retry) — выходим.
            if (ctx.state.isTerminal || stale()) break

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

            // Экспоненциальный backoff с jitter и пределом 30с перед следующей
            // попыткой. Слот semaphore при этом не удерживается (delay вне withPermit).
            val delayMs = retryDelayMs(attempt)
            Log.i(TAG, "Retrying ${ctx.downloadId} in ${delayMs}ms (attempt $attempt)")
            delay(delayMs)
        }
    }

    /**
     * Ожидает терминального состояния, пока C# качает. Периодически проверяет
     * pause/cancel флаги. Возвращает когда: state terminal, pauseRequested,
     * cancelRequested или цикл [generation] устарел (resume / retry).
     */
    private suspend fun awaitTerminalState(ctx: TransferContext, generation: Int) {
        while (!ctx.state.isTerminal && !ctx.pauseRequested && !ctx.cancelRequested &&
            !ctx.retrySignal && ctx.loopGeneration == generation
        ) {
            delay(200)
        }
    }

    /**
     * Классификация неудачи трансфера (план 5.5):
     *  - отмена пользователя — терминальная (CANCELLED);
     *  - битый файл / валидация / параметры — терминальная (retryable=false из bridge);
     *  - сетевые/временные (retryable=true) в рамках общего бюджета попыток —
     *    retry-loop продолжает с backoff; промежуточное состояние не выглядит
     *    для Dart окончательным failure.
     */
    private fun handleTransferFailure(ctx: TransferContext, e: SoulseekServiceException, attempt: Int) {
        Log.w(TAG, "Transfer ${ctx.downloadId} failed (attempt $attempt): ${e.code} — ${e.message}")

        if (ctx.cancelRequested) {
            ctx.state = TransferState.CANCELLED
            emitTransferEvent(ctx)
            persistTransfer(ctx)
            cleanupMappings(ctx)
            return
        }

        val canRetry = e.retryable &&
            attempt + 1 < MAX_RETRY_ATTEMPTS &&
            !ctx.pauseRequested

        if (canRetry) {
            ctx.state = TransferState.QUEUED
            ctx.bytesPerSecond = 0L
            emitTransferEvent(ctx)
            persistTransfer(ctx)
            return
        }

        ctx.state = TransferState.FAILED
        emitTransferEvent(
            ctx.downloadId, TransferState.FAILED, ctx.bytesReceived, ctx.sizeBytes,
            errorCode = e.code, retryable = e.retryable, message = e.message
        )
        persistTransfer(ctx)
        cleanupMappings(ctx)
    }

    /** Экспоненциальный backoff: base * 2^attempt, предел [RETRY_MAX_DELAY_MS], jitter до 10%. */
    private fun retryDelayMs(attempt: Int): Long {
        val exp = RETRY_BASE_DELAY_MS * (1L shl min(attempt, 4))
        val capped = min(exp, RETRY_MAX_DELAY_MS)
        val jitter = capped / 10L
        return capped - Random.nextLong(0, jitter + 1)
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
                setConnectionStateInternal(state)
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
                    // Сведения об очереди относятся к одному заходу в неё.
                    if (mapped != ctx.state) {
                        ctx.placeInQueue = null
                        ctx.queueStatus = null
                    }
                    // Очередь у пира слот не держит; пир начал отдавать —
                    // слот снова наш, если свободен.
                    if (mapped == TransferState.QUEUED_REMOTELY) {
                        ctx.lease?.release()
                    } else if (mapped == TransferState.DOWNLOADING) {
                        ctx.lease?.tryReacquire()
                    }
                    ctx.state = mapped
                    ctx.bytesReceived = obj.optLong("bytesReceived", ctx.bytesReceived)
                    emitTransferEvent(ctx)
                    onActiveTransfersChanged()
                }
                // Терминальные не-Failed состояния прилетят отдельным
                // downloadComplete/downloadFailed событием.
            }

            SoulseekEvents.BRIDGE_TRANSFER_QUEUE_INFO -> {
                val ctx = transfers[downloadId] ?: return
                // Опоздавший ответ: файл уже вышел из очереди пира.
                if (ctx.state != TransferState.QUEUED_REMOTELY) return
                ctx.placeInQueue = if (obj.isNull("placeInQueue")) null else obj.optInt("placeInQueue")
                ctx.queueStatus = obj.optString("queueStatus", null).takeUnless { it.isNullOrEmpty() }
                emitTransferEvent(ctx)
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

                // Регистрируем завершённый файл в кэше (NEW-3: вместе с
                // человекочитаемыми метаданными из поисковой выдачи).
                val finalFile = cacheManager.completeTransfer(
                    ctx.cacheKey,
                    ctx.fileExtension,
                    title = ctx.title,
                    artist = ctx.artist,
                    durationSeconds = ctx.durationSeconds
                )
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
                val rawState = BridgeStateMapper.mapTransferState(obj.optString("state", null))

                // Пауза: C#-передача отменена самим pauseDownload — сохраняем
                // PAUSED, не FAILED (resume продолжит с offset .part файла).
                if (ctx.pauseRequested) {
                    ctx.state = TransferState.PAUSED
                    ctx.bytesPerSecond = 0L
                    persistTransfer(ctx)
                    onActiveTransfersChanged()
                    return
                }

                // Отмена пользователя — терминальная (CANCELLED, не FAILED).
                if (ctx.cancelRequested || rawState == TransferState.CANCELLED) {
                    ctx.state = TransferState.CANCELLED
                    ctx.bytesPerSecond = 0L
                    emitTransferEvent(ctx)
                    persistTransfer(ctx)
                    cleanupMappings(ctx)
                    onActiveTransfersChanged()
                    return
                }

                // Сетевая/временная неудача в рамках бюджета попыток —
                // retry-loop продолжит с backoff. Состояние НЕ терминальное,
                // mappings сохранены (dedupe по cacheKey продолжает работать),
                // для Dart это не окончательный failure.
                val canRetry = retryable && ctx.retryCount + 1 < MAX_RETRY_ATTEMPTS
                if (canRetry) {
                    ctx.state = TransferState.QUEUED
                    ctx.bytesPerSecond = 0L
                    ctx.retrySignal = true
                    emitTransferEvent(ctx)
                    persistTransfer(ctx)
                    onActiveTransfersChanged()
                    return
                }

                // Терминальный отказ: битый файл/валидация (VALIDATION_*),
                // исчерпанный бюджет попыток, неретрайные ошибки.
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

            // Потоковые результаты поиска — во Flutter как есть (Dart разбирает
            // eventType "searchProgress" сам, состояния тут не хранится).
            SoulseekEvents.BRIDGE_SEARCH_PROGRESS -> eventSink(json)

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
        message: String? = null,
        title: String? = null,
        artist: String? = null,
        remoteFilename: String? = null
    ) {
        val ctx = transfers[downloadId]
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
                message = message,
                title = title ?: ctx?.title,
                artist = artist ?: ctx?.artist,
                remoteFilename = remoteFilename ?: ctx?.remoteFilename,
                placeInQueue = ctx?.queueInfoFor(state)?.first,
                queueStatus = ctx?.queueInfoFor(state)?.second
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
        localPath = localPath,
        title = title,
        artist = artist,
        remoteFilename = remoteFilename,
        placeInQueue = queueInfoFor(state)?.first,
        queueStatus = queueInfoFor(state)?.second
    )

    /** Сведения об очереди пира — только пока трансфер в ней стоит. */
    private fun TransferContext.queueInfoFor(eventState: TransferState): Pair<Int?, String?>? =
        if (eventState == TransferState.QUEUED_REMOTELY && state == TransferState.QUEUED_REMOTELY) {
            placeInQueue to queueStatus
        } else null

    private fun notFound(downloadId: String) = SoulseekServiceException(
        "TRANSFER_NOT_FOUND",
        "Transfer $downloadId not found",
        retryable = false
    )

    // Путь к директории кэша передаётся в C# как localDirectory.
    private val cacheDirectoryPath: String
        get() = cacheManager.cacheDirAbsolutePath
}
