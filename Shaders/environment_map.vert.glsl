#include "common.glsl"

const float2 Positions[] = float2[](
    float2(0, 1), float2(1, 1), float2(1, 0),
    float2(0, 1), float2(1, 0), float2(0, 0)
);

layout(location=0) out float2 out_position;
layout(location=1) out flat uint out_mipmap_level;

void main() {
    out_position = Positions[gl_VertexIndex];
    out_mipmap_level = gl_InstanceIndex;

    gl_Position.xy = out_position * 2 - float2(1);
    gl_Position.z = 0;
    gl_Position.w = 1;
}
