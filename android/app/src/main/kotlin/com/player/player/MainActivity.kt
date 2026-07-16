package com.player.player

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Display
import android.view.KeyEvent
import android.view.WindowManager
import androidx.core.content.FileProvider
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "player/volume_keys"
        )

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

    // Перехватываем физические кнопки громкости, чтобы Android не трогал
    // STREAM_MUSIC. События уходят в Dart через MethodChannel и там
    // применяются к нашей 0..200% шкале.
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
