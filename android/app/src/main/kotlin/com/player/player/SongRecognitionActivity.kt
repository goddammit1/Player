package com.player.player

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast

/**
 * Прозрачная activity-трамплин между плиткой в шторке и
 * [SongRecognitionService]: запрашивает микрофон (и уведомления на
 * Android 13+) и запускает сервис. Микрофонный foreground service можно
 * стартовать только из видимой activity — поэтому плитка не запускает
 * сервис сама. Ничего не рисует и сразу закрывается — пользователь
 * остаётся в том приложении, где был.
 */
class SongRecognitionActivity : Activity() {

    companion object {
        private const val REQUEST_PERMISSIONS = 1
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return // ждём ответа на запрос разрешений

        val missing = buildList {
            if (!granted(Manifest.permission.RECORD_AUDIO)) {
                add(Manifest.permission.RECORD_AUDIO)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                !granted(Manifest.permission.POST_NOTIFICATIONS)
            ) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (missing.isEmpty()) {
            startRecognition()
        } else {
            requestPermissions(missing.toTypedArray(), REQUEST_PERMISSIONS)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (granted(Manifest.permission.RECORD_AUDIO)) {
            startRecognition()
            return
        }
        Toast.makeText(this, "Song recognition needs microphone access", Toast.LENGTH_LONG)
            .show()
        // «Больше не спрашивать» — системный диалог не появится, остаются настройки.
        if (!shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null)
                )
            )
        }
        close()
    }

    private fun startRecognition() {
        SongRecognitionService.start(this)
        close()
    }

    private fun close() {
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    private fun granted(permission: String) =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
}
