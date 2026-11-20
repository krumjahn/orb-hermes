package com.keith.orbhermes

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.GridLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import kotlin.math.min

/**
 * Desk-mode voice assistant.
 *
 * The orb is the whole interface. It idles dim, wakes on the wake word,
 * listens, thinks, and speaks back while the orb breathes with the voice.
 * Tapping the screen reveals the options panel.
 *
 * The screen is only a viewer. The voice pipeline lives in [OrbCore], which is
 * kept alive by [OrbService], so the orb keeps hearing "Orbit" with the
 * screen off.
 */
class MainActivity : AppCompatActivity(), OrbCore.Listener {

    private lateinit var settings: Settings
    private lateinit var core: OrbCore
    private lateinit var orbView: OrbView
    private lateinit var statusText: TextView
    private lateinit var transcriptText: TextView
    private lateinit var hintText: TextView
    private lateinit var optionsPanel: View
    private lateinit var presetRow: LinearLayout
    private lateinit var presetNameText: TextView
    private lateinit var onboarding: View
    private lateinit var onboardingGrid: GridLayout

    private var currentPreset = OrbPresets.all.first()
    private val presetChips = mutableListOf<TextView>()
    private var optionsVisible = false
    private var onboardingShown = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        settings = Settings(this)
        core = OrbCore.get(this)

        orbView = findViewById(R.id.orbView)
        statusText = findViewById(R.id.statusText)
        transcriptText = findViewById(R.id.transcriptText)
        hintText = findViewById(R.id.hintText)
        optionsPanel = findViewById(R.id.optionsPanel)
        presetRow = findViewById(R.id.presetRow)
        presetNameText = findViewById(R.id.presetNameText)
        onboarding = findViewById(R.id.onboarding)
        onboardingGrid = findViewById(R.id.onboardingGrid)

        currentPreset = OrbPresets.byKey(settings.presetKey)
        orbView.renderScale = settings.renderScale
        orbView.setPreset(currentPreset)
        presetNameText.text = currentPreset.name

        buildPresetChips()
        buildOnboardingGrid()
        wireControls()

        // the connection details have to be stored before the core starts,
        // otherwise the first health probe uses the previous token
        applyConnection(intent)
        core.listener = this
        core.start()

        hintText.text = "tap for options"
        requestMicIfNeeded()
        applySimulation(intent)
    }

    override fun onResume() {
        super.onResume()
        orbView.onResume()
        // Android only lets the app open a microphone capture while it is on
        // screen, and a capture that was opened in the background is fed
        // nothing but zeros - so the core is told when the app comes back.
        core.onForegroundChanged(true)
        // the foreground service is what keeps the orb listening with the
        // screen off, so it is (re)started whenever the orb comes back
        ensureService()
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        applyConnection(intent)
        core.onSettingsChanged()
        applySimulation(intent)
    }

    // ------------------------------------------------------------------ ui

    private fun buildPresetChips() {
        presetRow.removeAllViews()
        presetChips.clear()
        OrbPresets.all.forEach { preset ->
            val chip = TextView(this)
            chip.text = preset.name
            chip.textSize = 13f
            chip.setTextColor(Color.WHITE)
            chip.setPadding(dp(14), dp(9), dp(14), dp(9))
            chip.setOnClickListener { selectPreset(preset) }
            presetRow.addView(chip)
            presetChips.add(chip)
        }
        refreshChipStyles()
    }

    private fun selectPreset(preset: OrbParams) {
        currentPreset = preset
        settings.presetKey = preset.key
        orbView.setPreset(preset)
        presetNameText.text = preset.name
        refreshChipStyles()
        core.touch()
    }

    private fun refreshChipStyles() {
        OrbPresets.all.forEachIndexed { index, preset ->
            val chip = presetChips[index]
            val selected = preset.key == currentPreset.key
            val bg = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(22).toFloat()
                if (selected) {
                    setColor(preset.glowColor withAlpha 0.55f)
                    setStroke(dp(1), preset.glowColor withAlpha 0.9f)
                } else {
                    setColor(Color.parseColor("#14161F"))
                    setStroke(dp(1), Color.parseColor("#2A2E3C"))
                }
            }
            chip.background = bg
        }
    }

    private fun buildOnboardingGrid() {
        onboardingGrid.removeAllViews()
        OrbPresets.all.forEach { preset ->
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setPadding(dp(6), dp(10), dp(6), dp(10))
                val bg = GradientDrawable().apply {
                    shape = GradientDrawable.RECTANGLE
                    cornerRadius = dp(14).toFloat()
                    setColor(Color.parseColor("#12141D"))
                    setStroke(dp(1), preset.glowColor withAlpha 0.5f)
                }
                background = bg
                isClickable = true
                setOnClickListener {
                    selectPreset(preset)
                    core.finishOnboarding()
                }
            }
            val dot = TextView(this).apply {
                text = "●"
                textSize = 22f
                setTextColor(preset.glowColor.opaque())
                gravity = Gravity.CENTER
            }
            card.addView(dot, LinearLayout.LayoutParams(dp(34), dp(34)))
            val label = TextView(this).apply {
                text = preset.name
                textSize = 11f
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
                setPadding(0, dp(6), 0, 0)
            }
            card.addView(label)
            val params = GridLayout.LayoutParams().apply {
                width = 0
                height = ViewGroup.LayoutParams.WRAP_CONTENT
                columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f)
                setMargins(dp(8), dp(8), dp(8), dp(8))
            }
            onboardingGrid.addView(card, params)
        }
    }

    private fun wireControls() {
        orbView.onTap = { toggleOptions() }
        findViewById<ImageButton>(R.id.closeButton).setOnClickListener {
            optionsPanel.visibility = View.GONE
            optionsVisible = false
            core.touch()
        }
        findViewById<ImageButton>(R.id.settingsButton).setOnClickListener { showSettings() }
        findViewById<ImageButton>(R.id.talkButton).setOnClickListener {
            optionsPanel.visibility = View.GONE
            optionsVisible = false
            core.talk()
        }
        findViewById<Button>(R.id.startButton).setOnClickListener { core.finishOnboarding() }
    }

    private fun toggleOptions() {
        core.touch()
        optionsVisible = !optionsVisible
        optionsPanel.visibility = if (optionsVisible) View.VISIBLE else View.GONE
        if (optionsVisible) {
            optionsPanel.postDelayed({ hideOptions() }, 20_000)
        }
    }

    private fun hideOptions() {
        if (!optionsVisible) return
        optionsVisible = false
        optionsPanel.visibility = View.GONE
    }

    // ------------------------------------------------------- core callbacks

    override fun onStatus(text: String) {
        statusText.text = text
    }

    override fun onTranscript(text: String, visible: Boolean) {
        if (!visible) {
            transcriptText.animate().alpha(0f).setDuration(1200).start()
            return
        }
        transcriptText.text = text
        transcriptText.animate().alpha(1f).setDuration(250).start()
    }

    override fun onFrame(core: OrbCore) {
        orbView.setDim(core.dim)
        orbView.setPulse(core.pulse)
        orbView.setAwake(core.awake)
        orbView.setAudioBands(core.bands[0], core.bands[1], core.bands[2], core.bands[3])

        // the first-run picker only shows until an orb has been chosen
        val needsOnboarding = core.phase == OrbPhase.ONBOARDING
        if (needsOnboarding != onboardingShown) {
            onboardingShown = needsOnboarding
            onboarding.visibility = if (needsOnboarding) View.VISIBLE else View.GONE
            if (!needsOnboarding) optionsPanel.visibility = View.GONE
        }

        // fade the chrome out when the orb is dim; a whisper of text stays
        // so the wake word is still discoverable
        if (settings.showHints) {
            val chromeAlpha = ((core.dim - MIN_DIM) / (1f - MIN_DIM)).coerceIn(0f, 1f)
            statusText.alpha = (0.14f + chromeAlpha * 0.56f).coerceIn(0f, 0.7f)
            hintText.alpha = (0.05f + chromeAlpha * 0.30f).coerceIn(0f, 0.35f)
        } else {
            statusText.alpha = 0f
            hintText.alpha = 0f
        }
    }

    // -------------------------------------------------------------- service

    private fun requestMicIfNeeded() {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.RECORD_AUDIO), 1001,
            )
        }
    }

    private fun ensureService() {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        try {
            ContextCompat.startForegroundService(this, Intent(this, OrbService::class.java))
        } catch (e: Exception) {
            android.util.Log.w("OrbHermes", "could not start the foreground service: ${e.message}")
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1001 && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            core.startStreaming()
            ensureService()
        }
    }

    // -------------------------------------------------------------- helpers

    /**
     * Handles the optional launch overrides, which make the app scriptable:
     *   adb shell am start -n com.keith.orbhermes/.MainActivity \
     *       --es server_url http://100.x.y.z:8787 --es server_token SECRET \
     *       --es voice_id English_SereneWoman \
     *       --ez prefer_cloud_voice true \
     *       --es sim_text "what is the weather"
     */
    private fun applyConnection(intent: Intent?) {
        if (intent == null) return
        intent.getStringExtra("server_token")?.let { settings.token = it }
        intent.getStringExtra("server_url")?.let { settings.baseUrl = it }
        // the voice the orb speaks with - the bridge uses the Beelink's
        // default when the phone does not name one
        intent.getStringExtra("voice_id")?.let { settings.voiceId = it }
        intent.getStringExtra("prefer_cloud_voice")?.let {
            settings.preferCloudVoice = it.equals("true", ignoreCase = true)
        }
    }

    private fun applySimulation(intent: Intent?) {
        if (intent == null) return
        val text = intent.getStringExtra("sim_text")
        if (!text.isNullOrBlank()) {
            core.simulate(text)
        }
        // say a phrase out loud, in the voice the orb uses for its answers
        val say = intent.getStringExtra("say")
        if (!say.isNullOrBlank()) {
            core.say(say)
        }
    }

    private fun showSettings() {
        val padding = dp(20)
        val urlInput = EditText(this).apply {
            setText(settings.baseUrl)
            hint = "http://192.168.1.20:8787"
            setSingleLine()
        }
        val tokenInput = EditText(this).apply {
            setText(settings.token)
            hint = "shared secret (blank = none)"
            setSingleLine()
        }
        val voiceInput = EditText(this).apply {
            setText(settings.voiceId)
            hint = "MiniMax voice id (blank = default)"
            setSingleLine()
        }
        val wakeInput = EditText(this).apply {
            setText(settings.wakePhrase)
            hint = "Orbit"
            setSingleLine()
        }
        val scaleInput = EditText(this).apply {
            setText(settings.renderScale.toString())
            hint = "0.25 - 1.0"
            setSingleLine()
        }
        val cloudBox = CheckBox(this).apply {
            isChecked = settings.preferCloudVoice
            text = "Use MiniMax voice from the Beelink"
        }
        val hintsBox = CheckBox(this).apply {
            isChecked = settings.showHints
            text = "Show text hints (off = orb only)"
        }

        val licencesButton = Button(this).apply {
            text = "Open-source licences"
            setOnClickListener { Licences.show(this@MainActivity) }
        }

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, dp(8), padding, 0)
            addView(label("Hermes server"))
            addView(urlInput)
            addView(label("Access token"))
            addView(tokenInput)
            addView(label("Wake word"))
            addView(wakeInput)
            addView(label("MiniMax voice id"))
            addView(voiceInput)
            addView(label("Orb render scale"))
            addView(scaleInput)
            addView(cloudBox)
            addView(hintsBox)
            addView(licencesButton)
        }

        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Connection")
            .setView(container)
            .setPositiveButton("Save") { _, _ ->
                settings.baseUrl = urlInput.text.toString()
                settings.token = tokenInput.text.toString()
                settings.wakePhrase = wakeInput.text.toString().ifBlank { WakeWord.DEFAULT_PHRASE }
                settings.voiceId = voiceInput.text.toString()
                settings.renderScale = scaleInput.text.toString().toFloatOrNull() ?: 0.42f
                settings.preferCloudVoice = cloudBox.isChecked
                settings.showHints = hintsBox.isChecked
                orbView.renderScale = settings.renderScale
                core.onSettingsChanged()
            }
            .setNeutralButton("Test") { _, _ ->
                settings.baseUrl = urlInput.text.toString()
                settings.token = tokenInput.text.toString()
                core.onSettingsChanged()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun label(text: String) = TextView(this).apply {
        this.text = text
        textSize = 12f
        setTextColor(Color.parseColor("#9AA3B8"))
        setPadding(0, dp(12), 0, 0)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private infix fun Int.withAlpha(alpha: Float): Int {
        val a = (alpha * 255).toInt().coerceIn(0, 255)
        return Color.argb(a, Color.red(this), Color.green(this), Color.blue(this))
    }

    /** Preset colours are 6-digit RGB, so the alpha byte has to be forced on. */
    private fun Int.opaque(): Int = this or (0xFF shl 24)

    override fun onPause() {
        super.onPause()
        orbView.onPause()
        // the app is no longer on screen, so no new capture may be opened
        core.onForegroundChanged(false)
    }

    override fun onDestroy() {
        super.onDestroy()
        // the core keeps running: the service is what holds it alive
        core.listener = null
    }

    companion object {
        private const val MIN_DIM = 0.22f
    }
}
