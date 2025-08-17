#include "common.glsl"

layout(local_size_x=16, local_size_y=16) in;

layout(set=1, binding=0) readonly uniform image2D u_src_image;
layout(set=1, binding=1) writeonly uniform image2D u_dst_image;

void main() {
    int2 src_size = imageSize(u_src_image);
    int2 dst_size = imageSize(u_dst_image);
    int2 src_coords = int2(gl_GlobalInvocationID.xy / float2(dst_size) * src_size);
    int2 dst_coords = int2(gl_GlobalInvocationID.xy);

    float4 color = DownsampleBox13(u_src_image, src_coords);
    imageStore(u_dst_image, dst_coords, color);
}
