package com.player.player

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * Локальное SQLite-хранилище для Soulseek-слоя.
 *
 * Три таблицы:
 *  - [TABLE_TRANSFERS]: состояние трансферов (persist + restore).
 *  - [TABLE_CACHE_ENTRIES]: метаданные кэша (LRU eviction, pin).
 *  - [TABLE_SETTINGS]: key-value настройки (soulseek_enabled, listen_port, …).
 *
 * ВАЖНО: пароль Soulseek здесь НЕ хранится — только в flutter_secure_storage
 * (Dart-сторона, Фаза 3). Здесь хранятся лишь non-secret параметры.
 *
 * Проект не использует Room, поэтому чистый SQLiteOpenHelper.
 */
class SoulseekDatabase(context: Context) :
    SQLiteOpenHelper(context, DB_NAME, null, DB_VERSION) {

    companion object {
        private const val DB_NAME = "soulseek.db"

        /**
         * v2 (NEW-3): в cache_entries добавлены колонки title / artist /
         * duration_seconds — кэш-лист показывает хэш-имена файлов, а не
         * человекочитаемые метаданные. Заполняются из TransferContext при
         * completeTransfer; для старых записей остаются NULL (UI фолбэк на
         * basename).
         */
        private const val DB_VERSION = 2

        const val TABLE_TRANSFERS = "transfers"
        const val TABLE_CACHE_ENTRIES = "cache_entries"
        const val TABLE_SETTINGS = "settings"

        // Колонки transfers
        const val COL_DOWNLOAD_ID = "download_id"
        const val COL_CACHE_KEY = "cache_key"
        const val COL_PEER_USERNAME = "peer_username"
        const val COL_REMOTE_FILENAME = "remote_filename"
        const val COL_SIZE_BYTES = "size_bytes"
        const val COL_STATE = "state"
        const val COL_BYTES_RECEIVED = "bytes_received"
        const val COL_LOCAL_PATH = "local_path"
        const val COL_FILE_EXTENSION = "file_extension"
        const val COL_RETRY_COUNT = "retry_count"
        const val COL_CREATED_AT = "created_at"
        const val COL_UPDATED_AT = "updated_at"

        // Колонки cache_entries
        const val COL_LOCAL_PATH_CE = "local_path"
        const val COL_SIZE_BYTES_CE = "size_bytes"
        const val COL_EXTENSION = "extension"
        const val COL_COMPLETE = "complete"
        const val COL_LAST_ACCESS_AT = "last_access_at"
        const val COL_PINNED = "pinned"

        // Колонки cache_entries (v2, NEW-3 — человекочитаемые метаданные)
        const val COL_TITLE = "title"
        const val COL_ARTIST = "artist"
        const val COL_DURATION_SECONDS = "duration_seconds"

        // Колонки settings
        const val COL_KEY = "key"
        const val COL_VALUE = "value"
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS $TABLE_TRANSFERS (
                $COL_DOWNLOAD_ID TEXT PRIMARY KEY,
                $COL_CACHE_KEY TEXT NOT NULL,
                $COL_PEER_USERNAME TEXT NOT NULL,
                $COL_REMOTE_FILENAME TEXT NOT NULL,
                $COL_SIZE_BYTES INTEGER NOT NULL,
                $COL_STATE TEXT NOT NULL,
                $COL_BYTES_RECEIVED INTEGER NOT NULL DEFAULT 0,
                $COL_LOCAL_PATH TEXT,
                $COL_FILE_EXTENSION TEXT,
                $COL_RETRY_COUNT INTEGER NOT NULL DEFAULT 0,
                $COL_CREATED_AT INTEGER NOT NULL,
                $COL_UPDATED_AT INTEGER NOT NULL
            )
            """.trimIndent()
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_transfers_state ON $TABLE_TRANSFERS($COL_STATE)"
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_transfers_cache_key ON $TABLE_TRANSFERS($COL_CACHE_KEY)"
        )

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS $TABLE_CACHE_ENTRIES (
                $COL_CACHE_KEY TEXT PRIMARY KEY,
                $COL_LOCAL_PATH_CE TEXT NOT NULL,
                $COL_SIZE_BYTES_CE INTEGER NOT NULL DEFAULT 0,
                $COL_EXTENSION TEXT,
                $COL_COMPLETE INTEGER NOT NULL DEFAULT 0,
                $COL_LAST_ACCESS_AT INTEGER NOT NULL,
                $COL_PINNED INTEGER NOT NULL DEFAULT 0,
                $COL_TITLE TEXT,
                $COL_ARTIST TEXT,
                $COL_DURATION_SECONDS INTEGER
            )
            """.trimIndent()
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS idx_cache_last_access ON $TABLE_CACHE_ENTRIES($COL_LAST_ACCESS_AT)"
        )

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS $TABLE_SETTINGS (
                $COL_KEY TEXT PRIMARY KEY,
                $COL_VALUE TEXT
            )
            """.trimIndent()
        )

        // Сидируем дефолтные настройки.
        val now = System.currentTimeMillis()
        putSettingRaw(db, SettingsKeys.SOULSEEK_ENABLED, "false")
        putSettingRaw(db, SettingsKeys.LISTEN_PORT, "50000")
        putSettingRaw(db, SettingsKeys.MAX_CACHE_SIZE, "1073741824") // 1 GiB
        putSettingRaw(db, SettingsKeys.MAX_CONCURRENT_DOWNLOADS, "3")
        putSettingRaw(db, SettingsKeys.PREFER_LOSSLESS, "false")
        putSettingRaw(db, SettingsKeys.ALLOWED_FORMATS, "flac,mp3,m4a,alac,wav,ape,wv")
        putSettingRaw(db, SettingsKeys.MAX_RETRY_ATTEMPTS, "3")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // v1 → v2 (NEW-3): человекочитаемые метаданные в cache_entries.
        // ALTER TABLE … ADD COLUMN сохраняет существующие строки: старые
        // записи получают NULL — UI показывает фолбэк (basename файла).
        if (oldVersion < 2) {
            db.execSQL(
                "ALTER TABLE $TABLE_CACHE_ENTRIES ADD COLUMN $COL_TITLE TEXT"
            )
            db.execSQL(
                "ALTER TABLE $TABLE_CACHE_ENTRIES ADD COLUMN $COL_ARTIST TEXT"
            )
            db.execSQL(
                "ALTER TABLE $TABLE_CACHE_ENTRIES ADD COLUMN $COL_DURATION_SECONDS INTEGER"
            )
        }
    }

    // ───────────────────────────────────────────────────────────────────
    //  Transfers CRUD
    // ───────────────────────────────────────────────────────────────────

    /** Полная строка трансфера, сохраняемая в БД. */
    data class TransferRow(
        val downloadId: String,
        val cacheKey: String,
        val peerUsername: String,
        val remoteFilename: String,
        val sizeBytes: Long,
        val state: String,
        val bytesReceived: Long,
        val localPath: String?,
        val fileExtension: String?,
        val retryCount: Int,
        val createdAt: Long,
        val updatedAt: Long
    )

    fun upsertTransfer(row: TransferRow) {
        val now = System.currentTimeMillis()
        val cv = ContentValues().apply {
            put(COL_DOWNLOAD_ID, row.downloadId)
            put(COL_CACHE_KEY, row.cacheKey)
            put(COL_PEER_USERNAME, row.peerUsername)
            put(COL_REMOTE_FILENAME, row.remoteFilename)
            put(COL_SIZE_BYTES, row.sizeBytes)
            put(COL_STATE, row.state)
            put(COL_BYTES_RECEIVED, row.bytesReceived)
            put(COL_LOCAL_PATH, row.localPath)
            put(COL_FILE_EXTENSION, row.fileExtension)
            put(COL_RETRY_COUNT, row.retryCount)
            put(COL_CREATED_AT, if (row.createdAt > 0) row.createdAt else now)
            put(COL_UPDATED_AT, now)
        }
        writableDatabase.insertWithOnConflict(
            TABLE_TRANSFERS, null, cv, SQLiteDatabase.CONFLICT_REPLACE
        )
    }

    /** Обновляет только прогресс/состояние (используется при throttle-чекпоинтах). */
    fun updateTransferProgress(
        downloadId: String,
        state: String,
        bytesReceived: Long
    ) {
        val cv = ContentValues().apply {
            put(COL_STATE, state)
            put(COL_BYTES_RECEIVED, bytesReceived)
            put(COL_UPDATED_AT, System.currentTimeMillis())
        }
        writableDatabase.update(
            TABLE_TRANSFERS, cv,
            "$COL_DOWNLOAD_ID = ?", arrayOf(downloadId)
        )
    }

    fun getTransfer(downloadId: String): TransferRow? {
        val db = readableDatabase
        val c = db.query(
            TABLE_TRANSFERS, null,
            "$COL_DOWNLOAD_ID = ?", arrayOf(downloadId),
            null, null, null
        )
        return c.use { if (it.moveToFirst()) cursorToTransferRow(it) else null }
    }

    /** Все трансферы в незавершённых состояниях (для restore после перезапуска). */
    fun getUnfinishedTransfers(): List<TransferRow> {
        val db = readableDatabase
        val terminalStates = "'COMPLETED','FAILED','CANCELLED'"
        val c = db.query(
            TABLE_TRANSFERS, null,
            "$COL_STATE NOT IN ($terminalStates)", null,
            null, null, "$COL_CREATED_AT ASC"
        )
        return c.use {
            val out = ArrayList<TransferRow>(it.count)
            while (it.moveToNext()) out.add(cursorToTransferRow(it))
            out
        }
    }

    fun deleteTransfer(downloadId: String) {
        writableDatabase.delete(
            TABLE_TRANSFERS, "$COL_DOWNLOAD_ID = ?", arrayOf(downloadId)
        )
    }

    fun deleteTransfersByCacheKey(cacheKey: String) {
        writableDatabase.delete(
            TABLE_TRANSFERS, "$COL_CACHE_KEY = ?", arrayOf(cacheKey)
        )
    }

    private fun cursorToTransferRow(c: android.database.Cursor): TransferRow =
        TransferRow(
            downloadId = c.getString(c.getColumnIndexOrThrow(COL_DOWNLOAD_ID)),
            cacheKey = c.getString(c.getColumnIndexOrThrow(COL_CACHE_KEY)),
            peerUsername = c.getString(c.getColumnIndexOrThrow(COL_PEER_USERNAME)),
            remoteFilename = c.getString(c.getColumnIndexOrThrow(COL_REMOTE_FILENAME)),
            sizeBytes = c.getLong(c.getColumnIndexOrThrow(COL_SIZE_BYTES)),
            state = c.getString(c.getColumnIndexOrThrow(COL_STATE)),
            bytesReceived = c.getLong(c.getColumnIndexOrThrow(COL_BYTES_RECEIVED)),
            localPath = if (c.isNull(c.getColumnIndexOrThrow(COL_LOCAL_PATH)))
                null else c.getString(c.getColumnIndexOrThrow(COL_LOCAL_PATH)),
            fileExtension = if (c.isNull(c.getColumnIndexOrThrow(COL_FILE_EXTENSION)))
                null else c.getString(c.getColumnIndexOrThrow(COL_FILE_EXTENSION)),
            retryCount = c.getInt(c.getColumnIndexOrThrow(COL_RETRY_COUNT)),
            createdAt = c.getLong(c.getColumnIndexOrThrow(COL_CREATED_AT)),
            updatedAt = c.getLong(c.getColumnIndexOrThrow(COL_UPDATED_AT))
        )

    // ───────────────────────────────────────────────────────────────────
    //  Cache entries CRUD
    // ───────────────────────────────────────────────────────────────────

    data class CacheEntryRow(
        val cacheKey: String,
        val localPath: String,
        val sizeBytes: Long,
        val extension: String?,
        val complete: Boolean,
        val lastAccessAt: Long,
        val pinned: Boolean,
        val title: String? = null,
        val artist: String? = null,
        val durationSeconds: Int? = null
    )

    fun upsertCacheEntry(row: CacheEntryRow) {
        val cv = ContentValues().apply {
            put(COL_CACHE_KEY, row.cacheKey)
            put(COL_LOCAL_PATH_CE, row.localPath)
            put(COL_SIZE_BYTES_CE, row.sizeBytes)
            put(COL_EXTENSION, row.extension)
            put(COL_COMPLETE, if (row.complete) 1 else 0)
            put(COL_LAST_ACCESS_AT, row.lastAccessAt)
            put(COL_PINNED, if (row.pinned) 1 else 0)
            put(COL_TITLE, row.title)
            put(COL_ARTIST, row.artist)
            put(COL_DURATION_SECONDS, row.durationSeconds)
        }
        writableDatabase.insertWithOnConflict(
            TABLE_CACHE_ENTRIES, null, cv, SQLiteDatabase.CONFLICT_REPLACE
        )
    }

    fun touchCacheEntry(cacheKey: String, sizeBytes: Long, complete: Boolean) {
        val cv = ContentValues().apply {
            put(COL_SIZE_BYTES_CE, sizeBytes)
            put(COL_COMPLETE, if (complete) 1 else 0)
            put(COL_LAST_ACCESS_AT, System.currentTimeMillis())
        }
        writableDatabase.update(
            TABLE_CACHE_ENTRIES, cv,
            "$COL_CACHE_KEY = ?", arrayOf(cacheKey)
        )
    }

    fun getCacheEntry(cacheKey: String): CacheEntryRow? {
        val c = readableDatabase.query(
            TABLE_CACHE_ENTRIES, null,
            "$COL_CACHE_KEY = ?", arrayOf(cacheKey),
            null, null, null
        )
        return c.use { if (it.moveToFirst()) cursorToCacheRow(it) else null }
    }

    fun deleteCacheEntry(cacheKey: String) {
        writableDatabase.delete(
            TABLE_CACHE_ENTRIES, "$COL_CACHE_KEY = ?", arrayOf(cacheKey)
        )
    }

    /**
     * Возвращает все кэш-записи, отсортированные по lastAccessAt ASC (для LRU).
     * Pinned записи идут в конец (не удаляются первыми).
     */
    fun getAllCacheEntriesLru(): List<CacheEntryRow> {
        val c = readableDatabase.query(
            TABLE_CACHE_ENTRIES, null,
            null, null, null, null,
            "$COL_PINNED ASC, $COL_LAST_ACCESS_AT ASC"
        )
        return c.use {
            val out = ArrayList<CacheEntryRow>(it.count)
            while (it.moveToNext()) out.add(cursorToCacheRow(it))
            out
        }
    }

    fun setCachePinned(cacheKey: String, pinned: Boolean) {
        val cv = ContentValues().apply {
            put(COL_PINNED, if (pinned) 1 else 0)
            put(COL_LAST_ACCESS_AT, System.currentTimeMillis())
        }
        writableDatabase.update(
            TABLE_CACHE_ENTRIES, cv,
            "$COL_CACHE_KEY = ?", arrayOf(cacheKey)
        )
    }

    /** Суммарный размер всех завершённых кэш-записей (для cleanup-решений). */
    fun getTotalCacheSize(): Long {
        val c = readableDatabase.rawQuery(
            "SELECT TOTAL($COL_SIZE_BYTES_CE) FROM $TABLE_CACHE_ENTRIES WHERE $COL_COMPLETE = 1",
            null
        )
        return c.use {
            if (it.moveToFirst()) (it.getLong(0)) else 0L
        }
    }

    private fun cursorToCacheRow(c: android.database.Cursor): CacheEntryRow =
        CacheEntryRow(
            cacheKey = c.getString(c.getColumnIndexOrThrow(COL_CACHE_KEY)),
            localPath = c.getString(c.getColumnIndexOrThrow(COL_LOCAL_PATH_CE)),
            sizeBytes = c.getLong(c.getColumnIndexOrThrow(COL_SIZE_BYTES_CE)),
            extension = if (c.isNull(c.getColumnIndexOrThrow(COL_EXTENSION)))
                null else c.getString(c.getColumnIndexOrThrow(COL_EXTENSION)),
            complete = c.getInt(c.getColumnIndexOrThrow(COL_COMPLETE)) == 1,
            lastAccessAt = c.getLong(c.getColumnIndexOrThrow(COL_LAST_ACCESS_AT)),
            pinned = c.getInt(c.getColumnIndexOrThrow(COL_PINNED)) == 1,
            title = if (c.isNull(c.getColumnIndexOrThrow(COL_TITLE)))
                null else c.getString(c.getColumnIndexOrThrow(COL_TITLE)),
            artist = if (c.isNull(c.getColumnIndexOrThrow(COL_ARTIST)))
                null else c.getString(c.getColumnIndexOrThrow(COL_ARTIST)),
            durationSeconds = if (c.isNull(c.getColumnIndexOrThrow(COL_DURATION_SECONDS)))
                null else c.getInt(c.getColumnIndexOrThrow(COL_DURATION_SECONDS))
        )

    // ───────────────────────────────────────────────────────────────────
    //  Settings CRUD
    // ───────────────────────────────────────────────────────────────────

    fun getSetting(key: String, default: String? = null): String? {
        val c = readableDatabase.query(
            TABLE_SETTINGS, arrayOf(COL_VALUE),
            "$COL_KEY = ?", arrayOf(key),
            null, null, null
        )
        return c.use {
            if (it.moveToFirst()) it.getString(0) else default
        }
    }

    fun getSettingInt(key: String, default: Int): Int =
        getSetting(key)?.toIntOrNull() ?: default

    fun getSettingLong(key: String, default: Long): Long =
        getSetting(key)?.toLongOrNull() ?: default

    fun getSettingBool(key: String, default: Boolean): Boolean =
        getSetting(key)?.toBooleanStrictOrNull() ?: default

    fun putSetting(key: String, value: String) {
        putSettingRaw(writableDatabase, key, value)
    }

    fun putSettingInt(key: String, value: Int) = putSetting(key, value.toString())
    fun putSettingLong(key: String, value: Long) = putSetting(key, value.toString())
    fun putSettingBool(key: String, value: Boolean) = putSetting(key, value.toString())

    private fun putSettingRaw(db: SQLiteDatabase, key: String, value: String) {
        val cv = ContentValues().apply {
            put(COL_KEY, key)
            put(COL_VALUE, value)
        }
        db.insertWithOnConflict(
            TABLE_SETTINGS, null, cv, SQLiteDatabase.CONFLICT_REPLACE
        )
    }
}

/** Ключи настроек в settings-таблице. */
object SettingsKeys {
    const val SOULSEEK_ENABLED = "soulseek_enabled"
    const val LISTEN_PORT = "listen_port"
    const val MAX_CACHE_SIZE = "max_cache_size"
    const val MAX_CONCURRENT_DOWNLOADS = "max_concurrent_downloads"
    const val PREFER_LOSSLESS = "prefer_lossless"
    const val ALLOWED_FORMATS = "allowed_formats"
    const val MAX_RETRY_ATTEMPTS = "max_retry_attempts"
    /** Имя пользователя Soulseek (non-secret, для отображения; пароль в secure storage). */
    const val USERNAME = "username"
}
