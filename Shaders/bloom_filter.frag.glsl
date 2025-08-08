#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform sampler2D u_texture;

layout(location=0) in float2 in_position;

layout(location=0) out float4 out_color;

void main() {
    float3 hdr_color = DownsampleBox13(u_texture, in_position, 1 / u_frame_info.window_pixel_size).rgb;
    float brightness = max(hdr_color.r, max(hdr_color.g, hdr_color.b));
    float contribution = max(0, brightness - u_frame_info.bloom_params.brightness_threshold);
    contribution /= max(brightness, 0.00001);

    out_color = float4(hdr_color * contribution, 1);
}
