import com.keith.orbhermes.AnswerCleaner

/**
 * The orb reads the answer out loud, so nothing but the answer may reach
 * the speaker.
 *
 * These samples are the real output of the Hermes CLI on the Beelink: the
 * good one, and the one from the day the agent had no model and answered
 * with a log of its tool calls.
 */
private var failures = 0

private fun show(text: String): String = "\"" + text.replace("\n", "\\n") + "\""

private fun check(label: String, ok: Boolean, detail: String = "") {
    println("  ${if (ok) "PASS" else "FAIL"}  $label" + if (detail.isNotEmpty()) "  $detail" else "")
    if (!ok) failures++
}

private val GOOD = """Query:

In one sentence, what is a liquid glass orb?

────────────────────────────────────────
☤ Hermes
A liquid glass orb is a decorative sphere typically made of clear glass enclosing a viscous liquid.
────────────────────────────────────────

Resume this session with:
  hermes --resume local-7ead336b

Session:        local-7ead336b
Duration:       11s
Messages:       2 (1 user, 0 tool calls)
"""

private val BROKEN = """🤖 AI Agent with Tool Calling
==================================================
🤖 AI Agent initialized with model:
🔑 Using API key: no-key-required
🛠️ Disabled toolset 'onboarding': setup_beat
🧰 Final tool selection (35 tools): annotate_preview, browser_exec, memory, read_file
🔎 Tool Search (tier 1): 19 MCP/plugin tools deferred behind tool_search
📊 Context limit: 256,000 tokens (compress at 75% = 192,000)

📝 User Query: In one sentence, what is a liquid glass orb?

==================================================
💻 Starting conversation: 'In one sentence...'

🔄 Making API call #1/10...
   📊 Request size: 2 messages, ~4,017 tokens (~16,068 chars)
   🔧 Available tools: 19
⚠️ Attempt 1/3, not retryable failed: HTTP 400: model is required
❌ OpenRouter rejected the request and retrying won't help: HTTP 400: model is required
   💡 Fix: pick another model (/model), or check `~/.hermes/logs/agent.log`.

📋 CONVERSATION SUMMARY
==================================================
✅ Completed: False
📎 API Calls: 1
💬 Messages: 1

🎯 FINAL RESPONSE:
------------------------------
OpenRouter rejected this request as malformed, so the model didn't answer.

Provider said: HTTP 400: model is required

🏁 Agent execution completed!
"""

fun main() {
    println("ANSWER CLEANER")

    val good = AnswerCleaner.clean(GOOD)
    check("the answer is taken out of the chrome",
          good == "A liquid glass orb is a decorative sphere typically made of clear glass enclosing a viscous liquid.",
          show(good))

    check("the tool log is never spoken", AnswerCleaner.clean(BROKEN).isEmpty(),
          show(AnswerCleaner.clean(BROKEN)))

    check("a broken agent is recognised", AnswerCleaner.failed(BROKEN))
    check("a good answer is not a failure", !AnswerCleaner.failed(GOOD))

    // a plain answer has to survive untouched
    val plain = AnswerCleaner.clean("It is four o'clock.")
    check("a plain answer survives", plain == "It is four o'clock.", show(plain))

    // an answer with paragraphs keeps them
    val two = AnswerCleaner.clean("First line.\n\nSecond line.")
    check("a two paragraph answer survives", two == "First line.\n\nSecond line.", show(two))

    // the FINAL RESPONSE label works as well
    val finalLabel = """🎯 FINAL RESPONSE:
------------------------------
Here is the answer.
"""
    check("the FINAL RESPONSE label is understood",
          AnswerCleaner.clean(finalLabel) == "Here is the answer.",
          show(AnswerCleaner.clean(finalLabel)))

    // and a label with nothing after it falls back to the chrome stripping
    val noAnswer = AnswerCleaner.clean("☤ Hermes\n")
    check("an empty answer stays empty", noAnswer.isEmpty(), show(noAnswer))

    println()
    if (failures > 0) {
        println("ANSWER CLEANER: $failures FAILURE(S)")
        kotlin.system.exitProcess(1)
    }
    println("ALL ANSWER CLEANER TESTS PASS")
}
