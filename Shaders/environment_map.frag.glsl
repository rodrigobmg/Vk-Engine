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
    // We assume V = R = N. This is part of the approximation and why the
    // result will not look 100% to the real life
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
            // Sample from the environment's mip level based on roughness/PDF
            // This technique removes noise from high frequency details and produces much better results
            float D = DistributionThrowbridgeReitz(N, H, roughness);
            float NdotH = max(dot(N, H), 0.0);
            float HdotV = max(dot(H, V), 0.0);
            float PDF = D * NdotH / (4 * HdotV) + 0.0001;

            const float Resolution = 1024;
            float sa_texel = 4 * Pi / (6 * Resolution * Resolution);
            float sa_sample = 1 / (float(Num_Samples) * PDF + 0.0001);

            float mip_level = roughness == 0 ? 0 : 0.5 * log2(sa_sample / sa_texel);

            float2 uv = CartesianToSphericalUV(L);

            prefiltered_color += textureLod(u_texture, uv, mip_level).rgb * NdotL;
            total_weight      += NdotL;
        }
    }

    prefiltered_color /= total_weight;

    out_color = float4(prefiltered_color, 1);
}
