#include "common.glsl"

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0) uniform Viewpoints {
    uint u_num_viewpoints;
    Viewpoint u_viewpoints[Max_Viewpoints];
};

DECLARE_PER_DRAW_CALL_MESH_PARAMS();

layout(location=0) in float3 in_viewpoint_position;
layout(location=2) in float3 in_position;

layout(location=0) out float out_distance;

void main() {
    float distance_to_light = length(in_position - in_viewpoint_position);
    distance_to_light /= u_viewpoints[0].z_far;
    gl_FragDepth = distance_to_light; // @Speed: make sure early depth test is not disabled
}
