import com.keith.orbhermes.Command

/**
 * The orb has to be able to be stopped while it is talking, and the phone is
 * the speaker - so the microphone hears the orb's own voice as well.
 *
 * These checks make sure the stop parser is strict enough that an answer
 * which happens to contain the word "stop" does not cut the orb off, and that
 * an answer can be cut into pieces that are read out one after another.
 */
private var failures = 0

private fun check(label: String, ok: Boolean, detail: String = "") {
    println("  ${if (ok) "PASS" else "FAIL"}  $label" + if (detail.isNotEmpty()) "  $detail" else "")
    if (!ok) failures++
}

private fun show(text: String): String = "\"" + text.replace("\n", "\\n") + "\""

fun main() {
    println("COMMAND")

    // the stop command
    check("stop is a stop command", Command.isStop("stop"))
    check("Stop. is a stop command", Command.isStop("Stop."))
    check("okay stop is a stop command", Command.isStop("okay stop"))
    check("please stop is a stop command", Command.isStop("please stop"))
    check("stop, please is a stop command", Command.isStop("stop, please"))
    check("shut up is a stop command", Command.isStop("shut up"))
    check("enough is a stop command", Command.isStop("enough"))
    check("never mind is a stop command", Command.isStop("never mind"))
    check("nevermind is a stop command", Command.isStop("nevermind"))

    // a sentence that merely contains the word is somebody talking
    check("a sentence is not a stop command", !Command.isStop("press stop to cancel the timer"))
    check("an answer is not a stop command", !Command.isStop("the server stopped responding"))
    check("a long answer is not a stop command", !Command.isStop("it stopped because the network was down"))
    check("an empty transcript is not a stop command", !Command.isStop(""))
    check("noise is not a stop command", !Command.isStop("um huh"))
    check("a word that starts like stop is not a stop command", !Command.isStop("stopwatch"))
    check("up on its own is not a stop command", !Command.isStop("up"))
    check("five words are not a stop command", !Command.isStop("please stop the music now"))

    // the answer is cut into pieces
    val answer = "The Raptors are second in the east. They won nine in a row. Next they play Toronto."
    val pieces = Command.sentences(answer)
    // a short sentence is joined to the one after it: a piece of a second and a
    // half would sound chopped
    check("the answer is cut into pieces", pieces.size == 2, "pieces=${pieces.size}")
    check("the pieces keep the words", pieces.joinToString(" ").contains("Raptors"))
    check("the first piece is the first sentence", pieces[0].startsWith("The Raptors"), show(pieces[0]))
    check("a short fragment is joined to the sentence after it",
        pieces[1].contains("nine in a row") && pieces[1].contains("Toronto"), show(pieces[1]))
    check("a whole answer stays whole when it is short",
        Command.sentences("Yes.").size == 1, show(Command.sentences("Yes.").joinToString("|")))
    check("an empty answer has no pieces", Command.sentences("").isEmpty())
    check("a long answer is cut again", Command.sentences("word ".repeat(80)).all { it.length <= 220 })

    // a fragment is joined to the sentence that follows it
    val joined = Command.sentences("Right. The meeting starts at nine.")
    check("a tiny fragment is joined to the next sentence", joined.size == 1, show(joined.joinToString("|")))

    println()
    if (failures > 0) {
        println("COMMAND: $failures FAILURE(S)")
        kotlin.system.exitProcess(1)
    }
    println("ALL COMMAND TESTS PASS")
}
