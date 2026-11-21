package com.keith.orbhermes

/**
 * The commands the orb understands without the wake word, and the way an
 * answer is cut into pieces that can be read out one after another.
 *
 * "Stop" has to be recognised while the orb is talking, and the orb is
 * talking with its own voice - so the microphone hears the answer as well as
 * the person. A loose match would cut the orb off in the middle of a sentence
 * that happens to contain the word "stop", so the parser is strict: the whole
 * transcript has to be the stop phrase and nothing else.
 *
 * Pure Kotlin on purpose - it carries no Android dependency so the offline
 * test suite can check it.
 */
object Command {

    /** Words that carry the meaning on their own. */
    private val STRONG = setOf(
        "stop", "enough", "cancel", "halt", "abort", "quiet", "silence", "shut", "nevermind",
    )

    /** Words that may sit in the phrase without carrying the meaning. */
    private val WEAK = setOf(
        "up", "it", "please", "now", "ok", "okay", "just", "hey", "um", "uh", "well", "there",
    )

    /** How many words the phrase may have. A sentence is not a stop command. */
    private const val MAX_WORDS = 4

    /** The shortest piece worth speaking on its own. */
    private const val MIN_PIECE = 24

    /**
     * Is this transcript a command to stop the orb?
     *
     * The whole transcript has to be the phrase. "Stop" and "okay, stop" are
     * commands; "press stop to cancel the timer" is somebody talking, and
     * must not cut the orb off.
     */
    fun isStop(raw: String): Boolean {
        val words = tokens(raw)
        if (words.isEmpty() || words.size > MAX_WORDS) return false
        // "never mind" arrives as two words
        if (words == listOf("never", "mind")) return true
        if (words.none { it in STRONG }) return false
        return words.all { it in STRONG || it in WEAK }
    }

    /**
     * Cuts an answer into pieces that can be spoken one after another.
     *
     * One request for the whole answer means nothing is heard until the whole
     * thing has been made - and on a slow machine that is most of the wait.
     * One request per piece means the first words are playing while the rest
     * is still being made.
     *
     * A piece that is far too long is cut again at a comma, because one very
     * long piece would be one very long wait.
     */
    fun sentences(text: String, maxLen: Int = 220): List<String> {
        val clean = text.replace(Regex("\\s+"), " ").trim()
        if (clean.isEmpty()) return emptyList()

        val raw = mutableListOf<String>()
        val builder = StringBuilder()
        for (ch in clean) {
            builder.append(ch)
            if (ch == '.' || ch == '!' || ch == '?') {
                raw.add(builder.toString())
                builder.setLength(0)
            }
        }
        if (builder.isNotEmpty()) raw.add(builder.toString())

        // a fragment like "Right." is too small to be a piece of its own
        val merged = mutableListOf<String>()
        var pending = ""
        for (piece in raw.map { it.trim() }.filter { it.isNotEmpty() }) {
            pending = if (pending.isEmpty()) piece else "$pending $piece"
            if (pending.length >= MIN_PIECE) {
                merged.add(pending)
                pending = ""
            }
        }
        if (pending.isNotEmpty()) merged.add(pending)

        val out = mutableListOf<String>()
        for (piece in merged) out.addAll(splitLong(piece, maxLen))
        return out.filter { it.isNotEmpty() }
    }

    /** Cuts a piece that is too long at the last comma or space that fits. */
    private fun splitLong(piece: String, maxLen: Int): List<String> {
        if (piece.length <= maxLen) return listOf(piece)
        val out = mutableListOf<String>()
        var rest = piece
        while (rest.length > maxLen) {
            var cut = rest.lastIndexOf(", ", maxLen)
            if (cut <= 0) cut = rest.lastIndexOf(' ', maxLen)
            if (cut <= 0) cut = maxLen
            out.add(rest.substring(0, cut).trim())
            rest = rest.substring(cut).trim()
        }
        if (rest.isNotEmpty()) out.add(rest)
        return out
    }

    /** Lower-case words, without the punctuation a transcriber leaves in. */
    private fun tokens(raw: String): List<String> = raw.lowercase()
        .replace(Regex("[^a-z\\s']"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()
        .split(" ")
        .filter { it.isNotEmpty() }
        .map { it.replace("'", "") }
        .filter { it.isNotEmpty() }
}
