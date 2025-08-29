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
    intensity_radius : float = 4; @Serialize(5) @FloatRange(0.1,100)
    source_radius : float = 0.05; @Serialize(6) @FloatRange(0.001,100)
    cast_shadows : bool; @Serialize(4)
    shadow_map : PointShadowMap;

    OnDestroy :: (world : *World, using component : *PointLightComponent) {
        DestroyShadowMap(*shadow_map);
    }
} @Component

// Inspired by https://lisyarus.github.io/blog/posts/point-light-attenuation.html, tweaked to match closely I/x^2
// Key differences:
//  * instead of smoothly settling as x < source_radius, we cut abruptly because physically nothing is supposed to be closer than source_radius
//  * the intensity parameter is not the max intensity at distance == 0, rather it tries to match closely I in the physically correct equation
//  * there is no parameter for the falloff, it is calculated automatically depending on the intensity_radius
// Parameters:
//  * source_radius: light sources are not infinitely small points; this describes to size of the light source as if it were a sphere.
// The lower it is, the closer objects need to be to the light source to receive a lot of light
//  * base_intensity: the same parameter as the physically correct equation, this is NOT the intensity at distance == 0
//  * intensity_radius: the distance at which the final intensity reaches 0, offseted by the source_radius
GetPointLightIntensity :: (source_radius : float, base_intensity : float, intensity_radius : float, distance : float) -> float {
    if distance > source_radius + intensity_radius {
        return 0;
    }

    Intensity_Factor :: 100.0; // Higher values matches more closely the physically correct equation

    source_radius = Max(source_radius, 0);
    max_intensity := Intensity_Factor * base_intensity;
    d := Max(distance - source_radius, 0);
    s := d / intensity_radius;
    falloff := Intensity_Factor * intensity_radius;
    one_minus_s_s := 1 - s * s;

    return max_intensity * (one_minus_s_s * one_minus_s_s) / (1 + falloff * s);
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

    OnDebugDraw :: (world : *World, using entity : *PointLightEntity) {
        if EntityIsSelected(guid) {
            position := TranslationVector(world_transform);
            DebugDrawSphereOutline(.{1,1,1,1}, position, light.source_radius);
            DebugDrawSphereOutline(.{1,1,1,1}, position, light.source_radius + light.intensity_radius);
        }
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
