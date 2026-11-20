package com.keith.orbhermes

/**
 * Takes the answer out of the Hermes CLI's output.
 *
 * The agent's CLI wraps its reply in a banner, the list of tools it loaded,
 * the calls it made and a session footer. Only the answer belongs in a reply:
 * the orb reads it out loud, so everything else has to come off first.
 *
 * The bridge does the same job, but the phone cannot count on it - an older
 * bridge may still be running on the Beelink, and then the orb would read a
 * log of tool calls out to the user instead of the answer.
 */
object AnswerCleaner {

    /** The labels the CLI puts in front of the answer. */
    private val LABELS = listOf("☤ Hermes", "FINAL RESPONSE:")

    /** The session footer the CLI prints after the answer. */
    private val FOOTER = listOf(
        "Resume this session with:",
        "Session:",
        "Duration:",
        "Messages:",
    )

    /**
     * What the CLI prints when the agent itself failed.
     *
     * The CLI exits with 0 even then, so the text is all there is to go by -
     * and there is no answer in it to read out.
     */
    private val FAILURES = listOf(
        "model is required",
        "OpenRouter rejected",
        "not retryable failed",
    )

    /** The CLI's own progress report - chrome, never the answer. */
    private val CHROME = listOf(
        "AI Agent", "Using API key", "Disabled toolset", "Final tool selection",
        "Tool Search", "Loaded ", "Some tools may not work", "Context limit",
        "User Query", "Starting conversation", "Making API call", "Request size",
        "Available tools", "Request debug dump", "Attempt ", "Fix:",
        "CONVERSATION SUMMARY", "Completed:", "API Calls:",
        "Agent execution completed",
    )

    /** True when the agent failed, so there is no answer to be had. */
    fun failed(text: String): Boolean =
        FAILURES.any { text.contains(it, ignoreCase = true) }

    /**
     * The answer, or an empty string when there is none.
     */
    fun clean(text: String): String {
        if (text.isBlank()) return ""
        if (failed(text)) return ""

        for (label in LABELS) {
            val at = text.indexOf(label)
            if (at < 0) continue
            val answer = takeAnswer(text.substring(at + label.length))
            if (answer.isNotBlank()) return answer
        }
        return stripChrome(text)
    }

    /** The text up to the rule or the footer that follows the answer. */
    private fun takeAnswer(text: String): String {
        val kept = mutableListOf<String>()
        var started = false
        for (line in text.lines()) {
            val stripped = line.trim()
            if (!started) {
                // after the label there may be blank lines and a rule
                if (stripped.isEmpty() || isRule(stripped)) continue
                started = true
            } else if (isRule(stripped)) {
                // the rule after the answer ends it
                break
            }
            if (FOOTER.any { stripped.startsWith(it) }) break
            if (stripped.startsWith("Agent execution completed")) break
            kept.add(line)
        }
        return kept.joinToString("\n").trim()
    }

    /** Drops the chrome when the CLI gave no label to go by. */
    private fun stripChrome(text: String): String {
        val kept = mutableListOf<String>()
        for (line in text.lines()) {
            val stripped = line.trim()
            if (stripped.isEmpty()) {
                kept.add(line)
                continue
            }
            if (stripped.startsWith("Query:")) continue
            if (FOOTER.any { stripped.startsWith(it) }) continue
            if (isRule(stripped)) continue
            if (CHROME.any { stripped.startsWith(it) }) continue
            if (startsWithEmoji(stripped)) continue
            kept.add(line)
        }
        return kept.joinToString("\n").trim()
    }

    /** A line made of nothing but rules, like the one the CLI draws. */
    private fun isRule(text: String): Boolean {
        if (text.isEmpty()) return false
        return text.all { it in "─-═_=~ " }
    }

    /** The progress lines start with an emoji. */
    private fun startsWithEmoji(text: String): Boolean {
        val code = text.first().toInt()
        return (code in 0x1F300..0x1FAFF) || (code in 0x2600..0x27BF)
    }
}
