#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform sampler2D u_texture;

layout(location=0) in float2 in_position;

layout(location=0) out float4 out_color;

void main() {
    float3 hdr_color = DownsampleBox13WithKarisAverage(u_texture, in_position, 1 / u_frame_info.window_pixel_size).rgb;
    hdr_color = max(hdr_color, 0.0001);

    float brightness = max(hdr_color.r, max(hdr_color.g, hdr_color.b));
    float knee = u_frame_info.bloom_params.brightness_threshold * u_frame_info.bloom_params.brightness_soft_threshold;
    float soft = brightness - u_frame_info.bloom_params.brightness_threshold + knee;
    soft = clamp(soft, 0, 2 * knee);
    soft = soft * soft / (4 * knee + 0.00001);

    float contribution = max(soft, brightness - u_frame_info.bloom_params.brightness_threshold);
    contribution /= max(brightness, 0.00001);

    out_color = float4(hdr_color * contribution, 1);
}
