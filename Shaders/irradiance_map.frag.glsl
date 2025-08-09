#include "common.glsl"
#include "pbr.glsl"

layout(set=1, binding=0) uniform sampler2D u_texture;

layout(location=0) in float2 in_position;

layout(location=0) out float4 out_color;

void main() {
    float2 spherical = UVToSpherical(in_position);
    float3 ray_direction = SphericalToCartesian(spherical.x, spherical.y);

    float3 right = float3(1,0,0);
    float3 up    = normalize(cross(ray_direction, right));
    right = normalize(cross(up, ray_direction));

    float3 irradiance = float3(0);

    const float Sample_Delta = Irradiance_Map_Sample_Delta;
    float num_samples = 0.0;
    for (float phi = 0; phi < 2 * Pi; phi += Sample_Delta) {
        for (float theta = 0; theta < 0.5 * Pi; theta += Sample_Delta) {
            float cost = cos(theta);
            float sint = sin(theta);
            float cosp = cos(phi);
            float sinp = sin(phi);

            float3 tangent_sample = float3(sint * cosp, sint * sinp, cost);
            float3 sample_vector = right * tangent_sample.x + up * tangent_sample.y + ray_direction * tangent_sample.z;
            float2 uv = CartesianToSphericalUV(sample_vector);

            float3 radiance = textureLod(u_texture, uv, 4).rgb;
            radiance *= cost * sint;

            irradiance += radiance;
            num_samples += 1;
        }
    }

    irradiance = (Pi * irradiance) / num_samples;

    out_color = float4(irradiance, 1);
}
