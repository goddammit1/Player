package com.player.player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Уведомления распознавания песен: «Listening…» на время записи (тихий канал)
 * и результат (канал с heads-up — пользователь в другом приложении).
 * Вызывать с main-потока (Toast при выключенных уведомлениях).
 */
class SongRecognitionNotifications(private val context: Context) {

    companion object {
        const val LISTENING_ID = 42140
        private const val RESULT_ID = 42141

        private const val PROGRESS_CHANNEL = "song_recognition_progress"
        private const val RESULT_CHANNEL = "song_recognition_result"
    }

    private val manager = NotificationManagerCompat.from(context)

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val system = context.getSystemService(NotificationManager::class.java)
            system.createNotificationChannel(
                NotificationChannel(
                    PROGRESS_CHANNEL,
                    "Song recognition: listening",
                    NotificationManager.IMPORTANCE_LOW
                ).apply { setShowBadge(false) }
            )
            system.createNotificationChannel(
                NotificationChannel(
                    RESULT_CHANNEL,
                    "Recognized songs",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply { setShowBadge(false) }
            )
        }
    }

    fun listening(): Notification = NotificationCompat.Builder(context, PROGRESS_CHANNEL)
        .setSmallIcon(R.drawable.ic_song_recognition)
        .setContentTitle("Listening…")
        .setContentText("Recognizing the song playing nearby")
        .setProgress(0, 0, true)
        .setOngoing(true)
        .setSilent(true)
        .addAction(
            0,
            "Cancel",
            PendingIntent.getService(
                context,
                0,
                SongRecognitionService.cancelIntent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        )
        .build()

    /** Результат сразу, без обложки — её добавляет [addCover], когда скачается. */
    fun found(title: String, artist: String) {
        show(foundBuilder(title, artist).build(), toast = foundToast(title, artist))
    }

    /**
     * Дорисовывает обложку в уже показанное уведомление. Если его успели
     * смахнуть или открыть — не возвращаем. Без повторного звука/всплытия.
     */
    fun addCover(title: String, artist: String, cover: Bitmap) {
        if (!isShowing(RESULT_ID)) return
        show(
            foundBuilder(title, artist).setLargeIcon(cover).setOnlyAlertOnce(true).build(),
            toast = null
        )
    }

    fun notFound() = retry("Song not recognized", "Try again closer to the sound source")

    fun failed(message: String) = retry("Couldn't recognize the song", message)

    private fun foundBuilder(title: String, artist: String): NotificationCompat.Builder {
        val query = if (artist.isEmpty()) title else "$artist $title"
        val search = PendingIntent.getActivity(
            context,
            1,
            MainActivity.searchIntent(context, query),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(context, RESULT_CHANNEL)
            .setSmallIcon(R.drawable.ic_song_recognition)
            .setContentTitle(title)
            .setContentText(artist)
            .setContentIntent(search)
            .addAction(0, "Find in ${appLabel()}", search)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
    }

    private fun foundToast(title: String, artist: String) =
        if (artist.isEmpty()) "Recognized: $title" else "Recognized: $artist — $title"

    private fun retry(title: String, text: String) {
        val again = PendingIntent.getActivity(
            context,
            2,
            Intent(context, SongRecognitionActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        show(
            NotificationCompat.Builder(context, RESULT_CHANNEL)
                .setSmallIcon(R.drawable.ic_song_recognition)
                .setContentTitle(title)
                .setContentText(text)
                .addAction(0, "Try again", again)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build(),
            toast = "$title. $text"
        )
    }

    /** «Player» или «Player Debug» — debug стоит рядом с релизом. */
    private fun appLabel() =
        context.applicationInfo.loadLabel(context.packageManager).toString()

    /**
     * Показывает уведомление, а если уведомления приложения или канала
     * результатов выключены — хотя бы Toast, иначе результат пропадёт молча.
     */
    private fun show(notification: Notification, toast: String?) {
        val channelBlocked = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(RESULT_CHANNEL)?.importance ==
            NotificationManager.IMPORTANCE_NONE
        if (!manager.areNotificationsEnabled() || channelBlocked) {
            if (toast != null) Toast.makeText(context, toast, Toast.LENGTH_LONG).show()
            return
        }
        try {
            manager.notify(RESULT_ID, notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS отозвано между проверкой и показом.
            if (toast != null) Toast.makeText(context, toast, Toast.LENGTH_LONG).show()
        }
    }

    private fun isShowing(id: Int): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            context.getSystemService(NotificationManager::class.java)
                .activeNotifications.any { it.id == id }
}
