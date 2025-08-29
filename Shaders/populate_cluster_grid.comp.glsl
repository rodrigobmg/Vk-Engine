#include "common.glsl"

layout(local_size_x=Populate_Cluster_Grid_Work_Group_Size, local_size_y=1, local_size_z=1) in;

DECLARE_PER_FRAME_PARAMS();

layout(set=1, binding=0, std430) buffer Clusters {
    LightCluster u_clusters[];
};
layout(set=1, binding=1, std140) uniform Viewpoints {
    Viewpoint u_viewpoint;
};

bool SphereIntersectsAABB(float3 sphere_center, float sphere_radius, float3 aabb_min, float3 aabb_max) {
    float3 closest_point = clamp(sphere_center, aabb_min, aabb_max);
    closest_point -= sphere_center;

    float sqrd_dist = dot(closest_point, closest_point);

    return sqrd_dist <= sphere_radius * sphere_radius;
}

bool PointLightIntersectsCluster(PointLight light, LightCluster cluster) {
    float radius = GetPointLightAttenuationDistance(light.intensity, u_frame_info.light_params.point_light_attenuation_threshold);
    float3 center = (u_viewpoint.view * float4(light.position, 1)).xyz;

    return SphereIntersectsAABB(center, radius, cluster.min, cluster.max);
}

void main() {
    uint index = gl_GlobalInvocationID.x;

    LightCluster cluster = u_clusters[index];
    cluster.num_lights = 0;

    for (uint i = 0; i < u_frame_info.num_point_lights && cluster.num_lights < Max_Lights_Per_Clusters; i += 1) {
        if (PointLightIntersectsCluster(u_point_lights[i], cluster)) {
            cluster.lights[cluster.num_lights] = i;
            cluster.num_lights += 1;
        }
    }

    u_clusters[index] = cluster;
}
