package com.keith.orbhermes

/**
 * OpenGL ES 3.0 re-implementation of the reference project's liquid-glass orb.
 *
 * The original renderer (LerSent001/orb) is WebGPU/WGSL. The Galaxy J4+ runs
 * Android 12 on a Mali-T720 (OpenGL ES 3.0, no WebGPU), so the look is rebuilt
 * here as an analytic ray/sphere shader with procedural displacement, refraction
 * and chromatic dispersion. Preset parameters and palette are unchanged.
 */
object OrbShader {

    const val VERTEX = """#version 300 es
layout(location = 0) in vec2 aPos;
out vec2 vUv;
void main() {
    vUv = aPos;
    gl_Position = vec4(aPos, 0.0, 1.0);
}
"""

    const val FRAGMENT = """#version 300 es
precision highp float;

in vec2 vUv;
out vec4 fragColor;

uniform vec2  uRes;
uniform float uTime;
uniform float uSpeed;
uniform float uRadius;
uniform float uZoom;
uniform float uWarp;
uniform float uRidgeAmt;
uniform float uSharp;
uniform float uShade;
uniform float uSheen;
uniform float uGloss;
uniform float uShellMidAlpha;
uniform float uShellEdgeAlpha;
uniform float uExposure;
uniform float uFlowIndex;
uniform float uEdgeGlow;
uniform float uGlassOpacity;
uniform float uContourDeform;
uniform float uBandDensity;
uniform float uChromaticShift;

uniform vec3 uColorA;
uniform vec3 uColorB;
uniform vec3 uColorC;
uniform vec3 uColorD;
uniform vec3 uHighlight;
uniform vec3 uShellInner;
uniform vec3 uShellMid;
uniform vec3 uShellEdge;
uniform vec3 uSheenColor;
uniform vec3 uSpecColor;
uniform vec3 uCanvas;
uniform vec3 uGlow;

// x = low, y = mid, z = high, w = overall energy (0..1)
uniform vec4 uAudio;
// 0 idle, 1 listening, 2 thinking, 3 speaking
uniform float uMode;
// Desk-mode presentation controls
uniform float uDim;    // 0.15 .. 1.0 brightness when idle
uniform float uPulse;  // 0 .. 1 radius pulse from the voice
uniform float uAwake;  // 0 .. 1 how "awake" the orb is

float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 x) {
    vec3 i = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash13(i);
    float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
    float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
    float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
    float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
    float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
    float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
    float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm(vec3 p) {
    float amp = 0.5;
    float sum = 0.0;
    for (int i = 0; i < 3; i++) {
        sum += amp * vnoise(p);
        p = p * 2.03 + vec3(5.2, 1.3, 9.7);
        amp *= 0.5;
    }
    return sum / 0.875;
}

// Two-octave variant used for the three normal taps, where the extra octave
// costs more than it shows on a phone GPU.
float fbm2(vec3 p) {
    float sum = 0.5 * vnoise(p);
    sum += 0.25 * vnoise(p * 2.03 + vec3(5.2, 1.3, 9.7));
    return sum / 0.75;
}

// Domain warp: every preset gets a slightly different flow topology via uFlowIndex.
vec3 flowWarp(vec3 p, float t) {
    float fi = uFlowIndex;
    return p + vec3(
        sin(p.y * 1.7 + t * 0.55 + fi),
        sin(p.z * 1.3 - t * 0.45 + fi * 1.7),
        cos(p.x * 1.9 + t * 0.35 + fi * 2.3)
    ) * (0.10 * uWarp);
}

// Scalar displacement field sampled on the unit sphere.
// Kept deliberately lean: this shader runs on an Adreno 308, where pow() and
// extra noise octaves cost far more than they add.
float surfaceField(vec3 dir, float t) {
    vec3 p = dir * (1.9 + uBandDensity * 0.35);
    float fi = uFlowIndex;
    vec3 q = p + vec3(
        sin(p.y * 1.7 + t * 0.55 + fi),
        sin(p.z * 1.3 - t * 0.45 + fi * 1.7),
        cos(p.x * 1.9 + t * 0.35 + fi * 2.3)
    ) * (0.10 * uWarp);

    float n = vnoise(q + vec3(0.0, 0.0, t * 0.22 * uSpeed));

    // ridge without pow(): smoothstep shape, then optional cubic bite
    float r = 1.0 - abs(n * 2.0 - 1.0);
    r = r * r * (3.0 - 2.0 * r);
    r = mix(r, r * r * r, clamp(uSharp / 5.0, 0.0, 1.0));
    float d = mix(n, r, clamp(uRidgeAmt, 0.0, 1.0));

    float bands = sin(dir.y * (3.0 + uBandDensity * 2.2) + t * 1.4 * uSpeed + n * 2.4) * 0.5 + 0.5;
    d = mix(d, d * 0.45 + bands * 0.55, clamp(uBandDensity * 0.34, 0.0, 0.72));
    return d;
}

vec3 orbNormal(vec3 dir, vec3 n0, float t) {
    vec3 up = abs(n0.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 t1 = normalize(cross(n0, up));
    vec3 t2 = cross(n0, t1);
    float e = 0.02;
    float d0 = surfaceField(dir, t);
    float d1 = surfaceField(normalize(dir + t1 * e), t);
    float d2 = surfaceField(normalize(dir + t2 * e), t);
    float amp = 0.9 + 2.2 * uContourDeform + 2.6 * uAudio.x + 3.2 * uAudio.w;
    vec3 grad = t1 * (d1 - d0) + t2 * (d2 - d0);
    return normalize(n0 - grad * amp);
}

// Procedural studio environment; refraction reads against it.
// Light falloffs use repeated squaring instead of pow().
vec3 envColor(vec3 rd) {
    float y = clamp(rd.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 base = mix(uCanvas * 1.7, uGlow * 0.30, y * y);
    float l1 = max(dot(rd, vec3(-0.4776, 0.7962, 0.3715)), 0.0);
    float l2 = max(dot(rd, vec3(0.7582, 0.2916, 0.5832)), 0.0);
    float l3 = max(dot(rd, vec3(0.1111, -0.8889, 0.4444)), 0.0);
    l1 = l1 * l1; l1 = l1 * l1; l1 = l1 * l1;          // ^8
    l2 = l2 * l2; l2 = l2 * l2; l2 = l2 * l2;          // ^8
    l3 = l3 * l3;                                     // ^2
    base += uHighlight * l1 * 0.85;
    base += uShellMid * l2 * 0.55;
    base += uShellEdge * l3 * 0.35;
    return base;
}

vec3 interiorColor(vec3 dir, float t) {
    vec3 p = dir * (2.2 + uBandDensity * 0.4);
    float fi = uFlowIndex;
    vec3 q = p * 1.15 + vec3(
        sin(p.y * 1.9 + t * 0.60 + fi),
        sin(p.z * 1.5 - t * 0.50 + fi * 1.7),
        cos(p.x * 2.1 + t * 0.40 + fi * 2.3)
    ) * (0.12 * uWarp);

    float n = vnoise(q + vec3(0.0, 0.0, t * 0.30 * uSpeed));
    float bands = sin(n * 9.0 + dir.z * 2.0 - t * 1.1 * uSpeed) * 0.5 + 0.5;
    float m = clamp(n * 0.75 + bands * 0.45, 0.0, 1.0);
    vec3 c = mix(uColorA, uColorB, smoothstep(0.15, 0.60, m));
    c = mix(c, uColorC, smoothstep(0.45, 0.85, m));
    c = mix(c, uColorD, smoothstep(0.70, 1.00, m));
    // push saturation so the interior does not wash out behind the glass layer
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return mix(vec3(luma), c, 1.38);
}

void main() {
    vec2 frag = gl_FragCoord.xy;
    vec2 uv = (frag - 0.5 * uRes) / min(uRes.x, uRes.y) * 2.0;
    float t = uTime;

    vec3 col = uCanvas * (1.0 - 0.06 * dot(uv, uv));
    float grain = hash13(vec3(frag, floor(t * 30.0))) - 0.5;
    col += grain * 0.005 * (0.25 + 2.0 * dot(col, vec3(0.33)));

    vec3 ro = vec3(0.0, 0.0, 3.25);
    vec3 rd = normalize(vec3(uv * uZoom * 1.45, -1.85));

    float radius = uRadius * (1.0 + 0.035 * uAudio.w + 0.085 * uPulse);
    float b = dot(ro, rd);
    float c = dot(ro, ro) - radius * radius;
    float h = b * b - c;

    float dCentre = length(uv);
    float halo = exp(-max(dCentre - radius * 1.12, 0.0) * 5.5);
    col += uGlow * halo * (0.10 + 0.35 * uEdgeGlow + 0.12 * uAudio.w) * (0.35 + 0.65 * uAwake);

    if (h > 0.0) {
        float tHit = -b - sqrt(h);
        vec3 p = ro + rd * tHit;
        vec3 n0 = normalize(p);
        vec3 n = orbNormal(n0, n0, t);

        vec3 inner = interiorColor(n0, t) * (0.62 + 0.60 * uShade);

        float ior = 1.35;
        float shift = uChromaticShift * 0.055;
        vec3 rrG = refract(rd, n, 1.0 / ior);
        if (dot(rrG, rrG) < 0.001) rrG = reflect(rd, n);
        vec3 env = envColor(rrG);
        // cheap dispersion: stretch the sampled environment per channel
        vec3 refr = vec3(env.r * (1.0 + shift), env.g, env.b * (1.0 - shift * 0.85));
        vec3 glass = mix(inner, refr, clamp(uGlassOpacity, 0.0, 1.0));

        vec3 L = normalize(vec3(-0.42, 0.72, 0.55));
        vec3 H = normalize(L - rd);
        float spec = pow(max(dot(n, H), 0.0), mix(24.0, 220.0, clamp(uGloss, 0.0, 1.0)));
        glass += uSpecColor * spec * (0.45 + 1.5 * uGloss);

        float rim = pow(1.0 - clamp(dot(n0, -rd), 0.0, 1.0), 2.6);
        float rim2 = rim * rim;
        float rim6 = rim2 * rim2 * rim2;
        glass += uSheenColor * rim * uSheen * 1.30;
        glass += uShellMid * rim * uShellMidAlpha * 1.60;
        glass += uShellEdge * rim6 * uShellEdgeAlpha * 2.60;
        glass += uHighlight * rim6 * (0.22 + 0.55 * uAudio.z);

        if (uMode > 0.5 && uMode < 1.5) {
            float ring = sin(dCentre * 26.0 - t * 5.0) * 0.5 + 0.5;
            glass += uGlow * pow(ring, 6.0) * 0.35 * (0.45 + uAudio.w);
        } else if (uMode > 1.5 && uMode < 2.5) {
            float sweep = sin(n0.y * 12.0 - t * 3.0) * 0.5 + 0.5;
            glass += uShellInner * pow(sweep, 5.0) * 0.22;
        } else if (uMode > 2.5) {
            glass += uHighlight * uAudio.w * 0.35;
        }

        col = mix(col, glass, smoothstep(0.0, 0.0060, h));
    }

    col *= uExposure;
    col = col / (col + vec3(0.85));
    col = sqrt(clamp(col, 0.0, 1.0));

    // Desk mode: the orb sinks into the background the longer nobody talks to it.
    vec3 dimTint = mix(vec3(0.035, 0.040, 0.058), vec3(1.0), clamp(uDim, 0.0, 1.0));
    col = col * mix(vec3(0.16, 0.18, 0.26), vec3(1.0), clamp(uDim, 0.0, 1.0)) + dimTint * 0.04;

    fragColor = vec4(col, 1.0);
}
"""
}
