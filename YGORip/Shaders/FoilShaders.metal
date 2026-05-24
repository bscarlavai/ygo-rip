#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

inline float fs_hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline half3 fs_hsv2rgb(half3 c) {
    half4 K = half4(1.0h, 2.0h / 3.0h, 1.0h / 3.0h, 3.0h);
    half3 p = abs(fract(c.xxx + K.xyz) * 6.0h - K.www);
    return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
}

inline half3 fs_colorDodge(half3 base, half3 blend) {
    return select(base / max(1.0h - blend, 0.001h),
                  half3(1.0h),
                  blend >= half3(0.999h));
}

[[stitchable]] half4 foilPassthrough(float2 position, half4 color) {
    return color;
}

// One foil shader for all rarities. In MTG, Scryfall returns the *non-foil*
// card image — the shader is responsible for rendering the foil treatment
// itself (moving sheen + iridescence at the highlight + tilt-twinkling
// sparkles), gated by the calling code (typically per-pull `isFoil` flag).
[[stitchable]] half4 cardShimmer(
    float2 position,
    half4 color,
    float2 size,
    float2 tilt,
    float sheenStrength,
    float rainbowSaturation,
    float sparkleDensity
) {
    if (color.a < 0.01h) {
        return color;
    }
    if (size.x < 1.0 || size.y < 1.0) {
        return color;
    }

    float2 uv = position / size;

    // Diagonal sheen with a soft halo + hot core.
    float bandPos = uv.x + uv.y - 1.0 + tilt.x * 0.6 - tilt.y * 0.4;
    float halo = exp(-bandPos * bandPos * 5.0);
    float core = exp(-bandPos * bandPos * 25.0);

    float hue = fract(0.55 + bandPos * 0.3 + tilt.y * 0.15);
    half3 rainbowTint = fs_hsv2rgb(half3(half(hue), half(rainbowSaturation), 1.0h));
    half3 sheenColor = mix(half3(1.0h), rainbowTint, half(rainbowSaturation));
    half3 sheenLayer = sheenColor * (half(halo) * 0.4h + half(core) * 0.7h) * half(sheenStrength);

    // Sparkles anchored to UV — tilt only chooses which cells light up so
    // they twinkle in place instead of swimming with the card.
    float2 cellUV = uv * 90.0;
    float2 cellI = floor(cellUV);
    float2 cellF = fract(cellUV) - 0.5;

    float rAlive = fs_hash(cellI);
    float rJx    = fs_hash(cellI + float2(13.7, 7.3));
    float rJy    = fs_hash(cellI + float2(31.1, 19.4));
    float rSize  = fs_hash(cellI + float2(53.2, 41.8));

    float2 jitter = (float2(rJx, rJy) - 0.5) * 0.7;
    float sparkleSize = 0.06 + rSize * 0.12;
    float dist = length(cellF - jitter);
    float star = smoothstep(sparkleSize, 0.0, dist);

    float threshold = 1.0 - sparkleDensity;
    float angle = atan2(tilt.y, tilt.x);
    float alive = step(threshold, fract(rAlive * 7.3 + angle * 0.5));
    half3 sparkleLayer = half3(1.0h) * half(star * alive);

    // Internal 0.55 safety scale keeps colorDodge from clipping bright bases
    // to white at max strengths.
    half3 foilBlend = sheenLayer + sparkleLayer * 0.7h;
    half3 result = fs_colorDodge(color.rgb, foilBlend * 0.55h);
    return half4(result, color.a);
}
