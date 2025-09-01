#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0, std140) uniform ViewpointData {
    Viewpoint u_viewpoint;
};

layout(location=0) out float3 out_position;
layout(location=1) out float3 out_viewpoint_position;

void main() {
    const float3 Positions[] = float3[](
        float3(-1,0,-1), float3(-1,0,1), float3(1,0,1),
        float3(-1,0,-1), float3(1,0,1), float3(1,0,-1)
    );

    float3 position = Positions[gl_VertexIndex] * 100;
    position.x += u_viewpoint.position.x;
    position.z += u_viewpoint.position.z;

    out_position = position;
    out_viewpoint_position = u_viewpoint.position;

    gl_Position = u_viewpoint.projection * u_viewpoint.view * float4(position, 1);
    gl_Position.y *= -1;
}
