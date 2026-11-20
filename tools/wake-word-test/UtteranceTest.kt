import com.keith.orbhermes.Utterance
import com.keith.orbhermes.UtteranceText
import com.keith.orbhermes.WavCodec

/**
 * The utterance is cut into clips, and a cut lands in the middle of a word as
 * often as not. Transcribed one clip at a time, every cut costs a word.
 *
 * The real case: "how are the Toronto Raptors" came back as "how are the
 * Toronto rap" plus "Doctors." - two clips, two transcripts, one lost word
 * and one word that was never spoken.
 *
 * These checks make sure the whole utterance is transcribed in one go, so the
 * cuts cannot cost anything.
 */
private var failures = 0

private fun show(text: String): String = "\"" + text.replace("\n", "\\n") + "\""

private fun check(label: String, ok: Boolean, detail: String = "") {
    println("  ${if (ok) "PASS" else "FAIL"}  $label" + if (detail.isNotEmpty()) "  $detail" else "")
    if (!ok) failures++
}

/** A clip of [samples] samples, all at the same level. */
private fun clip(samples: Int, level: Short = 4000): ByteArray {
    val pcm = ByteArray(samples * 2)
    for (i in 1 until pcm.size step 2) pcm[i] = level.toByte()
    return WavCodec.pcmToWav(pcm)
}

fun main() {
    println("UTTERANCE")

    // the clips are joined into one piece of audio
    val utterance = Utterance()
    check("an empty utterance is empty", utterance.isEmpty)
    utterance.add(clip(8000))          // 0.5 s
    utterance.add(clip(8000))          // 0.5 s
    check("the utterance is not empty once it has audio", !utterance.isEmpty)
    check("the clips are joined", utterance.wav().size == 44 + 16000 * 2,
          "size=${utterance.wav().size}")
    check("the length is measured", utterance.seconds > 0.9f, "seconds=${utterance.seconds}")
    utterance.clear()
    check("the utterance can start again", utterance.isEmpty)

    // The whole utterance is transcribed in one go, so the cuts do not matter.
    // The clip text is the broken one - it must not be used.
    val whole = "Orbit. how are the Toronto Raptors"
    val clips = "how are the Toronto rap Doctors."
    val question = UtteranceText.question(whole, clips, "Orbit")
    check("the whole utterance is used, not the pieces",
          question == "how are the Toronto Raptors", show(question))
    check("the lost word is not lost", question.contains("Raptors"), show(question))
    check("the word that was never spoken is gone",
          !question.contains("Doctors"), show(question))

    // the wake word is taken off the front, in the spellings whisper uses
    check("the wake word is taken off",
          UtteranceText.question("Orbit how are the Raptors doing", "", "Orbit") ==
              "how are the Raptors doing")
    check("the split wake word is taken off",
          UtteranceText.question("or a bit how are the Raptors doing", "", "Orbit") ==
              "how are the Raptors doing")
    check("a wake word in the middle is left alone",
          UtteranceText.question("how are the Raptors doing orbit", "", "Orbit") ==
              "how are the Raptors doing orbit")

    // when the whole transcript comes back empty the pieces are better than
    // nothing
    check("the pieces are used when the whole is empty",
          UtteranceText.question("", clips, "Orbit") == clips,
          show(UtteranceText.question("", clips, "Orbit")))
    check("nothing at all stays nothing",
          UtteranceText.question("", "", "Orbit").isEmpty())
    check("a wake word on its own is not a question",
          UtteranceText.question("Orbit.", "", "Orbit").isEmpty(),
          show(UtteranceText.question("Orbit.", "", "Orbit")))

    // and empty text is recognised
    check("empty text is empty", UtteranceText.isEmpty(""))
    check("punctuation alone is empty", UtteranceText.isEmpty("... ."))
    check("a word is not empty", !UtteranceText.isEmpty("Orbit"))

    println()
    if (failures > 0) {
        println("UTTERANCE: $failures FAILURE(S)")
        kotlin.system.exitProcess(1)
    }
    println("ALL UTTERANCE TESTS PASS")
}
