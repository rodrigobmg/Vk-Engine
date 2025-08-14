#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform sampler2D u_texture;

layout(location=0) in float2 in_position;

layout(location=0) out float4 out_color;

void main() {
    int2 size = textureSize(u_texture, 0);
    float2 texel_size = 1 / float2(size);

    out_color = DownsampleBox13(u_texture, in_position, texel_size);
}
