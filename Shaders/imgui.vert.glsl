#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0, std140) uniform Projection {
    float4x4 u_projection;
};

layout(location=0) in float2 v_position;
layout(location=1) in float2 v_tex_coords;
layout(location=2) in float4 v_color;

layout(location=0) out float2 out_tex_coords;
layout(location=1) out float4 out_color;

void main() {
    out_tex_coords = v_tex_coords;
    out_color = v_color;

    gl_Position = u_projection * float4(v_position, 0, 1);
    gl_Position.y *= -1;
}
