#include "common.glsl"

layout(local_size_x=Bloom_Compute_Work_Group_Size, local_size_y=Bloom_Compute_Work_Group_Size) in;

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform sampler2D u_src_texture;
layout(set=1, binding=1) writeonly uniform image2D u_dst_image;

void main() {
    int2 dst_size = imageSize(u_dst_image);
    int2 dst_coords = int2(gl_GlobalInvocationID.xy);
    if (dst_coords.x >= dst_size.x || dst_coords.y >= dst_size.y) {
        return;
    }

    int2 src_size = textureSize(u_src_texture, 0);
    float2 src_coords = IntegerToNormalizedTexCoords(dst_coords, dst_size);

    float3 hdr_color = DownsampleBox13WithKarisAverage(u_src_texture, src_coords, 1 / float2(src_size)).rgb;
    hdr_color = max(hdr_color, 0.0001);

    float brightness = max(hdr_color.r, max(hdr_color.g, hdr_color.b));
    float knee = u_frame_info.bloom_params.brightness_threshold * u_frame_info.bloom_params.brightness_soft_threshold;
    float soft = brightness - u_frame_info.bloom_params.brightness_threshold + knee;
    soft = clamp(soft, 0, 2 * knee);
    soft = soft * soft / (4 * knee + 0.00001);

    float contribution = max(soft, brightness - u_frame_info.bloom_params.brightness_threshold);
    contribution /= max(brightness, 0.00001);

    imageStore(u_dst_image, dst_coords, float4(hdr_color * contribution, 1));
}
