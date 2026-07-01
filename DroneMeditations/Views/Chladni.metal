#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// GPU Chladni field — a per-pixel port of the web WebGL fragment shader,
// rendered via SwiftUI's `.colorEffect`. Sharp per-pixel nodal lines at
// full frame rate instead of the CPU Canvas's grid of filled rectangles.
//
// Modes (up to 8: 4 voices × 2 crossfading eigenmode pairs) are passed as
// eight float4 scalar args — (m, n, weight, hue) each — NOT a buffer, so
// there's no array-binding uncertainty. modeCount says how many are live.
//
// Output is OPAQUE and additive: brightness carries the node strength. The
// view applies `.blendMode(.plusLighter)`, so dark areas add nothing (read
// as transparent) and bright nodal lines glow — this deliberately avoids
// any premultiplied-vs-straight alpha ambiguity.

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
    float4 m0, float4 m1, float4 m2, float4 m3,
    float4 m4, float4 m5, float4 m6, float4 m7
) {
    float4 modes[8] = { m0, m1, m2, m3, m4, m5, m6, m7 };

    float2 uv  = position / size;
    float2 puv = (uv - float2(0.5)) / max(zoom, 0.01) + float2(0.5);

    float field       = 0.0;
    float hueAccum    = 0.0;
    float weightAccum = 0.0;

    int count = int(modeCount);
    for (int i = 0; i < 8; i++) {
        if (i >= count) break;
        float mPi = modes[i].x * 3.14159265;
        float nPi = modes[i].y * 3.14159265;
        float w   = modes[i].z;
        float term = 0.5 * (cos(mPi * puv.x) * cos(nPi * puv.y)
                          - cos(nPi * puv.x) * cos(mPi * puv.y));
        field       += term * w;
        hueAccum    += modes[i].w * w;
        weightAccum += w;
    }

    float mag  = fabs(field);
    float node = max(0.0, 1.0 - mag * 9.0);

    // Center-driver bolt (data-independent — shows even with 0 modes, which
    // makes it a useful "is the shader running?" tell).
    float2 d      = puv - float2(0.5);
    float rCenter = length(d);
    float blob    = smoothstepG(0.025, 0.015, rCenter);
    float ring    = smoothstepG(0.012, 0.0, fabs(rCenter - 0.075));
    node = max(node, max(blob * 0.55, ring * 0.75));

    float hue  = weightAccum > 0.0 ? (hueAccum / weightAccum) : 0.5;
    float3 rgb = hsv2rgb(hue, 0.25, 0.95);
    return half4(half3(rgb * node), 1.0h);
}
