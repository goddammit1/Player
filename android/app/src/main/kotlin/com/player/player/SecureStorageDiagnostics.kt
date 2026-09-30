package com.player.player

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.security.auth.x500.X500Principal

/**
 * Диагностика secure storage (flutter_secure_storage 9.2.4) для отчёта,
 * который пользователь отправляет разработчику из настроек Soulseek.
 *
 * Зачем: при сбое инициализации плагин пишет настоящую причину только в
 * logcat (Log.e) и проглатывает её — в Dart доходит лишь вторичный NPE из
 * write(). Здесь те же шаги (Keystore, RSA-ключ плагина, MasterKey,
 * EncryptedSharedPreferences) выполняются напрямую, и каждое исключение
 * попадает в отчёт целиком. Разные шаги разделяют гипотезы: сломан весь
 * Keystore устройства / испорчены конкретные ключи приложения / ключи в
 * порядке, но не расшифровываются keyset'ы в prefs.
 *
 * Отчёт НЕ содержит учётных данных: только сведения об устройстве, наличие
 * ключей и записей (без значений) и тексты исключений.
 *
 * Существующее состояние только читается. Создаются лишь временные ключи
 * Keystore и временный prefs-файл с префиксом player_diagnostics_, они
 * удаляются в конце каждого шага.
 */
class SecureStorageDiagnostics private constructor(private val context: Context) {

    companion object {
        private const val CHANNEL = "player/diagnostics"
        private const val KEYSTORE = "AndroidKeyStore"

        // Имена из flutter_secure_storage 9.2.4 и androidx.security-crypto.
        private const val PLUGIN_PREFS = "FlutterSecureStorage"
        private const val PLUGIN_KEY_PREFS = "FlutterSecureKeyStorage"
        private const val PLUGIN_AES_PREF_KEY =
            "VGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"
        private const val PLUGIN_ENTRY_PREFIX =
            "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_"
        private const val PLUGIN_ALGORITHM_KEY = "FlutterSecureSAlgorithmKey"
        private const val PLUGIN_ALGORITHM_STORAGE = "FlutterSecureSAlgorithmStorage"
        private const val ESP_KEY_KEYSET =
            "__androidx_security_crypto_encrypted_prefs_key_keyset__"
        private const val ESP_VALUE_KEYSET =
            "__androidx_security_crypto_encrypted_prefs_value_keyset__"

        // Временные объекты диагностики — удаляются после каждого шага.
        private const val DIAG_AES_ALIAS = "player_diagnostics_aes"
        private const val DIAG_RSA_ALIAS = "player_diagnostics_rsa"
        private const val DIAG_MASTER_ALIAS = "player_diagnostics_master"
        private const val DIAG_ESP_PREFS = "player_diagnostics_esp"

        // Теги, под которыми плагин и Tink пишут причины сбоев.
        private val LOG_TAGS = listOf(
            "SecureStorageAndroid",
            "StorageCipher18Impl",
            "AndroidKeysetManager",
            "AndroidKeystoreKmsClient",
            "AndroidKeystoreAesGcm",
        )
        private const val MAX_LOG_LINES = 150
        private const val MAX_FRAMES = 8

        fun register(messenger: BinaryMessenger, context: Context): MethodChannel {
            val appContext = context.applicationContext
            return MethodChannel(messenger, CHANNEL).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "secureStorageReport") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    // Операции Keystore блокирующие (до секунд на медленном
                    // TEE) — выполняем вне UI-потока, ответ — на главном.
                    val main = Handler(Looper.getMainLooper())
                    Thread({
                        val report = runCatching {
                            SecureStorageDiagnostics(appContext).buildReport()
                        }.getOrElse { "Native report failed:\n${describe(it)}" }
                        main.post { result.success(report) }
                    }, "secure-storage-diagnostics").start()
                }
            }
        }

        private fun describe(t: Throwable): String = buildString {
            var cur: Throwable? = t
            val seen = HashSet<Throwable>()
            while (cur != null && seen.add(cur)) {
                if (cur !== t) append("Caused by: ")
                append(cur.javaClass.name).append(": ").append(cur.message).append('\n')
                cur.stackTrace.take(MAX_FRAMES).forEach { append("    at ").append(it).append('\n') }
                cur = cur.cause
            }
        }.trimEnd()
    }

    private val random = SecureRandom()

    fun buildReport(): String = buildString {
        appendDevice()
        append('\n')
        appendPrefs()
        append('\n')
        appendKeystore()
        append('\n')
        appendEncryptedPrefs()
        append('\n')
        appendLog()
    }

    // ── Отчёт по секциям ──

    private fun StringBuilder.appendDevice() {
        header("Device")
        append("Model: ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE})\n")
        append("Android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}), ")
        append("patch ${Build.VERSION.SECURITY_PATCH}\n")
        append("Build: ${Build.FINGERPRINT}\n")
        append("Locale: ${Locale.getDefault()}\n")
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        append("Screen lock set: ${keyguard?.isDeviceSecure ?: "unknown"}\n")
        runCatching {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)
            append("App: ${info.versionName}, installed ${fmt.format(Date(info.firstInstallTime))}, ")
            append("updated ${fmt.format(Date(info.lastUpdateTime))}\n")
        }
    }

    /** Состояние prefs-файлов плагина: только наличие и количество, без значений. */
    private fun StringBuilder.appendPrefs() {
        header("Plugin preferences (presence only)")
        step("$PLUGIN_PREFS.xml") {
            val all = context.getSharedPreferences(PLUGIN_PREFS, Context.MODE_PRIVATE).all
            val legacy = all.keys.count { it.startsWith(PLUGIN_ENTRY_PREFIX) }
            val keysets = listOf(ESP_KEY_KEYSET, ESP_VALUE_KEYSET).count { it in all }
            // Маркеры хранят только имена алгоритмов — не секрет.
            val markers = listOf(PLUGIN_ALGORITHM_KEY, PLUGIN_ALGORITHM_STORAGE).filter { it in all }
            val encrypted = all.size - legacy - keysets - markers.size
            "${all.size} entries; ESP keysets: $keysets/2; " +
                "ESP-encrypted entries: $encrypted; legacy-cipher entries: $legacy; " +
                "algorithm markers: ${markers.joinToString { "$it=${all[it]}" }.ifEmpty { "none" }}"
        }
        step("$PLUGIN_KEY_PREFS.xml") {
            val prefs = context.getSharedPreferences(PLUGIN_KEY_PREFS, Context.MODE_PRIVATE)
            "wrapped AES key: ${if (prefs.contains(PLUGIN_AES_PREF_KEY)) "present" else "absent"}"
        }
    }

    private fun StringBuilder.appendKeystore() {
        header("Android Keystore")
        val ks = try {
            KeyStore.getInstance(KEYSTORE).apply { load(null) }
        } catch (t: Throwable) {
            fail("open AndroidKeyStore", t)
            return
        }
        append("Aliases: ${runCatching { ks.aliases().toList().joinToString().ifEmpty { "none" } }.getOrElse { "error: ${it.message}" }}\n")

        // 1. Работает ли Keystore вообще: новый AES-ключ + шифрование.
        step("fresh AES-GCM key: generate, encrypt, decrypt") {
            try {
                val key = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
                    init(
                        KeyGenParameterSpec.Builder(
                            DIAG_AES_ALIAS,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setKeySize(256)
                            .build()
                    )
                    generateKey()
                }
                aesGcmRoundTrip(key)
                null
            } finally {
                runCatching { ks.deleteEntry(DIAG_AES_ALIAS) }
            }
        }

        // 2. Генерация RSA-ключа ровно со спецификацией плагина.
        step("fresh RSA key (plugin spec): generate, wrap, unwrap") {
            try {
                generatePluginRsaKey(DIAG_RSA_ALIAS)
                rsaWrapRoundTrip(ks, DIAG_RSA_ALIAS)
                null
            } finally {
                runCatching { ks.deleteEntry(DIAG_RSA_ALIAS) }
            }
        }

        // 3. Существующий RSA-ключ плагина (legacy-шифр).
        val rsaAlias = "${context.packageName}.FlutterSecureStoragePluginKey"
        if (ks.containsAlias(rsaAlias)) {
            step("existing plugin RSA key: wrap, unwrap") {
                rsaWrapRoundTrip(ks, rsaAlias)
                null
            }
            val wrapped = context.getSharedPreferences(PLUGIN_KEY_PREFS, Context.MODE_PRIVATE)
                .getString(PLUGIN_AES_PREF_KEY, null)
            if (wrapped != null) {
                step("existing wrapped AES key: unwrap with plugin RSA key") {
                    rsaCipher().run {
                        init(Cipher.UNWRAP_MODE, ks.getKey(rsaAlias, null) as PrivateKey)
                        unwrap(Base64.decode(wrapped, Base64.DEFAULT), "AES", Cipher.SECRET_KEY)
                    }
                    null
                }
            }
        } else {
            append("[--]   existing plugin RSA key: absent (created on first use)\n")
        }

        // 4. Существующий MasterKey EncryptedSharedPreferences.
        if (ks.containsAlias(MasterKey.DEFAULT_MASTER_KEY_ALIAS)) {
            step("existing master key: encrypt, decrypt") {
                aesGcmRoundTrip(ks.getKey(MasterKey.DEFAULT_MASTER_KEY_ALIAS, null) as SecretKey)
                null
            }
        } else {
            append("[--]   existing master key: absent (created on first use)\n")
        }
    }

    private fun StringBuilder.appendEncryptedPrefs() {
        header("EncryptedSharedPreferences")

        // 5. Весь стек security-crypto + Tink на временных ключе и файле.
        step("fresh master key + temp file: create, put, get") {
            try {
                val masterKey = MasterKey.Builder(context, DIAG_MASTER_ALIAS)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
                val prefs = createEncryptedPrefs(DIAG_ESP_PREFS, masterKey)
                check(prefs.edit().putString("probe", "ok").commit()) { "commit() returned false" }
                check(prefs.getString("probe", null) == "ok") { "read back mismatch" }
                null
            } finally {
                runCatching { context.deleteSharedPreferences(DIAG_ESP_PREFS) }
                runCatching {
                    KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(DIAG_MASTER_ALIAS)
                }
            }
        }

        // 6. Инициализация плагина на реальных данных. Выполняется, только
        // если master key и оба keyset'а уже есть: тогда create() лишь читает
        // и расшифровывает keyset'ы и ничего не создаёт и не перезаписывает.
        val prefs = context.getSharedPreferences(PLUGIN_PREFS, Context.MODE_PRIVATE)
        val hasKeysets = prefs.contains(ESP_KEY_KEYSET) && prefs.contains(ESP_VALUE_KEYSET)
        val hasMasterKey = runCatching {
            KeyStore.getInstance(KEYSTORE).apply { load(null) }
                .containsAlias(MasterKey.DEFAULT_MASTER_KEY_ALIAS)
        }.getOrDefault(false)
        if (hasKeysets && hasMasterKey) {
            step("existing master key + $PLUGIN_PREFS keysets: open (read-only)") {
                // Та же спецификация ключа, что в FlutterSecureStorage.java.
                val masterKey = MasterKey.Builder(context)
                    .setKeyGenParameterSpec(
                        KeyGenParameterSpec.Builder(
                            MasterKey.DEFAULT_MASTER_KEY_ALIAS,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setKeySize(256)
                            .build()
                    )
                    .build()
                createEncryptedPrefs(PLUGIN_PREFS, masterKey)
                null
            }
        } else {
            append("[--]   existing $PLUGIN_PREFS keysets: skipped ")
            append("(keysets ${if (hasKeysets) "present" else "absent"}, ")
            append("master key ${if (hasMasterKey) "present" else "absent"})\n")
        }
    }

    /** Выдержка из logcat приложения (без READ_LOGS видны только свои записи). */
    private fun StringBuilder.appendLog() {
        header("Log (own app, tags: ${LOG_TAGS.joinToString()})")
        val lines = try {
            val process = ProcessBuilder(
                listOf("logcat", "-d", "-v", "time", "-s") + LOG_TAGS.map { "$it:V" }
            ).redirectErrorStream(true).start()
            try {
                process.inputStream.bufferedReader().use { it.readLines() }
            } finally {
                process.destroy()
            }
        } catch (t: Throwable) {
            fail("read logcat", t)
            return
        }
        val tail = lines.filterNot { it.startsWith("--------- beginning of") }.takeLast(MAX_LOG_LINES)
        if (tail.isEmpty()) {
            append("(no entries: nothing logged yet or the buffer has rotated)\n")
        } else {
            tail.forEach { append(it).append('\n') }
        }
    }

    // ── Криптографические шаги ──

    private fun aesGcmRoundTrip(key: SecretKey) {
        val plain = ByteArray(32).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        val encrypted = cipher.doFinal(plain)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        check(cipher.doFinal(encrypted).contentEquals(plain)) { "decrypted data mismatch" }
    }

    /** Как RSACipher18Implementation: PKCS1 через AndroidKeyStoreBCWorkaround. */
    private fun rsaCipher(): Cipher =
        Cipher.getInstance("RSA/ECB/PKCS1Padding", "AndroidKeyStoreBCWorkaround")

    private fun rsaWrapRoundTrip(ks: KeyStore, alias: String) {
        val publicKey = checkNotNull(ks.getCertificate(alias)) { "no certificate for $alias" }.publicKey
        val privateKey = checkNotNull(ks.getKey(alias, null) as? PrivateKey) { "no private key for $alias" }
        val secret = SecretKeySpec(ByteArray(16).also(random::nextBytes), "AES")
        val wrapped = rsaCipher().run {
            init(Cipher.WRAP_MODE, publicKey)
            wrap(secret)
        }
        val unwrapped = rsaCipher().run {
            init(Cipher.UNWRAP_MODE, privateKey)
            unwrap(wrapped, "AES", Cipher.SECRET_KEY)
        }
        check(unwrapped.encoded.contentEquals(secret.encoded)) { "unwrapped key mismatch" }
    }

    /**
     * Спецификация и обход локали — как в RSACipher18Implementation.createKeys
     * (на части локалей генерация сертификата падает без Locale.ENGLISH).
     */
    private fun generatePluginRsaKey(alias: String) {
        val localeBefore = Locale.getDefault()
        try {
            Locale.setDefault(Locale.ENGLISH)
            val start = Calendar.getInstance()
            val end = Calendar.getInstance().apply { add(Calendar.YEAR, 25) }
            KeyPairGenerator.getInstance("RSA", KEYSTORE).run {
                initialize(
                    KeyGenParameterSpec.Builder(
                        alias,
                        KeyProperties.PURPOSE_DECRYPT or KeyProperties.PURPOSE_ENCRYPT,
                    )
                        .setCertificateSubject(X500Principal("CN=$alias"))
                        .setDigests(KeyProperties.DIGEST_SHA256)
                        .setBlockModes(KeyProperties.BLOCK_MODE_ECB)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1)
                        .setCertificateSerialNumber(BigInteger.ONE)
                        .setCertificateNotBefore(start.time)
                        .setCertificateNotAfter(end.time)
                        .build()
                )
                generateKeyPair()
            }
        } finally {
            Locale.setDefault(localeBefore)
        }
    }

    private fun createEncryptedPrefs(name: String, masterKey: MasterKey) =
        EncryptedSharedPreferences.create(
            context,
            name,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

    // ── Форматирование ──

    private fun StringBuilder.header(title: String) {
        append("== ").append(title).append(" ==\n")
    }

    /** Throwable, а не Exception: ошибки загрузки классов (R8) тоже в отчёт. */
    private fun StringBuilder.step(name: String, block: () -> String?) {
        try {
            val detail = block()
            append("[OK]   ").append(name)
            if (!detail.isNullOrEmpty()) append(": ").append(detail)
            append('\n')
        } catch (t: Throwable) {
            fail(name, t)
        }
    }

    private fun StringBuilder.fail(name: String, t: Throwable) {
        append("[FAIL] ").append(name).append('\n')
        append(describe(t).prependIndent("       ")).append('\n')
    }
}
