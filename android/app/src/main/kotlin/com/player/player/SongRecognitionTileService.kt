package com.player.player

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Плитка «Recognize song» в шторке быстрых настроек. Тап запускает
 * распознавание через [SongRecognitionActivity], повторный тап во время
 * записи — отменяет.
 */
class SongRecognitionTileService : TileService() {

    companion object {
        /** Просит систему перечитать состояние плитки (идёт ли запись). */
        fun refresh(context: Context) {
            try {
                requestListeningState(
                    context,
                    ComponentName(context, SongRecognitionTileService::class.java)
                )
            } catch (_: Exception) {
                // Плитка не добавлена в шторку / система не даёт обновить — не страшно.
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        val running = SongRecognitionService.isRunning
        tile.state = if (running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (running) "Listening…" else null
        }
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (SongRecognitionService.isRunning) {
            startService(SongRecognitionService.cancelIntent(this))
            return
        }
        if (isLocked) unlockAndRun { launch() } else launch()
    }

    private fun launch() {
        val intent = Intent(this, SongRecognitionActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
