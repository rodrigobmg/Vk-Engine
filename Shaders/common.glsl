#ifndef COMMON_GLSL
#define COMMON_GLSL

#define float2 vec2
#define float3 vec3
#define float4 vec4
#define float3x3 mat3
#define float4x4 mat4
#define double2 dvec2
#define double3 dvec3
#define double4 dvec4
#define double3x3 dmat3
#define double4x4 dmat4
#define int2 ivec2
#define int3 ivec3
#define int4 ivec4
#define uint2 uvec2
#define uint3 uvec3
#define uint4 uvec4

#include "shader_types.generated.glsl"

#define DECLARE_STATIC_VERTEX_ATTRIBUTES() \
    layout(location=0) in float3 v_position; \
    layout(location=1) in float3 v_normal; \
    layout(location=2) in float4 v_tangent; \
    layout(location=3) in float2 v_tex_coords

#ifdef SHADER_STAGE_VERTEX
#define DECLARE_PER_FRAME_PARAMS() \
    layout(set=0, binding=0, std140) uniform FrameData { \
        FrameInfo u_frame_info; \
    }
#endif

#ifdef SHADER_STAGE_FRAGMENT
#define DECLARE_PER_FRAME_PARAMS() \
    layout(set=0, binding=0, std140) uniform FrameData { \
        FrameInfo u_frame_info; \
    };
#endif

#ifdef SHADER_STAGE_VERTEX
#define DECLARE_PER_DRAW_CALL_MESH_PARAMS() \
    layout(set=2, binding=0, std430) readonly buffer MeshData { \
        MeshInstance u_mesh_instances[]; \
    }
#endif

#ifdef SHADER_STAGE_FRAGMENT
#define DECLARE_PER_DRAW_CALL_MESH_PARAMS() \
    layout(set=2, binding=0, std430) readonly buffer MeshData { \
        MeshInstance u_mesh_instances[]; \
    }; \
    layout(set=2, binding=1) uniform sampler2D u_base_color_texture; \
    layout(set=2, binding=2) uniform sampler2D u_normal_map_texture; \
    layout(set=2, binding=3) uniform sampler2D u_metallic_roughness_map_texture; \
    layout(set=2, binding=4) uniform sampler2D u_emissive_texture
#endif

#define Pi 3.14159265359
#define Tau Pi * 2
#define To_Rads Pi / 180.0
#define To_Degs 180.0 / Pi

#define lerp mix

float Acos(float x) {
    return acos(clamp(x, -1.0, 1.0));
}

float Asin(float x) {
    return asin(clamp(x, -1.0, 1.0));
}

#define ApplyToneMapping ApplyACESToneMapping

float3 ApplyReinhardToneMapping(float3 color) {
    return color / (color + float3(1.0));
}

float3 ApplyJodieReinhardToneMapping(float3 color) {
    // From: https://www.shadertoy.com/view/tdSXzD
    float l = dot(color, float3(0.2126, 0.7152, 0.0722));
    float3 tc = color / (color + 1);

    return lerp(color / (l + 1), tc, tc);
}

float3 ApplyACESToneMapping(float3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;

    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0, 1);
}

float3 LinearTosRGB(float3 color) {
    return pow(color, float3(1.0 / 2.2));
}

float3 sRGBToLinear(float3 color) {
    return pow(color, float3(2.2));
}

float InverseLerp(float a, float b, float t) {
    return (t - a) / (b - a);
}

#endif
