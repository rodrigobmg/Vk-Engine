// This file was auto generated

#ifndef SHADER_TYPES_GENERATED_GLSL
#define SHADER_TYPES_GENERATED_GLSL

struct FrameInfo {
    float time;
    float3 camera_position;
    float4x4 camera_view;
    float4x4 camera_projection;
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

#endif
