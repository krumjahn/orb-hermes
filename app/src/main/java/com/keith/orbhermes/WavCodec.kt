package com.keith.orbhermes

/**
 * Minimal RIFF/WAVE helpers.
 *
 * The phone records mono 16-bit PCM at 16 kHz. Captured chunks are joined
 * when a piece of speech was dropped on the way to the bridge, so the whole
 * utterance can be transcribed in one go instead of in pieces.
 */
object WavCodec {

    const val SAMPLE_RATE = 16000

    /** Wraps raw PCM in a WAV header. */
    fun pcmToWav(pcm: ByteArray, sampleRate: Int = SAMPLE_RATE): ByteArray {
        val dataLen = pcm.size
        val out = ByteArray(44 + dataLen)
        var i = 0
        fun ascii(text: String) {
            for (ch in text) out[i++] = ch.code.toByte()
        }
        fun intLe(value: Int) {
            out[i++] = (value and 0xFF).toByte()
            out[i++] = ((value shr 8) and 0xFF).toByte()
            out[i++] = ((value shr 16) and 0xFF).toByte()
            out[i++] = ((value shr 24) and 0xFF).toByte()
        }
        fun shortLe(value: Int) {
            out[i++] = (value and 0xFF).toByte()
            out[i++] = ((value shr 8) and 0xFF).toByte()
        }
        ascii("RIFF")
        intLe(36 + dataLen)
        ascii("WAVE")
        ascii("fmt ")
        intLe(16)
        shortLe(1)                    // PCM
        shortLe(1)                    // mono
        intLe(sampleRate)
        intLe(sampleRate * 2)         // byte rate
        shortLe(2)                    // block align
        shortLe(16)                   // bits per sample
        ascii("data")
        intLe(dataLen)
        pcm.copyInto(out, 44)
        return out
    }

    /** Extracts the PCM payload of a WAV file. */
    fun wavToPcm(wav: ByteArray): ByteArray {
        if (wav.size <= 44) return wav.copyOf()
        // walk the RIFF chunks to find 'data'
        var offset = 12
        while (offset + 8 <= wav.size) {
            val id = String(wav, offset, 4, Charsets.US_ASCII)
            val size = readIntLe(wav, offset + 4)
            if (id == "data") {
                val end = minOf(wav.size, offset + 8 + maxOf(size, 0))
                return wav.copyOfRange(offset + 8, end)
            }
            if (size <= 0) break
            offset += 8 + size + (size and 1)
        }
        // the chunk walk failed: look for the 'data' magic anywhere
        val index = indexOf(wav, "data")
        if (index >= 0 && index + 8 <= wav.size) {
            val size = readIntLe(wav, index + 4)
            val end = minOf(wav.size, index + 8 + maxOf(size, 0))
            return wav.copyOfRange(index + 8, end)
        }
        // no data chunk at all: assume a bare 44 byte header
        return wav.copyOfRange(44, wav.size)
    }

    private fun indexOf(data: ByteArray, magic: String): Int {
        val needle = magic.toByteArray(Charsets.US_ASCII)
        for (i in 0..data.size - needle.size) {
            var match = true
            for (j in needle.indices) {
                if (data[i + j] != needle[j]) {
                    match = false
                    break
                }
            }
            if (match) return i
        }
        return -1
    }

    private fun readIntLe(data: ByteArray, offset: Int): Int =
        (data[offset].toInt() and 0xFF) or
            ((data[offset + 1].toInt() and 0xFF) shl 8) or
            ((data[offset + 2].toInt() and 0xFF) shl 16) or
            ((data[offset + 3].toInt() and 0xFF) shl 24)
}
