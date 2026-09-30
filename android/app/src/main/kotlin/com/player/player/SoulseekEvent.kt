package com.player.player

import org.json.JSONArray
import org.json.JSONObject

/**
 * Состояние трансфера на Kotlin-стороне (Фаза 2).
 *
 * Маппится из строк C# [Soulseek.NET TransferStates] (flags, например
 * "Transferring", "Queued, Completed", "Succeeded"), приходящих в
 * SoulseekEventDto через ISoulseekEventSink.
 */
enum class TransferState {
    IDLE, CONNECTING, SEARCHING, QUEUED, DOWNLOADING, PREBUFFERED,
    COMPLETED, PAUSED, FAILED, CANCELLED;

    /** Терминальные состояния: трансфер завершён и не потребляет слот очереди. */
    val isTerminal: Boolean
        get() = this == COMPLETED || this == FAILED || this == CANCELLED

    /** Состояния, при которых трансфер числится «активным» (держит слот/lock). */
    val isActive: Boolean
        get() = this == QUEUED || this == DOWNLOADING || this == CONNECTING
}

/**
 * Состояние соединения с сервером Soulseek.
 * Маппится из строк C# SoulseekClientStates.
 */
enum class ConnectionState {
    DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING, FAILED
}

/** Событие трансфера, пересылаемое в Flutter через EventChannel. */
data class SoulseekTransferEvent(
    val downloadId: String,
    val state: TransferState,
    val bytesReceived: Long = 0L,
    val totalBytes: Long = 0L,
    val bytesPerSecond: Long = 0L,
    val localPath: String? = null,
    val errorCode: String? = null,
    val retryable: Boolean = false,
    val message: String? = null
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("eventType", SoulseekEvents.TYPE_TRANSFER)
        put("downloadId", downloadId)
        put("state", state.name)
        put("bytesReceived", bytesReceived)
        put("totalBytes", totalBytes)
        put("bytesPerSecond", bytesPerSecond)
        put("localPath", localPath ?: JSONObject.NULL)
        put("errorCode", errorCode ?: JSONObject.NULL)
        put("retryable", retryable)
        put("message", message ?: JSONObject.NULL)
    }
}

/** Событие соединения, пересылаемое в Flutter через EventChannel. */
data class SoulseekConnectionEvent(
    val state: ConnectionState,
    val message: String? = null
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("eventType", SoulseekEvents.TYPE_CONNECTION)
        put("state", state.name)
        put("message", message ?: JSONObject.NULL)
    }
}

/** Общие константы типов событий (контракт EventChannel). */
object SoulseekEvents {
    const val TYPE_TRANSFER = "transfer"
    const val TYPE_CONNECTION = "connection"
    const val TYPE_TRANSFER_SNAPSHOT = "transferSnapshot"

    // eventType строки, приходящие из C# bridge (SoulseekEventDto.eventType).
    const val BRIDGE_CLIENT_STATE_CHANGED = "clientStateChanged"
    const val BRIDGE_DISCONNECTED = "disconnected"
    const val BRIDGE_TRANSFER_STATE_CHANGED = "transferStateChanged"
    const val BRIDGE_TRANSFER_PROGRESS = "transferProgress"
    const val BRIDGE_DOWNLOAD_COMPLETE = "downloadComplete"
    const val BRIDGE_DOWNLOAD_FAILED = "downloadFailed"

    /** Сериализует список событий трансфера в snapshot-событие для Flutter. */
    fun snapshotJson(transfers: List<SoulseekTransferEvent>): JSONObject =
        JSONObject().apply {
            put("eventType", TYPE_TRANSFER_SNAPSHOT)
            put("transfers", JSONArray().apply { transfers.forEach { put(it.toJson()) } })
        }
}

/**
 * Маппинг строковых состояний C# bridge в Kotlin-энумы.
 * Строки могут быть комбинациями flags ("Queued, Completed").
 */
object BridgeStateMapper {

    fun mapTransferState(raw: String?): TransferState {
        if (raw.isNullOrEmpty()) return TransferState.IDLE
        // Порядок важен: сначала терминальные флаги.
        if (raw.contains("Succeeded")) return TransferState.COMPLETED
        if (raw.contains("Cancelled") || raw.contains("Aborted")) return TransferState.CANCELLED
        if (raw.contains("TimedOut") || raw.contains("Errored") || raw.contains("Rejected")) {
            return TransferState.FAILED
        }
        if (raw.contains("Transferring")) return TransferState.DOWNLOADING
        if (raw.contains("Negotiating") || raw.contains("Initializing") || raw.contains("Initialized")) {
            return TransferState.CONNECTING
        }
        if (raw.contains("Requested") || raw.contains("Queued")) return TransferState.QUEUED
        return TransferState.IDLE
    }

    fun mapConnectionState(raw: String?): ConnectionState {
        if (raw.isNullOrEmpty()) return ConnectionState.DISCONNECTED
        // C# SoulseekClientStates — flags: строка может быть комбинацией
        // ("Connected, LoggingIn", "Connected, LoggedIn"). Дефект №6: парсим
        // флаги явно — пользовательский CONNECTED означает ГОТОВНОСТЬ, т.е.
        // Connected+LoggedIn (SoulseekBridge.cs IsReady требует оба).
        // "Connected" без LoggedIn (в т.ч. с LoggingIn/LoggedOut) — клиент
        // ещё НЕ готов → CONNECTING, не CONNECTED.
        val loggedIn = raw.contains("LoggedIn")
        val loggingIn = raw.contains("LoggingIn")
        val connected = raw.contains("Connected")
        val connecting = raw.contains("Connecting")
        val disconnecting = raw.contains("Disconnecting")
        return when {
            loggedIn && connected -> ConnectionState.CONNECTED
            loggedIn -> ConnectionState.CONNECTED
            disconnecting -> ConnectionState.RECONNECTING
            connected || connecting || loggingIn -> ConnectionState.CONNECTING
            else -> ConnectionState.DISCONNECTED
        }
    }
}

/**
 * Разобранный ResultDto — универсальный ответ C# bridge-методов.
 * success=true → data содержит JSON полезной нагрузки (или null).
 */
data class BridgeCallResult(
    val success: Boolean,
    val data: String? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val retryable: Boolean = false
) {
    companion object {
        fun parse(json: String?): BridgeCallResult {
            if (json.isNullOrBlank()) {
                return BridgeCallResult(
                    success = false,
                    errorCode = "EMPTY_RESPONSE",
                    errorMessage = "Bridge returned empty response"
                )
            }
            return try {
                val obj = JSONObject(json)
                BridgeCallResult(
                    success = obj.optBoolean("success", false),
                    data = if (obj.isNull("data")) null else obj.optString("data", null),
                    errorCode = if (obj.isNull("errorCode")) null else obj.optString("errorCode", null),
                    errorMessage = if (obj.isNull("errorMessage")) null else obj.optString("errorMessage", null),
                    retryable = obj.optBoolean("retryable", false)
                )
            } catch (e: Exception) {
                BridgeCallResult(
                    success = false,
                    errorCode = "MALFORMED_RESPONSE",
                    errorMessage = "Bridge returned malformed JSON: ${e.message}"
                )
            }
        }
    }
}

/**
 * Ошибка сервисного слоя: пробрасывается в plugin и превращается в
 * MethodChannel result.error(code, message, {"retryable": bool}).
 */
class SoulseekServiceException(
    val code: String,
    message: String,
    val retryable: Boolean = false
) : Exception(message)

/**
 * Конвертация org.json значений в стандартные типы Flutter StandardMessageCodec
 * (Map/List/String/Int/Long/Double/Boolean/null). JSONObject/JSONArray кодек
 * не понимает, поэтому рекурсивно разворачиваем.
 */
object JsonInterop {

    fun toStandard(value: Any?): Any? = when (value) {
        null -> null
        is JSONObject -> {
            val map = LinkedHashMap<String, Any?>(value.length())
            for (key in value.keys()) {
                map[key] = toStandard(if (value.isNull(key)) null else value.get(key))
            }
            map
        }
        is JSONArray -> {
            val list = ArrayList<Any?>(value.length())
            for (i in 0 until value.length()) {
                list.add(toStandard(if (value.isNull(i)) null else value.get(i)))
            }
            list
        }
        is Boolean, is Int, is Long, is Double, is String -> value
        is Float -> value.toDouble()
        is Number -> value.toLong()
        else -> value.toString()
    }

    /** Map → JSONObject (маршалинг аргументов MethodChannel → C# bridge). */
    fun fromMap(map: Map<*, *>?): JSONObject = JSONObject().apply {
        map?.forEach { (k, v) -> put(k.toString(), wrap(v)) }
    }

    private fun wrap(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> fromMap(value)
        is List<*> -> JSONArray().apply { value.forEach { put(wrap(it)) } }
        else -> value
    }
}
