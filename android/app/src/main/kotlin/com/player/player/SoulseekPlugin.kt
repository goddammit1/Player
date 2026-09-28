package com.player.player

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.IBinder
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

    // EventChannel sink — установлен когда Flutter подписывается.
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    // Pending commands, выполненные ДО того как сервис привязался.
    // startService триггерит bind; команды ждут в очереди.
    private val pendingCommands = mutableListOf<Pair<MethodCall, MethodChannel.Result>>()

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            Log.i(TAG, "onServiceConnected")
            @Suppress("UNCHECKED_CAST")
            serviceBinder = service as? SoulseekForegroundService.SoulseekServiceBinder
            isBound = true

            // Устанавливаем listener для пересылки событий в EventChannel.
            serviceBinder?.setEventListener { json ->
                eventSink?.success(json)
            }

            // Выполняем ожидающие команды.
            val pending = ArrayList(pendingCommands)
            pendingCommands.clear()
            for ((call, result) in pending) {
                handleMethodCall(call, result)
            }
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
        eventSink = null
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

        // Восстановление состояния: немедленно отправляем snapshot активных
        // трансферов, чтобы Flutter восстановил UI после переподключения.
        serviceBinder?.transferManager?.let { mgr ->
            val active = mgr.getActiveTransfers()
            if (active.isNotEmpty()) {
                val snapshot = SoulseekEvents.snapshotJson(active).toString()
                sink?.success(snapshot)
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        Log.i(TAG, "EventChannel onCancel")
        eventSink = null
        // Снимаем listener в сервисе.
        serviceBinder?.setEventListener(null)
    }

    // ───────────────────────────────────────────────────────────────────
    //  MethodCallHandler
    // ───────────────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!isBound && call.method != "startService") {
            // Сервис ещё не привязан — команда пойдёт в очередь, выполнится
            // после onServiceConnected. Но для команд, требующих синхронного
            // результата, лучше вернуть error сразу, если startService не был вызван.
            if (serviceBinder == null) {
                // Ставим в очередь — выполнится после bind.
                pendingCommands.add(call to result)
                ensureServiceStarted()
                return
            }
        }
        handleMethodCall(call, result)
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
                    db?.putSettingInt(SettingsKeys.LISTEN_PORT, (account["listenPort"] as? Number)?.toInt() ?: 50000)
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
                    // searchAsync блокирует на весь таймаут поиска (до 15с) —
                    // выполняем на IO dispatcher.
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

                    // Acquire locks для активной передачи.
                    serviceBinder?.acquireLocks()

                    val ret = mgr.startDownload(
                        downloadId = downloadId,
                        peerUsername = peerUsername,
                        remoteFilename = remoteFilename,
                        sizeBytes = sizeBytes,
                        cacheKey = cacheKey,
                        fileExtension = fileExtension
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
                    result.success(entry?.let {
                        mapOf(
                            "cacheKey" to it.cacheKey,
                            "localPath" to it.localPath,
                            "sizeBytes" to it.sizeBytes,
                            "complete" to it.complete,
                            "pinned" to it.pinned
                        )
                    })
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
        if (!isBound) {
            val bindIntent = Intent(ctx, SoulseekForegroundService::class.java)
            isBound = ctx.bindService(
                bindIntent, serviceConnection, Context.BIND_AUTO_CREATE
            )
            Log.i(TAG, "bindService result: $isBound")
        }
    }

    private fun stopServiceCompletely() {
        val ctx = applicationContext ?: return
        if (isBound) {
            runCatching { ctx.unbindService(serviceConnection) }
            isBound = false
            serviceBinder = null
        }
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
        obj.put("timeoutMs", (call.argument<Number>("timeoutMs")?.toInt() ?: 15000))
        obj.put("responseLimit", (call.argument<Number>("responseLimit")?.toInt() ?: 250))

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
