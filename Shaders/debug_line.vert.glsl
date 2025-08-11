#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform Viewpoints {
    Viewpoint u_viewpoint;
};
layout(set=1, binding=1) readonly buffer Lines {
    DebugLine u_lines[];
};

layout(location=0) out float4 out_color;

void main() {
    DebugLine line = u_lines[gl_InstanceIndex];
    float3 position = gl_VertexIndex == 0 ? line.start : line.end;

    out_color = line.color;

    gl_Position = u_viewpoint.projection * u_viewpoint.view * float4(position, 1);
    gl_Position.y *= -1;
}

