package com.keith.orbhermes

import java.io.ByteArrayOutputStream
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Turns a stream of recorded audio into clips that begin at the onset of
 * speech.
 *
 * This matters for the wake word. A transcriber handed a clip that starts in
 * the middle of "Orbit" hears "bit" or "it" instead, and the wake word is
 * missed. So the energy VAD runs on small frames, the exact offset of the
 * onset is remembered, and the first clip of an utterance is built as
 * [marginBytes] of lead-in audio plus [windowBytes] of speech counted from
 * that onset.
 *
 * Follow-up clips continue the same utterance: they start exactly where the
 * previous clip ended, so no audio is ever lost.
 *
 * When the speaker stops, the audio that is still buffered is handed over as
 * well. It is the end of their sentence, and waiting for it to fill a whole
 * window would throw those last words away.
 *
 * Pure Kotlin on purpose - it carries no Android dependency so the offline
 * test suite can check the alignment.
 */
class ClipWindow(
    private val frameBytes: Int,
    private val windowBytes: Int,
    private val marginBytes: Int,
    private val maxPendingBytes: Int,
    /** How many quiet frames in a row mean that the speaker has stopped. */
    private val silenceFrames: Int = SILENCE_FRAMES,
    /** How long a clip that carries on from the previous one may be. */
    private val continuationBytes: Int = windowBytes,
) {

    private val pending = ByteArrayOutputStream(maxPendingBytes + frameBytes)
    /** Offset inside [pending] where the current speech began, -1 while silent. */
    private var speechStart = -1
    /** True when the next clip continues an utterance that is already running. */
    private var continuation = false
    /** Frames of quiet heard since the speech started. */
    private var silentFrames = 0
    /** How many bytes of quiet sit in [pending] after the last speech. */
    private var quietBytes = 0

    /** The level of the most recent frame, for the orb's meter. */
    var level: Float = 0f
        private set

    /**
     * True while the mic is hearing speech.
     *
     * This is what tells the app that the person is still talking, without
     * waiting for the recording to come back from the transcriber. A slow
     * transcription must not look like the end of the sentence.
     */
    val speaking: Boolean
        get() = speechStart >= 0

    /** The level a frame has to beat to count as speech. */
    var threshold: Float = 0.012f
        private set

    /** The tracked level of the room noise. */
    var noiseFloor: Float = 0.01f
        private set

    /**
     * Feed one frame of audio. Returns a clip when one is ready, otherwise
     * null. The first clip of an utterance starts [marginBytes] before the
     * detected onset; later clips continue where the previous one ended.
     */
    fun accept(frame: ByteArray, length: Int): ByteArray? {
        level = rms(frame, length)

        // Track the room noise only during quiet frames.
        if (level < noiseFloor * 2.2f) {
            noiseFloor = noiseFloor * 0.92f + level * 0.08f
        }
        val threshold = max(noiseFloor * 3.2f, 0.012f)
        this.threshold = threshold
        this.noiseFloor = noiseFloor

        pending.write(frame, 0, length)

        if (level > threshold) {
            silentFrames = 0
            quietBytes = 0
            if (speechStart < 0) {
                // the speech begins in this frame - remember exactly where
                speechStart = pending.size() - length
                continuation = false
            }
        } else {
            silentFrames++
            quietBytes += length
        }

        // The speaker has gone quiet. The audio that is still buffered is the
        // end of their sentence, so it is handed over now - waiting for it to
        // fill a whole window would throw the last words away.
        if (speechStart >= 0 && silentFrames >= silenceFrames) {
            val tail = takeClip(UNTIL_LAST_SPEECH)
            speechStart = -1
            continuation = false
            silentFrames = 0
            quietBytes = 0
            trimToMargin()
            return tail
        }

        if (speechStart < 0) {
            if (pending.size() > maxPendingBytes) trimToMargin()
            return null
        }

        // the first clip of an utterance waits for one window of speech; the
        // ones that continue it wait for a whole continuation
        val needed = if (continuation) continuationBytes else windowBytes
        if (pending.size() - speechStart < needed) return null

        // the first clip of an utterance carries the lead-in as well; the ones
        // that continue it pick up exactly where the last one stopped
        val limit = if (continuation) continuationBytes else marginBytes + windowBytes
        return takeClip(limit)
    }

    /**
     * Take the audio of the current utterance out of the buffer.
     *
     * The first clip of an utterance starts [marginBytes] before the onset and
     * carries on for [windowBytes]; the clips that continue it carry straight
     * on from the one before, for [continuationBytes].
     */
    private fun takeClip(limit: Int): ByteArray {
        val bytes = pending.toByteArray()
        val from = if (continuation) 0 else max(0, speechStart - marginBytes)
        val end = when {
            limit == UNTIL_LAST_SPEECH -> max(from, bytes.size - quietBytes)
            continuation -> min(bytes.size, limit)
            else -> min(bytes.size, from + limit)
        }
        val clip = bytes.copyOfRange(from, end)
        pending.reset()
        pending.write(bytes, end, bytes.size - end)
        // the speech carries on from the start of the new buffer
        speechStart = 0
        continuation = true
        // the quiet is only still in the buffer if the speech was not taken
        if (quietBytes > bytes.size - end) quietBytes = 0
        return clip
    }

    /** Throw away everything except a short lead-in, to bound the buffer. */
    private fun trimToMargin() {
        val bytes = pending.toByteArray()
        pending.reset()
        val keep = min(bytes.size, marginBytes)
        pending.write(bytes, bytes.size - keep, keep)
    }

    /**
     * Start again from scratch.
     *
     * The orb's own voice drives the detector while it is talking, and that
     * would leave the next utterance starting in the middle of a word. The
     * window is reset when the microphone is muted, so the next thing the
     * orb hears is the beginning of a sentence again.
     */
    fun reset() {
        pending.reset()
        speechStart = -1
        continuation = false
        silentFrames = 0
        quietBytes = 0
    }

    companion object {
        /**
         * How many quiet frames end an utterance (2.5 s at 25 ms per frame).
         *
         * A pause in the middle of a sentence is normal - a comma, a thought,
         * a breath. Half a second was short enough to cut people off, so the
         * orb now waits for a real stop before it decides the sentence is
         * over.
         */
        private const val SILENCE_FRAMES = 100

        /** Take everything up to the last sample of speech. */
        private const val UNTIL_LAST_SPEECH = -1

        /** Root-mean-square level of 16-bit PCM, roughly 0.0 .. 1.0. */
        fun rms(data: ByteArray, length: Int): Float {
            var sum = 0.0
            var peak = 0
            var i = 0
            while (i < length - 1) {
                val sample = (data[i + 1].toInt() shl 8) or (data[i].toInt() and 0xFF)
                val a = abs(sample)
                if (a > peak) peak = a
                sum += a.toDouble() * a
                i += 2
            }
            val samples = max(1, length / 2)
            val rms = sqrt(sum / samples) / 32768.0
            val peakLevel = min(1.0, peak / 32768.0 * 2.2).toFloat()
            return max(rms.toFloat(), peakLevel * 0.35f)
        }
    }
}
