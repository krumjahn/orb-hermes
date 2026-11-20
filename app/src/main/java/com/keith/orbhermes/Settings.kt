package com.keith.orbhermes

import android.content.Context
import android.content.SharedPreferences

/** Persisted app settings: where Hermes lives, which orb, how it speaks. */
class Settings(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("orb_hermes", Context.MODE_PRIVATE)

    /** Base URL of the Beelink bridge, e.g. http://192.168.1.20:8787 */
    var baseUrl: String
        get() = prefs.getString(KEY_BASE_URL, DEFAULT_BASE_URL) ?: DEFAULT_BASE_URL
        set(value) = prefs.edit().putString(KEY_BASE_URL, value.trim().trimEnd('/')).apply()

    /** Shared secret sent as X-Auth-Token; blank disables the check. */
    var token: String
        get() = prefs.getString(KEY_TOKEN, "") ?: ""
        set(value) = prefs.edit().putString(KEY_TOKEN, value.trim()).apply()

    var presetKey: String
        get() = prefs.getString(KEY_PRESET, OrbPresets.all.first().key) ?: OrbPresets.all.first().key
        set(value) = prefs.edit().putString(KEY_PRESET, value).apply()

    /** 0.25 .. 1.0 internal render scale of the orb surface. */
    var renderScale: Float
        get() = prefs.getFloat(KEY_SCALE, 0.42f)
        set(value) = prefs.edit().putFloat(KEY_SCALE, value.coerceIn(0.25f, 1f)).apply()

    /** true = use MiniMax TTS on the Beelink, false = phone's own engine. */
    var preferCloudVoice: Boolean
        get() = prefs.getBoolean(KEY_CLOUD_VOICE, true)
        set(value) = prefs.edit().putBoolean(KEY_CLOUD_VOICE, value).apply()

    /** Optional MiniMax voice id, blank = bridge default. */
    var voiceId: String
        get() = prefs.getString(KEY_VOICE_ID, "") ?: ""
        set(value) = prefs.edit().putString(KEY_VOICE_ID, value.trim()).apply()

    /** The word that wakes the orb up. */
    var wakePhrase: String
        get() = prefs.getString(KEY_WAKE, "Orbit") ?: "Orbit"
        set(value) = prefs.edit()
            .putString(KEY_WAKE, value.trim().ifBlank { "Orbit" })
            .apply()

    /** False = the desk shows the orb and nothing else, no hints at all. */
    var showHints: Boolean
        get() = prefs.getBoolean(KEY_SHOW_HINTS, true)
        set(value) = prefs.edit().putBoolean(KEY_SHOW_HINTS, value).apply()

    /** True once the user has picked an orb in the first-run picker. */
    var onboardingDone: Boolean
        get() = prefs.getBoolean(KEY_ONBOARDED, false)
        set(value) = prefs.edit().putBoolean(KEY_ONBOARDED, value).apply()

    companion object {
        const val DEFAULT_BASE_URL = "http://192.168.1.20:8787"
        private const val KEY_BASE_URL = "base_url"
        private const val KEY_TOKEN = "token"
        private const val KEY_PRESET = "preset"
        private const val KEY_SCALE = "render_scale"
        private const val KEY_CLOUD_VOICE = "cloud_voice"
        private const val KEY_VOICE_ID = "voice_id"
        private const val KEY_WAKE = "wake_phrase"
        private const val KEY_SHOW_HINTS = "show_hints"
        private const val KEY_ONBOARDED = "onboarded"
    }
}
