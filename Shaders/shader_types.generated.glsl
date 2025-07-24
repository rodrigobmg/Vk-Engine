// This file was auto generated

#ifndef SHADER_TYPES_GENERATED_GLSL
#define SHADER_TYPES_GENERATED_GLSL

struct DirectionalLight {
    float3 direction;
    float3 color;
    float intensity;
};

struct FrameInfo {
    float time;
    float2 window_pixel_size;
    uint num_directional_lights;
    uint num_point_lights;
};

#define MaterialType int
#define MaterialType_Opaque 0

struct MaterialPerInstance {
    MaterialType type;
    float3 base_color_tint;
    float3 emissive_tint;
    float emissive_strength;
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
};

#endif
