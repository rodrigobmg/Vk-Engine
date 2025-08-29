#include "common.glsl"

layout(local_size_x=1, local_size_y=1, local_size_z=1) in;

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0, std430) buffer Clusters {
    LightCluster u_clusters[];
};
layout(set=1, binding=1, std140) uniform Viewpoints {
    Viewpoint u_viewpoint;
};

float3 ScreenToView(float2 screen_coords) {
    float4 ndc;
    ndc.xy = (screen_coords / u_viewpoint.viewport_size) * 2 - float2(1);
    ndc.z = 0;
    ndc.w = 1;

    float4 view_coord = u_viewpoint.inv_projection * ndc;

    return view_coord.xyz / view_coord.w;
}

float3 LineIntersectionWithZPlane(float3 line_start, float3 line_end, float z_dist) {
    float3 direction = line_end - line_start;
    float3 normal = float3(0, 0, 1);

    float t = (z_dist - dot(normal, line_start)) / dot(normal, direction);

    return line_start + t * direction;
}

void main() {
    uint3 coords = uint3(gl_GlobalInvocationID);
    uint3 grid_size = uint3(Num_Clusters_X, Num_Clusters_Y, Num_Clusters_Z);
    uint tile_index = coords.x + (coords.y * grid_size.x) + (coords.z * grid_size.x * grid_size.y);
    float2 tile_size = u_viewpoint.viewport_size / float2(grid_size.xy);

    float2 min_tile_screenspace = coords.xy * tile_size;
    float2 max_tile_screenspace = (coords.xy + float2(1)) * tile_size;

    float3 min_tile = ScreenToView(min_tile_screenspace);
    float3 max_tile = ScreenToView(max_tile_screenspace);

    float plane_near = u_viewpoint.z_near * pow(u_viewpoint.z_far / u_viewpoint.z_near, coords.z / float(grid_size.z));
    float plane_far = u_viewpoint.z_near * pow(u_viewpoint.z_far / u_viewpoint.z_near, (coords.z + 1) / float(grid_size.z));

    float3 min_point_near = LineIntersectionWithZPlane(float3(0), min_tile, plane_near);
    float3 min_point_far  = LineIntersectionWithZPlane(float3(0), min_tile, plane_far);
    float3 max_point_near = LineIntersectionWithZPlane(float3(0), max_tile, plane_near);
    float3 max_point_far  = LineIntersectionWithZPlane(float3(0), max_tile, plane_far);

    u_clusters[tile_index].min = min(min_point_near, min_point_far);
    u_clusters[tile_index].max = max(max_point_near, max_point_far);
}
