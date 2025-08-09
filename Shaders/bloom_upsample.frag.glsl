#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform sampler2D u_texture;
layout(set=1, binding=1) uniform sampler2D u_previous_upsampled_texture;

layout(location=0) in float2 in_position;

layout(location=0) out float4 out_color;

void main() {
    int2 size = textureSize(u_previous_upsampled_texture, 0);
    float2 texel_size = 1 / float2(size);
    float4 upsampled = UpsampleTent9(u_previous_upsampled_texture, in_position, texel_size * u_frame_info.bloom_params.filter_radius);
    float4 other = textureLod(u_texture, in_position, 0);

    out_color = upsampled + other;
}
