package com.keith.orbhermes

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Talks to the Hermes bridge running on the Beelink.
 *
 * Endpoints (all on the bridge):
 *   GET  /health  -> {"ok":true,"hermes":"api-server","stt":"mcode-tools","tts":"mmx"}
 *   POST /chat    {"text":"...","session":"..."} -> {"reply":"..."}
 *   POST /stt     raw WAV bytes                -> {"text":"..."}
 *   POST /tts     {"text":"..."}                -> audio/mpeg
 */
class VoiceClient(
    private val baseUrl: String,
    private val token: String,
) {

    class Result<T>(val ok: Boolean, val value: T?, val error: String?)

    companion object {
        /**
         * The wake check has to answer quickly: it runs on the mic-upload
         * thread, and a slow answer there means the orb stops listening.
         * Whisper itself is quick, but the Beelink can be busy with other
         * work, so give it room before giving up on the phrase.
         */
        private const val WAKE_TIMEOUT_MS = 30_000
        private const val STT_TIMEOUT_MS = 45_000
        private const val TTS_TIMEOUT_MS = 45_000
        /**
         * A cold agent on the Beelink can take minutes: the CLI may try a
         * broken mode first, then the quiet one, then fall back to Ollama.
         * The phone has to wait longer than all of that, or it gives up
         * before the answer arrives.
         */
        private const val CHAT_TIMEOUT_MS = 420_000
    }

    fun health(): Result<String> {
        var conn: HttpURLConnection? = null
        return try {
            // a liveness probe must never block the voice loop
            conn = open("/health", "GET", readTimeoutMs = 6000)
                ?: return Result(false, null, "cannot reach $baseUrl")
            val code = conn.responseCode
            val body = readBody(conn, code)
            if (code in 200..299) Result(true, body, null)
            else Result(false, null, "HTTP $code: ${body?.take(160)}")
        } catch (e: Exception) {
            Result(false, null, e.message ?: "unreachable")
        } finally {
            conn?.disconnect()
        }
    }

    fun chat(text: String, session: String): Result<String> {
        val payload = JSONObject()
            .put("text", text)
            .put("session", session)
            // The model has no clock, so it is told what time it is where the
            // phone is - otherwise "what time is it" gets answered with
            // "I don't have access to the current time".
            .put("now", deviceTime())
            .put("timezone", TimeZone.getDefault().id)
            .toString()
        val conn = open("/chat", "POST", readTimeoutMs = CHAT_TIMEOUT_MS) ?: return Result(false, null, "cannot reach $baseUrl")
        return try {
            writeBody(conn, payload.toByteArray(), "application/json; charset=utf-8")
            val code = conn.responseCode
            val body = readBody(conn, code)
            if (code !in 200..299) {
                return Result(false, null, "HTTP $code: ${body?.take(200)}")
            }
            val reply = try {
                JSONObject(body ?: "").optString("reply").ifBlank { body?.trim().orEmpty() }
            } catch (e: Exception) {
                body?.trim().orEmpty()
            }
            Result(true, reply, null)
        } catch (e: Exception) {
            Result(false, null, e.message ?: "chat failed")
        } finally {
            conn.disconnect()
        }
    }

    /** Uploads recorded WAV audio and returns the transcribed text. */
    fun transcribe(wav: ByteArray): Result<String> {
        val conn = open("/stt", "POST", readTimeoutMs = STT_TIMEOUT_MS) ?: return Result(false, null, "cannot reach $baseUrl")
        return try {
            writeBody(conn, wav, "audio/wav")
            val code = conn.responseCode
            val body = readBody(conn, code)
            if (code !in 200..299) {
                return Result(false, null, "HTTP $code: ${body?.take(200)}")
            }
            val text = try {
                val json = JSONObject(body ?: "")
                // a bridge that answers with a bare line of text has no "text"
                // field - but an empty transcription is still an empty answer
                // and must not fall back to the raw json
                if (json.has("text")) json.optString("text") else body?.trim().orEmpty()
            } catch (e: Exception) {
                body?.trim().orEmpty()
            }
            Result(true, text, null)
        } catch (e: Exception) {
            Result(false, null, e.message ?: "transcribe failed")
        } finally {
            conn.disconnect()
        }
    }

    /**
     * Fast wake-word check. The bridge transcribes locally and reports whether
     * the clip contained the wake phrase.
     */
    fun wake(wav: ByteArray): Result<Pair<String, Boolean>> {
        val conn = open("/wake", "POST", readTimeoutMs = WAKE_TIMEOUT_MS) ?: return Result(false, null, "cannot reach $baseUrl")
        return try {
            writeBody(conn, wav, "audio/wav")
            val code = conn.responseCode
            val body = readBody(conn, code)
            if (code !in 200..299) {
                return Result(false, null, "HTTP $code: ${body?.take(200)}")
            }
            val json = JSONObject(body ?: "{}")
            Result(true, Pair(json.optString("text"), json.optBoolean("wake")), null)
        } catch (e: Exception) {
            Result(false, null, e.message ?: "wake check failed")
        } finally {
            conn.disconnect()
        }
    }

    /** Returns MP3 bytes for the spoken reply, or null if the bridge has no TTS. */
    fun synthesize(text: String, voiceId: String): Result<ByteArray> {
        val payload = JSONObject().put("text", text)
        if (voiceId.isNotBlank()) payload.put("voice", voiceId)
        val conn = open("/tts", "POST", readTimeoutMs = TTS_TIMEOUT_MS) ?: return Result(false, null, "cannot reach $baseUrl")
        return try {
            writeBody(conn, payload.toString().toByteArray(), "application/json; charset=utf-8")
            val code = conn.responseCode
            if (code !in 200..299) {
                val body = readBody(conn, code)
                return Result(false, null, "HTTP $code: ${body?.take(160)}")
            }
            val bytes = conn.inputStream.use { it.readBytes() }
            Result(true, bytes, null)
        } catch (e: Exception) {
            Result(false, null, e.message ?: "tts failed")
        } finally {
            conn.disconnect()
        }
    }

    /** The phone's own clock, in words, so the model can use it. */
    private fun deviceTime(): String {
        val format = SimpleDateFormat("EEEE, yyyy-MM-dd HH:mm:ss z", Locale.US)
        format.timeZone = TimeZone.getDefault()
        return format.format(Date())
    }

    private fun open(
        path: String,
        method: String,
        connectTimeoutMs: Int = 8000,
        readTimeoutMs: Int = 180000,
    ): HttpURLConnection? {        return try {
            val url = URL(baseUrl.trimEnd('/') + path)
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = method
            conn.connectTimeout = connectTimeoutMs
            conn.readTimeout = readTimeoutMs
            conn.useCaches = false
            if (token.isNotBlank()) conn.setRequestProperty("X-Auth-Token", token)
            conn
        } catch (e: Exception) {
            null
        }
    }

    private fun writeBody(conn: HttpURLConnection, bytes: ByteArray, contentType: String) {
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", contentType)
        conn.setFixedLengthStreamingMode(bytes.size)
        DataOutputStream(conn.outputStream).use { it.write(bytes) }
    }

    private fun readBody(conn: HttpURLConnection, code: Int): String? {
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        return stream?.let { BufferedInputStream(it).bufferedReader().use { r -> r.readText() } }
    }
}
