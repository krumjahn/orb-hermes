package com.keith.orbhermes

/**
 * Orb presets ported 1:1 from the reference project's `src/presets.ts`
 * (LerSent001/orb, MIT licence). The reference renderer is WebGPU/WGSL, which
 * the Galaxy J4+ cannot run, so this app re-implements the same look on
 * OpenGL ES 3.0. Every numeric parameter below is the original value so the
 * 13 presets stay visually faithful.
 */
data class OrbParams(
    val key: String,
    val name: String,
    val speed: Float,
    val radius: Float,
    val zoom: Float,
    val warp: Float,
    val ridgeAmt: Float,
    val sharp: Float,
    val shade: Float,
    val sheen: Float,
    val gloss: Float,
    val glassOpacity: Float,
    val shellMidAlpha: Float,
    val shellEdgeAlpha: Float,
    val exposure: Float,
    val flowIndex: Int,
    val edgeSoftness: Float,
    val edgeGlow: Float,
    val contourDeform: Float,
    val bandDensity: Float,
    val chromaticShift: Float,
    val colorA: Int,
    val colorB: Int,
    val colorC: Int,
    val colorD: Int,
    val highlightColor: Int,
    val shellInner: Int,
    val shellMid: Int,
    val shellEdge: Int,
    val sheenColor: Int,
    val specColor: Int,
    val canvasColor: Int,
    val glowColor: Int,
)

object OrbPresets {

    private const val BASE_SPEED = 1f
    private const val BASE_RADIUS = 0.72f
    private const val BASE_ZOOM = 0.3f
    private const val BASE_WARP = 3f
    private const val BASE_RIDGE = 0.5f
    private const val BASE_SHARP = 2.2f
    private const val BASE_SHADE = 0.3f
    private const val BASE_SHEEN = 0.36f
    private const val BASE_GLOSS = 0.28f
    private const val BASE_GLASS_OPACITY = 0.42f
    private const val BASE_SHELL_MID_ALPHA = 0.2f
    private const val BASE_SHELL_EDGE_ALPHA = 0.22f
    private const val BASE_EXPOSURE = 1f
    private const val BASE_EDGE_SOFTNESS = 0.005f
    private const val BASE_CONTOUR = 0f
    private const val BASE_BAND_DENSITY = 2f
    private const val BASE_CHROMATIC = 0.42f

    private val BASE_A = 0xF7FBFF.toInt()
    private val BASE_B = 0xD6E8F7.toInt()
    private val BASE_C = 0xA8C8F0.toInt()
    private val BASE_D = 0x6F9EE8.toInt()
    private val BASE_HIGHLIGHT = 0xFFFFFF.toInt()
    private val BASE_SHELL_INNER = 0xFFFFFF.toInt()
    private val BASE_SHELL_MID = 0xD6E8F7.toInt()
    private val BASE_SHELL_EDGE = 0x6F9EE8.toInt()
    private val BASE_SHEEN_COLOR = 0xEAF4FF.toInt()
    private val BASE_SPEC_COLOR = 0xDCEAFF.toInt()
    private val BASE_CANVAS = 0x000000.toInt()
    private val BASE_GLOW = 0x6F9EE8.toInt()

    private fun base(
        key: String,
        name: String,
        speed: Float = BASE_SPEED,
        radius: Float = BASE_RADIUS,
        zoom: Float = BASE_ZOOM,
        warp: Float = BASE_WARP,
        ridgeAmt: Float = BASE_RIDGE,
        sharp: Float = BASE_SHARP,
        shade: Float = BASE_SHADE,
        sheen: Float = BASE_SHEEN,
        gloss: Float = BASE_GLOSS,
        glassOpacity: Float = BASE_GLASS_OPACITY,
        shellMidAlpha: Float = BASE_SHELL_MID_ALPHA,
        shellEdgeAlpha: Float = BASE_SHELL_EDGE_ALPHA,
        exposure: Float = BASE_EXPOSURE,
        flowIndex: Int,
        edgeSoftness: Float = BASE_EDGE_SOFTNESS,
        edgeGlow: Float = 0f,
        contourDeform: Float = BASE_CONTOUR,
        bandDensity: Float = BASE_BAND_DENSITY,
        chromaticShift: Float = BASE_CHROMATIC,
        colorA: Int = BASE_A,
        colorB: Int = BASE_B,
        colorC: Int = BASE_C,
        colorD: Int = BASE_D,
        highlightColor: Int = BASE_HIGHLIGHT,
        shellInner: Int = BASE_SHELL_INNER,
        shellMid: Int = BASE_SHELL_MID,
        shellEdge: Int = BASE_SHELL_EDGE,
        sheenColor: Int = BASE_SHEEN_COLOR,
        specColor: Int = BASE_SPEC_COLOR,
        canvasColor: Int = BASE_CANVAS,
        glowColor: Int = BASE_GLOW,
    ) = OrbParams(
        key = key,
        name = name,
        speed = speed,
        radius = radius,
        zoom = zoom,
        warp = warp,
        ridgeAmt = ridgeAmt,
        sharp = sharp,
        shade = shade,
        sheen = sheen,
        gloss = gloss,
        glassOpacity = glassOpacity,
        shellMidAlpha = shellMidAlpha,
        shellEdgeAlpha = shellEdgeAlpha,
        exposure = exposure,
        flowIndex = flowIndex,
        edgeSoftness = edgeSoftness,
        edgeGlow = edgeGlow,
        contourDeform = contourDeform,
        bandDensity = bandDensity,
        chromaticShift = chromaticShift,
        colorA = colorA,
        colorB = colorB,
        colorC = colorC,
        colorD = colorD,
        highlightColor = highlightColor,
        shellInner = shellInner,
        shellMid = shellMid,
        shellEdge = shellEdge,
        sheenColor = sheenColor,
        specColor = specColor,
        canvasColor = canvasColor,
        glowColor = glowColor,
    )

    /** Display order matches `styleNames` in the reference project. */
    val all: List<OrbParams> = listOf(
        base(
            key = "siri", name = "Siri Wave", speed = 0.82f, zoom = 0.36f, warp = 3.2f,
            ridgeAmt = 0.5f, sharp = 2.2f, shade = 0.12f, sheen = 0.28f, gloss = 0.24f,
            glassOpacity = 0.44f, shellMidAlpha = 0.18f, shellEdgeAlpha = 0.18f, exposure = 2f,
            flowIndex = 9,
            colorA = 0xFFD86B.toInt(), colorB = 0x82F4FF.toInt(), colorC = 0xFF7BD5.toInt(),
            colorD = 0x8E6CFF.toInt(), shellMid = 0x9BF4FF.toInt(), shellEdge = 0xC5A9FF.toInt(),
            canvasColor = 0x030409.toInt(), glowColor = 0x956CFF.toInt(),
        ),
        base(
            key = "voiceWave", name = "Voice Membrane", speed = 0.95f, radius = 0.7f,
            contourDeform = 0.1f, zoom = 0.36f, warp = 2.6f, ridgeAmt = 0.46f, shade = 0.08f,
            sheen = 0.22f, gloss = 0.36f, glassOpacity = 0.48f, shellMidAlpha = 0.18f,
            shellEdgeAlpha = 0.2f, exposure = 1.35f, flowIndex = 19,
            colorA = 0x09030E.toInt(), colorB = 0xCE2CCB.toInt(), colorC = 0xFF5C71.toInt(),
            colorD = 0x7B53FF.toInt(), highlightColor = 0xFFD9F0.toInt(), shellMid = 0xE48BFF.toInt(),
            shellEdge = 0xFF7890.toInt(), sheenColor = 0xFFF1FA.toInt(), specColor = 0xE7D9FF.toInt(),
            canvasColor = 0x020105.toInt(), glowColor = 0xCE2CCB.toInt(),
        ),
        base(
            key = "particleRibbon", name = "Particle Ribbons", speed = 0.72f, radius = 0.66f,
            zoom = 0.36f, warp = 3.8f, ridgeAmt = 0.44f, sharp = 2.1f, shade = 0.12f,
            sheen = 0.28f, gloss = 0.24f, glassOpacity = 0.44f, shellMidAlpha = 0.18f,
            shellEdgeAlpha = 0.18f, exposure = 1.48f, flowIndex = 24,
            colorA = 0x63F1FF.toInt(), colorB = 0x4A9DFF.toInt(), colorC = 0x8566FF.toInt(),
            colorD = 0xF15DE1.toInt(), highlightColor = 0xF5FBFF.toInt(), shellInner = 0xFFFFFF.toInt(),
            shellMid = 0x9BF4FF.toInt(), shellEdge = 0xC5A9FF.toInt(),
            canvasColor = 0x010208.toInt(), glowColor = 0x765CFF.toInt(),
        ),
        base(
            key = "blueDrop", name = "Crystal Drop", speed = 0.9f, radius = 0.74f,
            contourDeform = 0.08f, zoom = 0.48f, warp = 2.65f, ridgeAmt = 0.42f, sharp = 2.4f,
            shade = 0.16f, sheen = 0.22f, gloss = 0.42f, glassOpacity = 0.66f,
            shellMidAlpha = 0.32f, shellEdgeAlpha = 0.24f, exposure = 1.24f, flowIndex = 20,
            colorA = 0x020B1D.toInt(), colorB = 0x0756B8.toInt(), colorC = 0x1EC8FF.toInt(),
            colorD = 0xDDFBFF.toInt(), highlightColor = 0xEAFBFF.toInt(), shellInner = 0xF6FDFF.toInt(),
            shellMid = 0x4FD7FF.toInt(), shellEdge = 0x466DFF.toInt(), sheenColor = 0xDDFBFF.toInt(),
            specColor = 0xA8D9FF.toInt(), canvasColor = 0x010207.toInt(), glowColor = 0x168DFF.toInt(),
        ),
        base(
            key = "violetEmber", name = "Violet Ember", speed = 1.12f, radius = 0.72f,
            contourDeform = 0.04f, zoom = 0.58f, warp = 4.7f, ridgeAmt = 0.73f, sharp = 3.3f,
            shade = 0.18f, sheen = 0.2f, gloss = 0.34f, glassOpacity = 0.62f,
            shellMidAlpha = 0.28f, shellEdgeAlpha = 0.24f, exposure = 1.28f, flowIndex = 21,
            colorA = 0x100016.toInt(), colorB = 0x4A0E8F.toInt(), colorC = 0xA52EFF.toInt(),
            colorD = 0xF1A7FF.toInt(), highlightColor = 0xFFD6FF.toInt(), shellInner = 0xFCF5FF.toInt(),
            shellMid = 0xC257FF.toInt(), shellEdge = 0x6C2DFF.toInt(), sheenColor = 0xF8E6FF.toInt(),
            specColor = 0xD4B7FF.toInt(), canvasColor = 0x030006.toInt(), glowColor = 0xA52EFF.toInt(),
        ),
        base(
            key = "refractiveBlob", name = "Refractive Gel", speed = 0.76f, radius = 0.73f,
            contourDeform = 0.16f, zoom = 0.46f, warp = 3.65f, ridgeAmt = 0.58f, sharp = 2.7f,
            shade = 0.14f, sheen = 0.14f, gloss = 0.52f, glassOpacity = 0.82f,
            shellMidAlpha = 0.42f, shellEdgeAlpha = 0.2f, exposure = 1.2f, flowIndex = 23,
            colorA = 0x1B102B.toInt(), colorB = 0x7056A8.toInt(), colorC = 0xBFA5F5.toInt(),
            colorD = 0xF1E8FF.toInt(), highlightColor = 0xFFFFFF.toInt(), shellInner = 0xF6F0FF.toInt(),
            shellMid = 0xD9C7FF.toInt(), shellEdge = 0xB59AE8.toInt(), sheenColor = 0xFFFFFF.toInt(),
            specColor = 0xE9DEFF.toInt(), canvasColor = 0x050208.toInt(), glowColor = 0xB18CFF.toInt(),
        ),
        base(
            key = "chromaticMetal", name = "Chromatic Metal", speed = 1.12f, radius = 0.72f,
            zoom = 0.36f, warp = 3.8f, ridgeAmt = 0.44f, sharp = 5.2f, shade = 0.1f,
            sheen = 0.14f, gloss = 0.46f, glassOpacity = 0.54f, shellMidAlpha = 0.2f,
            shellEdgeAlpha = 0.16f, exposure = 1.08f, flowIndex = 22,
            colorA = 0xFBFCFB.toInt(), colorB = 0x7F8683.toInt(), colorC = 0xD6DAD8.toInt(),
            colorD = 0x33373A.toInt(), highlightColor = 0xFFFFFF.toInt(), shellInner = 0xF7FCFF.toInt(),
            shellMid = 0x6EDCFF.toInt(), shellEdge = 0xFF806D.toInt(), sheenColor = 0xF7FCFF.toInt(),
            specColor = 0xD9F3FF.toInt(), canvasColor = 0x050606.toInt(), glowColor = 0xBDEFFF.toInt(),
        ),
        base(
            key = "aurora", name = "Aurora Veil", speed = 3f, contourDeform = 0.08f, zoom = 0.4f,
            warp = 4.2f, ridgeAmt = 0.62f, sharp = 2.1f, shade = 0.18f, exposure = 1.18f,
            flowIndex = 10,
            colorA = 0x030816.toInt(), colorB = 0x20F0B6.toInt(), colorC = 0x32A8FF.toInt(),
            colorD = 0xA34BFF.toInt(), shellMid = 0x32A8FF.toInt(), shellEdge = 0x20F0B6.toInt(),
            canvasColor = 0x010207.toInt(), glowColor = 0x20F0B6.toInt(),
        ),
        base(
            key = "frost", name = "Frost Flow", speed = 2.22f, contourDeform = 0.04f, zoom = 0.36f,
            warp = 3.7f, ridgeAmt = 0.45f, sharp = 2.05f, shade = 0.3f, sheen = 0.34f,
            gloss = 0.28f, glassOpacity = 0.42f, shellMidAlpha = 0.2f, shellEdgeAlpha = 0.22f,
            exposure = 1f, flowIndex = 15,
        ),
        base(
            key = "chrome", name = "Liquid Chrome", speed = 2f, zoom = 0.36f, warp = 3.8f,
            ridgeAmt = 0.44f, sharp = 5.2f, shade = 0.58f, exposure = 1.08f, flowIndex = 12,
            colorA = 0xFFFFFF.toInt(), colorB = 0xB9C0CA.toInt(), colorC = 0x343A43.toInt(),
            colorD = 0x030405.toInt(), shellMid = 0xB9C0CA.toInt(), shellEdge = 0xFFFFFF.toInt(),
            canvasColor = 0x050608.toInt(), glowColor = 0xFFFFFF.toInt(),
        ),
        base(
            key = "opal", name = "Iridescent Opal", speed = 1.5f, zoom = 0.3f, warp = 2.8f,
            ridgeAmt = 0.36f, sharp = 2f, shade = 0.1f, sheen = 0.3f, gloss = 0.26f,
            glassOpacity = 0.38f, shellMidAlpha = 0.2f, shellEdgeAlpha = 0.2f, exposure = 1.12f,
            flowIndex = 13,
            colorA = 0xFFF6E8.toInt(), colorB = 0x6EF2CF.toInt(), colorC = 0xFF91D8.toInt(),
            colorD = 0x756BFF.toInt(), shellMid = 0xCDE5FF.toInt(), shellEdge = 0xD9C8FF.toInt(),
            canvasColor = 0x07080D.toInt(), glowColor = 0x9E8CFF.toInt(),
        ),
        base(
            key = "spectrum", name = "Prismatic Field", speed = 1.8f, contourDeform = 0.03f,
            zoom = 0.46f, warp = 4.4f, ridgeAmt = 0.72f, shade = 0.06f, sheen = 0.26f,
            gloss = 0.24f, glassOpacity = 0.4f, shellMidAlpha = 0.18f, shellEdgeAlpha = 0.18f,
            exposure = 1.5f, flowIndex = 14,
            colorA = 0xFFFFFF.toInt(), colorB = 0x1677FF.toInt(), colorC = 0xF249A0.toInt(),
            colorD = 0x35E6B2.toInt(), shellMid = 0x66E8FF.toInt(), shellEdge = 0xD26CFF.toInt(),
            canvasColor = 0x03040A.toInt(), glowColor = 0x1677FF.toInt(),
        ),
        base(
            key = "plasma", name = "Neural Plasma", speed = 1.32f, contourDeform = 0.05f,
            zoom = 0.55f, warp = 5.4f, ridgeAmt = 0.78f, sharp = 4.2f, shade = 0.16f,
            exposure = 1.25f, flowIndex = 11,
            colorA = 0x06020E.toInt(), colorB = 0x0099FF.toInt(), colorC = 0x258BFF.toInt(),
            colorD = 0x1375FF.toInt(), shellInner = 0xFFFFFF.toInt(), shellMid = 0x1951C2.toInt(),
            shellEdge = 0x00E9FF.toInt(), canvasColor = 0x020105.toInt(), glowColor = 0x0099FF.toInt(),
        ),
    )

    fun byKey(key: String): OrbParams = all.firstOrNull { it.key == key } ?: all.first()
}
