package com.keith.orbhermes

import java.io.ByteArrayOutputStream

/**
 * The audio of one utterance.
 *
 * The recorder cuts the audio into clips at fixed byte offsets, and a cut
 * lands in the middle of a word as often as not. Transcribed one clip at a
 * time, every cut costs a word: "how are the Toronto rap" plus "Doctors."
 * instead of "how are the Toronto Raptors".
 *
 * So the clips are kept as audio and the whole utterance is transcribed in
 * one go at the end. The cuts then do not matter - the transcriber hears one
 * continuous sentence, and the last word is heard whole.
 *
 * Pure Kotlin on purpose - it carries no Android dependency so the offline
 * test suite can check the assembly.
 */
class Utterance {

    private val pcm = ByteArrayOutputStream()

    /** Adds a recorded clip. */
    fun add(wav: ByteArray) {
        pcm.write(WavCodec.wavToPcm(wav))
    }

    /** The whole utterance as one WAV, ready for the transcriber. */
    fun wav(): ByteArray = WavCodec.pcmToWav(pcm.toByteArray())

    /** True when nothing was recorded. */
    val isEmpty: Boolean get() = pcm.size() == 0

    /** How long the utterance is, in seconds. */
    val seconds: Float get() = pcm.size() / 2f / WavCodec.SAMPLE_RATE

    /** Starts again with the next utterance. */
    fun clear() {
        pcm.reset()
    }
}

/**
 * The question that goes to the agent.
 */
object UtteranceText {

    /**
     * The question to send.
     *
     * The whole utterance is transcribed in one go, so that is the text that
     * counts - with the wake word taken off the front, because the clip that
     * carried the wake word is the first part of the recording.
     *
     * The per-clip text is only used when the whole-utterance transcript came
     * back empty. It is the text of the pieces, so it may be missing a word
     * where a clip was cut - but it is better than nothing.
     */
    fun question(
        whole: String,
        clips: String,
        wakePhrase: String = WakeWord.DEFAULT_PHRASE,
    ): String {
        val clean = WakeWord.strip(whole, wakePhrase).trim()
        if (clean.any { it.isLetterOrDigit() }) return clean
        return WakeWord.strip(clips, wakePhrase).trim()
    }

    /** True when there is nothing worth sending. */
    fun isEmpty(text: String): Boolean = !text.any { it.isLetterOrDigit() }
}
