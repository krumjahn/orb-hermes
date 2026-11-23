import com.keith.orbhermes.WakeWord

/**
 * Standalone check of the phone-side wake-word matcher.
 *
 * Run it with tools/test-wake-word.sh - it compiles WakeWord.kt against the
 * cached Kotlin compiler, so no test framework or network access is needed.
 */
fun main() {
    val phrase = "Orbit"
    val matches = listOf(
        "Orbit" to true,
        "orbit" to true,
        "orbits" to true,
        "or bit" to true,
        "or a bit" to true,
        "or a bit." to true,
        "or u bit" to true,
        "hey orbit" to true,
        "Orbit, what time is it" to true,
        "orbt" to true,
        "orbit of mars" to true,
        // whisper renders the word with a swallowed "t" every now and then
        "or bid" to true,
        "or bids" to true,
        "or b it" to true,
        // and sometimes mis-hears the whole word: an aspirated h, a final d
        "Horbid, what do you know about me?" to true,
        "Horbit what time is it" to true,
        "orbot what time is it" to true,
        // the wake word clipped down to "orb" - it keeps its consonants
        "orb" to true,
        "hey orb" to true,
        // a bare "or" is only the wake word when it is all the transcriber
        // heard: "or" on its own is an ordinary English word, and treating
        // it as the wake word woke the orb on nearly every sentence that
        // started with one
        "or" to true,
        "hey or" to true,
        "or what time is it" to false,
        "hey or what time is it" to false,
        "Or, but what time is it?" to true,
        // a joined run of words has to sound like the word, not merely be a
        // couple of edits away from it: "or not" is "ornot", and that is
        // what a television said while the orb was listening
        "or not" to false,
        "or not at all" to false,
        "or maybe" to false,
        "or something" to false,
        "or the" to false,
        "or just" to false,
        "or buy" to false,
        "or ant" to false,
        "or wet" to false,
        "longer, they gained about an extra hour or not." to false,
        // words that merely look or sound similar must not wake the orb
        "a rabbit" to false,
        "herb" to false,
        "my habit is reading" to false,
        "hello there" to false,
        "for a bit" to false,
        "work on it" to false,
        "can you order a pizza" to false,
        "tell me a story" to false,
        "" to false,
        "." to false,
    )
    val strips = listOf(
        "Orbit." to "",
        "or a bit" to "",
        "or a bit what time is it" to "what time is it",
        "Orbit Orbit what time is it" to "what time is it",
        "hey orbit set a timer" to "set a timer",
        "or bid what time is it" to "what time is it",
        "Horbid what do you know about me" to "what do you know about me",
        "or what time is it" to "or what time is it",
        "or but what time is it" to "what time is it",
        "hey or what time is it" to "hey or what time is it",
        "orb what time is it" to "what time is it",
        "or" to "",
        "or not" to "or not",
        "my habit is reading" to "my habit is reading",
        "a rabbit" to "a rabbit",
        "what time is it" to "what time is it",
    )

    var failures = 0
    for ((text, expected) in matches) {
        val got = WakeWord.matches(text, phrase)
        if (got != expected) {
            failures++
            println("FAIL matches(${text.replace("\n", "\\n")}) = $got, expected $expected")
        }
    }
    for ((text, expected) in strips) {
        val got = WakeWord.strip(text, phrase)
        if (got != expected) {
            failures++
            println("FAIL strip(${text.replace("\n", "\\n")}) = '$got', expected '$expected'")
        }
    }
    if (failures == 0) {
        println("ALL KOTLIN WAKE TESTS PASS (${matches.size + strips.size} checks)")
    } else {
        println("$failures FAILURES")
        kotlin.system.exitProcess(1)
    }
}
