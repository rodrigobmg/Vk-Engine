#include "common.glsl"

layout(local_size_x=16, local_size_y=16) in;

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform sampler2D u_previous_upsampled_texture;
layout(set=1, binding=1) uniform sampler2D u_same_size_downsampled_texture;
layout(set=1, binding=2) writeonly uniform image2D u_dst_image;

void main() {
    int2 dst_size = imageSize(u_dst_image);
    int2 dst_coords = int2(gl_GlobalInvocationID.xy);
    if (dst_coords.x >= dst_size.x || dst_coords.y >= dst_size.y) {
        return;
    }

    int2 src_size = textureSize(u_previous_upsampled_texture, 0);
    float2 coords = IntegerToNormalizedTexCoords(dst_coords, dst_size);

    float4 color = UpsampleTent9(u_previous_upsampled_texture, coords, 1 / float2(src_size));
    float4 other = texture(u_same_size_downsampled_texture, coords);
    color += other;

    imageStore(u_dst_image, dst_coords, color);
}
