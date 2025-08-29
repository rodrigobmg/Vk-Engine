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

DirectionalLightComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    color : Vec3f = .{1,1,1}; @Serialize(2) @ColorEdit
    intensity : float = 1; @Serialize(3) @FloatRange(0,1000)
    cast_shadows : bool; @Serialize(4)
    shadow_map : ShadowMap;

    OnDestroy :: (world : *World, using component : *DirectionalLightComponent) {
        DestroyShadowMap(*shadow_map);
    }
} @Component

DirectionalLightEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    light : *DirectionalLightComponent; @Serialize(2)

    OnSpawn :: (world : *World, light : *DirectionalLightEntity) {
        light.light = CreateComponent(world, DirectionalLightComponent, light);
    }

    OnDespawn :: (world : *World, light : *DirectionalLightEntity) {
        DestroyComponent(world, light.light);
    }

    OnDebugDraw :: (world : *World, using entity : *DirectionalLightEntity) {
        if EntityIsSelected(guid) {
            position := TranslationVector(world_transform);
            right := RightVector(world_transform);
            up := UpVector(world_transform);
            direction := ForwardVector(world_transform);

            p0 := position + right * 0.3;
            p1 := position - right * 0.3;
            p2 := position + up * 0.3;
            p3 := position - up * 0.3;

            DebugDrawCircleOutline(.{1,1,1,1}, position, right, up, 0.3);
            DebugDrawLine(.{1,1,1,1}, p0, p0 + direction);
            DebugDrawLine(.{1,1,1,1}, p1, p1 + direction);
            DebugDrawLine(.{1,1,1,1}, p2, p2 + direction);
            DebugDrawLine(.{1,1,1,1}, p3, p3 + direction);
        }
    }
} @Entity

PointLightComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    color : Vec3f = .{1,1,1}; @Serialize(2) @ColorEdit
    intensity : float = 1; @Serialize(3) @FloatRange(0,1000)
    cast_shadows : bool; @Serialize(4)
    shadow_map : PointShadowMap;

    OnDestroy :: (world : *World, using component : *PointLightComponent) {
        DestroyShadowMap(*shadow_map);
    }
} @Component

PointLightEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    light : *PointLightComponent; @Serialize(2)

    OnSpawn :: (world : *World, light : *PointLightEntity) {
        light.light = CreateComponent(world, PointLightComponent, light);
    }

    OnDespawn :: (world : *World, light : *PointLightEntity) {
        DestroyComponent(world, light.light);
    }

    OnDebugDraw :: (world : *World, using entity : *PointLightEntity) {
        if EntityIsSelected(guid) {
            position := TranslationVector(world_transform);
            distance := GetPointLightAttenuationDistance(light.intensity, g_light_params.point_light_attenuation_threshold);
            DebugDrawSphereOutline(.{0,1,0,1}, position, distance);
        }
    }
} @Entity

LightParams :: struct {
    point_light_attenuation_threshold := 0.1; @FloatRange(0,1) @ShowInInspector
} @ShaderType

g_light_params : LightParams;

GetPointLightAttenuationDistance :: (intensity : float, intensity_threshold : float) -> float {
    return Sqrt(intensity / intensity_threshold);
}

g_debug_show_light_clusters := false;
g_debug_show_light_clusters_with_lights := false;

LightCluster :: struct {
    min : Vec3f;
    max : Vec3f;
    num_lights : u32;
    lights : [Max_Lights_Per_Clusters]u32 = ---;
} @ShaderType

g_clusters_readback_buffers : [Gfx_Num_Frames_In_Flight]GfxBuffer;
g_clusters_readback_data : [Gfx_Num_Frames_In_Flight]*void;

using _ :: struct {
    Max_Lights_Per_Clusters :: 100;
    Num_Clusters_X :: 16;
    Num_Clusters_Y :: 9;
    Num_Clusters_Z :: 24;
    Num_Clusters :: Num_Clusters_X * Num_Clusters_Y * Num_Clusters_Z;
    Populate_Cluster_Grid_Work_Group_Size :: Num_Clusters_X * Num_Clusters_Y;
} @ShaderType

ClusterGridBindingSet :: struct {
    clusters : GfxBindingStorageBuffer; @Binding(0) @ComputeStage
    viewpoint : GfxBindingUniformBuffer; @Binding(1) @ComputeStage
} @BindingSet

g_build_cluster_grid_pipeline : GfxComputePipeline;

CreateBuildClusterGridPipeline :: () {
    desc : GfxComputePipelineDesc;
    desc.shader = GetComputeShader("build_cluster_grid");
    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.ClusterGridBindingSet,
    ];

    ok := CreateGfxComputePipeline(*g_build_cluster_grid_pipeline, "Build Cluster Grid", desc);
    Assert(ok, "Could not create build cluster grid pipeline");
}

BuildClusterGrid :: (using ctx : *FrameRenderContext) {
    if IsNull(*g_build_cluster_grid_pipeline) {
        CreateBuildClusterGridPipeline();
    }

    pass := BeginGfxComputePass(cmd_buffer, "Build Cluster Grid");
    {
        BindComputePipeline(*pass, *g_build_cluster_grid_pipeline);

        Dispatch(*pass, Num_Clusters_X, Num_Clusters_Y, Num_Clusters_Z);
    }
    EndGfxComputePass(*pass);
}

g_populate_cluster_grid_pipeline : GfxComputePipeline;

CreatePopulateClusterGridPipeline :: () {
    desc : GfxComputePipelineDesc;
    desc.shader = GetComputeShader("populate_cluster_grid");
    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.ClusterGridBindingSet,
    ];

    ok := CreateGfxComputePipeline(*g_populate_cluster_grid_pipeline, "Populate Cluster Grid", desc);
    Assert(ok, "Could not create populate cluster grid pipeline");
}

PopulateClusterGrid :: (using ctx : *FrameRenderContext) {
    if IsNull(*g_populate_cluster_grid_pipeline) {
        CreatePopulateClusterGridPipeline();
    }

    pass := BeginGfxComputePass(cmd_buffer, "Populate Cluster Grid");
    {
        BindComputePipeline(*pass, *g_populate_cluster_grid_pipeline);
        Dispatch(*pass, Num_Clusters / Populate_Cluster_Grid_Work_Group_Size, 1, 1);
    }
    EndGfxComputePass(*pass);
}

PrepareClusters :: (using ctx : *FrameRenderContext, camera : *Camera) {
    if IsNull(*g_build_cluster_grid_pipeline) {
        CreateBuildClusterGridPipeline();
    }

    if IsNull(*g_populate_cluster_grid_pipeline) {
        CreatePopulateClusterGridPipeline();
    }

    if IsNull(*g_clusters_readback_buffers[g_gfx_context.frame_in_flight]) {
        desc : GfxBufferDesc;
        desc.size = xx (GLSLStd430Size(LightCluster) * Num_Clusters);
        desc.usage = .TransferDst;
        desc.memory_usage = .Readback;

        g_clusters_readback_buffers[g_gfx_context.frame_in_flight] = CreateGfxBuffer(TPrint("Light Cluster Readback %", g_gfx_context.frame_in_flight), desc);

        alloc_info : VmaAllocationInfo;
        vmaGetAllocationInfo(g_gfx_context.allocator, g_clusters_readback_buffers[g_gfx_context.frame_in_flight].allocation, *alloc_info);
        Assert(alloc_info.pMappedData != null);

        g_clusters_readback_data[g_gfx_context.frame_in_flight] = alloc_info.pMappedData;
    }

    clusters_size = xx (GLSLStd430Size(LightCluster) * Num_Clusters);
    clusters_offset = xx AllocFrameData(clusters_size);

    viewpoint_offset, viewpoint_size := AllocAndPackUniformFrameData(MakeViewpoint(camera));

    bindings := ClusterGridBindingSet.{
        clusters=.{buffer=FrameDataBuffer(), offset=xx clusters_offset, size=xx clusters_size},
        viewpoint=.{buffer=FrameDataBuffer(), offset=xx viewpoint_offset, size=xx viewpoint_size},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);
    BindComputeBindingSet(cmd_buffer, *g_build_cluster_grid_pipeline.layout, 1, *binding_set);

    BuildClusterGrid(ctx);

    AddMemoryBarrier(cmd_buffer, .AllCompute, .AllWrites, .AllCompute, .AllReads | .AllWrites);

    PopulateClusterGrid(ctx);

    AddMemoryBarrier(cmd_buffer, .AllCompute, .AllWrites, .AllCompute, .AllReads | .AllWrites);

    copy_pass := BeginGfxCopyPass(cmd_buffer, "Transfer Clusters for Readback");
    {
        CopyBufferToBuffer(*copy_pass, FrameDataBuffer(), *g_clusters_readback_buffers[g_gfx_context.frame_in_flight], clusters_offset, 0, clusters_size);
    }
    EndGfxCopyPass(*copy_pass);
}

GetLightCluster :: (index : int) -> LightCluster {
    ptr := g_clusters_readback_data[g_gfx_context.frame_in_flight];
    if !ptr {
        return .{};
    }

    ptr += cast(int, GLSLStd430Size(LightCluster)) * index;
    cluster : LightCluster;
    UnpackFromGLSLStd(*cluster, ptr, xx GLSLStd430Size(LightCluster), .Std430);

    return cluster;
}

DebugDrawCluster :: (color : Vec4f, index : int, transform : Mat4f, only_if_contains_lights : bool) {
    cluster := GetLightCluster(index);

    if only_if_contains_lights && cluster.num_lights == 0 {
        return;
    }

    center := (cluster.max + cluster.min) * 0.5;
    half_extents := (cluster.max - cluster.min) * 0.5;
    DebugDrawBoxOutline(color, center, half_extents, transform);
}

DebugDrawClusterLights :: (color : Vec4f, index : int, lights : []PointLight) {
    cluster := GetLightCluster(index);

    for i : 0..cast(s32, cluster.num_lights) - 1 {
        if cluster.lights[i] >= lights.count {
            continue;
        }

        light := lights[cluster.lights[i]];
        DebugDrawSphereOutline(color, light.position, GetPointLightAttenuationDistance(light.intensity, g_light_params.point_light_attenuation_threshold));
    }
}
