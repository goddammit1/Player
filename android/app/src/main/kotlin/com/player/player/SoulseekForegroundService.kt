package com.player.player

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import soulseek.wrapper.SoulseekBridge
import java.io.File

/**
 * Foreground Service — единый владелец [SoulseekBridge] (C#), [SoulseekTransferManager],
 * [SoulseekCacheManager], [SoulseekDatabase].
 *
 * Жизненный цикл:
 *  1. [onStartCommand] → [startForeground] (notification ДО любой сетевой работы),
 *     инициализация bridge + менеджеров, restore из БД.
 *  2. [onBind] → возвращает [SoulseekServiceBinder] (bound service pattern).
 *     Plugin получает доступ к transferManager/bridge через binder.
 *  3. [onTaskRemoved] → save checkpoint, НЕ удаляем незавершённые задачи.
 *  4. [onDestroy] → cancel operations, save state, disconnect bridge, release locks.
 *
 * WakeLock (PARTIAL_WAKE_LOCK) — только при активной передаче, всегда освобождается.
 * WifiLock (HIGH_PERF) — только при активной передаче, всегда освобождается.
 *
 * Notification actions (Pause All / Cancel) обрабатываются через BroadcastReceiver.
 */
class SoulseekForegroundService : Service() {

    companion object {
        private const val TAG = "SoulseekFgService"

        const val EXTRA_COMMAND = "command"
        const val COMMAND_START = "start"
        const val COMMAND_STOP = "stop"

        // Cache subdir внутри app cache.
        private const val CACHE_SUBDIR = "soulseek_cache"

        // WakeLock timeout — перевыбираем периодически, не держим бесконечно.
        private const val WAKE_LOCK_TIMEOUT_MS = 60_000L * 10L // 10 минут
    }

    private val binder = SoulseekServiceBinder()

    // ── Компоненты (lazy — создаются при первом onStartCommand) ──────────
    private var database: SoulseekDatabase? = null
    private var cacheManager: SoulseekCacheManager? = null
    private var bridge: SoulseekBridge? = null
    private var transferManager: SoulseekTransferManager? = null
    private var notificationHelper: SoulseekNotification? = null

    // ── Locks ────────────────────────────────────────────────────────────
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    // ── Coroutine scope для команд (serial execution) ────────────────────
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val commandMutex = Mutex()

    // ── BroadcastReceiver для notification actions ───────────────────────
    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                SoulseekNotification.ACTION_PAUSE_ALL -> {
                    serviceScope.launch {
                        commandMutex.withLock {
                            transferManager?.let { mgr ->
                                mgr.getActiveTransfers().forEach { ev ->
                                    runCatching { mgr.pauseDownload(ev.downloadId) }
                                }
                            }
                        }
                    }
                }
                SoulseekNotification.ACTION_CANCEL_TRANSFER -> {
                    val downloadId = intent.getStringExtra(SoulseekNotification.EXTRA_DOWNLOAD_ID)
                    if (!downloadId.isNullOrEmpty()) {
                        serviceScope.launch {
                            commandMutex.withLock {
                                runCatching { transferManager?.cancelDownload(downloadId) }
                            }
                        }
                    }
                }
            }
        }
    }

    @Volatile
    private var initialized = false

    // ───────────────────────────────────────────────────────────────────
    //  Lifecycle
    // ───────────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        // Регистрируем receiver для notification actions.
        val filter = IntentFilter().apply {
            addAction(SoulseekNotification.ACTION_PAUSE_ALL)
            addAction(SoulseekNotification.ACTION_CANCEL_TRANSFER)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(actionReceiver, filter)
        }
        Log.i(TAG, "onCreate: receiver registered")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "onStartCommand: ${intent?.getStringExtra(EXTRA_COMMAND) ?: "null"}")

        // Notification создаётся ДО любой сетевой работы (требование Android 12+).
        notificationHelper = SoulseekNotification(this)
        val initialNotification = notificationHelper!!.buildNotification(
            ConnectionState.DISCONNECTED, emptyList()
        )

        // Инициализация сети — только после успешного перехода в foreground.
        // При отказе (нет type-specific permission / запрет фонового старта) —
        // контролируемая остановка без сетевой инициализации и зависших команд.
        if (!startForegroundCompat(initialNotification)) {
            notificationHelper?.cancel()
            stopSelf()
            return START_NOT_STICKY
        }

        // Инициализация компонентов (один раз).
        if (!initialized) {
            initializeComponents()
            initialized = true
        }

        // Обработка команд.
        when (intent?.getStringExtra(EXTRA_COMMAND)) {
            COMMAND_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }

        // Если сервис убит — НЕ перезапускаем автоматически; restore произойдёт
        // при следующем запуске через plugin (читает БД + .part файлы).
        return START_NOT_STICKY
    }

    /** Инициализация bridge + менеджеров + restore из БД. */
    private fun initializeComponents() {
        val db = SoulseekDatabase(this)
        database = db

        val cacheDir = File(cacheDir, CACHE_SUBDIR)
        val maxCache = db.getSettingLong(SettingsKeys.MAX_CACHE_SIZE, 1_073_741_824L)
        val cache = SoulseekCacheManager(cacheDir, db, maxCache)
        cacheManager = cache

        val b = SoulseekBridge()
        bridge = b

        // TransferManager: eventSink пересылает события в plugin (через binder).
        // Plugin подписывается через binder.setEventListener.
        // Фаза B (разрыв №3): лимит параллелизма читается из soulseek.db
        // (max_concurrent_downloads, синкается из Dart-настроек), а не
        // хардкодом; listen_port дефолт выровнен с Dart (24150).
        val maxConcurrent = db.getSettingInt(SettingsKeys.MAX_CONCURRENT_DOWNLOADS, 3)
        val mgr = SoulseekTransferManager(
            bridge = b,
            database = db,
            cacheManager = cache,
            maxConcurrentDownloads = maxConcurrent,
            eventSink = { json ->
                serviceScope.launch {
                    commandMutex.withLock {
                        eventListener?.invoke(json)
                    }
                }
            },
            onActiveTransfersChanged = {
                updateNotificationInternal()
            }
        )
        transferManager = mgr

        // Устанавливаем event sink в C# bridge.
        b.setEventSink(mgr.createBridgeEventSink())

        // Restore незавершённых transfers из БД.
        mgr.restoreFromDatabase()

        Log.i(TAG, "initializeComponents: bridge, cache, transfer manager ready")
    }

    override fun onBind(intent: Intent?): IBinder {
        Log.i(TAG, "onBind")
        return binder
    }

    override fun onUnbind(intent: Intent?): Boolean {
        Log.i(TAG, "onUnbind")
        // true → onRebind при следующем bindService (после пересоздания Activity).
        return true
    }

    override fun onRebind(intent: Intent?) {
        Log.i(TAG, "onRebind")
        super.onRebind(intent)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "onTaskRemoved: saving checkpoints")
        // Сохраняем checkpoint, НЕ удаляем незавершённые задачи —
        // пользователь может вернуться; restore подхватит .part файлы.
        transferManager?.saveCheckpoints()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy: cleanup")
        transferManager?.cancelAllForShutdown()
        transferManager?.saveCheckpoints()

        // Shutdown bridge: JNI-имя метода "dispose" (см. [Register("dispose")] в SoulseekBridge.cs).
        // Отменяет все C#-загрузки и освобождает SoulseekClient.
        runCatching { bridge?.dispose() }

        releaseLocks()

        runCatching { unregisterReceiver(actionReceiver) }

        notificationHelper?.cancel()

        super.onDestroy()
    }

    // ───────────────────────────────────────────────────────────────────
    //  Foreground compat
    // ───────────────────────────────────────────────────────────────────

    /**
     * startForeground с учётом версии Android.
     * На Android 14+ (API 34) необходимо явно указать foregroundServiceType:
     * FOREGROUND_SERVICE_TYPE_DATA_SYNC or FOREGROUND_SERVICE_TYPE_SPECIAL_USE
     * (обе permission объявлены в манифесте без ограничения maxSdkVersion).
     *
     * @return true — сервис действительно в foreground;
     *         false — контролируемый отказ, вызывающий должен остановить сервис.
     */
    private fun startForegroundCompat(notification: android.app.Notification): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    SoulseekNotification.NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    SoulseekNotification.NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(SoulseekNotification.NOTIFICATION_ID, notification)
            }
            true
        } catch (e: SecurityException) {
            // Отсутствует type-specific разрешение (например FOREGROUND_SERVICE_DATA_SYNC
            // на API 34+). Продолжать сетевую работу под видом успешного FGS нельзя —
            // контролируемый отказ.
            Log.e(TAG, "startForeground denied, missing FGS permission: ${e.message}", e)
            false
        } catch (e: android.app.ForegroundServiceStartNotAllowedException) {
            // Запрет фонового старта (API 31+): сервис запущен из недопустимого контекста.
            Log.e(TAG, "startForeground not allowed (background start restriction): ${e.message}", e)
            false
        } catch (e: Exception) {
            // Прочие отказы (недопустимый тип, сбой системы и т.п.) — тоже без сети.
            Log.e(TAG, "startForeground failed: ${e.message}", e)
            false
        }
    }

    // ───────────────────────────────────────────────────────────────────
    //  Notification updates
    // ───────────────────────────────────────────────────────────────────

    @Volatile
    private var lastNotificationUpdateAt: Long = 0L

    /** Throttled обновление notification (не чаще ~500мс). */
    private fun updateNotificationInternal() {
        val now = System.currentTimeMillis()
        if (now - lastNotificationUpdateAt < 500L) return
        lastNotificationUpdateAt = now

        val transfers = transferManager?.getActiveTransfers() ?: emptyList()
        val connState = transferManager?.connectionState ?: ConnectionState.DISCONNECTED

        notificationHelper?.update(connState, transfers)
    }

    // ───────────────────────────────────────────────────────────────────
    //  Locks — WakeLock / WifiLock
    // ───────────────────────────────────────────────────────────────────

    /**
     * Acquire WakeLock + WifiLock при активной передаче.
     * Идемпотентно: повторные вызовы не перевыбирают уже удержанные lock'и.
     */
    fun acquireTransferLocks() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "Player:SoulseekTransfer"
                ).apply {
                    setReferenceCounted(false)
                    acquire(WAKE_LOCK_TIMEOUT_MS)
                }
                Log.i(TAG, "WakeLock acquired")
            }
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "Player:SoulseekTransfer"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.i(TAG, "WifiLock acquired")
            }
        } catch (e: Exception) {
            Log.w(TAG, "acquireTransferLocks failed: ${e.message}")
        }
    }

    /** Release WakeLock + WifiLock. Всегда освобождаем — no leak. */
    fun releaseTransferLocks() {
        releaseLocks()
    }

    private fun releaseLocks() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.w(TAG, "WakeLock release failed: ${e.message}")
        }
        try {
            wifiLock?.let {
                if (it.isHeld) it.release()
            }
            wifiLock = null
        } catch (e: Exception) {
            Log.w(TAG, "WifiLock release failed: ${e.message}")
        }
    }

    // ───────────────────────────────────────────────────────────────────
    //  Event listener — bridge из service в plugin (EventChannel)
    // ───────────────────────────────────────────────────────────────────

    @Volatile
    private var eventListener: ((String) -> Unit)? = null

    // ───────────────────────────────────────────────────────────────────
    //  Binder
    // ───────────────────────────────────────────────────────────────────

    /**
     * Binder даёт plugin'у доступ к сервисным компонентам.
     * Plugin вызывает методы binder'а для команд; сервис исполняет их
     * в [serviceScope] с [commandMutex] (serial executor).
     */
    inner class SoulseekServiceBinder : Binder() {

        val transferManager: SoulseekTransferManager?
            get() = this@SoulseekForegroundService.transferManager

        val cacheManager: SoulseekCacheManager?
            get() = this@SoulseekForegroundService.cacheManager

        val database: SoulseekDatabase?
            get() = this@SoulseekForegroundService.database

        val bridge: SoulseekBridge?
            get() = this@SoulseekForegroundService.bridge

        /** Установка слушателя событий для пересылки в EventChannel. */
        fun setEventListener(listener: ((String) -> Unit)?) {
            eventListener = listener
        }

        /**
         * Выполняет команду в serial-executor scope.
         * Используется plugin'ом для всех MethodChannel-команд, чтобы
         * гарантировать последовательное исполнение и thread-safety.
         */
        fun executeCommand(block: suspend () -> Unit) {
            serviceScope.launch {
                commandMutex.withLock { block() }
            }
        }

        /**
         * Синхронное выполнение команды (для методов, требующих результата).
         * Вызывается из plugin'а на background thread (MethodChannel handler).
         */
        fun executeCommandBlocking(block: suspend () -> Unit) {
            runBlocking {
                commandMutex.withLock { block() }
            }
        }

        fun acquireLocks() = acquireTransferLocks()
        fun releaseLocks() = releaseTransferLocks()

        /** Обновить notification (например, после смены connection state). */
        fun refreshNotification() = updateNotificationInternal()
    }
}
