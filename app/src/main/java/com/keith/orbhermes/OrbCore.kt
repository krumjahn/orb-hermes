package com.keith.orbhermes

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.min
import kotlin.math.sqrt

/** What the orb is doing right now. */
enum class OrbPhase { ONBOARDING, STANDBY, AWAKE, THINKING, SPEAKING }

/**
 * The whole voice pipeline, with no dependency on any screen.
 *
 * The orb is meant to live on a desk, so it has to keep listening with the
 * screen off. Android hands the microphone back as soon as the activity stops
 * being in the foreground, and it kills the process soon after, so the voice
 * pipeline cannot live in the activity.
 *
 * The brain therefore lives here, as a process-wide singleton, and both the
 * foreground service and the activity drive the same instance. The service
 * keeps the process alive and holds the "while in use" microphone privilege;
 * the activity only draws what the core reports.
 */
class OrbCore private constructor(private val appContext: Context) {

    /** The screen that shows the orb. */
    interface Listener {
        fun onStatus(text: String)

        /** [visible] false means the transcript should fade away again. */
        fun onTranscript(text: String, visible: Boolean)

        /** ~20 Hz on the main thread: the look of the orb comes from here. */
        fun onFrame(core: OrbCore)
    }

    @Volatile
    var listener: Listener? = null

    // ---- state the screen reads ------------------------------------------

    var phase: OrbPhase = OrbPhase.STANDBY
        private set
    var dim: Float = 1f
        private set
    var pulse: Float = 0f
        private set
    var awake: Float = 0.25f
        private set

    /**
     * The audio bands the orb actually draws.
     *
     * These are not the raw microphone levels. They follow the targets with
     * an attack and a decay, so the glass swells and settles instead of
     * snapping on every level jump - a raw level jumps from frame to frame,
     * and a glass that copies it frame by frame looks broken, not alive.
     */
    val bands: FloatArray
        get() = smoother.values
    var statusText: String = ""
        private set
    var transcriptText: String = ""
        private set
    var transcriptVisible: Boolean = false
        private set

    /** True once the user has picked an orb in the first-run picker. */
    var onboardingDone: Boolean = false
        private set

    // ---- internals --------------------------------------------------------

    private val settings = Settings(appContext)
    private val handler = Handler(Looper.getMainLooper())
    /** Shows what the orb is doing while it waits for an answer. */
    private val thinkingStatus = Handler(Looper.getMainLooper())
    private val replyExecutor = Executors.newSingleThreadExecutor()
    private val healthExecutor = Executors.newSingleThreadExecutor()
    private val pendingUploads = AtomicInteger(0)

    /**
     * The uploads must not be able to go deaf for good.
     *
     * A request that is written to a socket which has stopped reading has
     * no timeout of its own, and with one upload thread the orb stopped
     * hearing the wake word until the app was started again by hand. That
     * is what happens every time the bridge or the relay is restarted
     * underneath it. The guard gives every upload a deadline and replaces a
     * worker that misses it.
     */
    private val uploads = UploadGuard(
        deadlineMs = 75_000L,
        poolSize = 2,
        onGiveUp = {
            android.util.Log.w("OrbHermes", "an upload hung - a fresh worker takes over")
        },
    )

    private var streamer: VoiceStreamer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var player: MediaPlayer? = null
    private var visualizer: Visualizer? = null
    private var sessionId = UUID.randomUUID().toString()

    /** When the microphone last heard speech. Written by the capture thread. */
    @Volatile private var lastVoiceAt = 0L
    /**
     * True while the app is on screen.
     *
     * Android only lets an app that is in the foreground open a microphone
     * capture, and a capture that was opened in the background is fed nothing
     * but zeros for the rest of its life - the orb would never hear the wake
     * word again.
     */
    @Volatile private var appInForeground = false
    /** When the microphone last returned pure silence (0 while it is alive). */
    @Volatile private var micSilentSince = 0L
    /** When the capture was last (re)opened, so a failure cannot cause a loop. */
    private var lastCaptureStartAt = 0L
    private var lastInteractionAt = 0L
    private var lastDimLog = 0L
    /** The level of the reply, measured by the visualiser. */
    @Volatile private var speechLevel = 0f
    /** When the visualiser last delivered a sample of the reply. */
    @Volatile private var lastVisualizerAt = 0L
    /**
     * The audio levels the orb is moving towards.
     *
     * They are written by the capture thread (and by the ticker while the
     * orb talks) and read by the ticker, which is the only place that
     * touches the bands the renderer sees.
     */
    @Volatile private var bandTargetLow = 0f
    @Volatile private var bandTargetMid = 0f
    @Volatile private var bandTargetHigh = 0f
    @Volatile private var bandTargetAll = 0f
    /** True while the orb is talking, so the microphone does not drive it. */
    @Volatile private var micMuted = false
    /** The smoothing that turns the raw levels into the bands the orb draws. */
    private val smoother = BandSmoother()
    private var droppedChunks = 0
    private var lastHealthCheckAt = 0L
    private var outageAnnounced = false

    private val utterance = StringBuilder()
    /**
     * The audio of the utterance.
     *
     * The clips are cut at fixed offsets, and a cut lands in the middle of a
     * word as often as not. The audio is kept so the whole utterance can be
     * transcribed in one go at the end - then the cuts do not matter, and the
     * last word is heard whole.
     */
    private val utteranceAudio = Utterance()

    private var started = false
    private var tickerRunning = false

    // ------------------------------------------------------------- lifecycle

    /** Starts the pipeline. Safe to call more than once. */
    fun start() {
        if (started) return
        started = true
        onboardingDone = settings.onboardingDone
        initLocalTts()
        startTicker()
        if (onboardingDone) {
            enterStandby()
        } else {
            phase = OrbPhase.ONBOARDING
            setStatus("")
            setTranscript("", false)
        }
        checkHealth()
    }

    /** Releases the microphone and the audio hardware. */
    fun stop() {
        started = false
        tickerRunning = false
        handler.removeCallbacksAndMessages(null)
        stopStreaming()
        stopSpeaking()
        try {
            tts?.shutdown()
        } catch (e: Exception) {
            // ignore
        }
        tts = null
        ttsReady = false
        uploads.shutdown()
        replyExecutor.shutdownNow()
        healthExecutor.shutdownNow()
    }

    // ------------------------------------------------------------------ ui

    /** The first-run orb picker was dismissed. */
    fun finishOnboarding() {
        settings.onboardingDone = true
        onboardingDone = true
        enterStandby()
    }

    /** The talk button: start an utterance, or close the current one. */
    fun talk() {
        if (phase == OrbPhase.AWAKE) {
            finishUtterance()
        } else {
            wakeUp("")
        }
        touch()
    }

    /** Settings were changed in the dialog; pick up the new values. */
    fun onSettingsChanged() {
        checkHealth()
        if (phase == OrbPhase.STANDBY) {
            setStatus("Say “${settings.wakePhrase}”")
        }
    }

    /** Debug hook: pretend the user said [text]. */
    fun simulate(text: String) {
        wakeUp(text)
        handler.postDelayed({ finishUtterance() }, 600)
    }

    /**
     * Debug hook: say a phrase out loud through the normal reply path.
     *
     * It is the quickest way to hear a voice without waiting for the agent:
     * the same MiniMax voice the orb uses for its answers is asked for.
     */
    fun say(text: String) {
        if (text.isBlank()) return
        speak(text)
    }

    fun touch() {
        lastInteractionAt = System.currentTimeMillis()
    }

    private fun setStatus(text: String) {
        statusText = text
        listener?.onStatus(text)
    }

    private fun setTranscript(text: String, visible: Boolean) {
        transcriptText = text
        transcriptVisible = visible
        listener?.onTranscript(text, visible)
    }

    // -------------------------------------------------------------- phases

    private fun enterStandby() {
        phase = OrbPhase.STANDBY
        utterance.setLength(0)
        setStatus("Say “${settings.wakePhrase}”")
        // a fresh start is bright: the orb dims only after a while of silence
        lastInteractionAt = System.currentTimeMillis()
        dim = 1f
        startStreaming()
    }

    private fun wakeUp(command: String) {
        if (phase == OrbPhase.SPEAKING) return
        phase = OrbPhase.AWAKE
        utterance.setLength(0)
        utteranceAudio.clear()
        droppedChunks = 0
        if (command.isNotBlank()) utterance.append(command.trim()).append(' ')
        // The sentence is only over once the microphone goes quiet. The
        // clock starts when the wake happened, but the capture thread takes
        // it over as soon as the person carries on talking.
        lastVoiceAt = System.currentTimeMillis()
        touch()
        setStatus("Listening…")
        setTranscript(if (command.isBlank()) "" else "You: $command", command.isNotBlank())
    }

    /**
     * The app came to the foreground or went to the background.
     *
     * A capture that is opened while the app is in the background is fed zeros
     * by Android, and it stays that way: the orb would never hear anything
     * again. So the capture is only opened while the app is on screen, and
     * every tick checks that it is still really listening.
     */
    fun onForegroundChanged(foreground: Boolean) {
        appInForeground = foreground
        if (foreground) ensureCapture()
    }

    /** Makes sure the microphone is really listening, and really working. */
    private fun ensureCapture() {
        if (!appInForeground) return
        val now = System.currentTimeMillis()
        if (streamer?.isRunning != true) {
            // do not hammer the microphone: a missing permission or a busy
            // audio stack would otherwise be retried twenty times a second
            if (now - lastCaptureStartAt < 2_000) return
            startStreaming()
            return
        }
        val silentSince = micSilentSince
        if (silentSince > 0L && now - silentSince > MIC_SILENT_MS && isReallyForeground()) {
            android.util.Log.w(
                "OrbHermes",
                "the microphone is returning nothing but silence - restarting the capture",
            )
            micSilentSince = 0L
            stopStreaming()
            startStreaming()
        }
    }

    /**
     * True when the app is really in front of the user.
     *
     * A dozing phone still counts as "visible", but Android hands a capture
     * that was opened then nothing but zeros - and it never recovers. So the
     * capture is only opened while the orb is actually on screen.
     */
    private fun isReallyForeground(): Boolean {
        val info = ActivityManager.RunningAppProcessInfo()
        return try {
            ActivityManager.getMyMemoryState(info)
            info.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        } catch (e: Exception) {
            false
        }
    }

    fun startStreaming() {
        if (streamer?.isRunning == true) return
        // A capture opened in the background is fed zeros, so it is only opened
        // while the app is on screen. It keeps working once the screen is off.
        if (!appInForeground) return
        if (!isReallyForeground()) return
        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            setStatus("Microphone permission needed")
            return
        }
        val stream = VoiceStreamer(
            onChunk = { wav, level ->
                handleChunk(wav, level)
            },
            onLevel = { low, mid, high, all ->
                // while the orb is talking the microphone only hears the
                // speaker, so its levels are ignored - the reply drives the
                // glass instead
                if (!micMuted) {
                    bandTargetLow = low
                    bandTargetMid = mid
                    bandTargetHigh = high
                    bandTargetAll = all
                }
                // a microphone that the system has taken away returns nothing
                // but zeros - that is how a dead capture shows itself
                if (all <= 0f) {
                    if (micSilentSince == 0L) micSilentSince = System.currentTimeMillis()
                } else {
                    micSilentSince = 0L
                }
            },
            onActivity = { speaking ->
                // The microphone is the only thing that knows whether the
                // person is still talking. The transcription can take seconds
                // to come back, and counting that as silence cuts the
                // sentence short.
                //
                // The clock is stamped on both edges: while they talk, and
                // again at the moment they stop. The second stamp matters -
                // it is what keeps the last clip, which is handed over just
                // after the mic goes quiet, from being left out of the
                // question.
                lastVoiceAt = System.currentTimeMillis()
            },
        )
        if (!stream.start()) {
            setStatus("Microphone unavailable")
            return
        }
        streamer = stream
        lastCaptureStartAt = System.currentTimeMillis()
        micSilentSince = 0L
        // the permission may have arrived after the core was started
        if (phase == OrbPhase.STANDBY) {
            setStatus("Say “${settings.wakePhrase}”")
        }
    }

    private fun stopStreaming() {
        streamer?.stop()
        streamer = null
    }

    /** A speech chunk arrived from the mic. */
    private fun handleChunk(wav: ByteArray, level: Float) {
        if (phase == OrbPhase.ONBOARDING) return
        if (pendingUploads.get() > 8) {
            // the bridge is too slow to keep up; remember that a piece of the
            // utterance was lost so the whole thing can be transcribed later
            droppedChunks++
            android.util.Log.i("OrbHermes", "chunk dropped, backlog=${pendingUploads.get()}")
            return
        }
        pendingUploads.incrementAndGet()
        // the count has to come down exactly once, however the upload ends:
        // when it finishes, when it fails, and when it is given up on
        val counted = AtomicBoolean(true)
        val handedOff = AtomicBoolean(false)
        fun release() {
            if (counted.compareAndSet(true, false)) pendingUploads.decrementAndGet()
        }
        uploads.submit(
            work = {
                try {
                    val client = client()
                    if (phase == OrbPhase.STANDBY) {
                        val result = client.wake(wav)
                        val (text, woke) = result.value ?: ("" to false)
                        if (!result.ok) {
                            android.util.Log.w("OrbHermes", "wake check failed: ${result.error}")
                        }
                        if (woke || WakeWord.matches(text, settings.wakePhrase)) {
                            // the transcriber may spell the wake word slightly off
                            // ("Orbic"), so the echo is removed with the same fuzzy
                            // rules that matched it in the first place
                            val remainder = WakeWord.strip(text, settings.wakePhrase)
                            android.util.Log.i("OrbHermes", "wake: heard=\"$text\" remainder=\"$remainder\"")
                            handler.post {
                                if (phase == OrbPhase.STANDBY) {
                                    wakeUp(remainder)
                                    // The clip that carried the wake word is the
                                    // first part of the utterance, so it is kept
                                    // with the rest of it. The whole sentence is
                                    // transcribed in one go at the end, and a cut
                                    // in the middle of a word then costs nothing.
                                    utteranceAudio.add(wav)
                                }
                            }
                        }
                    } else if (phase == OrbPhase.AWAKE) {
                        val result = client.transcribe(wav)
                        val raw = result.value?.trim().orEmpty()
                        // the text is only in the utterance once the post below
                        // has run, so the count must not drop before it
                        handedOff.set(true)
                        handler.post {
                            try {
                                if (phase == OrbPhase.AWAKE) {
                                    // keep the audio too, so the whole utterance
                                    // can be transcribed in one go at the end
                                    utteranceAudio.add(wav)
                                    // the first chunk usually still carries the wake
                                    // word itself - only the first one is stripped
                                    val text = if (utterance.isEmpty()) {
                                        WakeWord.strip(raw, settings.wakePhrase)
                                    } else {
                                        raw
                                    }
                                    if (text.isNotEmpty() && text.any { it.isLetterOrDigit() }) {
                                        utterance.append(text).append(' ')
                                        touch()
                                        setTranscript("You: ${utterance.toString().trim()}", true)
                                    }
                                }
                            } finally {
                                release()
                            }
                        }
                    }
                } catch (e: Exception) {
                    // keep the loop alive, but say what went wrong - a failure that
                    // is swallowed here looks exactly like the orb ignoring you
                    android.util.Log.w("OrbHermes", "upload failed: ${e.message}", e)
                }
            },
            // the guard calls this exactly once, so the count cannot get stuck
            // high - that would make the orb drop every clip from then on
            onDone = { if (!handedOff.get()) release() },
            // the wake check has a 30 second read timeout of its own, so this
            // only fires when the request is stuck in a socket write
            deadlineMs = 40_000L,
        )
    }

    /** Called when the speaker goes quiet after an utterance. */
    private fun finishUtterance() {
        val clips = utterance.toString().trim()
        // The whole utterance is transcribed in one go. The clips are cut at
        // fixed offsets, and a cut lands in the middle of a word as often as
        // not: "how are the Toronto rap" plus "Doctors." instead of "how are
        // the Toronto Raptors". One continuous piece of audio does not have
        // that problem - the transcriber hears the whole sentence.
        val audio = if (!utteranceAudio.isEmpty) utteranceAudio.wav() else null
        val seconds = utteranceAudio.seconds
        val hadGaps = droppedChunks > 0
        utterance.setLength(0)
        utteranceAudio.clear()
        droppedChunks = 0
        if (clips.isEmpty() && audio == null) {
            phase = OrbPhase.STANDBY
            setStatus("Say “${settings.wakePhrase}”")
            return
        }
        phase = OrbPhase.THINKING
        touch()
        setStatus("Thinking…")
        // The model can take a while to wake up on the Beelink, and in desk
        // mode there is no status line to look at. So the status goes into
        // the text that fades in over the orb, and it says more as the wait
        // gets longer.
        showThinkingStatus()
        replyExecutor.execute {
            var text = clips
            if (audio != null) {
                try {
                    val whole = client().transcribe(audio).value?.trim().orEmpty()
                    val question = UtteranceText.question(whole, clips, settings.wakePhrase)
                    if (!UtteranceText.isEmpty(question)) {
                        text = question
                        android.util.Log.i(
                            "OrbHermes",
                            "whole utterance (%.1fs%s): %s".format(
                                seconds,
                                if (hadGaps) ", with gaps" else "",
                                text,
                            ),
                        )
                    }
                } catch (e: Exception) {
                    // keep what we have
                    android.util.Log.w(
                        "OrbHermes",
                        "the whole utterance could not be transcribed: ${e.message}",
                    )
                }
            }
            android.util.Log.i("OrbHermes", "utterance: $text")
            if (UtteranceText.isEmpty(text)) {
                // only the wake word came back - keep listening for the command
                android.util.Log.i("OrbHermes", "wake echo only, still listening")
                handler.post {
                    if (phase == OrbPhase.THINKING) {
                        phase = OrbPhase.AWAKE
                        lastVoiceAt = System.currentTimeMillis()
                        setStatus("Listening…")
                    }
                }
                return@execute
            }
            val reply = try {
                client().chat(text, sessionId)
            } catch (e: Exception) {
                VoiceClient.Result(false, null, e.message ?: "chat failed")
            }
            handler.post {
                thinkingStatus.removeCallbacksAndMessages(null)
                if (!reply.ok) {
                    // a silent orb looks broken, so a failed answer is said out
                    // loud as well as written down
                    android.util.Log.w("OrbHermes", "chat failed: ${reply.error}")
                    setTranscript("Hermes unreachable: ${reply.error}", true)
                    apologise()
                    return@post
                }
                val rawAnswer = reply.value?.trim().orEmpty()
                // The agent's CLI wraps its answer in a log of tool calls and
                // a session footer. Only the answer may be read out - and if
                // the agent failed there is no answer at all.
                val answer = AnswerCleaner.clean(rawAnswer)
                if (answer.isBlank()) {
                    android.util.Log.w(
                        "OrbHermes",
                        "no usable answer: ${rawAnswer.replace('\n', ' ').take(140)}",
                    )
                    setTranscript("Hermes did not answer", true)
                    apologise()
                    return@post
                }
                setTranscript("You: $text\n\nHermes: $answer", true)
                speak(answer)
            }
        }
    }

    /**
     * Shows what the orb is doing while it waits for an answer.
     *
     * A cold model on the Beelink can take a minute to load, and a silent
     * orb looks broken. The text says so, and gets more specific the longer
     * it takes.
     */
    private fun showThinkingStatus() {
        thinkingStatus.removeCallbacksAndMessages(null)
        setTranscript("Thinking…", true)
        thinkingStatus.postDelayed({
            if (phase == OrbPhase.THINKING) {
                setTranscript("Still thinking… Hermes is waking up.", true)
            }
        }, 8_000)
        thinkingStatus.postDelayed({
            if (phase == OrbPhase.THINKING) {
                setTranscript("Still thinking… this is taking a while.", true)
            }
        }, 25_000)
        thinkingStatus.postDelayed({
            if (phase == OrbPhase.THINKING) {
                setTranscript("Still thinking… the agent is slow today.", true)
            }
        }, 60_000)
        thinkingStatus.postDelayed({
            if (phase == OrbPhase.THINKING) {
                setTranscript("Still thinking… still trying.", true)
            }
        }, 150_000)
    }

    // --------------------------------------------------------------- speak

    private fun speak(text: String) {
        if (text.isBlank()) {
            phase = OrbPhase.AWAKE
            return
        }
        phase = OrbPhase.SPEAKING
        touch()
        setStatus("Speaking…")
        setMicMuted(true)
        if (settings.preferCloudVoice) {
            replyExecutor.execute {
                val result = try {
                    client().synthesize(text, settings.voiceId)
                } catch (e: Exception) {
                    VoiceClient.Result(false, null, e.message ?: "tts failed")
                }
                handler.post {
                    if (result.ok && result.value != null && result.value!!.isNotEmpty()) {
                        playRemoteAudio(result.value!!)
                    } else {
                        speakLocally(text)
                    }
                }
            }
        } else {
            speakLocally(text)
        }
    }

    private fun playRemoteAudio(bytes: ByteArray) {
        try {
            stopSpeaking()
            val file = File(appContext.cacheDir, "hermes_reply.mp3")
            file.writeBytes(bytes)
            val mp = MediaPlayer()
            mp.setAudioAttributes(
                android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            mp.setDataSource(file.absolutePath)
            mp.setOnCompletionListener {
                it.release()
                player = null
                releaseVisualizer()
                onSpeechFinished()
            }
            mp.setOnErrorListener { m, _, _ ->
                m.release()
                player = null
                releaseVisualizer()
                onSpeechFinished()
                true
            }
            mp.prepare()
            attachVisualizer(mp)
            mp.start()
            player = mp
        } catch (e: Exception) {
            onSpeechFinished()
        }
    }

    private fun attachVisualizer(mp: MediaPlayer) {
        try {
            val v = Visualizer(mp.audioSessionId)
            v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(
                    visualizer: Visualizer?,
                    waveform: ByteArray?,
                    samplingRate: Int,
                ) {
                    if (waveform == null || waveform.size < 4) return
                    var sum = 0.0
                    var i = 0
                    while (i < waveform.size - 1) {
                        val s = ((waveform[i + 1].toInt() shl 8) or (waveform[i].toInt() and 0xFF)) / 32768.0
                        sum += s * s
                        i += 2
                    }
                    val rms = sqrt(sum / (waveform.size / 2.0))
                    // A soft curve instead of a hard cut: a loud reply used to
                    // peg the level at 1.0 and hold it there, which froze the
                    // glass instead of making it move.
                    val level = (1f - kotlin.math.exp(-rms * 6.0)).toFloat()
                    // The waveform arrives in small chunks, so the level jumps.
                    // A fast attack and a slower decay turn it into a speech
                    // envelope instead of noise.
                    speechLevel = if (level > speechLevel) {
                        speechLevel + (level - speechLevel) * 0.5f
                    } else {
                        speechLevel + (level - speechLevel) * 0.15f
                    }
                    lastVisualizerAt = System.currentTimeMillis()
                }

                override fun onFftDataCapture(
                    visualizer: Visualizer?,
                    fft: ByteArray?,
                    samplingRate: Int,
                ) {
                }
            }, Visualizer.getMaxCaptureRate() / 2, true, false)
            v.setEnabled(true)
            visualizer = v
            lastVisualizerAt = System.currentTimeMillis()
        } catch (e: Exception) {
            visualizer = null
        }
    }

    private fun releaseVisualizer() {
        try {
            visualizer?.release()
        } catch (e: Exception) {
            // ignore
        }
        visualizer = null
        speechLevel = 0f
    }

    private fun onSpeechFinished() {
        setMicMuted(false)
        phase = OrbPhase.AWAKE
        lastVoiceAt = System.currentTimeMillis()
        touch()
        setStatus("Listening…")
        scheduleTranscriptHide(TRANSCRIPT_LINGER_MS)
        handler.postDelayed({
            if (phase == OrbPhase.AWAKE) finishUtterance()
        }, 900)
    }

    private fun initLocalTts() {
        tts = TextToSpeech(appContext) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) tts?.language = Locale.US
        }
    }

    /**
     * Says that the answer did not come.
     *
     * The orb is usually used without looking at it, so a failure that is only
     * written down is a failure the user never notices.
     */
    private fun apologise() {
        phase = OrbPhase.SPEAKING
        touch()
        setStatus("Hermes is not answering")
        setMicMuted(true)
        speakLocally("Sorry, Hermes is not answering right now.")
    }

    private fun speakLocally(text: String) {
        if (!ttsReady) {
            onSpeechFinished()
            return
        }
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "hermes")
        handler.postDelayed({
            if (phase == OrbPhase.SPEAKING) onSpeechFinished()
        }, 1500L + text.length * 65L)
    }

    /**
     * Mutes the microphone while the orb talks.
     *
     * The levels are dropped as well: the microphone would only hear the
     * speaker, and the orb should breathe with its own reply, not with the
     * echo of it.
     */
    private fun setMicMuted(value: Boolean) {
        micMuted = value
        streamer?.setMuted(value)
    }

    private fun stopSpeaking() {
        player?.let {
            try {
                it.stop()
                it.release()
            } catch (e: Exception) {
                // ignore
            }
        }
        player = null
        releaseVisualizer()
        tts?.stop()
    }

    // --------------------------------------------------------------- ticker

    private fun startTicker() {
        if (tickerRunning) return
        tickerRunning = true
        val ticker = object : Runnable {
            override fun run() {
                if (!tickerRunning) return
                val now = System.currentTimeMillis()

                // dim the orb the longer nobody talks to it
                val idle = (now - lastInteractionAt).coerceAtLeast(0)
                val target = 1f - (1f - MIN_DIM) * (idle.toFloat() / IDLE_FADE_MS).coerceIn(0f, 1f)
                // come back up quickly, sink down slowly
                dim += (target - dim) * if (target > dim) 0.14f else 0.06f
                if (now - lastDimLog > 3000) {
                    lastDimLog = now
                    android.util.Log.i(
                        "OrbHermes",
                        "dim=%.2f idle=%d phase=%s bands=%.3f/%.3f/%.3f/%.3f pulse=%.3f".format(
                            dim, idle, phase, bands[0], bands[1], bands[2], bands[3], pulse,
                        ),
                    )
                }

                // speaking: the reply drives the glass. The envelope only
                // moves the *targets* - the bands follow them with a little
                // inertia, so the orb swells and settles instead of twitching
                // on every sample.
                if (phase == OrbPhase.SPEAKING) {
                    if (visualizer == null) {
                        // no visualiser on this device: fake a plausible envelope
                        val t = (now % 700) / 700f
                        speechLevel = (0.35f + 0.35f * kotlin.math.sin(t * Math.PI).toFloat())
                    } else if (now - lastVisualizerAt > VISUALIZER_STALE_MS) {
                        // the visualiser went quiet - the reply is over, so
                        // the orb settles instead of holding its last level
                        speechLevel *= 0.88f
                    }
                    // The envelope never sits perfectly still: a slow breath
                    // keeps the glass alive even under a steady voice.
                    val breath = 0.85f + 0.15f * kotlin.math.sin(now / 420.0).toFloat()
                    val envelope = speechLevel * breath
                    bandTargetAll = envelope
                    bandTargetLow = envelope * 0.8f
                    bandTargetMid = envelope * 0.6f
                    bandTargetHigh = envelope * 0.5f
                } else if (streamer?.isRunning != true) {
                    bandTargetLow = 0f
                    bandTargetMid = 0f
                    bandTargetHigh = 0f
                    bandTargetAll = 0f
                }

                // Follow the targets with an attack and a decay. The raw
                // microphone level jumps from syllable to syllable, and a
                // glass that copies it frame by frame looks broken rather
                // than alive.
                smoother.step(0, bandTargetLow)
                smoother.step(1, bandTargetMid)
                smoother.step(2, bandTargetHigh)
                smoother.step(3, bandTargetAll)

                // slow breathing while awake
                val breathing = if (phase == OrbPhase.STANDBY) 0f else
                    0.06f * (0.5f + 0.5f * kotlin.math.sin(now / 1400.0).toFloat())
                val pulseTarget = min(1f, bands[3] + breathing)
                pulse += (pulseTarget - pulse) * PULSE_SMOOTH
                awake = if (phase == OrbPhase.STANDBY) 0.25f else 1f

                // state transitions
                if (phase == OrbPhase.AWAKE) {
                    val quiet = now - lastVoiceAt
                    // the sentence is only over when the microphone has gone
                    // quiet and every recording that was sent has come back -
                    // otherwise the last words are still on their way
                    val nothingInFlight = pendingUploads.get() == 0
                    // the audio counts too: the transcript of a clip can come
                    // back empty while the recording itself is perfectly good
                    val hasUtterance = utterance.isNotEmpty() || !utteranceAudio.isEmpty
                    if (hasUtterance && quiet > SILENCE_MS && nothingInFlight) {
                        finishUtterance()
                    } else if (quiet > IDLE_MS) {
                        enterStandby()
                    }
                }

                // keep an eye on the bridge so a restart is noticed by itself
                if (phase == OrbPhase.STANDBY && now - lastHealthCheckAt > 30_000) {
                    checkHealth()
                }

                // the system can take the microphone away; make sure the orb
                // is really listening before it waits for the wake word
                ensureCapture()

                listener?.onFrame(this@OrbCore)

                handler.postDelayed(this, 50)
            }
        }
        handler.post(ticker)
    }

    // -------------------------------------------------------------- helpers

    /** The transcript is temporary: the desk settles back to the bare orb. */
    private fun scheduleTranscriptHide(delayMs: Long) {
        handler.removeCallbacks(hideTranscript)
        handler.postDelayed(hideTranscript, delayMs)
    }

    private val hideTranscript = Runnable {
        if (phase != OrbPhase.SPEAKING) {
            setTranscript(transcriptText, false)
        } else {
            scheduleTranscriptHide(4000)
        }
    }

    private fun checkHealth() {
        lastHealthCheckAt = System.currentTimeMillis()
        healthExecutor.execute {
            val result = try {
                client().health()
            } catch (e: Exception) {
                VoiceClient.Result(false, null, e.message ?: "unreachable")
            }
            handler.post {
                if (phase == OrbPhase.ONBOARDING) return@post
                if (!result.ok) {
                    // say it once, then go back to being a quiet orb
                    if (!outageAnnounced) {
                        outageAnnounced = true
                        setStatus("Not reachable: ${result.error}")
                    }
                } else if (outageAnnounced) {
                    outageAnnounced = false
                    setStatus("Connected")
                    handler.postDelayed({
                        if (phase == OrbPhase.STANDBY) {
                            setStatus("Say “${settings.wakePhrase}”")
                        }
                    }, 2000)
                } else if (phase == OrbPhase.STANDBY) {
                    setStatus("Say “${settings.wakePhrase}”")
                }
            }
        }
    }

    private fun client() = VoiceClient(settings.baseUrl, settings.token)

    companion object {
        private const val MIN_DIM = 0.22f
        private const val IDLE_FADE_MS = 45_000f
        private const val TRANSCRIPT_LINGER_MS = 9_000L

        /** The size pulse follows the energy without snapping to it. */
        private const val PULSE_SMOOTH = 0.25f
        /** How long the visualiser may stay quiet before the orb settles. */
        private const val VISUALIZER_STALE_MS = 400L

        /**
         * How long the mic has to stay quiet before the sentence is sent.
         *
         * The pause itself is already waited for by the capture, which only
         * says the speaker has stopped after a couple of seconds of silence.
         * This is the short grace on top of that, so the last clip - the one
         * with the final words - has come back from the transcriber.
         */
        private const val SILENCE_MS = 500L

        /** How long the orb waits for a command before going back to standby. */
        private const val IDLE_MS = 25_000L

        /**
         * How long the microphone may return nothing but silence before the
         * capture is opened again. Android silences a capture that was opened
         * in the background, and it never recovers on its own.
         */
        private const val MIC_SILENT_MS = 8_000L

        @Volatile
        private var instance: OrbCore? = null

        fun get(context: Context): OrbCore =
            instance ?: synchronized(this) {
                instance ?: OrbCore(context.applicationContext).also { instance = it }
            }
    }
}
