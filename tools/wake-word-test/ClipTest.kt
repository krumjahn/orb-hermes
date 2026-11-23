import com.keith.orbhermes.ClipWindow

/**
 * Checks that the recorded audio is cut into clips that begin at the onset of
 * the speech. If a clip starts in the middle of the wake word, the
 * transcriber hears "bit" instead of "Orbit" and the wake word is missed.
 *
 * It also checks the two things that make people get cut off mid-sentence:
 * the audio that is still buffered when the speaker stops must not be thrown
 * away, and a pause in the middle of a sentence must not end the utterance.
 */
private const val RATE = 16000
private const val FRAME_BYTES = RATE * 2 / 40          // 25 ms
private const val WINDOW_BYTES = RATE * 2 * 12 / 10    // 1.2 s of speech
private const val MARGIN_BYTES = RATE * 2 * 35 / 100   // 0.35 s of lead-in
private const val CONTINUATION_BYTES = RATE * 2 * 3     // 3 s for a clip that carries on
private const val MAX_PENDING_BYTES = RATE * 2 * 3     // 3 s
private const val SILENCE_FRAMES = 100                 // 2.5 s of quiet ends the utterance

private var failures = 0

private fun check(name: String, condition: Boolean) {
    if (condition) {
        println("  PASS  $name")
    } else {
        println("  FAIL  $name")
        failures++
    }
}

/** One frame of 16-bit PCM. */
private fun frame(value: Int): ByteArray {
    val out = ByteArray(FRAME_BYTES)
    for (i in out.indices step 2) {
        out[i] = (value and 0xFF).toByte()
        out[i + 1] = ((value shr 8) and 0xFF).toByte()
    }
    return out
}

private fun firstLoudIndex(pcm: ByteArray): Int {
    var i = 0
    while (i < pcm.size - 1) {
        val sample = (pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xFF)
        if (kotlin.math.abs(sample) > 2000) return i
        i += 2
    }
    return -1
}

/** How many loud samples the clip holds. */
private fun loudCount(pcm: ByteArray): Int {
    var count = 0
    var i = 0
    while (i < pcm.size - 1) {
        val sample = (pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xFF)
        if (kotlin.math.abs(sample) > 2000) count++
        i += 2
    }
    return count
}

private fun newWindow() = ClipWindow(
    FRAME_BYTES,
    WINDOW_BYTES,
    MARGIN_BYTES,
    MAX_PENDING_BYTES,
    SILENCE_FRAMES,
    CONTINUATION_BYTES,
)

fun main() {
    println("CLIP WINDOW TESTS")

    // 1. silence produces nothing at all
    run {
        val w = newWindow()
        var clips = 0
        repeat(400) { if (w.accept(frame(0), FRAME_BYTES) != null) clips++ }
        check("silence produces no clip", clips == 0)
    }

    // 2. a clip starts MARGIN before the onset, and is MARGIN + WINDOW long
    run {
        val w = newWindow()
        var clip: ByteArray? = null
        repeat(20) { w.accept(frame(0), FRAME_BYTES) }         // 0.5 s of silence
        repeat(120) {
            val c = w.accept(frame(9000), FRAME_BYTES)           // speech
            if (c != null && clip == null) clip = c
        }
        check("a clip is produced for speech", clip != null)
        if (clip != null) {
            check("clip length is margin + window", clip.size == MARGIN_BYTES + WINDOW_BYTES)
            val onset = firstLoudIndex(clip)
            check("clip keeps the onset inside it", onset in 0 until clip.size)
            check(
                "clip starts about MARGIN before the speech (got $onset, want ~$MARGIN_BYTES)",
                kotlin.math.abs(onset - MARGIN_BYTES) <= FRAME_BYTES * 2,
            )
        }
    }

    // 3. the clip is emitted promptly - within a second of the onset
    run {
        val w = newWindow()
        var framesToClip = -1
        repeat(20) { w.accept(frame(0), FRAME_BYTES) }
        for (i in 1..120) {
            if (w.accept(frame(9000), FRAME_BYTES) != null) {
                framesToClip = i
                break
            }
        }
        check("clip arrives within 1.2 s of the onset", framesToClip in 1..48)
    }

    // 4. two clips in a row are contiguous - no audio is lost between them
    run {
        val w = newWindow()
        val clips = mutableListOf<ByteArray>()
        repeat(20) { w.accept(frame(0), FRAME_BYTES) }
        repeat(300) {
            val c = w.accept(frame(9000), FRAME_BYTES)
            if (c != null) clips.add(c)
        }
        check("a long utterance produces several clips", clips.size >= 2)
        if (clips.size >= 2) {
            // the first clip of an utterance is margin + window, the ones that
            // continue it are a whole continuation
            check(
                "first clip is margin + window (got ${clips[0].size})",
                clips[0].size == MARGIN_BYTES + WINDOW_BYTES,
            )
            check(
                "continuation clips are one continuation (got ${clips[1].size})",
                clips[1].size == CONTINUATION_BYTES,
            )
            check(
                "clips do not grow without bound",
                clips.all { it.size <= MARGIN_BYTES + maxOf(WINDOW_BYTES, CONTINUATION_BYTES) },
            )
        }
    }

    // 5. a long silence does not blow up the buffer
    run {
        val w = newWindow()
        var clips = 0
        repeat(2000) { if (w.accept(frame(0), FRAME_BYTES) != null) clips++ }
        check("long silence stays quiet", clips == 0)
    }

    // 6. a quiet background does not trigger a clip
    run {
        val w = newWindow()
        var clips = 0
        repeat(400) { if (w.accept(frame(60), FRAME_BYTES) != null) clips++ }
        check("low background noise produces no clip", clips == 0)
    }

    // 7. after a long pause the next utterance starts with its own lead-in
    run {
        val w = newWindow()
        val clips = mutableListOf<ByteArray>()
        repeat(20) { w.accept(frame(0), FRAME_BYTES) }
        repeat(80) {
            val c = w.accept(frame(9000), FRAME_BYTES)
            if (c != null) clips.add(c)
        }
        repeat(SILENCE_FRAMES + 20) { w.accept(frame(0), FRAME_BYTES) }   // the speaker stops
        repeat(80) {
            val c = w.accept(frame(9000), FRAME_BYTES)
            if (c != null) clips.add(c)
        }
        check("a second utterance is clipped too", clips.size >= 2)
        if (clips.size >= 2) {
            check(
                "the second utterance gets its own lead-in (got ${clips.last().size})",
                clips.last().size == MARGIN_BYTES + WINDOW_BYTES,
            )
        }
    }

    // 8. the window knows when the person is talking
    //    The app uses this to decide when the sentence is over. It has to
    //    come from the microphone, because a slow transcription would
    //    otherwise look like the end of the sentence.
    run {
        val w = newWindow()
        check("a fresh window is not speaking", !w.speaking)

        repeat(40) { w.accept(frame(9000), FRAME_BYTES) }
        check("speech is heard", w.speaking)

        // the speaker stops: after 2.5 s of quiet the window says so
        repeat(SILENCE_FRAMES + 1) { w.accept(frame(0), FRAME_BYTES) }
        check("silence is heard", !w.speaking)

        // and it picks the next utterance up again
        repeat(40) { w.accept(frame(9000), FRAME_BYTES) }
        check("speech is heard again", w.speaking)
    }

    // 9. the words at the end are not thrown away
    //    The audio that is still buffered when the speaker stops is the end
    //    of their sentence. It used to be dropped, which cut every question
    //    off in the middle.
    run {
        val w = newWindow()
        val clips = mutableListOf<ByteArray>()
        repeat(20) { w.accept(frame(0), FRAME_BYTES) }
        // 1.5 s of speech: one full clip of 1.2 s, and 0.3 s still buffered
        repeat(60) {
            val c = w.accept(frame(9000), FRAME_BYTES)
            if (c != null) clips.add(c)
        }
        // the speaker stops
        repeat(SILENCE_FRAMES + 20) {
            val c = w.accept(frame(0), FRAME_BYTES)
            if (c != null) clips.add(c)
        }
        check("the end of the sentence is handed over", clips.size >= 2)
        val tail = clips.lastOrNull()
        if (tail != null) {
            check("the tail is not empty", tail.isNotEmpty())
            check(
                "the tail holds the words that were still buffered",
                loudCount(tail) > 0,
            )
        }
        // every loud sample that was spoken has to be in one of the clips
        val spoken = clips.sumOf { loudCount(it) }
        check(
            "no speech was lost (spoken 60 frames, clips hold $spoken)",
            spoken >= 60 * (FRAME_BYTES / 2),
        )
    }

    // 10. a pause in the middle of a sentence does not end the utterance
    run {
        val w = newWindow()
        val clips = mutableListOf<ByteArray>()
        repeat(20) { w.accept(frame(0), FRAME_BYTES) }
        repeat(80) {
            val c = w.accept(frame(9000), FRAME_BYTES)
            if (c != null) clips.add(c)
        }
        // a pause that is shorter than the tolerance
        repeat(SILENCE_FRAMES - 20) { w.accept(frame(0), FRAME_BYTES) }
        repeat(80) {
            val c = w.accept(frame(9000), FRAME_BYTES)
            if (c != null) clips.add(c)
        }
        check("the pause did not end the utterance", w.speaking)
        if (clips.size >= 2) {
            check(
                "the clip after the pause carries on (got ${clips[1].size})",
                clips[1].size == CONTINUATION_BYTES,
            )
        }
    }

    // 11. a reset starts the next utterance from scratch
    //     The orb's own voice would otherwise leave the detector in the
    //     middle of a word, and the next sentence would start there.
    run {
        val w = newWindow()
        repeat(20) { w.accept(frame(0), FRAME_BYTES) }
        repeat(60) { w.accept(frame(9000), FRAME_BYTES) }     // speech, never handed over
        w.reset()
        check("a reset clears the speech", !w.speaking)
        repeat(20) { w.accept(frame(0), FRAME_BYTES) }
        var clip: ByteArray? = null
        repeat(120) {
            val c = w.accept(frame(9000), FRAME_BYTES)
            if (c != null && clip == null) clip = c
        }
        check(
            "the next utterance gets its own lead-in",
            clip != null && clip.size == MARGIN_BYTES + WINDOW_BYTES,
        )
    }

    // 12. a quiet voice in a quiet room is heard
    //     These are the levels this phone's microphone actually produces: the
    //     room sits at about 0.0035 and a voice at about 0.02. A bar that
    //     sits three times above the noise leaves the voice under it, and
    //     the question is then never heard at all.
    run {
        val w = newWindow()
        var clip: ByteArray? = null
        repeat(100) { w.accept(frame(115), FRAME_BYTES) }       // the room at 0.0035
        repeat(120) {
            val c = w.accept(frame(655), FRAME_BYTES)            // the voice at 0.02
            if (c != null && clip == null) clip = c
        }
        check("a quiet voice in a quiet room is heard", clip != null)
    }

    // 13. a quiet voice is still heard when the room is louder
    //     With a television in the room the noise rises to about 0.012 while
    //     the voice stays at about 0.024. The bar used to follow the room up
    //     to 0.039 and the voice never got over it.
    run {
        val w = newWindow()
        var clip: ByteArray? = null
        repeat(150) { w.accept(frame(400), FRAME_BYTES) }       // the room at 0.0122
        repeat(120) {
            val c = w.accept(frame(786), FRAME_BYTES)            // the voice at 0.024
            if (c != null && clip == null) clip = c
        }
        check("a quiet voice is heard in a louder room", clip != null)
    }

    // 14. a dip between the words does not cut the sentence in half
    //     The bar follows the speaker while they are talking, so a voice
    //     that gets quieter between two words is still speech. This is what
    //     turned "what's on my calendar" into "what's on my-".
    run {
        val w = newWindow()
        repeat(100) { w.accept(frame(115), FRAME_BYTES) }       // the room at 0.0035
        repeat(40) { w.accept(frame(655), FRAME_BYTES) }        // the voice at 0.02
        repeat(150) { w.accept(frame(295), FRAME_BYTES) }       // a dip to 0.009
        check("a dip between the words does not end the utterance", w.speaking)
        check("the bar stayed under the voice", w.threshold < 0.009f)
    }

    // 15. a real pause does end the utterance
    run {
        val w = newWindow()
        repeat(100) { w.accept(frame(115), FRAME_BYTES) }
        repeat(40) { w.accept(frame(655), FRAME_BYTES) }
        repeat(SILENCE_FRAMES + 20) { w.accept(frame(115), FRAME_BYTES) }
        check("a real pause ends the utterance", !w.speaking)
    }

    if (failures == 0) {
        println("ALL CLIP WINDOW TESTS PASS")
    } else {
        println("$failures CLIP WINDOW TEST(S) FAILED")
        kotlin.system.exitProcess(1)
    }
}
