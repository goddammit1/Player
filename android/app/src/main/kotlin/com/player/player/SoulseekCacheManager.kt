package com.player.player

import android.util.Log
import java.io.File
import java.security.MessageDigest

/**
 * Управление кэшем скачанных файлов Soulseek.
 *
 * Физически файлы лежат в `<app_cache>/soulseek_cache/`:
 *  - во время загрузки: `<cacheKey>.part`
 *  - после завершения: `<cacheKey>.<extension>` (atomic rename делает C# bridge).
 *
 * Метаданные (путь, размер, complete, lastAccessAt, pinned) хранятся в
 * [SoulseekDatabase] (таблица cache_entries), что позволяет LRU eviction и
 * восстановление после перезапуска.
 *
 * ВАЖНО: само скачивание и atomic rename .part → final выполняет C# bridge
 * ([SoulseekBridge.downloadToFileAsync]). Этот менеджер отвечает за:
 *  - проверку наличия завершённого файла (cache hit),
 *  - поиск .part файла для resume,
 *  - обновление метаданных после завершения,
 *  - LRU cleanup и удаление кэша,
 *  - sanitization ключей/расширений,
 *  - pin/unpin.
 */
class SoulseekCacheManager(
    private val cacheDir: File,
    private val database: SoulseekDatabase,
    private val maxCacheSizeBytes: Long
) {
    companion object {
        private const val TAG = "SoulseekCacheManager"
        const val PART_SUFFIX = ".part"

        /**
         * Вычисляет deterministic cacheKey = sha256(sourceId + peerUsername + remoteFilename + sizeBytes).
         * Hex-строка (64 символа), безопасна как имя файла.
         */
        fun computeCacheKey(
            sourceId: String,
            peerUsername: String,
            remoteFilename: String,
            sizeBytes: Long
        ): String {
            val input = "$sourceId\u0000$peerUsername\u0000$remoteFilename\u0000$sizeBytes"
            val md = MessageDigest.getInstance("SHA-256")
            return md.digest(input.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
        }
    }

    init {
        if (!cacheDir.exists()) cacheDir.mkdirs()
    }

    /** Абсолютный путь к директории кэша — передаётся в C# bridge как localDirectory. */
    val cacheDirAbsolutePath: String
        get() = cacheDir.absolutePath

    /** Запись о кэшированном файле (если файл существует на диске). */
    data class CacheEntry(
        val cacheKey: String,
        val localPath: String,
        val sizeBytes: Long,
        val complete: Boolean,
        val lastAccessAt: Long,
        val pinned: Boolean,
        /** NEW-3: человекочитаемые метаданные (NULL для старых записей). */
        val title: String? = null,
        val artist: String? = null,
        val durationSeconds: Int? = null
    )

    /**
     * Возвращает завершённый кэш-файл или null, если файла нет/он неполный.
     * Обновляет lastAccessAt (LRU touch) при cache hit.
     */
    fun getCacheEntry(cacheKey: String): CacheEntry? {
        val sanitized = sanitizeCacheKey(cacheKey) ?: return null
        val row = database.getCacheEntry(sanitized) ?: return null
        val file = File(row.localPath)
        if (!file.exists() || file.length() == 0L) {
            // Файл пропал с диска (например, пользователь очистил кэш ОС) —
            // удаляем «висящую» запись.
            database.deleteCacheEntry(sanitized)
            return null
        }
        if (row.complete) {
            // LRU touch
            database.touchCacheEntry(sanitized, file.length(), true)
            return CacheEntry(
                cacheKey = sanitized,
                localPath = row.localPath,
                sizeBytes = file.length(),
                complete = true,
                lastAccessAt = System.currentTimeMillis(),
                pinned = row.pinned,
                title = row.title,
                artist = row.artist,
                durationSeconds = row.durationSeconds
            )
        }
        return null
    }

    /**
     * Все завершённые кэш-записи с существующим на диске файлом, LRU-порядок.
     *
     * P1-каскад: источник истины для Flutter cache sheet — нативная БД,
     * а не Dart-индекс knownCacheKeys (последний терял записи, завершённые
     * без активной подписки на event stream).
     */
    fun getAllCacheEntries(): List<CacheEntry> {
        val rows = database.getAllCacheEntriesLru()
        val out = ArrayList<CacheEntry>(rows.size)
        for (row in rows) {
            val file = File(row.localPath)
            if (!row.complete || !file.exists() || file.length() == 0L) continue
            out.add(
                CacheEntry(
                    cacheKey = row.cacheKey,
                    localPath = row.localPath,
                    sizeBytes = file.length(),
                    complete = true,
                    lastAccessAt = row.lastAccessAt,
                    pinned = row.pinned,
                    title = row.title,
                    artist = row.artist,
                    durationSeconds = row.durationSeconds
                )
            )
        }
        return out
    }

    /**
     * Возвращает .part файл для resume, если он существует и имеет размер > 0.
     * Не проверяет complete-флаг: чисто по наличию .part на диске.
     */
    fun getPartFile(cacheKey: String): File? {
        val sanitized = sanitizeCacheKey(cacheKey) ?: return null
        val partFile = File(cacheDir, "$sanitized$PART_SUFFIX")
        return if (partFile.exists() && partFile.length() > 0L) partFile else null
    }

    /**
     * Возвращает .part файл для новой/продолжаемой загрузки.
     * Если .part уже есть — возвращаем его (resume); иначе вернётся путь,
     * куда C# bridge запишет данные (он сам создаст FileStream).
     */
    fun ensurePartFile(cacheKey: String): File {
        val sanitized = sanitizeCacheKey(cacheKey)
            ?: throw SoulseekServiceException(
                "INVALID_CACHE_KEY",
                "cacheKey contains invalid characters",
                retryable = false
            )
        return File(cacheDir, "$sanitized$PART_SUFFIX")
    }

    /**
     * Регистрирует завершённую загрузку в БД: ищет финальный файл
     * `<cacheKey>.<extension>`, обновляет cache_entries.
     *
     * NEW-3: [title]/[artist]/[durationSeconds] — человекочитаемые
     * метаданные из поисковой выдачи; NULL допустимы (restore-сценарий).
     *
     * C# bridge делает atomic rename .part → final; здесь мы лишь фиксируем
     * результат в метаданных.
     */
    fun completeTransfer(
        cacheKey: String,
        extension: String,
        title: String? = null,
        artist: String? = null,
        durationSeconds: Int? = null
    ): File? {
        val sanitizedKey = sanitizeCacheKey(cacheKey) ?: return null
        val safeExt = sanitizeExtension(extension) ?: "dat"
        val finalFile = File(cacheDir, "$sanitizedKey.$safeExt")
        if (!finalFile.exists()) {
            Log.w(TAG, "completeTransfer: final file not found: ${finalFile.absolutePath}")
            return null
        }
        val size = finalFile.length()
        database.upsertCacheEntry(
            SoulseekDatabase.CacheEntryRow(
                cacheKey = sanitizedKey,
                localPath = finalFile.absolutePath,
                sizeBytes = size,
                extension = safeExt,
                complete = true,
                lastAccessAt = System.currentTimeMillis(),
                pinned = false,
                title = title,
                artist = artist,
                durationSeconds = durationSeconds
            )
        )
        // После регистрации нового файла — запускаем cleanup, чтобы не превысить лимит.
        cleanup()
        return finalFile
    }

    /**
     * Удаляет кэш-файл и запись в БД для [cacheKey].
     * Удаляет как финальный файл, так и .part (если остался).
     */
    fun removeCache(cacheKey: String): Boolean {
        val sanitized = sanitizeCacheKey(cacheKey) ?: return false
        var removedAny = false
        val row = database.getCacheEntry(sanitized)
        if (row != null) {
            removedAny = tryDelete(File(row.localPath))
            database.deleteCacheEntry(sanitized)
        }
        // .part мог остаться без записи в БД (прерванная загрузка).
        val partFile = File(cacheDir, "$sanitized$PART_SUFFIX")
        removedAny = tryDelete(partFile) || removedAny
        // Также удаляем transfer-записи, связанные с этим cacheKey.
        database.deleteTransfersByCacheKey(sanitized)
        return removedAny
    }

    /** Закрепляет файл (не удаляется при LRU cleanup). */
    fun pin(cacheKey: String, pinned: Boolean) {
        val sanitized = sanitizeCacheKey(cacheKey) ?: return
        database.setCachePinned(sanitized, pinned)
    }

    fun isPinned(cacheKey: String): Boolean {
        val sanitized = sanitizeCacheKey(cacheKey) ?: return false
        return database.getCacheEntry(sanitized)?.pinned ?: false
    }

    /**
     * LRU eviction: если суммарный размер завершённых кэш-файлов превышает
     * [maxCacheSizeBytes], удаляем самые старые (по lastAccessAt) незакреплённые
     * файлы, пока не уложимся в лимит.
     *
     * Возвращает количество удалённых файлов.
     */
    fun cleanup(): Int {
        if (maxCacheSizeBytes <= 0L) return 0
        val entries = database.getAllCacheEntriesLru()
        var totalSize = entries.filter { it.complete }.sumOf { it.sizeBytes }
        if (totalSize <= maxCacheSizeBytes) return 0

        var removed = 0
        for (entry in entries) {
            if (totalSize <= maxCacheSizeBytes) break
            if (!entry.complete) continue
            if (entry.pinned) continue
            val file = File(entry.localPath)
            val fileSize = if (file.exists()) file.length() else 0L
            if (tryDelete(file)) {
                database.deleteCacheEntry(entry.cacheKey)
                database.deleteTransfersByCacheKey(entry.cacheKey)
                totalSize -= fileSize
                removed++
            }
        }
        if (removed > 0) {
            Log.i(TAG, "cleanup: removed $removed cache files, size now ~$totalSize bytes")
        }
        return removed
    }

    /** Очищает весь кэш (кроме pinned) — используется при reset. */
    fun clearAll(includePinned: Boolean = false): Int {
        val entries = database.getAllCacheEntriesLru()
        var removed = 0
        for (entry in entries) {
            if (!includePinned && entry.pinned) continue
            if (tryDelete(File(entry.localPath))) removed++
            tryDelete(File(cacheDir, "${entry.cacheKey}$PART_SUFFIX"))
            database.deleteCacheEntry(entry.cacheKey)
        }
        return removed
    }

    /** Текущий суммарный размер завершённого кэша. */
    fun totalCacheSize(): Long = database.getTotalCacheSize()

    // ───────────────────────────────────────────────────────────────────
    //  Sanitization — защита от path traversal
    // ───────────────────────────────────────────────────────────────────

    /**
     * Проверяет, что [cacheKey] — безопасное имя файла: нет path-сепараторов,
     * нет `..`, не абсолютный путь. SHA-256 hex всегда проходит, но метод
     * защищает от случаев, когда ключ формируется на стороне без хэширования.
     *
     * Возвращает sanitized ключ (или null, если ключ невалиден).
     */
    fun sanitizeCacheKey(cacheKey: String): String? {
        if (cacheKey.isBlank()) return null
        if (cacheKey.contains("..") ||
            cacheKey.contains('/') ||
            cacheKey.contains('\\') ||
            cacheKey.contains(File.separatorChar)
        ) {
            return null
        }
        // Дополнительно: заменяем любые недопустимые для имён файлов символы.
        val cleaned = cacheKey.map { c ->
            if (c in INVALID_FILENAME_CHARS || c.code < 32) '_' else c
        }.joinToString("")
        return cleaned.ifBlank { null }
    }

    /** Санитизация расширения: убираем точку, path-сепараторы, traversal. */
    fun sanitizeExtension(extension: String): String? {
        if (extension.isBlank()) return null
        var ext = extension.trim().trimStart('.')
        if (ext.contains("..") || ext.contains('/') || ext.contains('\\') || ext.contains(File.separatorChar)) {
            return null
        }
        ext = ext.map { c ->
            if (c in INVALID_FILENAME_CHARS || c.code < 32) '_' else c
        }.joinToString("")
        return ext.ifBlank { null }
    }

    private val INVALID_FILENAME_CHARS = setOf(
        '<', '>', ':', '"', '|', '?', '*', '\u0000'
    )

    private fun tryDelete(file: File): Boolean {
        return try {
            if (file.exists()) file.delete() else false
        } catch (e: Exception) {
            Log.w(TAG, "Failed to delete ${file.absolutePath}: ${e.message}")
            false
        }
    }
}
