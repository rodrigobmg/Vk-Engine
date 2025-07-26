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

    float sample_delta = 0.025;
    float num_samples = 0.0;
    for (float phi = 0; phi < 2 * Pi; phi += sample_delta) {
        for (float theta = 0; theta < 0.5 * Pi; theta += sample_delta) {
            float3 tangent_sample = float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta));
            float3 sample_vector = right * tangent_sample.x + up * tangent_sample.y + ray_direction * tangent_sample.z;
            float2 uv = CartesianToSphericalUV(sample_vector);

            float3 radiance = textureLod(u_texture, uv, 0).rgb;
            radiance *= cos(theta) * sin(theta);

            irradiance += radiance;
            num_samples += 1;
        }
    }

    irradiance = (Pi * irradiance) / num_samples;

    out_color = float4(irradiance, 1);
}
