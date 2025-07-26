#include "common.glsl"
#include "pbr.glsl"

layout(set=1, binding=0) uniform sampler2D u_texture;

layout(location=0) in float2 in_position;
layout(location=1) in flat uint in_mipmap_level;

layout(location=0) out float4 out_color;

void main() {
    float roughness = in_mipmap_level / float(Num_Environment_Map_Levels - 1);
    float2 spherical = UVToSpherical(in_position);

    float3 N = SphericalToCartesian(spherical.x, spherical.y);
    float3 R = N;
    float3 V = R;

    float3 right = float3(1,0,0);
    float3 up    = normalize(cross(N, right));
    right = normalize(cross(up, N));

    float total_weight = 0;
    float3 prefiltered_color = float3(0);

    const uint Num_Samples = 1024;
    for(uint i = 0; i < Num_Samples; i += 1) {
        float2 Xi = Hammersley(i, Num_Samples);
        float3 H  = ImportanceSampleGGX(Xi, N, roughness);
        float3 L  = normalize(2 * dot(V, H) * H - V);
        float NdotL = max(dot(N, L), 0.0);

        if (NdotL > 0) {
            float2 uv = CartesianToSphericalUV(L);

            float3 color = textureLod(u_texture, uv, 0).rgb;

            prefiltered_color += color * NdotL;
            total_weight      += NdotL;
        }
    }

    prefiltered_color /= total_weight;

    out_color = float4(prefiltered_color, 1);
}
