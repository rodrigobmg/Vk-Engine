#include "common.glsl"

layout(local_size_x=16, local_size_y=16) in;

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) readonly uniform image2D u_previous_upsampled_image;
layout(set=1, binding=1) readonly uniform image2D u_same_size_downsampled_image;
layout(set=1, binding=2) writeonly uniform image2D u_dst_image;

void main() {
    int2 src_size = imageSize(u_previous_upsampled_image);
    int2 dst_size = imageSize(u_dst_image);
    int2 src_coords = int2(gl_GlobalInvocationID.xy / float2(dst_size) * src_size);
    int2 dst_coords = int2(gl_GlobalInvocationID.xy);
    if (dst_coords.x >= dst_size.x || dst_coords.y >= dst_size.y) {
        return;
    }

    float4 color = UpsampleTent9(u_previous_upsampled_image, src_coords, src_size);
    float4 other = imageLoad(u_same_size_downsampled_image, dst_coords);
    color += other;

    imageStore(u_dst_image, dst_coords, color);
}
