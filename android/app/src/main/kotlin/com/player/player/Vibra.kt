package com.player.player

/**
 * Аудиоотпечаток в формате Shazam через нативную libvibra.so
 * (Vibra, GPL-3.0; исходники и JNI-мост — android/app/src/main/cpp/).
 */
object Vibra {
    init {
        System.loadLibrary("vibra")
    }

    class Signature(val uri: String, val sampleMs: Long)

    /** 16-бит моно PCM → отпечаток, `null` — Vibra не справилась. */
    fun fingerprint(pcm: ByteArray, sampleRate: Int): Signature? {
        val raw = nativeFingerprint(pcm, sampleRate) ?: return null
        return Signature(raw[0], raw[1].toLong())
    }

    @JvmStatic
    private external fun nativeFingerprint(pcm: ByteArray, sampleRate: Int): Array<String>?
}
