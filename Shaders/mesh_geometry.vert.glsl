#include "common.glsl"

// For gl_Layer
#ifdef SHADOW_MAP_PASS
    #if defined(GL_AMD_vertex_shader_layer)
    #extension GL_AMD_vertex_shader_layer : require
    #endif

    #if defined(GL_NV_viewport_array2)
    #extension GL_NV_viewport_array2 : require
    #endif

    #if !defined(GL_AMD_vertex_shader_layer) && !defined(GL_NV_viewport_array2)
    #error No extension available for usage of gl_Layer inside vertex shader.
    #endif
#endif

DECLARE_STATIC_VERTEX_ATTRIBUTES();

DECLARE_PER_FRAME_PARAMS();
DECLARE_FORWARD_PASS_PARAMS();
DECLARE_PER_DRAW_CALL_MESH_PARAMS();

layout(location=0) out float3 out_viewpoint_position;
layout(location=1) out flat uint out_instance_index;
layout(location=2) out float3 out_position;
layout(location=3) out float3 out_normal;
layout(location=4) out float3 out_tangent;
layout(location=5) out float3 out_bitangent;
layout(location=6) out float2 out_tex_coords;

void main() {
    #ifdef SHADOW_MAP_PASS
        out_instance_index = gl_InstanceIndex / 4;
        Viewpoint viewpoint = u_viewpoints[gl_InstanceIndex % 4];
        gl_Layer = gl_InstanceIndex % 4;
    #else
        out_instance_index = gl_InstanceIndex;
        Viewpoint viewpoint = u_viewpoints[0];
    #endif

    MeshInstance mesh = u_mesh_instances[out_instance_index];

    float3 world_space_position = (mesh.transform * float4(v_position, 1)).xyz;
    float3 world_space_normal = normalize(mesh.normal_transform * v_normal);
    float3 world_space_tangent = normalize(mesh.normal_transform * v_tangent.xyz);
    world_space_tangent = normalize(world_space_tangent - dot(world_space_tangent, world_space_normal) * world_space_normal);

    out_viewpoint_position = viewpoint.position;
    out_position = world_space_position;
    out_normal = world_space_normal;
    out_tangent = world_space_tangent;
    out_bitangent = v_tangent.w * cross(out_normal, out_tangent);
    out_tex_coords = v_tex_coords;
    out_tex_coords.y = 1 - out_tex_coords.y;

    gl_Position = viewpoint.projection * viewpoint.view * float4(world_space_position, 1);
    gl_Position.y = -gl_Position.y;
}
