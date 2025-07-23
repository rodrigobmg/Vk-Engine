#version 460

#include "common.glsl"
#include "fxaa.glsl"

layout(location=0) in float2 in_position;

layout(location=0) out float4 out_color;

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform sampler2D u_color_texture;

void main() {
    // float3 color = texture(u_color_texture, in_position).rgb;
    float3 color = FXAA(u_color_texture, in_position, 1 / u_frame_info.window_pixel_size).rgb;
    color = LinearTosRGB(color);
    color = ApplyToneMapping(color);

    out_color = float4(color, 1);
}

