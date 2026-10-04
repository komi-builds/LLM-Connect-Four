#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A soft diagonal band of light that sweeps across a layer (the winning discs, §6).
// `phase` runs 0...1 across one pass; the band starts and ends outside the bounds, so the
// loop restarts invisibly. Only lit pixels change; transparent pixels stay transparent.
[[ stitchable ]] half4 specularSweep(float2 position, SwiftUI::Layer layer, float4 bounds, float phase) {
    half4 color = layer.sample(position);
    if (color.a <= 0.0h) {
        return color;
    }
    float2 uv = (position - bounds.xy) / max(bounds.zw, float2(1.0));
    float diagonal = (uv.x * 0.8 + uv.y * 0.6);
    float center = mix(-0.45, 1.85, phase);
    float band = exp(-pow((diagonal - center) / 0.13, 2.0));
    float rim = smoothstep(0.30, 0.50, length(uv - 0.5)) * band;
    half light = half(band * 0.75 + rim * 0.35);
    half3 lit = min(color.rgb + light * color.a, half3(color.a));
    return half4(lit, color.a);
}
