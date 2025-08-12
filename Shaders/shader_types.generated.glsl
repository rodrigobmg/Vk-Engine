// This file was auto generated

#ifndef SHADER_TYPES_GENERATED_GLSL
#define SHADER_TYPES_GENERATED_GLSL

struct BloomParams {
    float resolution_factor;
    float brightness_threshold;
    float brightness_soft_threshold;
    float blend_intensity;
    float filter_radius;
};

struct DebugLine {
    float3 start;
    float3 end;
    float4 color;
};

struct Viewpoint {
    float3 position;
    float3 direction;
    float3 right;
    float3 up;
    float4x4 transform;
    float4x4 view;
    float4x4 projection;
    float4x4 view_projection;
    float2 viewport_size;
    float fov;
    float z_near;
    float z_far;
};

struct DirectionalLight {
    float3 direction;
    float3 color;
    float intensity;
    int shadow_map_index;
    uint shadow_map_resolution;
    float shadow_map_cascade_sizes[4];
    Viewpoint shadow_map_viewpoints[4];
};

struct EntityOutlineParams {
    float thickness;
    float covered_alpha;
    float4 color;
};

struct ShadowMapParams {
    uint noise_resolution;
    float2 depth_bias_min_max;
    float normal_bias;
    float filter_radius;
};

struct FrameInfo {
    float time;
    float2 window_pixel_size;
    uint num_directional_lights;
    uint num_point_lights;
    float skybox_light_intensity;
    ShadowMapParams shadow_map_params;
    BloomParams bloom_params;
    EntityOutlineParams entity_outline_params;
};

#define GizmoMesh int
#define GizmoMesh_Cube 0
#define GizmoMesh_Sphere 1
#define GizmoMesh_SphereQuarter 2
#define GizmoMesh_Plane 3
#define GizmoMesh_Arrow 4
#define GizmoMesh_SquareArrow 5
#define GizmoMesh_RotateFullThin 6
#define GizmoMesh_RotateFull 7
#define GizmoMesh_RotateHalf 8
#define GizmoMesh_RotateQuarter 9

struct GizmoWidget {
    uint id;
    GizmoMesh mesh_id;
    float4 color;
    float4x4 transform;
};

#define MaterialFlags int
#define MaterialFlags_HasMetallicRoughness 1
#define MaterialFlags_HasDepthMap 2

#define MaterialType int
#define MaterialType_Opaque 0

struct MaterialPerInstance {
    MaterialType type;
    MaterialFlags flags;
    float3 base_color_tint;
    float metallic;
    float roughness;
    float3 emissive_tint;
    float emissive_strength;
    float depth_map_scale;
};

struct MeshInstance {
    uint4 entity_guid;
    float4x4 transform;
    float3x3 normal_transform;
    MaterialPerInstance material;
};

struct PointLight {
    float3 position;
    float3 color;
    float intensity;
    int shadow_map_index;
    uint shadow_map_resolution;
    Viewpoint shadow_map_viewpoints[6];
};

#endif
