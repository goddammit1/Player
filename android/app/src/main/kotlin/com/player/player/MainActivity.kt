package com.player.player

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.support.v4.media.session.MediaSessionCompat
import android.view.Display
import android.view.KeyEvent
import android.view.WindowManager
import androidx.core.content.FileProvider
import androidx.media.VolumeProviderCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Базовый AudioServiceActivity + явный запрос максимальной частоты
 * обновления у системы.
 *
 * По умолчанию Android (особенно на устройствах с переменной частотой
 * — Realme/OnePlus/Xiaomi) не даёт приложению 120 Hz, пока оно само
 * об этом не попросит. Без этого Flutter-приложение рендерится на
 * 60 Hz даже если телефон поддерживает 90/120 Hz.
 *
 * Здесь мы при старте находим максимальный режим экрана с тем же
 * физическим разрешением, что и текущий, и просим систему отдать
 * приложение в этом режиме. Если устройство не поддерживает выбор
 * режимов (старая прошивка / fallback) — мы остаёмся на дефолте,
 * никаких эксепшенов.
 */
class MainActivity : AudioServiceActivity() {
    private var volumeChannel: MethodChannel? = null
    private var updateChannel: MethodChannel? = null
    private var volumeProvider: VolumeProviderCompat? = null
    private var mediaController: android.support.v4.media.session.MediaControllerCompat? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        /** 0..200% с шагом 5% → 40 делений remote-шкалы. Должно совпадать с _remoteVolumeMax в player_service.dart. */
        private const val REMOTE_VOLUME_MAX = 40
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "player/volume_keys"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart просит перевести MediaSession в remote-режим
                    // громкости: после этого система шлёт нажатия кнопок
                    // в наш VolumeProvider даже в фоне и на локскрине.
                    "enableRemoteVolume" -> {
                        val current = call.argument<Int>("current")
                            ?: REMOTE_VOLUME_MAX / 2
                        result.success(enableRemoteVolume(current))
                    }
                    // Слайдер в UI подвинули — синхронизируем позицию шкалы.
                    "syncRemoteVolume" -> {
                        val current = (call.argument<Int>("current") ?: 0)
                            .coerceIn(0, REMOTE_VOLUME_MAX)
                        volumeProvider?.setCurrentVolume(current)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        updateChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "player/app_update"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("INVALID_PATH", "APK path is missing.", null)
                    return@setMethodCallHandler
                }

                try {
                    installApk(path)
                    result.success(null)
                } catch (error: Throwable) {
                    result.error("INSTALL_FAILED", error.message, null)
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyHighRefreshRate()
    }

    private fun installApk(path: String) {
        val apk = File(path)
        require(apk.exists() && apk.length() > 0L) { "Downloaded APK was not found." }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            throw IllegalStateException(
                "Allow installation from this app, then tap Download and install again."
            )
        }

        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.update_file_provider",
            apk
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /**
     * Переводит MediaSession audio_service в режим remote volume.
     * После setPlaybackToRemote система маршрутизирует кнопки громкости
     * в наш VolumeProviderCompat даже когда приложение свёрнуто или экран
     * заблокирован — это единственный поддерживаемый Android способ
     * получать кнопки громкости в фоне.
     */
    private fun enableRemoteVolume(current: Int): Boolean {
        val session = findMediaSession() ?: return false
        val clamped = current.coerceIn(0, REMOTE_VOLUME_MAX)
        val provider: VolumeProviderCompat
        if (volumeProvider == null) {
            provider = createVolumeProvider(clamped)
            volumeProvider = provider
        } else {
            provider = volumeProvider!!
            provider.setCurrentVolume(clamped)
        }
        return try {
            session.setPlaybackToRemote(provider)
            // MediaControllerCompat нужен чтобы слать sendCustomAction в фоне
            // (MethodChannel до Dart не добирается пока Activity не в фокусе).
            if (mediaController == null) {
                mediaController =
                    android.support.v4.media.session.MediaControllerCompat(
                        this, session.sessionToken
                    )
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun createVolumeProvider(current: Int): VolumeProviderCompat =
        object : VolumeProviderCompat(
            VOLUME_CONTROL_ABSOLUTE,
            REMOTE_VOLUME_MAX,
            current.coerceIn(0, REMOTE_VOLUME_MAX)
        ) {
            // Кнопки громкости в фоне/на локскрине: direction = ±1.
            // Используем sendCustomAction → audio_service → customAction(Dart),
            // потому что MethodChannel не доходит до Dart в background.
            override fun onAdjustVolume(direction: Int) {
                if (direction == 0) return
                mainHandler.post {
                    val bundle = android.os.Bundle()
                    bundle.putInt("direction", direction)
                    mediaController?.transportControls
                        ?.sendCustomAction("vol_adjust", bundle)
                }
            }

            // Системный слайдер remote-громкости.
            override fun onSetVolumeTo(volume: Int) {
                mainHandler.post {
                    val bundle = android.os.Bundle()
                    bundle.putInt("volume", volume.coerceIn(0, REMOTE_VOLUME_MAX))
                    mediaController?.transportControls
                        ?.sendCustomAction("vol_set", bundle)
                }
            }
        }

    /**
     * audio_service не даёт публичного доступа к своей MediaSessionCompat,
     * поэтому достаём её рефлексией. Поддерживаем и static, и instance
     * вариант поля (зависит от версии плагина). Если структура изменится —
     * вернём null, и останется прежний foreground-перехват ниже.
     */
    private fun findMediaSession(): MediaSessionCompat? {
        return try {
            val cls = Class.forName("com.ryanheise.audioservice.AudioService")
            val sessionField = cls.getDeclaredField("mediaSession")
            sessionField.isAccessible = true
            val target: Any? =
                if (java.lang.reflect.Modifier.isStatic(sessionField.modifiers)) {
                    null
                } else {
                    val instanceField = cls.getDeclaredField("instance")
                    instanceField.isAccessible = true
                    instanceField.get(null) ?: return null
                }
            sessionField.get(target) as? MediaSessionCompat
        } catch (_: Throwable) {
            null
        }
    }

    // Форграунд-фолбэк: пока Activity в фокусе, key-события приходят сюда
    // и до VolumeProvider не доезжают. Перехватываем и шлём в Dart тем же
    // маршрутом, чтобы поведение на главном экране не изменилось.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    volumeChannel?.invokeMethod("up", null)
                }
                return true
            }
            KeyEvent.KEYCODE_VOLUME_DOWN -> {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    volumeChannel?.invokeMethod("down", null)
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun applyHighRefreshRate() {
        try {
            val display: Display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display ?: return
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay ?: return
            }

            val current = display.mode
            val modes = display.supportedModes
            if (modes.isEmpty()) return

            // Ищем режим с тем же физическим разрешением и максимальной
            // частотой обновления. Менять разрешение мы не хотим —
            // это вызывает перерисовку и хуже выглядит.
            val best = modes
                .filter {
                    it.physicalWidth == current.physicalWidth &&
                            it.physicalHeight == current.physicalHeight
                }
                .maxByOrNull { it.refreshRate }
                ?: return

            val params: WindowManager.LayoutParams = window.attributes
            params.preferredDisplayModeId = best.modeId
            // Подсказка для прошивок OPPO/Realme/OnePlus, которые
            // иногда игнорируют preferredDisplayModeId, но уважают
            // preferredRefreshRate.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                params.preferredRefreshRate = best.refreshRate
            }
            window.attributes = params
        } catch (_: Throwable) {
            // best-effort; на любой случай — молча остаёмся на дефолте.
        }
    }
}
