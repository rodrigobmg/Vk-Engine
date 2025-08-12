#include "common.glsl"

DECLARE_STATIC_VERTEX_ATTRIBUTES();

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform ViewpointData {
    Viewpoint u_viewpoint;
};
layout(set=1, binding=1) readonly buffer MeshData {
    GizmoWidget u_widgets[];
};

layout(location=0) out float3 out_viewpoint_position;
layout(location=1) out float3 out_position;
layout(location=2) out float3 out_normal;
layout(location=3) out float4 out_color;

void main() {
    GizmoWidget widget = u_widgets[gl_InstanceIndex];

    float3 world_space_position = (widget.transform * float4(in_position, 1)).xyz;
    float3 world_space_normal = normalize((widget.transform * float4(in_normal, 0)).xyz);

    out_viewpoint_position = u_viewpoint.position;
    out_position = world_space_position;
    out_normal = world_space_normal;
    out_color = widget.color;

    gl_Position = u_viewpoint.projection * u_viewpoint.view * float4(world_space_position, 1);
    gl_Position.y = -gl_Position.y;
}
