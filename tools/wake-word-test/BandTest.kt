import com.keith.orbhermes.BandSmoother
import kotlin.math.abs

/**
 * The orb's motion has to be smooth.
 *
 * The raw microphone level jumps around, so if it were copied straight into
 * the shader the glass would twitch every frame. The smoother is what stands
 * between the two: these checks pin down that it reacts quickly, settles
 * gently, and never jumps.
 */
private var failures = 0

private fun check(label: String, ok: Boolean, detail: String = "") {
    println("  ${if (ok) "PASS" else "FAIL"}  $label" + if (detail.isNotEmpty()) "  $detail" else "")
    if (!ok) failures++
}

fun main() {
    println("BAND SMOOTHER")

    val smoother = BandSmoother()

    // rising: quick, but never more than the attack allows
    val first = smoother.step(0, 1f)
    check("a band rises straight away", first > 0f, "value=$first")
    check("a band never jumps further than the attack", first <= BandSmoother.DEFAULT_ATTACK + 1e-6f,
          "value=$first attack=${BandSmoother.DEFAULT_ATTACK}")

    // the gap closes over a few frames
    var value = first
    var frames = 1
    while (abs(value - 1f) > 0.01f && frames < 200) {
        value = smoother.step(0, 1f)
        frames++
    }
    check("a band reaches its target in about a quarter of a second", frames in 1..20,
          "frames=$frames")

    // falling: slower than the rise, so the orb settles instead of dropping
    val falling = BandSmoother()
    falling.step(0, 1f)
    val afterDrop = falling.step(0, 0f)
    val drop = BandSmoother.DEFAULT_ATTACK - afterDrop
    check("a band falls more gently than it rises", drop > 0f && drop < BandSmoother.DEFAULT_ATTACK,
          "drop=$drop")

    // the real test: a wildly noisy level must not make the band jump
    val noisy = BandSmoother()
    val targets = floatArrayOf(0f, 1f, 0f, 1f, 0.2f, 0.9f, 0f, 1f, 0.05f, 0.8f)
    var worst = 0f
    var previous = noisy.values[0]
    for (target in targets) {
        val current = noisy.step(0, target)
        worst = maxOf(worst, abs(current - previous))
        previous = current
    }
    check("a noisy level never makes the band jump", worst <= BandSmoother.DEFAULT_ATTACK + 1e-6f,
          "worst step=$worst")

    // the band stays in range, whatever the target is
    val range = BandSmoother()
    var lowest = 1f
    var highest = 0f
    for (step in 0 until 50) {
        val target = if (step % 2 == 0) 2f else -1f
        val current = range.step(1, target)
        lowest = minOf(lowest, current)
        highest = maxOf(highest, current)
    }
    check("a band stays between zero and one", lowest >= 0f && highest <= 1f,
          "low=$lowest high=$highest")

    // all four bands move on their own
    val four = BandSmoother()
    four.step(floatArrayOf(0.1f, 0.2f, 0.3f, 0.4f))
    check("every band has its own value",
          abs(four.values[0] - 0.1f * BandSmoother.DEFAULT_ATTACK) < 1e-5f &&
          abs(four.values[3] - 0.4f * BandSmoother.DEFAULT_ATTACK) < 1e-5f,
          four.values.joinToString("/"))

    // a reset forgets the old level
    four.reset()
    check("a reset clears the bands", four.values.all { it == 0f })

    println()
    if (failures > 0) {
        println("BAND SMOOTHER: $failures FAILURE(S)")
        kotlin.system.exitProcess(1)
    }
    println("ALL BAND SMOOTHER TESTS PASS")
}
