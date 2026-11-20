package com.keith.orbhermes

/**
 * Smooths the raw audio levels into the bands the orb draws.
 *
 * The microphone level jumps from syllable to syllable, and the raw level
 * also arrives in bursts - three frames of audio at a time. Copied straight
 * into the shader that makes the glass twitch, which reads as a glitch
 * rather than as the orb reacting to a voice.
 *
 * So each band follows its target with an attack and a decay: up quickly so
 * the orb reacts at once, down gently so it settles rather than drops. The
 * band can never move further in one step than the attack or the decay
 * allows, which is what keeps the motion smooth.
 */
class BandSmoother(
    private val attack: Float = DEFAULT_ATTACK,
    private val decay: Float = DEFAULT_DECAY,
) {

    /** The smoothed values, in the order the renderer wants them. */
    val values = FloatArray(BANDS)

    /**
     * Moves one band towards [target] and returns its new value.
     *
     * The gap to the target is closed by a fraction of it: the attack when
     * the level rises, the decay when it falls.
     */
    fun step(index: Int, target: Float): Float {
        val current = values[index]
        // the renderer expects 0..1, so an odd target can never push a band
        // out of range
        val goal = target.coerceIn(0f, 1f)
        val factor = if (goal > current) attack else decay
        val next = current + (goal - current) * factor
        values[index] = next
        return next
    }

    /** Moves every band towards its target. */
    fun step(targets: FloatArray): FloatArray {
        for (index in 0 until minOf(BANDS, targets.size)) {
            step(index, targets[index])
        }
        return values
    }

    /** Forgets the old levels - used when the orb starts from scratch. */
    fun reset() {
        for (index in values.indices) values[index] = 0f
    }

    companion object {
        const val BANDS = 4

        /**
         * How fast the glass follows the voice.
         *
         * The ticker runs every 50 ms, so an attack of 0.35 gets most of the
         * way there in about a quarter of a second, and the slower decay
         * lets it sink back gently.
         */
        const val DEFAULT_ATTACK = 0.35f
        const val DEFAULT_DECAY = 0.12f
    }
}
