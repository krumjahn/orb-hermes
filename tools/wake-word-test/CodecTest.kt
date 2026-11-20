import com.keith.orbhermes.WavCodec

/**
 * Checks the WAV helpers used to re-read a whole utterance when a captured
 * chunk was lost on the way to the bridge.
 */
fun main() {
    var failures = 0

    fun check(name: String, ok: Boolean, detail: String = "") {
        if (!ok) {
            failures++
            println("FAIL $name${if (detail.isEmpty()) "" else " - $detail"}")
        }
    }

    // round trip: pcm -> wav -> pcm
    val pcm = ByteArray(3200) { (it % 256).toByte() }   // 1600 samples
    val wav = WavCodec.pcmToWav(pcm)
    check("wav header size", wav.size == 44 + pcm.size, "got ${wav.size}")
    check("riff magic", String(wav, 0, 4, Charsets.US_ASCII) == "RIFF")
    check("wave magic", String(wav, 8, 4, Charsets.US_ASCII) == "WAVE")
    check("data magic", String(wav, 36, 4, Charsets.US_ASCII) == "data")
    check("sample rate", WavCodec.readIntLe(wav, 24) == 16000)
    check("channels", WavCodec.readShortLe(wav, 22) == 1)
    check("bits per sample", WavCodec.readShortLe(wav, 34) == 16)
    check("data length", WavCodec.readIntLe(wav, 40) == pcm.size)

    val back = WavCodec.wavToPcm(wav)
    check("round trip length", back.size == pcm.size, "got ${back.size}")
    check("round trip content", back.contentEquals(pcm))

    // joining two chunks and reading them back must give the same bytes
    val a = ByteArray(160) { 1 }
    val b = ByteArray(160) { 2 }
    val joined = a + b
    val joinedWav = WavCodec.pcmToWav(joined)
    check("joined round trip", WavCodec.wavToPcm(joinedWav).contentEquals(joined))

    // a WAV with an extra chunk before 'data' must still be found
    val inner = WavCodec.pcmToWav(pcm)
    val junk = ByteArray(12 + 8 + 4)
    "LIFF".forEachIndexed { i, c -> junk[12 + i] = c.code.toByte() }
    junk[16] = 4                                   // chunk size
    val withJunk = junk + inner.copyOfRange(12, inner.size)
    val junkPcm = WavCodec.wavToPcm(withJunk)
    check("chunk walk", junkPcm.contentEquals(pcm), "got ${junkPcm.size} bytes")

    // and a file where the chunk walk cannot work at all
    val garbage = ByteArray(10 + pcm.size)
    "xxdata".forEachIndexed { i, c -> garbage[i] = c.code.toByte() }
    garbage[6] = (pcm.size and 0xFF).toByte()          // payload size
    garbage[7] = ((pcm.size shr 8) and 0xFF).toByte()
    pcm.copyInto(garbage, 10)
    check("magic fallback", WavCodec.wavToPcm(garbage).contentEquals(pcm))

    // a bare header (no chunk walk) still yields the payload
    check("bare header", WavCodec.wavToPcm(wav).contentEquals(pcm))

    if (failures == 0) {
        println("ALL WAV CODEC TESTS PASS")
    } else {
        println("$failures FAILURES")
        kotlin.system.exitProcess(1)
    }
}

/** Small helpers so the test can read the header fields directly. */
private fun WavCodec.readIntLe(data: ByteArray, offset: Int): Int =
    (data[offset].toInt() and 0xFF) or
        ((data[offset + 1].toInt() and 0xFF) shl 8) or
        ((data[offset + 2].toInt() and 0xFF) shl 16) or
        ((data[offset + 3].toInt() and 0xFF) shl 24)

private fun WavCodec.readShortLe(data: ByteArray, offset: Int): Int =
    (data[offset].toInt() and 0xFF) or ((data[offset + 1].toInt() and 0xFF) shl 8)
