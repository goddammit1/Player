package com.player.player

import android.annotation.SuppressLint
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.TimeZone
import java.util.UUID
import kotlin.coroutines.coroutineContext

/**
 * Распознавание играющей рядом песни (плитка в шторке → [SongRecognitionActivity]
 * → этот сервис). Работает без Flutter: пишет 9 с с микрофона, считает
 * отпечаток через [Vibra] и спрашивает неофициальный discovery-API Shazam —
 * тот может поменяться или начать отклонять запросы без предупреждения.
 * Результат — уведомление с переходом к поиску в приложении.
 *
 * Foreground service типа microphone: без него запись из фона (пользователь
 * в другом приложении) запрещена. Запускать — только из видимой activity.
 *
 * Замер на телефоне (LTE + VPN): запись 9,5 с, отпечаток 0,3 с, первый
 * запрос к Shazam 1,2 с (из них ~0,9 с — TLS), обложка ~1 с. Поэтому
 * соединение прогревается параллельно с записью, а уведомление показывается
 * сразу, не дожидаясь обложки.
 */
class SongRecognitionService : Service() {

    companion object {
        private const val TAG = "SongRecognition"
        private const val ACTION_CANCEL = "com.player.player.song_recognition.CANCEL"

        private const val SAMPLE_RATE = 16000
        private const val RECORD_SECONDS = 9

        private const val SHAZAM_HOST = "https://amp.shazam.com"

        /** Идёт запись/распознавание — для состояния плитки. Меняется на main. */
        @Volatile
        var isRunning = false
            private set

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, SongRecognitionService::class.java)
            )
        }

        fun cancelIntent(context: Context): Intent =
            Intent(context, SongRecognitionService::class.java).setAction(ACTION_CANCEL)
    }

    private sealed class Outcome {
        class Found(val title: String, val artist: String, val coverUrl: String) : Outcome()
        object NotFound : Outcome()
        class Failed(val message: String) : Outcome()
    }

    private class RecognitionException(message: String) : Exception(message)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Текущее распознавание (запись → запрос); догрузка обложки — вне его. */
    private var job: Job? = null
    private lateinit var notifications: SongRecognitionNotifications

    override fun onCreate() {
        super.onCreate()
        notifications = SongRecognitionNotifications(this)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            job?.cancel()
            endRecognition()
            stopSelf()
            return START_NOT_STICKY
        }
        if (isRunning) return START_NOT_STICKY

        try {
            ServiceCompat.startForeground(
                this,
                SongRecognitionNotifications.LISTENING_ID,
                notifications.listening(),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    0
                }
            )
        } catch (e: Exception) {
            // Запуск не из видимой activity: Android не даёт микрофон в фоне.
            Log.w(TAG, "startForeground failed", e)
            notifications.failed("Couldn't access the microphone")
            stopSelf(startId)
            return START_NOT_STICKY
        }

        isRunning = true
        SongRecognitionTileService.refresh(this)
        job = scope.launch {
            val outcome = try {
                recognize()
            } catch (e: RecognitionException) {
                Outcome.Failed(e.message ?: "Recognition failed")
            }
            withContext(Dispatchers.Main) {
                when (outcome) {
                    is Outcome.Found -> notifications.found(outcome.title, outcome.artist)
                    Outcome.NotFound -> {
                        Log.i(TAG, "not found")
                        notifications.notFound()
                    }
                    is Outcome.Failed -> {
                        Log.i(TAG, "failed: ${outcome.message}")
                        notifications.failed(outcome.message)
                    }
                }
                // Плитка свободна сразу: новое распознавание не ждёт обложку.
                endRecognition()
            }
            if (outcome is Outcome.Found) {
                loadCover(outcome.coverUrl)?.let { cover ->
                    withContext(Dispatchers.Main) {
                        notifications.addCover(outcome.title, outcome.artist, cover)
                    }
                }
            }
            // startId: если пользователь уже запустил новое распознавание,
            // этот stopSelf его не остановит.
            withContext(Dispatchers.Main) { stopSelf(startId) }
        }
        return START_NOT_STICKY
    }

    /** Убрать «Listening…» и освободить плитку. Только на main. */
    private fun endRecognition() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        isRunning = false
        SongRecognitionTileService.refresh(this)
    }

    override fun onDestroy() {
        scope.cancel()
        isRunning = false
        SongRecognitionTileService.refresh(this)
        super.onDestroy()
    }

    private suspend fun recognize(): Outcome {
        // TLS-рукопожатие с Shazam (~0,9 с на LTE) идёт параллельно с записью;
        // запрос после неё берёт готовое соединение из пула HttpURLConnection.
        // Не дочерняя корутина: при ошибке записи не ждём зависший HEAD.
        scope.launch { prewarmConnection() }
        val pcm = record()
        if (pcm.size < SAMPLE_RATE * 2 * 3) throw RecognitionException("Couldn't record audio")
        // Сплошные нули — микрофон занят другим приложением (Android глушит
        // вторую запись) или выключен в быстрых настройках.
        if (pcm.all { it == 0.toByte() }) {
            throw RecognitionException("Microphone is busy or turned off")
        }
        val signature = Vibra.fingerprint(pcm, SAMPLE_RATE)
            ?: throw RecognitionException("Couldn't process the recording")
        coroutineContext.ensureActive()
        return lookup(signature)
    }

    /**
     * Открывает соединение с Shazam заранее. Ответ (404) не важен; тело
     * дочитывается и закрывается без disconnect() — иначе сокет не вернётся
     * в пул и выигрыша не будет.
     */
    private fun prewarmConnection() {
        try {
            val connection = URL("$SHAZAM_HOST/").openConnection() as HttpURLConnection
            connection.requestMethod = "HEAD"
            connection.connectTimeout = 8_000
            connection.readTimeout = 8_000
            val code = connection.responseCode
            (if (code >= 400) connection.errorStream else connection.inputStream)?.close()
        } catch (e: IOException) {
            // Не прогрелось — запрос просто откроет соединение сам.
        }
    }

    /** 16-бит моно PCM с микрофона, [RECORD_SECONDS] секунд. */
    @SuppressLint("MissingPermission") // проверено в SongRecognitionActivity
    private suspend fun record(): ByteArray {
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer, SAMPLE_RATE * 2)
            )
        } catch (e: Exception) {
            throw RecognitionException("Microphone is unavailable")
        }
        try {
            if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                throw RecognitionException("Microphone is unavailable")
            }
            val pcm = ByteArray(SAMPLE_RATE * 2 * RECORD_SECONDS)
            var offset = 0
            recorder.startRecording()
            while (offset < pcm.size) {
                coroutineContext.ensureActive()
                val read = recorder.read(pcm, offset, minOf(4096, pcm.size - offset))
                if (read <= 0) break
                offset += read
            }
            return pcm.copyOf(offset)
        } finally {
            try {
                recorder.stop()
            } catch (_: IllegalStateException) {
            }
            recorder.release()
        }
    }

    private fun lookup(signature: Vibra.Signature): Outcome {
        val url = URL(
            "$SHAZAM_HOST/discovery/v5/en/US/android/-/tag/" +
                "${UUID.randomUUID()}/${UUID.randomUUID()}" +
                "?sync=true&webv3=true&sampling=true&connected=" +
                "&shazamapiversion=v3&sharehub=true&video=v3"
        )
        val now = System.currentTimeMillis()
        val body = JSONObject()
            .put(
                "geolocation",
                JSONObject().put("altitude", 0).put("latitude", 0).put("longitude", 0)
            )
            .put(
                "signature",
                JSONObject()
                    .put("samplems", signature.sampleMs)
                    .put("timestamp", now)
                    .put("uri", signature.uri)
            )
            .put("timestamp", now)
            .put("timezone", TimeZone.getDefault().id)

        val json = try {
            val connection = url.openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = 12_000
                connection.readTimeout = 20_000
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setRequestProperty("Accept", "*/*")
                connection.setRequestProperty("Content-Language", "en_US")
                connection.setRequestProperty("User-Agent", "Shazam/13.0.0 (Android; 13)")
                connection.outputStream.use { it.write(body.toString().toByteArray()) }
                val code = connection.responseCode
                if (code !in 200..299) {
                    Log.w(TAG, "Shazam HTTP $code")
                    throw RecognitionException("Shazam rejected the request (HTTP $code)")
                }
                connection.inputStream.bufferedReader().use { JSONObject(it.readText()) }
            } finally {
                connection.disconnect()
            }
        } catch (e: IOException) {
            Log.w(TAG, "Shazam request failed", e)
            throw RecognitionException("Couldn't reach Shazam")
        } catch (e: org.json.JSONException) {
            throw RecognitionException("Unexpected response from Shazam")
        }

        val track = json.optJSONObject("track") ?: return Outcome.NotFound
        val title = track.optString("title").trim()
        if (title.isEmpty()) return Outcome.NotFound
        val artist = track.optString("subtitle").trim()
        val coverUrl = track.optJSONObject("images")?.optString("coverart").orEmpty()
        Log.i(TAG, "found: $artist — $title")
        return Outcome.Found(title, artist, coverUrl)
    }

    /**
     * Обложка для уведомления, уменьшенная до [COVER_SIZE_PX]: полноразмерный
     * bitmap раздувает Parcel уведомления. Не скачалась — уведомление без неё.
     */
    private fun loadCover(url: String): Bitmap? {
        if (url.isEmpty()) return null
        return try {
            val connection = URL(url).openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = 5_000
                connection.readTimeout = 5_000
                val bitmap = connection.inputStream.use { BitmapFactory.decodeStream(it) }
                    ?: return null
                val scale = COVER_SIZE_PX.toFloat() / maxOf(bitmap.width, bitmap.height)
                if (scale >= 1f) {
                    bitmap
                } else {
                    Bitmap.createScaledBitmap(
                        bitmap,
                        (bitmap.width * scale).toInt().coerceAtLeast(1),
                        (bitmap.height * scale).toInt().coerceAtLeast(1),
                        true
                    )
                }
            } finally {
                connection.disconnect()
            }
        } catch (e: IOException) {
            null
        }
    }
}

private const val COVER_SIZE_PX = 256
