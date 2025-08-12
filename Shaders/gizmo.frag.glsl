#include "common.glsl"

layout(location=0) in float3 in_viewpoint_position;
layout(location=1) in float3 in_position;
layout(location=2) in float3 in_normal;
layout(location=3) in float4 in_color;

layout(location=0) out float4 out_color;

void main() {
    float3 light_dir = normalize(float3(1));

    float light_intensity = max(dot(-light_dir, in_normal), 0);
    light_intensity = lerp(0.3, 1, light_intensity);

    out_color.rgb = in_color.rgb;
    out_color.a = in_color.a;
}
