package com.keith.orbhermes

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min

/**
 * Continuous microphone streamer for desk mode.
 *
 * The mic stays open and the audio is cut into short clips. A clip is only
 * handed to the caller when it actually contains speech (simple energy VAD
 * against a tracked noise floor).
 *
 * The clip always *starts at the moment the speech started*, not at an
 * arbitrary buffer boundary. That matters for the wake word: a transcriber
 * that is handed a clip which begins in the middle of "Orbit" hears "bit" or
 * "it" instead, and the wake word is missed. The energy VAD therefore runs on
 * small frames so the onset can be located precisely, and the clip is built
 * as [MARGIN] of lead-in audio plus [WINDOW] of speech from that onset.
 *
 * While the orb is speaking the stream keeps running. An echo canceller takes
 * the orb's own voice out of the microphone, so a person can still cut the
 * reply short by saying "stop".
 */
class VoiceStreamer(
    private val onChunk: (wav: ByteArray, level: Float) -> Unit,
    private val onLevel: (low: Float, mid: Float, high: Float, all: Float) -> Unit,
    /** Called when the mic starts or stops hearing speech. */
    private val onActivity: (speaking: Boolean) -> Unit = {},
) {

    @Volatile private var running = false
    /** Set when the detector has to start over, picked up by the capture loop. */
    @Volatile private var resetRequested = false
    private var recorder: AudioRecord? = null
    private var thread: Thread? = null
    /** Takes the phone's own speaker out of the microphone. */
    private var echoCanceller: AcousticEchoCanceler? = null

    val isRunning: Boolean get() = running

    /**
     * Throws away what the detector has buffered.
     *
     * The orb's own voice is in there after it has talked, and it would
     * otherwise be the beginning of the next utterance.
     */
    fun reset() {
        resetRequested = true
    }

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (running) return true
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL, ENCODING)
        if (minBuffer <= 0) return false
        val bufferSize = max(minBuffer, FRAME_BYTES * 4)
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                CHANNEL,
                ENCODING,
                bufferSize,
            )
        } catch (e: Exception) {
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return false
        }
        recorder = rec
        running = true
        attachEchoCanceller(rec)
        rec.startRecording()
        thread = Thread { pump(rec) }.also { it.start() }
        return true
    }

    /**
     * Takes the phone's own speaker out of the microphone.
     *
     * The orb talks through the phone, so the microphone hears the answer.
     * The echo canceller is the only thing that can tell the orb's voice from
     * the person's, and it is what lets a person cut the reply short by saying
     * "stop".
     *
     * Not every device has one. Without it the orb still works - it just
     * cannot be interrupted by voice.
     */
    private fun attachEchoCanceller(rec: AudioRecord) {
        try {
            if (!AcousticEchoCanceler.isAvailable()) return
            val canceler = AcousticEchoCanceler.create(rec.audioSessionId)
            if (canceler != null) {
                canceler.enabled = true
                echoCanceller = canceler
            }
        } catch (e: Exception) {
            echoCanceller = null
        }
    }

    fun stop() {
        running = false
        try {
            thread?.join(1500)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        recorder?.release()
        recorder = null
        thread = null
        try {
            echoCanceller?.release()
        } catch (e: Exception) {
            // ignore
        }
        echoCanceller = null
    }

    private fun pump(rec: AudioRecord) {
        try {
            pumpLoop(rec)
        } catch (e: Exception) {
            // never let the capture thread take the app down
            android.util.Log.e("OrbHermes", "voice stream stopped: ${e.message}", e)
        }
    }

    private fun pumpLoop(rec: AudioRecord) {
        val frame = ByteArray(FRAME_BYTES)
        val window = ClipWindow(
            FRAME_BYTES,
            WINDOW_BYTES,
            MARGIN_BYTES,
            MAX_PENDING_BYTES,
            SILENCE_FRAMES,
            CONTINUATION_BYTES,
        )
        var levelTicks = 0
        var clips = 0
        var speaking = false

        while (running) {
            val read = try {
                rec.read(frame, 0, frame.size)
            } catch (e: Exception) {
                -1
            }
            if (read <= 0) {
                if (read < 0) break
                continue
            }

            // the clip (if any) starts at the onset of the speech
            if (resetRequested) {
                resetRequested = false
                window.reset()
            }
            val clip = window.accept(frame, read)

            // whether the person is talking right now. The app uses this to
            // decide when the sentence is over, so it has to come from the
            // microphone and not from the transcriber - a slow transcription
            // would otherwise look like the end of the sentence.
            //
            // It is reported on every frame while the person talks, not just
            // when speech starts: the app keeps a clock, and the clock has
            // to keep moving for as long as there is talking.
            if (window.speaking) {
                speaking = true
                onActivity(true)
            } else if (speaking) {
                speaking = false
                onActivity(false)
            }

            // the level meter only needs a few updates per second
            levelTicks++
            if (levelTicks % 3 == 0) {
                val low = min(1f, window.level * 4.2f)
                onLevel(low * 0.45f, low * 0.3f, low * 0.25f, low)
            }

            // a slow heartbeat: shows that the mic is live and how loud the
            // room is, which is the first thing to check when the wake word
            // does not arrive
            if (levelTicks % 200 == 0) {
                android.util.Log.i(
                    "OrbHermes",
                    "mic level=%.4f thr=%.4f floor=%.4f clips=%d".format(
                        window.level, window.threshold, window.noiseFloor, clips,
                    ),
                )
            }

            if (clip != null) {
                clips++
                onChunk(wavFromPcm(clip), window.level)
            }
        }
        try {
            rec.stop()
        } catch (e: Exception) {
            // already stopped
        }
    }

    private fun wavFromPcm(pcm: ByteArray): ByteArray {
        val dataLen = pcm.size
        val out = ByteArrayOutputStream(44 + dataLen)
        fun ascii(s: String) = s.forEach { out.write(it.code) }
        ascii("RIFF")
        writeIntLE(out, 36 + dataLen)
        ascii("WAVE")
        ascii("fmt ")
        writeIntLE(out, 16)
        writeShortLE(out, 1)                 // PCM
        writeShortLE(out, 1)                 // mono
        writeIntLE(out, SAMPLE_RATE)
        writeIntLE(out, SAMPLE_RATE * 2)     // byte rate
        writeShortLE(out, 2)                 // block align
        writeShortLE(out, 16)                // bits per sample
        ascii("data")
        writeIntLE(out, dataLen)
        out.write(pcm)
        return out.toByteArray()
    }

    private fun writeIntLE(out: ByteArrayOutputStream, value: Int) {
        out.write(value and 0xFF)
        out.write((value shr 8) and 0xFF)
        out.write((value shr 16) and 0xFF)
        out.write((value shr 24) and 0xFF)
    }

    private fun writeShortLE(out: ByteArrayOutputStream, value: Int) {
        out.write(value and 0xFF)
        out.write((value shr 8) and 0xFF)
    }

    companion object {
        const val SAMPLE_RATE = 16000
        private const val CHANNEL = AudioFormat.CHANNEL_IN_MONO
        private const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
        /** 25 ms frames - small enough to locate the onset of the speech. */
        private const val FRAME_BYTES = SAMPLE_RATE * 2 / 40
        /** 1.2 s of speech, measured from the onset. */
        private const val WINDOW_BYTES = SAMPLE_RATE * 2 * 12 / 10
        /**
         * 0.35 s of lead-in audio kept before the onset.
         *
         * The onset is found by energy, and the quiet start of a word like
         * "Orbit" can sit under the threshold - so the lead-in has to be long
         * enough to carry the whole word, not just its loud half.
         */
        private const val MARGIN_BYTES = SAMPLE_RATE * 2 * 35 / 100
        /** Cap on the silence buffered while waiting for someone to speak. */
        private const val MAX_PENDING_BYTES = SAMPLE_RATE * 2 * 3
        /**
         * 2.5 s of quiet before the orb decides the sentence is over.
         *
         * A pause in the middle of a sentence is normal, and half a second
         * was short enough to cut people off mid-sentence.
         */
        private const val SILENCE_FRAMES = 100
        /**
         * 3 s for a clip that carries on from the previous one.
         *
         * A longer clip gives the transcriber more to work with, and fewer
         * clip edges to cut a word in half.
         */
        private const val CONTINUATION_BYTES = SAMPLE_RATE * 2 * 3
    }
}
