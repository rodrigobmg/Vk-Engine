#version 460

#include "common.glsl"

DECLARE_STATIC_VERTEX_ATTRIBUTES();

DECLARE_PER_FRAME_PARAMS();
DECLARE_PER_DRAW_CALL_MESH_PARAMS();

layout(location=0) out float3 out_camera_position;
layout(location=1) out flat uint out_instance_index;
layout(location=2) out float3 out_position;
layout(location=3) out float3 out_normal;
layout(location=4) out float3 out_tangent;
layout(location=5) out float3 out_bitangent;
layout(location=6) out float2 out_tex_coords;

void main() {
    MeshInstance mesh = u_mesh_instances[gl_InstanceIndex];

    float3 world_space_position = (mesh.transform * float4(v_position, 1)).xyz;
    float3 world_space_normal = normalize(mesh.normal_transform * v_normal);
    float3 world_space_tangent = normalize(mesh.normal_transform * v_tangent.xyz);
    world_space_tangent = normalize(world_space_tangent - dot(world_space_tangent, world_space_normal) * world_space_normal);

    out_camera_position = u_frame_info.camera_position;
    out_instance_index = gl_InstanceIndex;
    out_position = world_space_position;
    out_normal = world_space_normal;
    out_tangent = world_space_tangent;
    out_bitangent = v_tangent.w * cross(out_normal, out_tangent);
    out_tex_coords = v_tex_coords;
    out_tex_coords.y = 1 - out_tex_coords.y;

    gl_Position = u_frame_info.camera_projection * u_frame_info.camera_view * float4(world_space_position, 1);
    gl_Position.y = -gl_Position.y;
}
