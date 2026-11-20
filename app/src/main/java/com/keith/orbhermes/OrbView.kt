package com.keith.orbhermes

import android.content.Context
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.util.AttributeSet
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.pow

/**
 * Renders the liquid-glass orb. OpenGL ES 3.0 so it runs on the Galaxy J4+
 * (Mali-T720). The surface is rendered at a reduced internal resolution and
 * upscaled by the compositor, which keeps the frame rate usable on this GPU.
 */
class OrbView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : GLSurfaceView(context, attrs) {

    private val renderer = OrbRenderer()

    /** Internal render scale: 0.25 = fastest, 0.75 = crispest. */
    var renderScale: Float = 0.42f
        set(value) {
            field = value.coerceIn(0.25f, 1f)
            applyFixedSize()
        }

    init {
        setEGLContextClientVersion(3)
        setEGLConfigChooser(8, 8, 8, 0, 0, 0)
        preserveEGLContextOnPause = true
        setRenderer(renderer)
        renderMode = RENDERMODE_CONTINUOUSLY
    }

    fun setPreset(params: OrbParams) {
        renderer.preset = params
    }

    /** x = low, y = mid, z = high, w = overall energy, all 0..1. */
    fun setAudioBands(low: Float, mid: Float, high: Float, all: Float) {
        renderer.audio = floatArrayOf(low, mid, high, all)
    }

    /** 0 idle, 1 listening, 2 thinking, 3 speaking. */
    fun setMode(mode: Int) {
        renderer.mode = mode
    }

    /** Desk mode: 0.15 (deeply dimmed) .. 1.0 (fully awake). */
    fun setDim(dim: Float) {
        renderer.dim = dim.coerceIn(0.12f, 1f)
    }

    /** Speech-driven size pulse, 0..1. */
    fun setPulse(pulse: Float) {
        renderer.pulse = pulse.coerceIn(0f, 1f)
    }

    /** How awake the orb looks, 0..1. Drives the outer glow. */
    fun setAwake(awake: Float) {
        renderer.awake = awake.coerceIn(0f, 1f)
    }

    /** Debug: render a flat clear only, to measure the display ceiling. */
    fun setSimpleMode(enabled: Boolean) {
        renderer.simpleMode = enabled
    }

    /** Fired when the user taps the orb. */
    var onTap: (() -> Unit)? = null

    override fun onTouchEvent(event: android.view.MotionEvent): Boolean {
        if (event.action == android.view.MotionEvent.ACTION_UP) {
            onTap?.invoke()
        }
        return true
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        applyFixedSize()
    }

    private fun applyFixedSize() {
        val w = width
        val h = height
        if (w <= 0 || h <= 0) return
        holder.setFixedSize(
            (w * renderScale).toInt().coerceAtLeast(64),
            (h * renderScale).toInt().coerceAtLeast(64),
        )
    }
}

private class OrbRenderer : GLSurfaceView.Renderer {

    @Volatile var preset: OrbParams = OrbPresets.all.first()
    @Volatile var audio: FloatArray = floatArrayOf(0f, 0f, 0f, 0f)
    @Volatile var mode: Int = 0
    @Volatile var simpleMode: Boolean = false
    @Volatile var dim: Float = 1f
    @Volatile var pulse: Float = 0f
    @Volatile var awake: Float = 1f

    private var program = 0
    private var vbo = 0
    private var startNanos = 0L
    private var uniformLocations: HashMap<String, Int> = hashMapOf()

    private val quad: FloatBuffer = ByteBuffer
        .allocateDirect(6 * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
        .apply {
            put(floatArrayOf(-1f, -1f, 3f, -1f, -1f, 3f))
            position(0)
        }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        program = buildProgram(OrbShader.VERTEX, OrbShader.FRAGMENT)
        val ids = IntArray(1)
        GLES30.glGenBuffers(1, ids, 0)
        vbo = ids[0]
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
        GLES30.glBufferData(
            GLES30.GL_ARRAY_BUFFER, 6 * 4, quad, GLES30.GL_STATIC_DRAW,
        )
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 0, 0)
        GLES30.glDisable(GLES30.GL_DEPTH_TEST)
        GLES30.glDisable(GLES30.GL_CULL_FACE)
        startNanos = System.nanoTime()
    }

    override fun onDrawFrame(gl: GL10?) {
        // Cap at ~30 fps: this GPU throttles badly when driven flat out, and
        // 30 fps is indistinguishable for an ambient orb.
        val now = System.nanoTime()
        if (now - lastDrawNanos < 33_000_000L) return
        lastDrawNanos = now

        val p = preset
        val a = audio
        val time = ((System.nanoTime() - startNanos) / 1_000_000_000.0).toFloat()

        GLES30.glClearColor(p.canvasColor.red(), p.canvasColor.green(), p.canvasColor.blue(), 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        if (simpleMode) {
            frameCount++
            drawNanos += System.nanoTime() - now
            if (now - lastFpsLog > 3_000_000_000L) {
                val seconds = (now - lastFpsLog) / 1_000_000_000f
                android.util.Log.i("OrbHermes", String.format(
                    "fps=%.1f frames=%d drawMs=%.1f surface=%dx%d [simple]",
                    frameCount / seconds, frameCount, drawNanos / 1_000_000f / frameCount,
                    viewportWidth, viewportHeight,
                ))
                frameCount = 0
                drawNanos = 0
                lastFpsLog = now
            }
            return
        }
        GLES30.glUseProgram(program)

        setFloat("uRes", viewportWidth.toFloat(), viewportHeight.toFloat())
        setFloat("uTime", time)
        setFloat("uSpeed", p.speed)
        setFloat("uRadius", p.radius)
        setFloat("uZoom", p.zoom)
        setFloat("uWarp", p.warp)
        setFloat("uRidgeAmt", p.ridgeAmt)
        setFloat("uSharp", p.sharp)
        setFloat("uShade", p.shade)
        setFloat("uSheen", p.sheen)
        setFloat("uGloss", p.gloss)
        setFloat("uShellMidAlpha", p.shellMidAlpha)
        setFloat("uShellEdgeAlpha", p.shellEdgeAlpha)
        setFloat("uExposure", p.exposure)
        setFloat("uFlowIndex", p.flowIndex.toFloat())
        setFloat("uEdgeGlow", p.edgeGlow)
        setFloat("uGlassOpacity", p.glassOpacity)
        setFloat("uContourDeform", p.contourDeform)
        setFloat("uBandDensity", p.bandDensity)
        setFloat("uChromaticShift", p.chromaticShift)

        setColor("uColorA", p.colorA)
        setColor("uColorB", p.colorB)
        setColor("uColorC", p.colorC)
        setColor("uColorD", p.colorD)
        setColor("uHighlight", p.highlightColor)
        setColor("uShellInner", p.shellInner)
        setColor("uShellMid", p.shellMid)
        setColor("uShellEdge", p.shellEdge)
        setColor("uSheenColor", p.sheenColor)
        setColor("uSpecColor", p.specColor)
        setColor("uCanvas", p.canvasColor)
        setColor("uGlow", p.glowColor)

        val loc = uniformLocations["uAudio"] ?: -1
        if (loc >= 0) {
            GLES30.glUniform4f(loc, a.getOrElse(0) { 0f }, a.getOrElse(1) { 0f },
                a.getOrElse(2) { 0f }, a.getOrElse(3) { 0f })
        }
        setFloat("uMode", mode.toFloat())
        setFloat("uDim", dim)
        setFloat("uPulse", pulse)
        setFloat("uAwake", awake)

        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 0, 0)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)

        frameCount++
        drawNanos += System.nanoTime() - now
        if (now - lastFpsLog > 3_000_000_000L) {
            val seconds = (now - lastFpsLog) / 1_000_000_000f
            android.util.Log.i("OrbHermes", String.format(
                "fps=%.1f frames=%d drawMs=%.1f surface=%dx%d",
                frameCount / seconds, frameCount, drawNanos / 1_000_000f / frameCount,
                viewportWidth, viewportHeight,
            ))
            frameCount = 0
            drawNanos = 0
            lastFpsLog = now
        }
    }

    private fun setFloat(name: String, v: Float) {
        val loc = uniformLocations[name] ?: return
        GLES30.glUniform1f(loc, v)
    }

    private fun setFloat(name: String, x: Float, y: Float) {
        val loc = uniformLocations[name] ?: return
        GLES30.glUniform2f(loc, x, y)
    }

    private fun setColor(name: String, argb: Int) {
        val loc = uniformLocations[name] ?: return
        GLES30.glUniform3f(loc, argb.red(), argb.green(), argb.blue())
    }

    private fun buildProgram(vertexSrc: String, fragmentSrc: String): Int {
        val vs = compile(GLES30.GL_VERTEX_SHADER, vertexSrc)
        val fs = compile(GLES30.GL_FRAGMENT_SHADER, fragmentSrc)
        val prog = GLES30.glCreateProgram()
        GLES30.glAttachShader(prog, vs)
        GLES30.glAttachShader(prog, fs)
        GLES30.glLinkProgram(prog)
        val status = IntArray(1)
        GLES30.glGetProgramiv(prog, GLES30.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES30.glGetProgramInfoLog(prog)
            GLES30.glDeleteProgram(prog)
            throw RuntimeException("Orb shader link failed: $log")
        }
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        collectUniforms(prog)
        return prog
    }

    private fun collectUniforms(prog: Int) {
        uniformLocations = hashMapOf()
        val count = IntArray(1)
        GLES30.glGetProgramiv(prog, GLES30.GL_ACTIVE_UNIFORMS, count, 0)
        for (i in 0 until count[0]) {
            val size = IntArray(1)
            val name = GLES30.glGetActiveUniform(prog, i, size, 0, IntArray(1), 0)
            val loc = GLES30.glGetUniformLocation(prog, name)
            if (loc >= 0) uniformLocations[name] = loc
        }
    }

    private fun compile(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES30.glGetShaderInfoLog(shader)
            GLES30.glDeleteShader(shader)
            throw RuntimeException("Orb shader compile failed: $log")
        }
        return shader
    }

    private var viewportWidth = 1
    private var viewportHeight = 1
    private var frameCount = 0
    private var drawNanos = 0L
    private var lastFpsLog = System.nanoTime()
    private var lastDrawNanos = 0L

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES30.glViewport(0, 0, width, height)
        viewportWidth = width
        viewportHeight = height
    }
}

/** sRGB hex -> linear RGB floats, so the shader's final gamma round-trips. */
private fun Int.red(): Float = toLinear(((this shr 16) and 0xFF) / 255f)
private fun Int.green(): Float = toLinear(((this shr 8) and 0xFF) / 255f)
private fun Int.blue(): Float = toLinear((this and 0xFF) / 255f)

private fun toLinear(c: Float): Float = c.pow(2.2f)
