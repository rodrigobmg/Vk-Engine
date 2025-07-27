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

// https://learnopengl.com/Advanced-Lighting/Parallax-Mapping
float2 ParallaxOcclusionMapping(sampler2D depth_map, float height_scale, float2 tex_coords, float3 view_dir) {
    const float Num_Layers = 32;
    const float Layer_Depth = 1 / Num_Layers;

    tex_coords.y = 1 - tex_coords.y;

    float current_layer_depth = 0;
    float2 delta_uv = (view_dir.xy * height_scale) / Num_Layers;

    float2 current_uv = tex_coords;
    float current_depth_map_value = texture(depth_map, current_uv).r;

    while (current_layer_depth < current_depth_map_value) {
        // Shift the texture coords along the direction of P
        current_uv -= delta_uv;
        current_depth_map_value = texture(depth_map, current_uv).r;
        current_layer_depth += Layer_Depth;
    }

    float2 prev_uv = current_uv + delta_uv;
    float after_depth = current_depth_map_value - current_layer_depth;
    float before_depth = texture(depth_map, prev_uv).r - current_layer_depth + Layer_Depth;

    float weight = after_depth / (after_depth - before_depth);
    float2 final_uv = lerp(current_uv, prev_uv, weight);

    return final_uv;
}

void main() {
    MeshInstance mesh = u_mesh_instances[in_instance_index];

    float3x3 TBN = float3x3(in_tangent, in_bitangent, in_normal);

    float2 tex_coords;
    if ((mesh.material.flags & MaterialFlags_HasDepthMap) != 0) {
        float3 tangent_view_pos = TBN * in_viewpoint_position;
        float3 tangent_frag_pos = TBN * in_position;
        float3 tangent_view_dir = normalize(tangent_view_pos - tangent_frag_pos);

        tex_coords = ParallaxOcclusionMapping(u_depth_map_texture, mesh.material.depth_map_scale, in_tex_coords, tangent_view_dir);
        if (tex_coords.x < 0 || tex_coords.x > 1 || tex_coords.y < 0 || tex_coords.y > 1) {
            discard;
        }
    } else {
        tex_coords = in_tex_coords;
    }

    float3 N = texture(u_normal_map_texture, tex_coords).xyz;
    N = N * 2 - float3(1);
    N = normalize(TBN * N);

    float3 V = normalize(in_viewpoint_position - in_position);

    float3 base_color = texture(u_base_color_texture, tex_coords).rgb;
    base_color *= sRGBToLinear(mesh.material.base_color_tint);

    float3 emissive = texture(u_emissive_texture, tex_coords).rgb;
    emissive *= sRGBToLinear(mesh.material.emissive_tint) * mesh.material.emissive_strength;

    float metallic, roughness;
    if ((mesh.material.flags & MaterialFlags_HasMetallicRoughness) != 0) {
        float4 metallic_roughness = texture(u_metallic_roughness_map_texture, tex_coords);
        metallic = metallic_roughness.b;
        roughness = metallic_roughness.g;
    } else {
        metallic = mesh.material.metallic;
        roughness = mesh.material.roughness;
    }

    float3 Lo = float3(0);

    for (int i = 0; i < u_frame_info.num_directional_lights; i += 1) {
        DirectionalLight light = u_directional_lights[i];
        float3 light_color = sRGBToLinear(light.color);
        float shadow = 1 - SampleShadowMap(u_frame_info.shadow_map_params, light, u_shadow_map_noise_texture, u_shadow_maps[i], in_position, N, gl_FragCoord.xy);

        float3 L = -light.direction;
        Lo += CalculateBRDF(base_color, metallic, roughness, N, V, L, light_color * light.intensity * shadow);
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

    float3 R = reflect(-V, N);

    float2 irradiance_uv = CartesianToSphericalUV(N);
    #ifndef TEXTURE_ORIGIN_BOTTOM_LEFT
        irradiance_uv.y = 1 - irradiance_uv.y;
    #endif
    float3 irradiance = textureLod(u_irradiance_map, irradiance_uv, 0).rgb;

    float2 environment_uv = CartesianToSphericalUV(R);
    #ifndef TEXTURE_ORIGIN_BOTTOM_LEFT
        environment_uv.y = 1 - environment_uv.y;
    #endif
    float3 environment = textureLod(u_environment_map, environment_uv, roughness * (Num_Environment_Map_Levels - 1)).rgb;

    float3 ambient = CalculateAmbientBRDF(base_color, metallic, roughness, N, V, irradiance, environment, u_brdf_lut);
    float3 color = ambient + Lo + emissive;

    out_color.rgb = color;
    out_color.a = 1;
}
