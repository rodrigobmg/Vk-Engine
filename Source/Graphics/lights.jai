DirectionalLight :: struct {
    direction : Vec3f;
    color : Vec3f;
    intensity : float;
    shadow_map_index : s32;
    shadow_map_resolution : u32;
    shadow_map_cascade_sizes : [Num_Shadow_Map_Cascades]float = Shadow_Map_Cascade_Sizes;
    shadow_map_viewpoints : [Num_Shadow_Map_Cascades]Viewpoint;
} @ShaderType

PointLight :: struct {
    position : Vec3f;
    color : Vec3f;
    intensity : float;
    shadow_map_index : s32;
    shadow_map_resolution : u32;
    shadow_map_viewpoints : [6]Viewpoint;
} @ShaderType

LightCluster :: struct {
    min : Vec3f;
    max : Vec3f;
    num_lights : u32;
    lights : [Max_Lights_Per_Clusters]u32 = ---;

} @ShaderType

using _ :: struct {
    Max_Lights_Per_Clusters :: 100;
    Num_Clusters_X :: 16;
    Num_Clusters_Y :: 9;
    Num_Clusters_Z :: 24;
    Num_Clusters :: Num_Clusters_X * Num_Clusters_Y * Num_Clusters_Z;
} @ShaderType

BuildClusterGrid :: (using ctx : *FrameRenderContext, camera : *Camera, clusters_offset : u32, clusters_size : u32) {
}

AssignLightsToClusters :: (using ctx : *FrameRenderContext, camera : *Camera, clusters_offset : u32, clusters_size : u32) {
}

PrepareClusters :: (using ctx : *FrameRenderContext, camera : *Camera) {
    size := GLSLStd430Size(LightCluster) * Num_Clusters;
    offset, ptr := AllocFrameData(size);

    BuildClusterGrid(ctx, camera, xx offset, xx size);
    AssignLightsToClusters(ctx, camera, xx offset, xx size);
}
