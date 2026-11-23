package com.keith.orbhermes

/**
 * Wake-word matching.
 *
 * Speech-to-text is fuzzy, so the matcher tolerates the ways a transcriber
 * might render the word: "orbit", "orbits", "or bit", "or a bit", "hey orbit".
 *
 * The split forms matter in practice: whisper likes to render "Orbit" as
 * "or a bit", which is three spoken tokens with a filler vowel in the middle,
 * so neighbouring tokens are joined - with and without fillers - before they
 * are compared against the phrase.
 *
 * Whisper also mis-hears the word itself - "Horbid" and "orbot" are the same
 * word spoken aloud - so the matcher compares how a word sounds, not only how
 * it happens to be spelled.
 */
object WakeWord {

    const val DEFAULT_PHRASE = "Orbit"

    /** How many neighbouring tokens may be joined into one candidate word. */
    private const val MAX_JOIN = 3

    /** Spoken fillers a transcriber inserts inside a word: "orbit" -> "or a bit". */
    private val FILLERS = setOf(
        "a", "uh", "um", "u", "er", "erm", "the", "hmm", "mm", "h", "m",
    )

    /** Politeness words that may sit in front of the wake word: "hey orbit". */
    private val LEADING_NOISE = setOf(
        "hey", "hi", "ok", "okay", "yo", "so", "well", "uh", "um",
    )

    /** Does this transcript contain the wake word? */
    fun matches(raw: String, phrase: String = DEFAULT_PHRASE): Boolean {
        val target = phrase.lowercase().trim()
        if (target.isEmpty()) return false

        val words = tokenize(raw)
        if (words.isEmpty()) return false

        val aliases = aliases(target)
        for (i in words.indices) {
            if (matchAt(words, i, aliases) > 0) return true
        }
        return false
    }

    /**
     * How many tokens the wake word covers at this position (0 = no match).
     *
     * A direct spelling is preferred over the clipped-word fallback, so
     * "or a bit" wins over the clipped "or" that starts the same phrase.
     */
    private fun matchAt(words: List<String>, index: Int, aliases: Set<String>): Int {
        for (n in 1..MAX_JOIN) {
            if (index + n > words.size) break
            for (candidate in candidates(words, index, n)) {
                if (candidate in aliases) return n
                if (fuzzyHit(candidate, n, aliases)) return n
            }
        }
        // A clipped wake word ("Orb" instead of "Orbit") only counts at the
        // front of the utterance, because the fragment is a perfectly
        // ordinary English word and must not wake the orb mid-sentence.
        if (index < words.size && startsUtterance(words, index) &&
            isClippedWord(words[index], aliases)
        ) {
            return 1
        }
        // A bare "or" is the one fragment that is too common to trust, so it
        // only counts when it is all the transcriber heard.
        if (index < words.size && isBareClippedWord(words, index, aliases)) {
            return 1
        }
        return 0
    }

    /**
     * A word the transcriber cut short.
     *
     * Whisper regularly drops the end of the wake word and leaves "orb"
     * behind. That only counts at the front of the utterance, because the
     * fragment is a perfectly ordinary English word and must not wake the
     * orb in the middle of a sentence.
     *
     * The fragment has to keep at least three letters and two of the
     * phrase's consonants. A bare "or" is far too common in ordinary
     * speech - "or not", "or maybe", "or the" all start with one - and
     * treating it as the wake word woke the orb on nearly every sentence
     * that came out of a television.
     */
    private fun isClippedWord(candidate: String, aliases: Set<String>): Boolean {
        if (candidate.length < 3) return false
        val spoken = spokenForm(candidate)
        val skeleton = consonants(spoken)
        if (skeleton.length < 2) return false
        return aliases.any {
            it.length > spoken.length && it.startsWith(spoken) &&
                skeleton in consonants(it)
        }
    }

    /** The wake word is said first, so only the front of the utterance counts. */
    private fun startsUtterance(words: List<String>, index: Int): Boolean {
        if (index == 0) return true
        return index == 1 && words[0] in LEADING_NOISE
    }

    /**
     * The wake word was cut short to a bare "or".
     *
     * "or" is a perfectly ordinary English word, and treating it as the wake
     * word woke the orb on nearly every sentence that started with one:
     * "or not", "or maybe", "or the". A dictionary of 197,000 words gave
     * 196,344 such pairs.
     *
     * It is still a real case - whisper sometimes leaves nothing but "or"
     * behind - so it counts when it is all the transcriber heard. A
     * sentence that carries on after it is a sentence, not a wake word.
     */
    private fun isBareClippedWord(
        words: List<String>,
        index: Int,
        aliases: Set<String>,
    ): Boolean {
        val candidate = words[index]
        if (candidate.length != 2) return false
        if (!aliases.any { it.length > candidate.length && it.startsWith(candidate) }) {
            return false
        }
        // it has to be the whole utterance, apart from a politeness word
        if (index == 0) return words.size == 1
        return index == 1 && words.size == 2 && words[0] in LEADING_NOISE
    }

    /**
     * Fuzzy match of one candidate against the phrase's aliases.
     *
     * A single spoken token may be one character off ("orbt" -> "orbit").
     *
     * A joined run of words has to *sound* like the phrase as well. Spelling
     * alone is far too loose here: "or not" is only two edits away from
     * "orbit", and a television talking about anything at all would wake the
     * orb. "or bid" and "or a bit" still work, because they carry the
     * consonants of the word.
     */
    private fun fuzzyHit(candidate: String, tokens: Int, aliases: Set<String>): Boolean {
        for (alias in aliases) {
            if (tokens == 1) {
                if (candidate.length in 3..8 && levenshtein(candidate, alias) <= 1) return true
                if (soundsLike(candidate, alias)) return true
            } else {
                if (soundsLikeJoined(candidate, alias)) return true
            }
        }
        return false
    }

    /**
     * Does a joined run of words sound like the phrase?
     *
     * Spelling is far too loose for a joined run: "or not" is two edits away
     * from "orbit" and "for a bit" is only one, and both of them are
     * ordinary English. The consonants are what a listener hears, so the run
     * has to carry the same ones as the word itself.
     */
    private fun soundsLikeJoined(candidate: String, alias: String): Boolean {
        if (candidate.length !in 3..12) return false
        val spoken = spokenForm(candidate)
        if (spoken == alias) return true
        if (consonants(spoken) != consonants(alias)) return false
        return levenshtein(spoken, alias) <= 2
    }

    /**
     * Does this word sound like the wake phrase?
     *
     * Whisper renders "Orbit" in ways that no spelling rule catches: "Horbid"
     * (an aspirated h and a final d), "orbot" (the second vowel drifts) or
     * "orbt" (the middle vowel swallowed). These rules compare how the word
     * sounds rather than how it was spelled, so the orb still wakes when the
     * transcriber picks a different spelling for the same sound.
     */
    private fun soundsLike(candidate: String, alias: String): Boolean {
        if (candidate.length !in 3..8) return false
        val spoken = spokenForm(candidate)
        if (spoken == alias) return true
        // one letter off, but only for a word nearly as long as the phrase
        if (spoken.length >= alias.length - 1 && levenshtein(spoken, alias) <= 1) return true
        // the same consonants in the same order: "rabbit" is not "orbit"
        if (consonants(spoken) != consonants(alias)) return false
        if (candidate.length > alias.length + 1) return false
        return levenshtein(spoken, alias) <= 2
    }

    /**
     * The word as it is actually pronounced.
     *
     * A leading h before a vowel is usually not spoken ("horbit"), and a
     * final d is often a t the transcriber heard wrong ("orbid").
     */
    private fun spokenForm(word: String): String {
        var out = word
        if (out.length > 2 && out.startsWith("h") && out[1] in "aeiou") {
            out = out.substring(1)
        }
        if (out.length > 2 && out.endsWith("d")) {
            out = out.dropLast(1) + "t"
        }
        return out
    }

    /**
     * The consonants of a word: the skeleton a listener hears.
     *
     * The endings a transcriber gets wrong are forgiven, so "orbits" and
     * "orbids" have the same skeleton.
     */
    private fun consonants(word: String): String {
        var skeleton = word.filter { it !in "aeiou" }
        if (skeleton.endsWith("ts")) {
            skeleton = skeleton.dropLast(1)
        } else if (skeleton.endsWith("ds")) {
            skeleton = skeleton.dropLast(2) + "t"
        } else if (skeleton.endsWith("d")) {
            skeleton = skeleton.dropLast(1) + "t"
        }
        return skeleton
    }

    /**
     * Removes leading wake words from a transcript.
     *
     * The first chunk after waking usually still contains the wake word itself
     * ("Orbit." / "or a bit"), and that echo should not end up in the command
     * the assistant receives.
     */
    fun strip(raw: String, phrase: String = DEFAULT_PHRASE): String {
        val target = phrase.lowercase().trim()
        if (target.isEmpty()) return raw.trim()

        val rawWords = raw.split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (rawWords.isEmpty()) return ""
        val words = rawWords.map { it.lowercase().trim { ch -> !ch.isLetter() } }
        val aliases = aliases(target)

        var index = 0
        while (index < words.size) {
            // a politeness word may sit in front of the wake word
            val probe = if (words[index] in LEADING_NOISE) index + 1 else index
            val matched = matchAt(words, probe, aliases)
            if (matched == 0) break
            index = probe + matched
        }
        return rawWords.drop(index).joinToString(" ").trim()
    }

    /**
     * Candidate spellings of a run of spoken tokens.
     *
     * "orbit" may arrive as ["orbit"], ["or","bit"] or ["or","a","bit"], so a
     * window is joined both as-is and with the spoken fillers removed.
     */
    private fun candidates(words: List<String>, start: Int, size: Int): List<String> {
        val window = words.subList(start, start + size)
        if (window.isEmpty()) return emptyList()
        val result = mutableListOf(window.joinToString(""))
        val stripped = window.filter { it !in FILLERS }
        if (stripped.isNotEmpty() && stripped.size != window.size) {
            result.add(stripped.joinToString(""))
        }
        return result
    }

    /** Lower-case, punctuation-free tokens. */
    private fun tokenize(raw: String): List<String> = raw.lowercase()
        .replace(Regex("[^a-z\\s']"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()
        .split(" ")
        .filter { it.isNotEmpty() }
        .map { it.replace("'", "") }
        .filter { it.isNotEmpty() }

    /** The phrase plus the ways a transcriber tends to inflect it. */
    private fun aliases(phrase: String): Set<String> {
        val compact = phrase.replace(" ", "")
        return setOf(compact, compact + "s", compact + "es")
    }

    private fun levenshtein(a: String, b: String): Int {
        if (a == b) return 0
        if (a.isEmpty()) return b.length
        if (b.isEmpty()) return a.length
        var previous = IntArray(b.length + 1) { it }
        val current = IntArray(b.length + 1)
        for (i in 1..a.length) {
            current[0] = i
            for (j in 1..b.length) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                current[j] = minOf(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
            }
            previous = current.copyOf()
        }
        return previous[b.length]
    }
}
