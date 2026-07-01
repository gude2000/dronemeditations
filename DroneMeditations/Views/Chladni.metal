#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// GPU Chladni field — a per-pixel port of the web WebGL fragment shader
// (web/js/visualizations.js). Rendered via SwiftUI's `.colorEffect`, so it
// runs on the GPU: sharp, per-pixel nodal lines at full frame rate instead
// of the CPU Canvas's grid of filled rectangles.
//
// The mode list (up to 8: 4 voices × 2 crossfading eigenmode pairs) is
// passed as four parallel float arrays (m, n, weight, hue) plus a count.
// Arrays are always padded to 8 on the Swift side so indexing [0..count)
// never overruns.

// GLSL-compatible smoothstep (Metal's is undefined when edge0 > edge1,
// which the center-blob call relies on).
static inline float smoothstepG(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

static inline float3 hsv2rgb(float h, float s, float v) {
    float3 K = float3(1.0, 2.0 / 3.0, 1.0 / 3.0);
    float3 p = abs(fract(float3(h) + K) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

[[ stitchable ]] half4 chladniField(
    float2 position,
    half4 currentColor,
    float2 size,
    float zoom,
    float modeCount,
    device const float *ms,
    device const float *ns,
    device const float *ws,
    device const float *hues
) {
    // Zoom about the plate center; no clipping — the cos field is periodic,
    // so it tiles to fill the viewport at any zoom (matches the web).
    float2 uv  = position / size;
    float2 puv = (uv - float2(0.5)) / max(zoom, 0.01) + float2(0.5);

    float field       = 0.0;
    float hueAccum    = 0.0;
    float weightAccum = 0.0;

    int count = int(modeCount);
    for (int i = 0; i < 8; i++) {
        if (i >= count) break;
        float mPi = ms[i] * 3.14159265;
        float nPi = ns[i] * 3.14159265;
        float w   = ws[i];
        // Antisymmetric Chladni formula. Calibration pairs are all m < n,
        // so the term never vanishes.
        float term = 0.5 * (cos(mPi * puv.x) * cos(nPi * puv.y)
                          - cos(nPi * puv.x) * cos(mPi * puv.y));
        field       += term * w;
        hueAccum    += hues[i] * w;
        weightAccum += w;
    }

    float mag  = fabs(field);
    // Tight threshold -> thin nodal curves (this crispness is what the web
    // has and the old CPU grid lacked).
    float node = max(0.0, 1.0 - mag * 9.0);

    // Center-driver bolt: small sand pile + thin nodal ring at small radius.
    float2 d       = puv - float2(0.5);
    float rCenter  = length(d);
    float blob     = smoothstepG(0.025, 0.015, rCenter);
    float ring     = smoothstepG(0.012, 0.0, fabs(rCenter - 0.075));
    node = max(node, max(blob * 0.55, ring * 0.75));

    if (node <= 0.04) return half4(0.0);

    float hue   = weightAccum > 0.0 ? (hueAccum / weightAccum) : 0.5;
    float3 rgb  = hsv2rgb(hue, 0.25, 0.95);
    float alpha = node * 0.85;
    // Premultiplied output (SwiftUI colorEffect convention).
    return half4(half3(rgb * alpha), half(alpha));
}
