#include "common.glsl"
#include "pbr.glsl"

float GeometrySchlickGGXForBrdfLUT(float NdotV, float roughness) {
    float r = roughness;
    float k = (r * r) / 2.0;

    float num = NdotV;
    float denom = NdotV * (1.0 - k) + k;

    return num / denom;
}

float GeometrySmithForBrdfLUT(float3 N, float3 V, float3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);

    float ggx2 = GeometrySchlickGGXForBrdfLUT(NdotV, roughness);
    float ggx1 = GeometrySchlickGGXForBrdfLUT(NdotL, roughness);

    return ggx1 * ggx2;
}

float2 IntegrateBRDF(float NdotV, float roughness) {
    float3 V;
    V.x = sqrt(1 - NdotV * NdotV);
    V.y = 0;
    V.z = NdotV;

    float A = 0;
    float B = 0;

    float3 N = float3(0, 0, 1);

    const uint Num_Samples = 1024;
    for (uint i = 0; i < Num_Samples; i += 1) {
        float2 Xi = Hammersley(i, Num_Samples);
        float3 H  = ImportanceSampleGGX(Xi, N, roughness);
        float3 L  = normalize(2 * dot(V, H) * H - V);

        float NdotL = max(L.z, 0.0);
        float NdotH = max(H.z, 0.0);
        float VdotH = max(dot(V, H), 0.0);

        if (NdotL > 0) {
            float G = GeometrySmithForBrdfLUT(N, V, L, roughness);
            float G_Vis = (G * VdotH) / (NdotH * NdotV);
            float Fc = pow(1 - VdotH, 5.0);

            A += (1 - Fc) * G_Vis;
            B += Fc * G_Vis;
        }
    }

    A /= float(Num_Samples);
    B /= float(Num_Samples);

    return float2(A, B);
}

layout(location=0) in float2 in_position;

layout(location=0) out float4 out_color;

void main() {
    float2 result = IntegrateBRDF(in_position.x, in_position.y);

    out_color = float4(result, 0, 1);
}
