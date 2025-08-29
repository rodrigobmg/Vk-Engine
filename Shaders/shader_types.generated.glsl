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
    float4x4 inv_projection;
    float4x4 view_projection;
    float4x4 inv_view_projection;
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

struct EditorSettings {
    EntityOutlineParams entity_outline;
    bool use_blur_effect;
    float blur_effect_resolution_factor;
    int blur_effect_iterations;
};

struct LightParams {
    float point_light_attenuation_threshold;
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
    LightParams light_params;
    float skybox_light_intensity;
    ShadowMapParams shadow_map_params;
    BloomParams bloom_params;
    EditorSettings editor_settings;
};

#define GizmoMesh int
#define GizmoMesh_Cube 0
#define GizmoMesh_Sphere 1
#define GizmoMesh_SphereQuarter 2
#define GizmoMesh_Plane 3
#define GizmoMesh_TranslatePlane 4
#define GizmoMesh_Arrow 5
#define GizmoMesh_SquareArrow 6
#define GizmoMesh_RotateFullThin 7
#define GizmoMesh_RotateFull 8
#define GizmoMesh_RotateHalf 9
#define GizmoMesh_RotateQuarter 10

struct GizmoWidget {
    uint id;
    GizmoMesh mesh_id;
    float4 color;
    float4x4 transform;
    bool shaded;
};

struct LightCluster {
    float3 min;
    float3 max;
    uint num_lights;
    uint lights[100];
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
    uint skinning_matrices_offset;
};

struct PointLight {
    float3 position;
    float3 color;
    float intensity;
    int shadow_map_index;
    uint shadow_map_resolution;
    Viewpoint shadow_map_viewpoints[6];
};

#define Max_Viewpoints 6

#define Num_Environment_Map_Levels 6

#define Max_Shadow_Maps 2
#define Max_Point_Shadow_Maps 20

#define Kawase_Bur_Compute_Work_Group_Size 16

#define Bloom_Compute_Work_Group_Size 16

#define Num_Shadow_Map_Cascades 4
#define Shadow_Map_Noise_Size 32
#define Num_Shadow_Map_Sqrt_Samples 8
#define Num_Shadow_Map_Samples 64

#define Num_Point_Shadow_Map_Cbrt_Samples 3
#define Num_Point_Shadow_Map_Samples 27

#define BRDF_LUT_Compute_Work_Group_Size 16

#define Max_Lights_Per_Clusters 100
#define Num_Clusters_X 16
#define Num_Clusters_Y 9
#define Num_Clusters_Z 24
#define Num_Clusters 3456
#define Populate_Cluster_Grid_Work_Group_Size 144

#endif
