package com.player.player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * Управление уведомлением foreground service Soulseek.
 *
 * Канал: [CHANNEL_ID] (IMPORTANCE_LOW — беззвучное, не прерывает пользователя).
 * Содержимое: статус соединения + 1-2 активные загрузки с прогрессом.
 * Actions: Pause All, Cancel (для активных transfer).
 * PendingIntent: возврат в MainActivity (открытие приложения).
 *
 * Совместимость: Android 13+ требует POST_NOTIFICATIONS permission —
 * запрос делает Dart-сторона (Фаза 3) через permission_handler; здесь
 * лишь создаём notification, не запрашивая permission.
 */
class SoulseekNotification(private val context: Context) {

    companion object {
        const val CHANNEL_ID = "soulseek_service"
        private const val CHANNEL_NAME = "Soulseek Transfers"
        const val NOTIFICATION_ID = 42137

        // Action-ключи для PendingIntent (broadcast в сервис).
        const val ACTION_PAUSE_ALL = "com.player.player.soulseek.PAUSE_ALL"
        const val ACTION_CANCEL_TRANSFER = "com.player.player.soulseek.CANCEL_TRANSFER"
        const val EXTRA_DOWNLOAD_ID = "downloadId"
    }

    init {
        createNotificationChannel()
    }

    /** Создаёт notification channel (Android 8+). Идемпотентно. */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val existing = manager?.getNotificationChannel(CHANNEL_ID)
            if (existing == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Soulseek P2P file transfer status"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    /**
     * Строит notification для foreground service.
     *
     * @param connectionState текущее состояние соединения
     * @param activeTransfers список активных (незавершённых) transfer-событий;
     *        показываем первые 1-2, остальные суммируем счётчиком.
     */
    fun buildNotification(
        connectionState: ConnectionState,
        activeTransfers: List<SoulseekTransferEvent>
    ): Notification {
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(buildContentIntent())
            .setPriority(NotificationCompat.PRIORITY_LOW)

        // Заголовок: статус соединения.
        val connectionText = when (connectionState) {
            ConnectionState.CONNECTED -> "Soulseek: Connected"
            ConnectionState.CONNECTING -> "Soulseek: Connecting…"
            ConnectionState.RECONNECTING -> "Soulseek: Reconnecting…"
            ConnectionState.FAILED -> "Soulseek: Connection failed"
            ConnectionState.DISCONNECTED -> "Soulseek: Disconnected"
        }
        builder.setContentTitle(connectionText)

        // Текст: активные загрузки.
        if (activeTransfers.isEmpty()) {
            builder.setContentText("No active transfers")
                .setProgress(0, 0, false)
        } else {
            val downloading = activeTransfers.filter { it.state == TransferState.DOWNLOADING }
            if (downloading.isNotEmpty()) {
                val first = downloading.first()
                val shortName = shortFilename(first)
                val percent = if (first.totalBytes > 0) {
                    ((first.bytesReceived * 100) / first.totalBytes).toInt()
                } else 0
                builder.setContentText("$shortName — $percent%")
                    .setProgress(100, percent, first.totalBytes <= 0)

                if (downloading.size > 1) {
                    builder.setSubText("+${downloading.size - 1} more downloading")
                }
            } else {
                // Все в очереди/подключении.
                builder.setContentText("${activeTransfers.size} transfer(s) queued")
                    .setProgress(0, 0, true)
            }

            // Action: Pause All (если есть активные).
            builder.addAction(
                buildPauseAllAction()
            )

            // Action: Cancel для первого активного transfer.
            val firstActive = activeTransfers.firstOrNull { it.state.isActive }
            if (firstActive != null) {
                builder.addAction(
                    buildCancelAction(firstActive.downloadId)
                )
            }
        }

        return builder.build()
    }

    /** PendingIntent для открытия MainActivity при тапе на notification. */
    private fun buildContentIntent(): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getActivity(context, 0, intent, flags)
    }

    /** Action «Pause All» — broadcast в SoulseekForegroundService. */
    private fun buildPauseAllAction(): NotificationCompat.Action {
        val intent = Intent(ACTION_PAUSE_ALL).apply {
            setPackage(context.packageName)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getBroadcast(context, 1, intent, flags)
        return NotificationCompat.Action.Builder(
            android.R.drawable.ic_media_pause,
            "Pause All",
            pendingIntent
        ).build()
    }

    /** Action «Cancel» для конкретного transfer. */
    private fun buildCancelAction(downloadId: String): NotificationCompat.Action {
        val intent = Intent(ACTION_CANCEL_TRANSFER).apply {
            setPackage(context.packageName)
            putExtra(EXTRA_DOWNLOAD_ID, downloadId)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        // RequestCode уникален per downloadId (hashCode), чтобы не перетирать.
        val pendingIntent = PendingIntent.getBroadcast(
            context, downloadId.hashCode(), intent, flags
        )
        return NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_close_clear_cancel,
            "Cancel",
            pendingIntent
        ).build()
    }

    /** Короткое имя файла из remoteFilename/локального пути для отображения. */
    private fun shortFilename(event: SoulseekTransferEvent): String {
        val path = event.localPath
        if (!path.isNullOrEmpty()) {
            val name = path.substringAfterLast('/')
            return name.substringAfterLast('\\').take(40)
        }
        return event.downloadId.take(12)
    }

    /**
     * Обновляет notification через NotificationManager.
     * Вызывается сервисом при изменении состояния/прогресса (throttled).
     */
    fun update(
        connectionState: ConnectionState,
        activeTransfers: List<SoulseekTransferEvent>
    ) {
        val notification = buildNotification(connectionState, activeTransfers)
        val manager = context.getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, notification)
    }

    /** Отменяет notification (при остановке сервиса). */
    fun cancel() {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager?.cancel(NOTIFICATION_ID)
    }
}
