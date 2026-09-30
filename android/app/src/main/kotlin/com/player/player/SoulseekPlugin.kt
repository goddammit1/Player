package com.player.player

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import soulseek.wrapper.SoulseekBridge

/**
 * Flutter Plugin — мост между Dart-стороной (Фаза 3) и нативным Soulseek-слоем.
 *
 * Каналы:
 *  - MethodChannel "soulseek/methods" — команды (connect, search, download, …).
 *  - EventChannel  "soulseek/events"  — поток событий (transfer progress, state, connection).
 *
 * Архитектура:
 *  Plugin запускает и привязывается к [SoulseekForegroundService] через
 *  [Context.bindService]. Команды перенаправляются в сервисный binder,
 *  который исполняет их в serial-executor coroutine scope.
 *
 * Восстановление состояния:
 *  При подписке на EventChannel (onListen) plugin немедленно отправляет
 *  snapshot активных трансферов (getActiveTransfers), чтобы Flutter-сторона
 *  могла восстановить UI после пересоздания Activity / холодного старта.
 *
 * Маршалинг:
 *  Dart передаёт Map<String, Any>. Plugin конвертирует в JSON-строку для
 *  вызова C# bridge-методов (они принимают JSON). Результаты парсятся из
 *  ResultDto JSON обратно в Map для Flutter.
 *
 * Обработка ошибок:
 *  При ошибке возвращается result.error(code, message, details), где details
 *  содержит {"retryable": bool}. SoulseekServiceException пробрасывается с
 *  своими code/retryable; BridgeCallResult.failure — с bridge'овым code.
 */
class SoulseekPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "SoulseekPlugin"
        private const val METHOD_CHANNEL = "soulseek/methods"
        private const val EVENT_CHANNEL = "soulseek/events"

        /** P3: максимум ожидания onServiceConnected для команд в очереди. */
        private const val PENDING_COMMAND_TIMEOUT_MS = 10_000L

        /** Дефект №3: ответ getConnectionState, когда состояние неизвестно
         *  (binder нет и bind не инициирован — сервис может работать). */
        private const val CONNECTION_STATE_UNKNOWN = "UNKNOWN"
    }

    private var applicationContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    // Scope для блокирующих C# bridge-вызовов (connect/search/configureSharing)
    // — выносим с platform thread на IO dispatcher во избежание ANR.
    // MethodChannel.Result потокобезопасен (можно вызывать из любого потока).
    private val ioScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // Service binding
    private var serviceBinder: SoulseekForegroundService.SoulseekServiceBinder? = null
    private var isBound = false

    // P3: bind уже инициирован (bindService вернул true), но onServiceConnected
    // ещё не наступил. Команды, пришедшие в этом окне, не выполняются сразу —
    // они ставятся в pendingCommands и исполняются после подключения.
    private var bindPending = false

    // EventChannel sink — установлен когда Flutter подписывается.
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    // EventSink.success помечен @UiThread — вызов из фонового потока (события
    // приходят из сервиса через Dispatchers.IO) бросает RuntimeException и
    // роняет процесс. Маршализуем все отправки на main thread.
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Отправка события в Flutter строго на main thread. */
    private fun sendEvent(json: String) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(json)
        } else {
            mainHandler.post {
                // Гонка: onCancel мог выполниться, пока post висел в очереди.
                eventSink?.success(json)
            }
        }
    }

    /**
     * Дефект №3: snapshot текущего connection state менеджера как
     * connection-событие. Connection-события приходят только при ИЗМЕНЕНИЯХ,
     * поэтому после (re)bind'а / новой подписки Flutter сам о существующем
     * соединении не узнал бы.
     */
    private fun sendConnectionSnapshot() {
        val mgr = serviceBinder?.transferManager ?: return
        sendEvent(SoulseekConnectionEvent(state = mgr.connectionState).toJson().toString())
    }

    // Pending commands, выполненные ДО того как сервис привязан.
    // startService триггерит bind; команды ждут в очереди.
    //
    // P3: очередь ограничена по времени — если onServiceConnected не наступил
    // за [PENDING_COMMAND_TIMEOUT_MS] (bind не удался, сервис умер), команды
    // завершаются retryable-ошибкой SERVICE_BIND_TIMEOUT, а не висят вечно.
    private val pendingCommands =
        mutableListOf<Triple<MethodCall, MethodChannel.Result, Long>>()
    private var pendingCommandsTimer: java.util.Timer? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            Log.i(TAG, "onServiceConnected")
            bindPending = false
            cancelPendingTimer()
            @Suppress("UNCHECKED_CAST")
            serviceBinder = service as? SoulseekForegroundService.SoulseekServiceBinder
            isBound = true

            // Устанавливаем listener для пересылки событий в EventChannel.
            serviceBinder?.setEventListener { json ->
                sendEvent(json)
            }

            // Дефект №3: сразу после установки listener отправляем snapshot
            // текущего connection state — синхронизировано с последующими
            // событиями (они пойдут через тот же listener/main-handler).
            sendConnectionSnapshot()

            // Выполняем ожидающие команды.
            executePendingCommands()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            Log.i(TAG, "onServiceDisconnected")
            serviceBinder = null
            isBound = false
        }

        override fun onBindingDied(name: ComponentName?) {
            Log.w(TAG, "onBindingDied")
            serviceBinder = null
            isBound = false
            bindPending = false
        }

        // P3: система не смогла привязаться (сервис не запустился) —
        // ожидающие команды завершаем ошибкой вместо вечного зависания.
        override fun onNullBinding(name: ComponentName?) {
            Log.w(TAG, "onNullBinding")
            bindPending = false
            isBound = false
            serviceBinder = null
            failPendingCommands(
                "SERVICE_UNAVAILABLE",
                "Failed to bind to Soulseek service"
            )
        }
    }

    // ───────────────────────────────────────────────────────────────────
    //  FlutterPlugin lifecycle
    // ───────────────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
        Log.i(TAG, "onAttachedToEngine: channels registered")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null

        // Отвязываемся от сервиса (если привязаны).
        if (isBound && applicationContext != null) {
            runCatching {
                applicationContext!!.unbindService(serviceConnection)
            }
            isBound = false
            serviceBinder = null
        }
        bindPending = false
        eventSink = null
        // Завершаем ожидающие команды — engine уничтожается, ответ некому получать.
        failPendingCommands("ENGINE_DETACHED", "Flutter engine is detached")
        cancelPendingTimer()
        // Отменяем pending bridge-корутины.
        ioScope.cancel()
        applicationContext = null
        Log.i(TAG, "onDetachedFromEngine: channels unregistered")
    }

    // ───────────────────────────────────────────────────────────────────
    //  EventChannel.StreamHandler
    // ───────────────────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        Log.i(TAG, "EventChannel onListen")
        eventSink = sink

        // P1-фикс: onCancel снимает service-listener, поэтому при каждой
        // новой подписке Flutter переустанавливаем его. Без этого после
        // цикла cancel→listen события TransferManager терялись навсегда
        // (первый resolve зависал в ожидании completed).
        serviceBinder?.setEventListener { json ->
            sendEvent(json)
        }

        // Восстановление состояния: немедленно отправляем snapshot ВСЕХ
        // трансферов (включая терминальные), чтобы Flutter видел завершённые
        // загрузки даже если их событие было доставлено до подписки.
        serviceBinder?.transferManager?.let { mgr ->
            val all = mgr.getAllTransfers()
            if (all.isNotEmpty()) {
                val snapshot = SoulseekEvents.snapshotJson(all).toString()
                sendEvent(snapshot)
            }
        }

        // Дефект №3: snapshot и connection state, если binder уже есть, —
        // повторная подписка сразу видит актуальный статус соединения,
        // не ожидая следующего события изменения.
        sendConnectionSnapshot()
    }

    override fun onCancel(arguments: Any?) {
        Log.i(TAG, "EventChannel onCancel")
        eventSink = null
        // Снимаем listener в сервисе (onListen установит заново).
        serviceBinder?.setEventListener(null)
    }

    // ───────────────────────────────────────────────────────────────────
    //  MethodCallHandler
    // ───────────────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Фаза B (разрыв №3): синк настроек не должен поднимать foreground
        // service (общий путь ниже при отсутствии binder запускает его).
        // Обрабатываем ранней веткой — пишем в soulseek.db напрямую.
        if (call.method == "updateNativeSettings") {
            handleUpdateNativeSettings(call, result)
            return
        }
        // Дефект №3: отсутствие binder у нового экземпляра плагина не
        // доказывает отсутствия соединения — foreground service может
        // продолжать работать (пересоздание Flutter engine). Если bind уже
        // инициирован, команда ниже встанет в pending-очередь и получит
        // реальное состояние после onServiceConnected. Если привязки нет
        // вовсе — отдаём UNKNOWN: Dart трактует его как unknown и не
        // перезаписывает локальный статус ложным DISCONNECTED.
        if (call.method == "getConnectionState" && serviceBinder == null && !bindPending) {
            result.success(CONNECTION_STATE_UNKNOWN)
            return
        }
        // P3: bind инициирован, но binder ещё не доставлен (окно между
        // bindService(true) и onServiceConnected). Раньше такие команды
        // падали с NOT_CONNECTED "Service not bound" без retryable — теперь
        // они встают в очередь и исполняются сразу после подключения binder'а.
        if (bindPending && serviceBinder == null && call.method != "startService") {
            queuePendingCommand(call, result)
            return
        }
        if (!isBound && call.method != "startService") {
            if (serviceBinder == null) {
                // Сервис не запускался — запускаем и ставим команду в очередь,
                // выполнится после onServiceConnected.
                queuePendingCommand(call, result)
                ensureServiceStarted()
                return
            }
        }
        handleMethodCall(call, result)
    }

    // ───────────────────────────────────────────────────────────────────
    //  Pending commands queue (P3)
    // ───────────────────────────────────────────────────────────────────

    /** Ставит команду в очередь ожидания bind'а и запускает таймаут-таймер. */
    private fun queuePendingCommand(call: MethodCall, result: MethodChannel.Result) {
        // onMethodCall и onServiceConnected оба исполняются на main thread.
        // Раньше команда добавлялась через mainHandler.post — если сообщение
        // onServiceConnected уже стояло в очереди looper'а раньше этого post,
        // оно выполнялось первым, дренировало ПУСТУЮ очередь, и команда
        // (connect) зависала до SERVICE_BIND_TIMEOUT. Добавляем синхронно;
        // если binder успел подключиться — исполняем сразу.
        val enqueue = {
            if (serviceBinder != null) {
                handleMethodCall(call, result)
            } else {
                pendingCommands.add(Triple(call, result, System.currentTimeMillis()))
                schedulePendingTimer()
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) enqueue() else mainHandler.post { enqueue() }
    }

    /** Периодически проверяет очередь: зависшие команды завершаются ошибкой. */
    private fun schedulePendingTimer() {
        pendingCommandsTimer?.cancel()
        val timer = java.util.Timer("SoulseekPendingCommands", true)
        pendingCommandsTimer = timer
        timer.schedule(
            object : java.util.TimerTask() {
                override fun run() {
                    mainHandler.post { expirePendingCommands() }
                }
            },
            PENDING_COMMAND_TIMEOUT_MS
        )
    }

    private fun cancelPendingTimer() {
        pendingCommandsTimer?.cancel()
        pendingCommandsTimer = null
    }

    /** Завершает команды, ожидающие дольше [PENDING_COMMAND_TIMEOUT_MS]. */
    private fun expirePendingCommands() {
        if (pendingCommands.isEmpty()) return
        val now = System.currentTimeMillis()
        val expired = pendingCommands.filter { now - it.third >= PENDING_COMMAND_TIMEOUT_MS }
        if (expired.isEmpty()) return
        pendingCommands.removeAll(expired)
        cancelPendingTimer()
        for ((_, result, _) in expired) {
            result.error(
                "SERVICE_BIND_TIMEOUT",
                "Soulseek service did not bind within ${PENDING_COMMAND_TIMEOUT_MS / 1000}s",
                mapOf("retryable" to true)
            )
        }
        // Если остались живые команды — перепланируем таймер на ближайшую.
        if (pendingCommands.isNotEmpty()) schedulePendingTimer()
    }

    /** Исполняет все отложенные команды (вызывается из onServiceConnected). */
    private fun executePendingCommands() {
        if (pendingCommands.isEmpty()) return
        val pending = ArrayList(pendingCommands)
        pendingCommands.clear()
        cancelPendingTimer()
        for ((call, result, _) in pending) {
            handleMethodCall(call, result)
        }
    }

    /** Завершает все отложенные команды ошибкой (onNullBinding / detach). */
    private fun failPendingCommands(code: String, message: String) {
        mainHandler.post {
            if (pendingCommands.isEmpty()) return@post
            val pending = ArrayList(pendingCommands)
            pendingCommands.clear()
            cancelPendingTimer()
            for ((_, result, _) in pending) {
                result.error(code, message, mapOf("retryable" to true))
            }
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = applicationContext ?: run {
            result.error("NO_CONTEXT", "Application context is null", null)
            return
        }

        try {
            when (call.method) {
                "startService" -> {
                    ensureServiceStarted()
                    result.success(true)
                }

                "stopService" -> {
                    stopServiceCompletely()
                    result.success(true)
                }

                "configureAccount" -> {
                    val json = buildAccountJson(call.argument<Map<String, Any>>("account"))
                    val bridge = serviceBinder?.bridge
                    if (bridge == null) {
                        result.error("NOT_CONNECTED", "Service not bound", null)
                        return
                    }
                    // Account конфигурация — не отдельный bridge-метод;
                    // сохраняем в БД и используем при connect.
                    val db = serviceBinder?.database
                    val account = call.argument<Map<String, Any>>("account") ?: emptyMap()
                    db?.putSetting(SettingsKeys.USERNAME, account["username"] as? String ?: "")
                    db?.putSettingInt(SettingsKeys.LISTEN_PORT, (account["listenPort"] as? Number)?.toInt() ?: 24150)
                    result.success(true)
                }

                "connect" -> {
                    val bridge = serviceBinder?.bridge
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val account = call.argument<Map<String, Any>>("account")
                        ?: run { result.error("INVALID_ARGS", "account is required", null); return }
                    val json = buildAccountJson(account)
                    // connectAsync блокирует до завершения login (секунды) —
                    // выполняем на IO dispatcher, result вызываем по завершении.
                    ioScope.launch {
                        val res = BridgeCallResult.parse(runCatching { bridge.connectAsync(json) }
                            .getOrElse { e ->
                                "{\"success\":false,\"errorCode\":\"JNI_ERROR\",\"errorMessage\":\"${e.message?.replace("\"", "'")}\"}"
                            })
                        replyBridgeResult(result, res) { data ->
                            // data = {"username":"...","state":"..."} — разворачиваем в Map.
                            JsonInterop.toStandard(JSONObject(data)) as Map<String, Any?>
                        }
                    }
                }

                "disconnect" -> {
                    val bridge = serviceBinder?.bridge
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    // Bridge не имеет отдельного disconnect; dispose() отменяет
                    // загрузки и освобождает клиент. Новый connect создаст новый клиент.
                    ioScope.launch {
                        runCatching { bridge.dispose() }
                        result.success(true)
                    }
                }

                "search" -> {
                    val bridge = serviceBinder?.bridge
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val json = buildSearchJson(call)
                    // searchAsync блокирует до завершения поиска (не дольше
                    // общего бюджета timeoutMs) — выполняем на IO dispatcher.
                    ioScope.launch {
                        val res = BridgeCallResult.parse(runCatching { bridge.searchAsync(json) }
                            .getOrElse { e ->
                                "{\"success\":false,\"errorCode\":\"JNI_ERROR\",\"errorMessage\":\"${e.message?.replace("\"", "'")}\"}"
                            })
                        replyBridgeResult(result, res) { data ->
                            // data — JSON-массив SearchResultDto; разворачиваем в List<Map>.
                            val arr = JSONArray(data)
                            val list = ArrayList<Map<String, Any?>>(arr.length())
                            for (i in 0 until arr.length()) {
                                list.add(JsonInterop.toStandard(arr.getJSONObject(i)) as Map<String, Any?>)
                            }
                            list
                        }
                    }
                }

                "startDownload" -> {
                    val mgr = serviceBinder?.transferManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val downloadId = call.argument<String>("downloadId")
                        ?: run { result.error("INVALID_ARGS", "downloadId is required", null); return }
                    val peerUsername = call.argument<String>("peerUsername")
                        ?: run { result.error("INVALID_ARGS", "peerUsername is required", null); return }
                    val remoteFilename = call.argument<String>("remoteFilename")
                        ?: run { result.error("INVALID_ARGS", "remoteFilename is required", null); return }
                    val sizeBytes = (call.argument<Number>("sizeBytes")?.toLong() ?: 0L)
                    val cacheKey = call.argument<String>("cacheKey")
                        ?: run { result.error("INVALID_ARGS", "cacheKey is required", null); return }
                    val fileExtension = call.argument<String>("fileExtension") ?: "dat"
                    // NEW-3: метаданные для человекочитаемого кэш-листа.
                    val title = call.argument<String>("title")
                    val artist = call.argument<String>("artist")
                    val durationSeconds = call.argument<Number>("durationSeconds")?.toInt()

                    // Acquire locks для активной передачи.
                    serviceBinder?.acquireLocks()

                    val ret = mgr.startDownload(
                        downloadId = downloadId,
                        peerUsername = peerUsername,
                        remoteFilename = remoteFilename,
                        sizeBytes = sizeBytes,
                        cacheKey = cacheKey,
                        fileExtension = fileExtension,
                        title = title,
                        artist = artist,
                        durationSeconds = durationSeconds
                    )
                    // ret может быть путём (cache hit) или downloadId.
                    val map = mapOf(
                        "downloadId" to downloadId,
                        "result" to ret,
                        "cacheHit" to (ret != downloadId)
                    )
                    result.success(map)
                }

                "pauseDownload" -> {
                    val mgr = serviceBinder?.transferManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val downloadId = call.argument<String>("downloadId")
                        ?: run { result.error("INVALID_ARGS", "downloadId is required", null); return }
                    serviceBinder?.executeCommandBlocking { mgr.pauseDownload(downloadId) }
                    releaseLocksIfIdle()
                    result.success(true)
                }

                "resumeDownload" -> {
                    val mgr = serviceBinder?.transferManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val downloadId = call.argument<String>("downloadId")
                        ?: run { result.error("INVALID_ARGS", "downloadId is required", null); return }
                    serviceBinder?.acquireLocks()
                    serviceBinder?.executeCommandBlocking { mgr.resumeDownload(downloadId) }
                    result.success(true)
                }

                "cancelDownload" -> {
                    val mgr = serviceBinder?.transferManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val downloadId = call.argument<String>("downloadId")
                        ?: run { result.error("INVALID_ARGS", "downloadId is required", null); return }
                    serviceBinder?.executeCommandBlocking { mgr.cancelDownload(downloadId) }
                    releaseLocksIfIdle()
                    result.success(true)
                }

                "removeCache" -> {
                    val cache = serviceBinder?.cacheManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val cacheKey = call.argument<String>("cacheKey")
                        ?: run { result.error("INVALID_ARGS", "cacheKey is required", null); return }
                    val removed = cache.removeCache(cacheKey)
                    result.success(removed)
                }

                "getTransfer" -> {
                    val mgr = serviceBinder?.transferManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val downloadId = call.argument<String>("downloadId")
                        ?: run { result.error("INVALID_ARGS", "downloadId is required", null); return }
                    val ev = mgr.getTransfer(downloadId)
                    result.success(ev?.let { JsonInterop.toStandard(it.toJson()) })
                }

                "getCacheEntry" -> {
                    val cache = serviceBinder?.cacheManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val cacheKey = call.argument<String>("cacheKey")
                        ?: run { result.error("INVALID_ARGS", "cacheKey is required", null); return }
                    val entry = cache.getCacheEntry(cacheKey)
                    result.success(entry?.let { mapCacheEntry(it) })
                }

                "setSharingDirectory" -> {
                    // Sharing directory настраивается через configureSharing bridge-метод.
                    val bridge = serviceBinder?.bridge
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val json = buildSharingJson(call)
                    // configureSharingAsync блокирует (ReconfigureOptionsAsync) — на IO.
                    ioScope.launch {
                        val res = BridgeCallResult.parse(
                            runCatching { bridge.configureSharingAsync(json) }
                                .getOrElse { e ->
                                    "{\"success\":false,\"errorCode\":\"JNI_ERROR\",\"errorMessage\":\"${e.message?.replace("\"", "'")}\"}"
                                }
                        )
                        replyBridgeResult(result, res) { true }
                    }
                }

                "getActiveTransfers" -> {
                    val mgr = serviceBinder?.transferManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val all = call.argument<Boolean>("includeTerminal") ?: false
                    val list = if (all) mgr.getAllTransfers() else mgr.getActiveTransfers()
                    val mapped = list.map { JsonInterop.toStandard(it.toJson()) as Map<String, Any?> }
                    result.success(mapped)
                }

                "pinCache" -> {
                    val cache = serviceBinder?.cacheManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val cacheKey = call.argument<String>("cacheKey")
                        ?: run { result.error("INVALID_ARGS", "cacheKey is required", null); return }
                    val pinned = call.argument<Boolean>("pinned") ?: true
                    cache.pin(cacheKey, pinned)
                    result.success(true)
                }

                "cleanupCache" -> {
                    val cache = serviceBinder?.cacheManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val removed = cache.cleanup()
                    result.success(removed)
                }

                // P1-каскад: полный список кэш-записей из нативной БД,
                // чтобы Flutter не зависел от Dart-индекса knownCacheKeys.
                "getCacheEntries" -> {
                    val cache = serviceBinder?.cacheManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    val entries = cache.getAllCacheEntries()
                    result.success(entries.map { mapCacheEntry(it) })
                }

                // P2: актуальный статус коннекта при (повторном) входе на
                // страницу настроек — без ожидания нового connection-события.
                "getConnectionState" -> {
                    val mgr = serviceBinder?.transferManager
                        ?: run { result.error("NOT_CONNECTED", "Service not bound", null); return }
                    result.success(mgr.connectionState.name)
                }

                else -> result.notImplemented()
            }
        } catch (e: SoulseekServiceException) {
            result.error(e.code, e.message, mapOf("retryable" to e.retryable))
        } catch (e: Exception) {
            Log.e(TAG, "handleMethodCall error for ${call.method}", e)
            result.error("INTERNAL_ERROR", e.message, null)
        }
    }

    // ───────────────────────────────────────────────────────────────────
    //  Settings sync (Фаза B, разрыв №3)
    // ───────────────────────────────────────────────────────────────────

    /**
     * Фаза B (разрыв №3): синк настроек из Dart-БД в нативную soulseek.db.
     *
     * Вызывается ранней веткой [onMethodCall] — НЕ запускает foreground
     * service: Dart зовёт синк на старте приложения, когда сервис ещё не
     * нужен. Если сервис уже привязан — пишем через его БД и применяем
     * лимит кэша на лету; иначе открываем собственный SQLiteOpenHelper
     * (тот же файл soulseek.db) и закрываем после записи.
     *
     * Единицы: cacheLimitMb приходит в мегабайтах, soulseek.db хранит
     * max_cache_size в БАЙТАХ (см. сид в SoulseekDatabase.onCreate) —
     * конвертация MB × 1024 × 1024; 0 = unlimited (cleanup трактует
     * <= 0 как отсутствие лимита).
     */
    private fun handleUpdateNativeSettings(call: MethodCall, result: MethodChannel.Result) {
        val ctx = applicationContext ?: run {
            result.error("NO_CONTEXT", "Application context is null", null)
            return
        }
        ioScope.launch {
            try {
                val listenPort = call.argument<Number>("listenPort")?.toInt()
                val cacheLimitMb = call.argument<Number>("cacheLimitMb")?.toInt()
                val maxParallel = call.argument<Number>("maxParallelDownloads")?.toInt()
                val username = call.argument<String>("username")

                val boundDb = serviceBinder?.database
                val db = boundDb ?: SoulseekDatabase(ctx)
                try {
                    listenPort?.let { db.putSettingInt(SettingsKeys.LISTEN_PORT, it) }
                    cacheLimitMb?.let {
                        db.putSettingLong(
                            SettingsKeys.MAX_CACHE_SIZE,
                            it.toLong() * 1024L * 1024L
                        )
                    }
                    maxParallel?.let {
                        db.putSettingInt(SettingsKeys.MAX_CONCURRENT_DOWNLOADS, it)
                    }
                    username?.takeIf { it.isNotEmpty() }?.let {
                        db.putSetting(SettingsKeys.USERNAME, it)
                    }

                    // Живой сервис: применяем лимит кэша немедленно (LRU
                    // eviction при снижении лимита). Параллелизм (Semaphore)
                    // не ресайзится на лету — подхватится при следующем
                    // старте сервиса из soulseek.db.
                    if (boundDb != null) {
                        cacheLimitMb?.let {
                            serviceBinder?.cacheManager
                                ?.updateMaxCacheSizeBytes(it.toLong() * 1024L * 1024L)
                        }
                    }
                } finally {
                    if (boundDb == null) db.close()
                }
                result.success(true)
            } catch (e: Exception) {
                // Best-effort: Dart-сторона сохраняет значения в своей БД
                // независимо; ошибка синка не должна ломать UI.
                Log.e(TAG, "updateNativeSettings failed", e)
                result.success(false)
            }
        }
    }

    // ───────────────────────────────────────────────────────────────────
    //  Cache entry mapping
    // ───────────────────────────────────────────────────────────────────

    /**
     * CacheEntryRow → MethodChannel Map. Этап 2.3 серии 02: пробрасывает
     * `extension` (колонка есть в БД v2, но раньше не доезжала до Dart) —
     * нужно для метки качества кэш-треков («FLAC»/«MP3») в
     * SoulseekSource.trackFromCacheEntry.
     */
    private fun mapCacheEntry(it: SoulseekCacheManager.CacheEntry): Map<String, Any?> =
        mapOf(
            "cacheKey" to it.cacheKey,
            "localPath" to it.localPath,
            "sizeBytes" to it.sizeBytes,
            "complete" to it.complete,
            "pinned" to it.pinned,
            "title" to it.title,
            "artist" to it.artist,
            "durationSeconds" to it.durationSeconds,
            "extension" to it.extension
        )

    // ───────────────────────────────────────────────────────────────────
    //  Service start / stop
    // ───────────────────────────────────────────────────────────────────

    private fun ensureServiceStarted() {
        val ctx = applicationContext ?: return
        // Запускаем foreground service.
        val startIntent = Intent(ctx, SoulseekForegroundService::class.java).apply {
            putExtra(SoulseekForegroundService.EXTRA_COMMAND, SoulseekForegroundService.COMMAND_START)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ctx.startForegroundService(startIntent)
        } else {
            ctx.startService(startIntent)
        }
        // Привязываемся (если ещё не привязаны).
        if (!isBound && !bindPending) {
            val bindIntent = Intent(ctx, SoulseekForegroundService::class.java)
            val ok = ctx.bindService(
                bindIntent, serviceConnection, Context.BIND_AUTO_CREATE
            )
            isBound = ok
            // P3: bindService=true означает лишь, что запрос принят — binder
            // придёт асинхронно через onServiceConnected. Помечаем окно
            // ожидания, чтобы команды этого интервала становились в очередь,
            // а не падали «Service not bound».
            bindPending = ok
            Log.i(TAG, "bindService result: $ok (pending=$bindPending)")
        }
    }

    private fun stopServiceCompletely() {
        val ctx = applicationContext ?: return
        if (isBound) {
            runCatching { ctx.unbindService(serviceConnection) }
            isBound = false
            serviceBinder = null
        }
        bindPending = false
        val stopIntent = Intent(ctx, SoulseekForegroundService::class.java).apply {
            putExtra(SoulseekForegroundService.EXTRA_COMMAND, SoulseekForegroundService.COMMAND_STOP)
        }
        ctx.stopService(stopIntent)
    }

    // ───────────────────────────────────────────────────────────────────
    //  Lock management helpers
    // ───────────────────────────────────────────────────────────────────

    private fun releaseLocksIfIdle() {
        val mgr = serviceBinder?.transferManager ?: return
        if (mgr.getActiveTransfers().none { it.state.isActive }) {
            serviceBinder?.releaseLocks()
        }
    }

    // ───────────────────────────────────────────────────────────────────
    //  JSON marshalling — Map<String, Any> → JSON string для C# bridge
    // ───────────────────────────────────────────────────────────────────

    private fun buildAccountJson(account: Map<String, Any>?): String {
        val obj = JSONObject()
        if (account != null) {
            obj.put("username", account["username"] ?: JSONObject.NULL)
            obj.put("password", account["password"] ?: JSONObject.NULL)
            obj.put("listenPort", (account["listenPort"] as? Number)?.toInt() ?: 50000)
            obj.put("enableListener", account["enableListener"] as? Boolean ?: true)
            obj.put("messageTimeoutMs", (account["messageTimeoutMs"] as? Number)?.toInt() ?: 30000)
        }
        return obj.toString()
    }

    private fun buildSearchJson(call: MethodCall): String {
        val obj = JSONObject()
        obj.put("requestId", call.argument<String>("requestId") ?: "")
        obj.put("query", call.argument<String>("query") ?: "")
        obj.put("timeoutMs", (call.argument<Number>("timeoutMs")?.toInt() ?: 10000))
        obj.put("idleTimeoutMs", (call.argument<Number>("idleTimeoutMs")?.toInt() ?: 2500))
        obj.put("responseLimit", (call.argument<Number>("responseLimit")?.toInt() ?: 100))
        obj.put("fileLimit", (call.argument<Number>("fileLimit")?.toInt() ?: 200))

        val filters = call.argument<Map<String, Any>>("filters")
        val filtersObj = JSONObject()
        if (filters != null) {
            // extensions: List<String>
            (filters["extensions"] as? List<*>)?.let { exts ->
                val arr = JSONArray()
                exts.forEach { arr.put(it.toString()) }
                filtersObj.put("extensions", arr)
            }
            (filters["minSizeBytes"] as? Number)?.let { filtersObj.put("minSizeBytes", it.toLong()) }
            (filters["maxSizeBytes"] as? Number)?.let { filtersObj.put("maxSizeBytes", it.toLong()) }
            (filters["minBitrate"] as? Number)?.let { filtersObj.put("minBitrate", it.toInt()) }
            filtersObj.put("losslessOnly", filters["losslessOnly"] as? Boolean ?: false)
            (filters["minPeerUploadSpeed"] as? Number)?.let { filtersObj.put("minPeerUploadSpeed", it.toInt()) }
            (filters["maxPeerQueueLength"] as? Number)?.let { filtersObj.put("maxPeerQueueLength", it.toInt()) }
        }
        obj.put("filters", filtersObj)
        return obj.toString()
    }

    private fun buildSharingJson(call: MethodCall): String {
        val obj = JSONObject()
        call.argument<Boolean>("enableListener")?.let { obj.put("enableListener", it) }
        call.argument<Int>("listenPort")?.let { obj.put("listenPort", it) }
        call.argument<Int>("maximumUploadSpeed")?.let { obj.put("maximumUploadSpeed", it) }
        call.argument<Int>("maximumDownloadSpeed")?.let { obj.put("maximumDownloadSpeed", it) }
        return obj.toString()
    }

    // ───────────────────────────────────────────────────────────────────
    //  Bridge result → MethodChannel result
    // ───────────────────────────────────────────────────────────────────

    /**
     * Формирует MethodChannel.Result из BridgeCallResult.
     * success → result.success(transform(data))
     * failure → result.error(code, message, {"retryable": retryable})
     */
    private inline fun <T> replyBridgeResult(
        result: MethodChannel.Result,
        res: BridgeCallResult,
        crossinline transform: (String) -> T
    ) {
        if (res.success) {
            val payload: Any? = if (res.data.isNullOrEmpty()) {
                true
            } else {
                runCatching { transform(res.data) }.getOrDefault(true)
            }
            result.success(payload)
        } else {
            result.error(
                res.errorCode ?: "BRIDGE_ERROR",
                res.errorMessage ?: "Unknown bridge error",
                mapOf("retryable" to res.retryable)
            )
        }
    }
}
