#include "common.glsl"
#include "pbr.glsl"
#include "shadow.glsl"

DECLARE_PER_FRAME_PARAMS();
DECLARE_FORWARD_PASS_PARAMS();
DECLARE_PER_DRAW_CALL_MESH_PARAMS();

layout(location=0) in float3 in_viewpoint_position;
layout(location=1) in flat uint in_instance_index;
layout(location=2) in float3 in_position;
layout(location=3) in float3 in_normal;
layout(location=4) in float3 in_tangent;
layout(location=5) in float3 in_bitangent;
layout(location=6) in float2 in_tex_coords;

layout(location=0) out float4 out_color;

void main() {
    MeshInstance mesh = u_mesh_instances[in_instance_index];

    float3x3 TBN = float3x3(in_tangent, in_bitangent, in_normal);
    float3 N = texture(u_normal_map_texture, in_tex_coords).xyz;
    N = N * 2 - float3(1);
    N = normalize(TBN * N);

    float3 V = normalize(in_viewpoint_position - in_position);

    float3 base_color = texture(u_base_color_texture, in_tex_coords).rgb;
    base_color = sRGBToLinear(base_color);
    base_color *= mesh.material.base_color_tint;

    float3 emissive = texture(u_emissive_texture, in_tex_coords).rgb;
    emissive = sRGBToLinear(emissive);
    emissive *= sRGBToLinear(mesh.material.emissive_tint) * mesh.material.emissive_strength;

    float2 metallic_roughness = texture(u_metallic_roughness_map_texture, in_tex_coords).zy;
    float metallic = metallic_roughness.x;
    float roughness = metallic_roughness.y;

    float3 Lo = float3(0);

    for (int i = 0; i < u_frame_info.num_directional_lights; i += 1) {
        DirectionalLight light = u_directional_lights[i];
        float shadow = 1 - SampleShadowMap(u_frame_info.shadow_map_params, light, u_shadow_map_noise_texture, u_shadow_maps[i], in_position, N, gl_FragCoord.xy);

        float3 L = -light.direction;
        Lo += CalculateBRDF(base_color, metallic, roughness, N, V, L, light.color * light.intensity * shadow);
    }

    for (int i = 0; i < u_frame_info.num_point_lights; i += 1) {
        PointLight light = u_point_lights[i];
        float3 light_color = sRGBToLinear(light.color);

        float3 L = light.position - in_position;
        float distance_sqrd = dot(L, L);
        float distance = sqrt(distance_sqrd);
        L /= distance;

        float intensity = light.intensity / distance_sqrd;
        Lo += CalculateBRDF(base_color, metallic, roughness, N, V, L, light_color * intensity);
    }

    float2 environment_uv = CartesianToSphericalUV(N);
    float3 irradiance = textureLod(u_irradiance_map, environment_uv, 0).rgb;
    float3 environment = textureLod(u_environment_map, environment_uv, roughness * Num_Environment_Map_Levels).rgb;
    float3 ambient = CalculateAmbientBRDF(base_color, metallic, roughness, N, V, irradiance, environment, u_brdf_lut);
    float3 color = ambient + Lo + emissive;

    out_color.rgb = color;
    out_color.a = 1;
}
