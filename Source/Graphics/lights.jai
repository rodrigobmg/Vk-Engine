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
    intensity_radius : float;
    source_radius : float;
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

    OnDebugDraw :: (world : *World, entity : *Entity, light : *DirectionalLightComponent) {
        if EntityOrParentIsSelected(world, entity.guid) {
            position := TranslationVector(entity.world_transform);
            right := RightVector(entity.world_transform);
            up := UpVector(entity.world_transform);
            direction := ForwardVector(entity.world_transform);

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
} @Entity

PointLightComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    color : Vec3f = .{1,1,1}; @Serialize(2) @ColorEdit
    intensity : float = 1; @Serialize(3) @FloatRange(0,1000)
    intensity_radius : float = 0; @Serialize(5) @FloatRange(0,100)
    source_radius : float = 0.05; @Serialize(6) @FloatRange(0.001,100)
    cast_shadows : bool; @Serialize(4)
    shadow_map : PointShadowMap;

    OnDestroy :: (world : *World, using component : *PointLightComponent) {
        DestroyShadowMap(*shadow_map);
    }

    OnDebugDraw :: (world : *World, entity : *Entity, light : *PointLightComponent) {
        if EntityOrParentIsSelected(world, entity.guid) {
            position := TranslationVector(entity.world_transform);
            DebugDrawSphereOutline(.{1,1,1,1}, position, light.source_radius);
            DebugDrawSphereOutline(.{1,1,1,1}, position, GetPointLightAttenuationDistance(light));
        }
    }
} @Component

Point_Light_Attenuation_Threshold :: 0.07;

GetPointLightAttenuationDistance :: (source_radius : float, base_intensity : float, intensity_radius : float) -> float {
    if intensity_radius > 0 {
        return source_radius + intensity_radius;
    }

    return source_radius + Sqrt(base_intensity / Point_Light_Attenuation_Threshold);
}

GetPointLightAttenuationDistance :: (light : *PointLightComponent) -> float {
    return GetPointLightAttenuationDistance(light.source_radius, light.intensity, light.intensity_radius);
}

PointLightEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    light : *PointLightComponent; @Serialize(2)

    OnSpawn :: (world : *World, light : *PointLightEntity) {
        light.light = CreateComponent(world, PointLightComponent, light);
    }

    OnDespawn :: (world : *World, light : *PointLightEntity) {
        DestroyComponent(world, light.light);
    }
} @Entity

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
}
