#load "mesh.jai";
#load "texture2d.jai";
#load "shader.jai";
#load "material.jai";
#load "mesh_buffer.jai";
#load "allocator.jai";
#load "binding_set_allocator.jai";

#load "imgui.jai";
#load "image_based_lighting.jai";
#load "forward_pass.jai";
#load "compositing.jai";
#load "shadow_map.jai";
#load "point_shadow_map.jai";
#load "skybox.jai";
#load "entity_selection.jai";
#load "bloom.jai";
#load "debug_draw.jai";
#load "gizmo_draw.jai";
#load "kawase_blur.jai";

g_linear_clamp_sampler : GfxSampler;
g_nearest_clamp_sampler : GfxSampler;

InitRenderer :: () {
    if !LoadAllShaders() {
        Basic.exit(1);
    }

    CreateRenderTargets(); // This must be first because some functions use e.g. g_color_texture.desc

    CreateAllBindingSetLayouts();

    CreateAllPipelines();

    InitTextureUpload();

    CreateGlobalShadowMapObjects();

    InitFrameDataAllocators();
    InitBindingSetAllocators();

    sampler_desc : GfxSamplerDesc;
    sampler_desc.min_filter = .Linear;
    sampler_desc.mag_filter = .Linear;
    g_linear_clamp_sampler = CreateGfxSampler("Linear Clamp", sampler_desc);
    Assert(!IsNull(*g_linear_clamp_sampler));

    sampler_desc = .{};
    sampler_desc.min_filter = .Nearest;
    sampler_desc.mag_filter = .Nearest;
    g_nearest_clamp_sampler = CreateGfxSampler("Nearest Clamp", sampler_desc);
    Assert(!IsNull(*g_nearest_clamp_sampler));
}

CleanupRenderer :: () {
    DestroyRenderTargets();

    DestroyAllBindingSetLayouts();

    DestroyAllPipelines();

    CleanupTextureUpload();

    DestroyGlobalShadowMapObjects();

    for * g_frame_data_allocators {
        DestroyFrameDataAllocator(it);
    }

    DestroyBindingSetAllocators();

    DestroyAllShaders();

    DestroyGfxSampler(*g_skybox_sampler);
    DestroyGfxSampler(*g_linear_clamp_sampler);
    DestroyGfxSampler(*g_nearest_clamp_sampler);
}

#placeholder Shader_Binding_Set_Types;

IsInShaderBindingSetTypesArray :: (type : Type) -> bool {
    return ArrayFindFirst(Shader_Binding_Set_Types, type) != -1;
}

g_binding_set_layouts : struct {
    #insert -> string {
        builder : StringBuilder;

        for Shader_Binding_Set_Types {
            Appendln(*builder, "%1 : GfxBindingSetLayout;", it);
        }

        return StringBuilderBuild(*builder);
    }
}

CreateAllBindingSetLayouts :: () {
    #insert -> string {
        builder : StringBuilder;

        for Shader_Binding_Set_Types {
            Appendln(*builder, "g_binding_set_layouts.%1 = CreateGfxBindingSetLayout(%1);", it);
            Appendln(*builder, "Assert(!IsNull(*g_binding_set_layouts.%1), \"Could not create shader binding set layout for type %1\");", it);
        }

        return StringBuilderBuild(*builder);
    }
}

DestroyAllBindingSetLayouts :: () {
    #insert -> string {
        builder : StringBuilder;

        for Shader_Binding_Set_Types {
            Appendln(*builder, "DestroyGfxBindingSetLayout(*g_binding_set_layouts.%1);", it);
        }

        return StringBuilderBuild(*builder);
    }
}

// Pipeline layout used to bind binding sets outside of any render pass at the beginning of the frame
g_dummy_frame_pipeline_layout : GfxPipelineLayout;

g_material_texture_sampler : GfxSampler;

CreateAllPipelines :: () {
    {
        sampler_desc : GfxSamplerDesc;
        sampler_desc.min_filter = .Linear;
        sampler_desc.mag_filter = .Linear;
        sampler_desc.mipmap_filter = .Linear;
        sampler_desc.u_address_mode = .Repeat;
        sampler_desc.v_address_mode = .Repeat;

        g_material_texture_sampler = CreateGfxSampler("Material Texture", sampler_desc);
        Assert(!IsNull(*g_material_texture_sampler), "Could not create material texture sampler");
    }

    frame_layout_desc : GfxPipelineLayoutDesc;
    frame_layout_desc.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
    ];
    g_dummy_frame_pipeline_layout = CreateGfxPipelineLayout("Dummy Frame", frame_layout_desc);
    Assert(!IsNull(*g_dummy_frame_pipeline_layout), "Could not create dummy frame pipeline layout");

    CreateForwardPipeline();
    CreateCompositingPipeline();
    CreateShadowMapPipeline();
    CreatePointShadowMapPipeline();
    CreateSkyboxPipeline();
    CreateIrradianceMapPipeline();
    CreateEnvironmentMapPipeline();
    CreateEntityGUIDPipeline();
    CreateBloomFilterComputePipeline();
    CreateBloomDownsampleComputePipeline();
    CreateBloomUpsampleComputePipeline();
    CreateDebugLinesPipeline();
    CreateGizmoPipeline();
    CreateGizmoLinesPipeline();
}

DestroyAllPipelines :: () {
    for * g_kawase_blur_downsample_pipeline {
        if !IsNull(it) {
            DestroyGfxGraphicsPipeline(it);
        }
    }
    for * g_kawase_blur_upsample_pipeline {
        if !IsNull(it) {
            DestroyGfxGraphicsPipeline(it);
        }
    }

    DestroyGfxGraphicsPipeline(*g_gizmo_lines_pipeline);
    DestroyGfxGraphicsPipeline(*g_gizmo_pipeline);
    DestroyGfxGraphicsPipeline(*g_debug_lines_pipeline);
    DestroyGfxComputePipeline(*g_bloom_upsample_compute_pipeline);
    DestroyGfxComputePipeline(*g_bloom_downsample_compute_pipeline);
    DestroyGfxComputePipeline(*g_bloom_filter_compute_pipeline);
    DestroyGfxGraphicsPipeline(*g_entity_guid_pipeline);
    DestroyGfxGraphicsPipeline(*g_environment_map_pipeline);
    DestroyGfxGraphicsPipeline(*g_irradiance_map_pipeline);
    DestroyGfxGraphicsPipeline(*g_skybox_pipeline);
    DestroyGfxGraphicsPipeline(*g_forward_pipeline);
    DestroyGfxGraphicsPipeline(*g_point_shadow_map_pipeline);
    DestroyGfxGraphicsPipeline(*g_shadow_map_pipeline);

    DestroyGfxGraphicsPipeline(*g_compositing_pipeline);
    DestroyGfxSampler(*g_entity_guid_sampler);

    DestroyGfxTexture(*g_brdf_lut);
    DestroyGfxSampler(*g_brdf_lut_sampler);
    DestroyGfxGraphicsPipeline(*g_brdf_lut_pipeline);

    DestroyGfxSampler(*g_material_texture_sampler);

    DestroyGfxPipelineLayout(*g_dummy_frame_pipeline_layout);
}

g_final_texture : GfxTexture;
g_color_texture : GfxTexture;
g_depth_texture : GfxTexture;
g_selected_entities_depth_texture : GfxTexture;

g_blurred_color : KawaseBlur;

CreateRenderTargets :: () {
    WaitForGPUIdle();

    if !IsNull(*g_final_texture) {
        DestroyGfxTexture(*g_final_texture);
    }

    if !IsNull(*g_color_texture) {
        DestroyGfxTexture(*g_color_texture);
    }

    if !IsNull(*g_depth_texture) {
        DestroyGfxTexture(*g_depth_texture);
    }

    if !IsNull(*g_selected_entities_depth_texture) {
        DestroyGfxTexture(*g_selected_entities_depth_texture);
    }

    w, h := GetWindowPixelSize(g_window);

    texture_desc : GfxTextureDesc;
    texture_desc.type = .Texture2D;
    texture_desc.width = xx w;
    texture_desc.height = xx h;

    texture_desc.pixel_format = .RGBA8UNorm;
    texture_desc.usage = .ColorAttachment | .TransferSrc;

    g_final_texture = CreateGfxTexture("Final", texture_desc);
    Assert(!IsNull(*g_final_texture), "Could not create final texture");

    texture_desc.pixel_format = .RGBA16Float;
    texture_desc.usage = .ColorAttachment | .TransferSrc | .Sampled | .Storage;

    g_color_texture = CreateGfxTexture("Color", texture_desc);
    Assert(!IsNull(*g_color_texture), "Could not create color texture");

    if g_editor_settings.use_blur_effect {
        CreateKawaseBlurTextures(*g_blurred_color, g_editor_settings.blur_effect_iterations, texture_desc, g_editor_settings.blur_effect_resolution_factor);
    }

    texture_desc.pixel_format = .Depth32Float;
    texture_desc.usage = .DepthStencilAttachment;

    g_depth_texture = CreateGfxTexture("Depth", texture_desc);
    Assert(!IsNull(*g_depth_texture), "Could not create depth texture");

    g_selected_entities_depth_texture = CreateGfxTexture("Selected Entities Depth", texture_desc);
    Assert(!IsNull(*g_selected_entities_depth_texture), "Could not create selected entities depth texture");

    CreateEntityGUIDTextures();
    CreateBloomTextures();
    CreateGizmoTextures(*g_gizmo_ctx);
    CreateImGuiColorTexture();
}

DestroyRenderTargets :: () {
    DestroyKawaseBlur(*g_blurred_color);
    DestroyGfxTexture(*g_imgui_color_texture);
    DestroyGfxTexture(*g_gizmo_ctx.depth_texture);
    DestroyGfxTexture(*g_final_texture);
    DestroyGfxTexture(*g_color_texture);
    DestroyGfxTexture(*g_depth_texture);
    DestroyGfxTexture(*g_selected_entities_depth_texture);
    DestroyGfxTexture(*g_entity_guid_texture);
    DestroyGfxTexture(*g_selected_entity_guid_texture);

    for * g_entity_guid_readback_buffers {
        if !IsNull(it) {
            DestroyGfxBuffer(it);
        }
    }

    DestroyBloomTextures();
}

MeshEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    mesh : *Asset(Mesh); @Serialize(2)
    material : *Asset(Material); @Serialize(3)
    cast_shadows := true; @Serialize(4)
    cast_point_shadows := false; @Serialize(5)
    aabb : AABB;
} @Entity

DirectionalLightEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    color : Vec3f = .{1,1,1}; @Serialize(2) @ColorEdit
    intensity : float = 1; @Serialize(3) @FloatRange(0,1000)
    cast_shadows : bool; @Serialize(4)
    shadow_map : ShadowMap;

    OnDebugDraw :: (world : *World, light : *DirectionalLightEntity) {
        if  EntityIsSelected(light.guid) {
            position := TranslationVector(light.world_transform);
            right := RightVector(light.world_transform);
            up := UpVector(light.world_transform);
            direction := ForwardVector(light.world_transform);

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

    OnDespawn :: (world : *World, light : *DirectionalLightEntity) {
        DestroyShadowMap(*light.shadow_map);
    }
} @Entity

Global_Point_Light_Intensity_Threshold :: 0.01;

PointLightEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    color : Vec3f = .{1,1,1}; @Serialize(2) @ColorEdit
    intensity : float = 1; @Serialize(3) @FloatRange(0,1000)
    cast_shadows : bool; @Serialize(4)
    shadow_map : PointShadowMap;

    OnDebugDraw :: (world : *World, light : *PointLightEntity) {
        if EntityIsSelected(light.guid) {
            position := TranslationVector(light.world_transform);
            distance := GetPointLightAttenuationDistance(light.intensity, light.intensity * Global_Point_Light_Intensity_Threshold);
            DebugDrawSphereOutline(.{0,1,0,1}, position, distance);
        }
    }

    OnDespawn :: (world : *World, light : *PointLightEntity) {
        DestroyShadowMap(*light.shadow_map);
    }
} @Entity

GetPointLightAttenuationDistance :: (intensity : float, intensity_threshold : float) -> float {
    // Light intensity at distance D for base intensity I is I/D^2
    // Solve for I/D^2 < T
    //   I/D^2 < T
    //   I < T*D^2
    //   0 < T*D^2-I
    //   T*D^2-I > 0

    return (4 * intensity * intensity_threshold) / (2 * intensity_threshold);
}

EmptyBindingSet :: struct {
} @BindingSet

Max_Shadow_Maps :: 2;
Max_Point_Shadow_Maps :: 20;

FrameBindingSet :: struct {
    frame_info : GfxBindingUniformBuffer; @Binding(0) @VertexStage @FragmentStage @ComputeStage
    directional_lights : GfxBindingStorageBuffer; @Binding(1) @FragmentStage @AllowNull
    point_lights : GfxBindingStorageBuffer; @Binding(2) @FragmentStage @AllowNull
    brdf_lut : GfxBindingCombinedTextureSampler; @Binding(3) @FragmentStage
    shadow_map_noise : GfxBindingCombinedTextureSampler; @Binding(4) @FragmentStage
} @BindingSet

ShadowMapParams :: struct {
    noise_resolution : u32;
    depth_bias_min_max : Vec2f;
    normal_bias : float;
    filter_radius : float;
} @ShaderType

FrameInfo :: struct {
    time : float;
    window_pixel_size : Vec2f;
    num_directional_lights : u32;
    num_point_lights : u32;
    skybox_light_intensity := 1.0;
    shadow_map_params : ShadowMapParams;
    bloom_params : BloomParams;
    editor_settings : EditorSettings;
} @ShaderType

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

Max_Viewpoints :: 6;

Viewpoint :: struct {
    position : Vec3f;
    direction : Vec3f;
    right : Vec3f;
    up : Vec3f;
    transform : Mat4f;
    view : Mat4f;
    projection : Mat4f;
    view_projection : Mat4f;
    viewport_size : Vec2f;
    fov : float;
    z_near : float;
    z_far : float;
} @ShaderType

ViewpointsData :: struct {
    num_viewpoints : u32 = 1;
    viewpoints : [Max_Viewpoints]Viewpoint;
}

MakeViewpoint :: (camera : *Camera) -> Viewpoint {
    w, h := GetWindowPixelSize(g_window);

    return .{
        position=camera.position,
        right=RightVector(camera.transform),
        up=UpVector(camera.transform),
        direction=ForwardVector(camera.transform),
        transform=camera.transform,
        view=camera.view,
        projection=camera.projection,
        view_projection=camera.projection * camera.view,
        fov=ToRads(camera.fov_in_degrees),
        viewport_size=.{xx w, xx h},
        z_near=camera.z_near,
        z_far=camera.z_far,
    };
}

FrameRenderContext :: struct {
    world : *World;
    cmd_buffer : *GfxCommandBuffer;
    frame_binding_set : GfxBindingSet;
}

g_mesh_buffer : MeshBuffer;
g_selected_mesh_buffer : MeshBuffer;

RenderFrame :: (world : *World, camera : *Camera) {
    w, h := GetWindowPixelSize(g_window);

    BeginFrame();

    ResetFrameDataAllocator();
    ResetBindingSetAllocators();

    ClearMeshBuffer(*g_mesh_buffer);

    frustum := MakePerspectiveFrustum(camera.transform, camera.fov_in_degrees, w / cast(float, h), camera.z_near, camera.z_far);
    for * world.MeshEntity_storage {
        if it.flags & .Hidden {
            continue;
        }

        if !it.mesh {
            continue;
        }

        if IsNull(*it.mesh.vertex_buffer) || IsNull(*it.mesh.index_buffer) {
            continue;
        }

        aabb := GetTransformedAABB(it.world_transform, it.mesh.static_bounds);
        if !AABBIsInFrustum(aabb, frustum) {
            continue;
        }

        material := ifx it.material then it.material else g_default_material;

        position := TranslationVector(it.world_transform);
        depth := TransformPoint(camera.view, position).z;
        key := MakeMeshBufferKey(*it.mesh.vertex_buffer, *it.mesh.index_buffer, material, depth);
        PushMesh(*g_mesh_buffer, key, it.guid, *it.mesh.vertex_buffer, *it.mesh.index_buffer, it.mesh.vertex_count, it.mesh.index_count, it.world_transform, material);
    }

    SortMeshBuffer(*g_mesh_buffer);
    AllocDrawData(*g_mesh_buffer);

    ClearMeshBuffer(*g_selected_mesh_buffer);

    for * guid : g_editor_selected_entities {
        it := GetEntity(world, guid, MeshEntity);
        if !it {
            continue;
        }

        if it.flags & .Hidden {
            continue;
        }

        if !it.mesh {
            continue;
        }

        if IsNull(*it.mesh.vertex_buffer) || IsNull(*it.mesh.index_buffer) {
            continue;
        }

        aabb := GetTransformedAABB(it.world_transform, it.mesh.static_bounds);
        if !AABBIsInFrustum(aabb, frustum) {
            continue;
        }

        material := ifx it.material then it.material else g_default_material;

        position := TranslationVector(it.world_transform);
        depth := TransformPoint(camera.view, position).z;
        key := MakeMeshBufferKey(*it.mesh.vertex_buffer, *it.mesh.index_buffer, material, depth);
        PushMesh(*g_selected_mesh_buffer, key, it.guid, *it.mesh.vertex_buffer, *it.mesh.index_buffer, it.mesh.vertex_count, it.mesh.index_count, it.world_transform, material);
    }

    SortMeshBuffer(*g_selected_mesh_buffer);
    AllocDrawData(*g_selected_mesh_buffer);

    for * world.DirectionalLightEntity_storage {
        if it.flags & .Hidden {
            continue;
        }

        if it.cast_shadows {
            PopulateShadowMapMeshBuffer(world, *it.shadow_map, ForwardVector(it.world_transform), camera.transform);
        }
    }

    for * world.PointLightEntity_storage {
        if it.flags & .Hidden {
            continue;
        }

        if it.cast_shadows {
            UpdatePointShadowMapFarPlane(it);
            PopulateShadowMapMeshBuffers(world, *it.shadow_map, TranslationVector(it.world_transform));
        }
    }

    ctx : FrameRenderContext;
    ctx.world = world;

    cmd_buffer := CreateGfxCommandBuffer("Main");
    ctx.cmd_buffer = *cmd_buffer;

    if IsNull(*g_brdf_lut) {
        RenderBRDFLUT(ctx.cmd_buffer);
    }

    num_directional_lights : u64 = xx world.DirectionalLightEntity_storage.count;
    directional_lights_size := GLSLStd430Size(DirectionalLight) * num_directional_lights;
    directional_lights_offset, directional_lights_ptr := AllocFrameData(directional_lights_size);
    shadow_map_index : s32 = 0;
    for * world.DirectionalLightEntity_storage {
        if it.flags & .Hidden {
            continue;
        }

        if it.cast_shadows && it.shadow_map.resolution == 0 {
            InitShadowMap(*it.shadow_map, Default_Shadow_Map_Resolution);
        }

        directional_light := DirectionalLight.{
            direction=ForwardVector(it.world_transform),
            color=it.color,
            intensity=it.intensity,
            shadow_map_index=ifx it.cast_shadows then shadow_map_index else -1,
            shadow_map_resolution=it.shadow_map.resolution,
        };

        if it.cast_shadows {
            for * viewpoint : directional_light.shadow_map_viewpoints {
                viewpoint.* = GetShadowMapViewpoint(*it.shadow_map, directional_light.direction, camera.transform, it_index);
            }

            shadow_map_index += 1;
        }

        directional_lights_ptr += PackToGLSLStd(directional_light, directional_lights_ptr, .Std430);
    }

    num_point_lights : u64 = xx world.PointLightEntity_storage.count;
    point_lights_size := GLSLStd430Size(PointLight) * num_point_lights;
    point_lights_offset, point_lights_ptr := AllocFrameData(point_lights_size);
    point_shadow_map_index : s32 = 0;
    for * world.PointLightEntity_storage {
        if it.flags & .Hidden {
            continue;
        }

        if it.cast_shadows && it.shadow_map.resolution == 0 {
            InitShadowMap(*it.shadow_map, Default_Point_Shadow_Map_Resolution);
        }

        point_light := PointLight.{
            position=TranslationVector(it.world_transform),
            color=it.color,
            intensity=it.intensity,
            shadow_map_index=ifx it.cast_shadows then point_shadow_map_index else -1,
            shadow_map_resolution=it.shadow_map.resolution,
        };

        if it.cast_shadows {
            for * viewpoint : point_light.shadow_map_viewpoints {
                viewpoint.* = GetShadowMapViewpoint(*it.shadow_map, point_light.position, xx it_index);
            }

            point_shadow_map_index += 1;
        }

        point_lights_ptr += PackToGLSLStd(point_light, point_lights_ptr, .Std430);
    }

    frame_info := FrameInfo.{
        time=xx Basic.to_float64_seconds(Basic.current_time_monotonic()),
        window_pixel_size=.{xx w, xx h},
        num_point_lights=xx num_point_lights,
        num_directional_lights=xx num_directional_lights,
        skybox_light_intensity=world.skybox_light_intensity,
        editor_settings=g_editor_settings,
        shadow_map_params=.{
            noise_resolution=Shadow_Map_Noise_Size,
            depth_bias_min_max=.{1, 5},
            normal_bias=10,
            filter_radius=1,
        },
        bloom_params=g_bloom_params,
    };
    frame_info.bloom_params.blend_intensity /= cast(float, Bloom_Num_Downsample_Passes);
    frame_info_offset, frame_info_size := AllocAndPackUniformFrameData(frame_info);

    frame_binding_set := FrameBindingSet.{
        frame_info=.{buffer=FrameDataBuffer(), offset=xx frame_info_offset, size=xx frame_info_size},
        directional_lights=.{buffer=FrameDataBuffer(), offset=xx directional_lights_offset, size=xx directional_lights_size},
        point_lights=.{buffer=FrameDataBuffer(), offset=xx point_lights_offset, size=xx point_lights_size},
        brdf_lut=.{texture=*g_brdf_lut, sampler=*g_brdf_lut_sampler},
        shadow_map_noise=.{texture=*g_shadow_map_noise_texture, sampler=*g_shadow_map_noise_sampler},
    };

    ctx.frame_binding_set = CreateGfxBindingSet(GlobalBindingSetAllocator(), frame_binding_set);
    BindGraphicsBindingSet(*cmd_buffer, *g_dummy_frame_pipeline_layout, 0, *ctx.frame_binding_set);
    BindComputeBindingSet(*cmd_buffer, *g_dummy_frame_pipeline_layout, 0, *ctx.frame_binding_set);

    TextureUploadPass(*cmd_buffer);
    GenerateEnvironmentMaps(*cmd_buffer);

    for * world.DirectionalLightEntity_storage {
        if it.flags & .Hidden {
            continue;
        }

        if it.cast_shadows {
            ShadowMapPass(*ctx, *it.shadow_map, ForwardVector(it.world_transform), camera);
        }
    }

    for * world.PointLightEntity_storage {
        if it.flags & .Hidden {
            continue;
        }

        if it.cast_shadows {
            PointShadowMapPass(*ctx, *it.shadow_map, TranslationVector(it.world_transform));
        }
    }

    AddTextureBarriers(*cmd_buffer, .Undefined, .ColorAttachment, .[*g_color_texture, *g_entity_guid_texture, *g_selected_entity_guid_texture]);
    AddTextureBarrier(*cmd_buffer, .Undefined, .DepthStencilAttachment, *g_depth_texture);

    ForwardPass(*ctx, camera, *g_mesh_buffer);
    DebugLinesPass(*ctx, camera);
    SkyboxPass(*ctx, camera, ifx world.skybox && world.skybox.base_texture then *world.skybox.base_texture.texture);

    EntityGUIDPass(*ctx, *g_entity_guid_texture, *g_depth_texture, camera, *g_mesh_buffer);
    EntityGUIDPass(*ctx, *g_selected_entity_guid_texture, *g_selected_entities_depth_texture, camera, *g_selected_mesh_buffer);

    AddTextureBarrier(*cmd_buffer, .ColorAttachment, .TransferSrc, *g_entity_guid_texture);

    TransferEntityGUIDForReadback(*cmd_buffer);

    AddTextureBarrier(*cmd_buffer, .TransferSrc, .ShaderReadOnly, *g_entity_guid_texture);

    AddTextureBarrier(*cmd_buffer, .ColorAttachment, .ShaderReadOnly, *g_selected_entity_guid_texture);
    AddTextureBarrier(*cmd_buffer, .ColorAttachment, .General, *g_color_texture);

    // RenderBloom(*ctx, *g_color_texture);
    ComputeBloom(*ctx, *g_color_texture);

    AddTextureBarrier(*cmd_buffer, .General, .ShaderReadOnly, *g_color_texture);
    AddTextureBarrier(*cmd_buffer, .Undefined, .ColorAttachment, *g_final_texture);

    GizmoPass(*ctx, *g_gizmo_ctx);
    ImGuiPass(*cmd_buffer, ImGui.GetDrawData());
    if g_editor_settings.use_blur_effect {
        RenderKawaseBlur(*cmd_buffer, *g_blurred_color, *g_color_texture);
    }

    CompositingPass(*ctx);

    AddTextureBarrier(*cmd_buffer, .ColorAttachment, .TransferSrc, *g_final_texture);

    swapchain_texture := *g_gfx_context.swapchain_textures[g_gfx_context.frame_swapchain_image_index];
    AddTextureBarrier(*cmd_buffer, 0, 0, .AllGraphics, .AllWrites | .AllReads, .Undefined, .TransferDst, swapchain_texture);

    region : VkImageBlit;
    region.srcSubresource = MakeVkImageSubresourceLayers(g_final_texture.desc, 0);
    region.srcOffsets[1].x = xx g_final_texture.desc.width;
    region.srcOffsets[1].y = xx g_final_texture.desc.height;
    region.srcOffsets[1].z = 1;

    region.dstSubresource = MakeVkImageSubresourceLayers(swapchain_texture.desc, 0);
    region.dstOffsets[1].x = xx swapchain_texture.desc.width;
    region.dstOffsets[1].y = xx swapchain_texture.desc.height;
    region.dstOffsets[1].z = 1;

    vkCmdBlitImage(cmd_buffer.cmd_buffer, g_final_texture.image, .TRANSFER_SRC_OPTIMAL, swapchain_texture.image, .TRANSFER_DST_OPTIMAL, 1, *region, .LINEAR);

    AddTextureBarrier(*cmd_buffer, .AllGraphics, .AllWrites, 0, 0, .TransferDst, .PresentSrc, swapchain_texture);

    SubmitGfxCommandBuffer(*cmd_buffer);

    SubmitFrame();
}

g_brdf_lut : GfxTexture;
g_brdf_lut_sampler : GfxSampler;
g_brdf_lut_pipeline : GfxGraphicsPipeline;

BRDF_LUT_Resolution : u32 : 512;

RenderBRDFLUT :: (cmd_buffer : *GfxCommandBuffer) {
    texture_desc : GfxTextureDesc;
    texture_desc.type = .Texture2D;
    texture_desc.pixel_format = .RGBA16Float;
    texture_desc.width = BRDF_LUT_Resolution;
    texture_desc.height = BRDF_LUT_Resolution;
    texture_desc.usage = .ColorAttachment | .Sampled;

    g_brdf_lut = CreateGfxTexture("BRDF LUT", texture_desc);
    Assert(!IsNull(*g_brdf_lut), "Could not create BRDF LUT texture");

    sampler_desc : GfxSamplerDesc;
    sampler_desc.min_filter = .Linear;
    sampler_desc.mag_filter = .Linear;
    sampler_desc.u_address_mode = .ClampToEdge;
    sampler_desc.v_address_mode = .ClampToEdge;

    g_brdf_lut_sampler = CreateGfxSampler("BRDF LUT", sampler_desc);
    Assert(!IsNull(*g_brdf_lut_sampler), "Could not create BRDF LUT sampler");

    pipeline_desc : GfxGraphicsPipelineDesc;
    pipeline_desc.vertex_shader = GetVertexShader("screen_effect");
    pipeline_desc.fragment_shader = GetFragmentShader("brdf_lut");
    AddColorAttachment(*pipeline_desc, g_brdf_lut.desc.pixel_format);

    g_brdf_lut_pipeline = CreateGfxGraphicsPipeline("BRDF LUT", pipeline_desc);
    Assert(!IsNull(*g_brdf_lut_pipeline), "Could not create BRDF LUT pipeline");

    AddTextureBarrier(cmd_buffer, .Undefined, .ColorAttachment, *g_brdf_lut);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_brdf_lut);

    pass := BeginGfxRenderPass(cmd_buffer, "BRDF LUT", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_brdf_lut_pipeline);
        SetViewport(*pass, .{width=xx BRDF_LUT_Resolution, height=xx BRDF_LUT_Resolution});
        SetScissor(*pass, .{w=xx BRDF_LUT_Resolution, h=xx BRDF_LUT_Resolution});

        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);

    AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *g_brdf_lut);
}

Plane :: struct {
    origin : Vec3f;
    normal : Vec3f;
}

MakePlane :: inline (origin : Vec3f, normal : Vec3f) -> Plane {
    return .{origin, Normalized(normal)};
}

SignedDistanceToPlane :: inline (point : Vec3f, plane : Plane) -> float {
    return Dot(plane.normal, point) - Dot(plane.normal, plane.origin);
}

AABB :: struct {
    center : Vec3f;
    half_extents : Vec3f;
}

Frustum :: struct {
    far_plane, near_plane : Plane;
    left_plane, right_plane : Plane;
    top_plane, bottom_plane : Plane;

    #place far_plane;
    planes : [6]Plane;
}

AABBIsInFrontOrOnPlane :: (aabb : AABB, plane : Plane) -> bool {
    r := aabb.half_extents.x * Abs(plane.normal.x)
        + aabb.half_extents.y * Abs(plane.normal.y)
        + aabb.half_extents.z * Abs(plane.normal.z);

    dist_to_plane := SignedDistanceToPlane(aabb.center, plane);

    return dist_to_plane > 0 || Abs(dist_to_plane) <= r;
}

AABBIsInFrustum :: inline (aabb : AABB, using frustum : Frustum) -> bool {
    return AABBIsInFrontOrOnPlane(aabb, left_plane)
        && AABBIsInFrontOrOnPlane(aabb, right_plane)
        && AABBIsInFrontOrOnPlane(aabb, top_plane)
        && AABBIsInFrontOrOnPlane(aabb, bottom_plane)
        && AABBIsInFrontOrOnPlane(aabb, near_plane)
        && AABBIsInFrontOrOnPlane(aabb, far_plane);
}

PointIsInFrustum :: inline (point : Vec3f, using frustum : Frustum) -> bool {
    return SignedDistanceToPlane(point, left_plane) >= 0
        && SignedDistanceToPlane(point, right_plane) >= 0
        && SignedDistanceToPlane(point, top_plane) >= 0
        && SignedDistanceToPlane(point, bottom_plane) >= 0
        && SignedDistanceToPlane(point, near_plane) >= 0
        && SignedDistanceToPlane(point, far_plane) >= 0;
}

MakePerspectiveFrustum :: (transform : Mat4f, fov_in_degrees : float, aspect_ratio : float, z_near : float, z_far : float) -> Frustum {
    inv_aspect_ratio := 1 / aspect_ratio;
    if !Math.is_finite(inv_aspect_ratio) {
        return .{};
    }

    half_near_v_side := z_near * Tan(ToRads(fov_in_degrees * 0.5));
    half_near_h_side := half_near_v_side * aspect_ratio;
    half_near_h_hypothenuse := Sqrt(z_near * z_near + half_near_h_side * half_near_h_side);
    half_near_v_hypothenuse := Sqrt(z_near * z_near + half_near_v_side * half_near_v_side);

    half_far_v_side := z_far * Tan(ToRads(fov_in_degrees * 0.5));
    half_far_h_side := half_far_v_side * aspect_ratio;
    half_far_h_hypothenuse := Sqrt(z_far * z_far + half_far_h_side * half_far_h_side);
    half_far_v_hypothenuse := Sqrt(z_far * z_far + half_far_v_side * half_far_v_side);

    right   := RightVector(transform);
    up      := UpVector(transform);
    forward := ForwardVector (transform);
    position := TranslationVector(transform);

    using result : Frustum = ---;
    near_plane   = MakePlane(position + z_near * forward, forward);
    far_plane    = MakePlane(position + z_far * forward, -forward);

    far_center := z_far * forward;

    far_right := far_center + right * half_far_h_side;
    far_left  := far_center - right * half_far_h_side;
    right_center := far_right - Normalized(far_right) * (half_far_h_hypothenuse - half_near_h_hypothenuse) * 0.5;
    left_center  := far_left - Normalized(far_left) * (half_far_h_hypothenuse - half_near_h_hypothenuse) * 0.5;

    right_plane  = MakePlane(position + right_center, Cross(far_right, up));
    left_plane   = MakePlane(position + left_center, Cross(up, far_left));

    far_top    := far_center + up * half_far_v_side;
    far_bottom := far_center - up * half_far_v_side;
    top_center    := far_top - Normalized(far_top) * (half_far_v_hypothenuse - half_near_v_hypothenuse) * 0.5;
    bottom_center := far_bottom - Normalized(far_bottom) * (half_far_v_hypothenuse - half_near_v_hypothenuse) * 0.5;

    top_plane    = MakePlane(position + top_center, Cross(right, far_top));
    bottom_plane = MakePlane(position + bottom_center, Cross(far_bottom, right));

    return result;
}

MakeOrthographicFrustum :: (transform : Mat4f, l : float, r : float, t : float, b : float, z_near : float, z_far : float) -> Frustum {
    forward := ForwardVector (transform);
    right   := RightVector(transform);
    up      := UpVector(transform);
    position := TranslationVector(transform);

    using result : Frustum = ---;
    near_plane = MakePlane(position + z_near * forward, forward);
    far_plane  = MakePlane(position + z_far * forward, -forward);

    forward_center := forward * (z_near + z_far) * 0.5;
    right_plane = MakePlane(position + forward_center + r * right, -right);
    left_plane  = MakePlane(position + forward_center + l * right, right);

    top_plane    = MakePlane(position + forward_center - t * up, -up);
    bottom_plane = MakePlane(position + forward_center - b * up, up);

    return result;
}

GetTransformedAABB :: (transform : Mat4f, aabb : AABB) -> AABB {
    //      e---g
    // a---c \  |
    // |\  |  \ |
    // | \ |   \|
    // |  \|h---f
    // d---b

    a := aabb.center - aabb.half_extents;
    f := aabb.center + aabb.half_extents;
    b := Vec3f.{f.x, f.y, a.z};
    c := Vec3f.{f.x, a.y, a.z};
    d := Vec3f.{a.x, f.y, a.z};
    e := Vec3f.{a.x, a.y, f.z};
    g := Vec3f.{f.x, a.y, f.z};
    h := Vec3f.{a.x, f.y, f.z};

    a = TransformPoint(transform, a);
    b = TransformPoint(transform, b);
    c = TransformPoint(transform, c);
    d = TransformPoint(transform, d);
    e = TransformPoint(transform, e);
    f = TransformPoint(transform, f);
    g = TransformPoint(transform, g);
    h = TransformPoint(transform, h);

    min := Min(Min(Min(Min(Min(Min(Min(a, b), c), d), e), f), g), h);
    max := Max(Max(Max(Max(Max(Max(Max(a, b), c), d), e), f), g), h);

    return .{center=(max + min) * 0.5, half_extents=(max - min) * 0.5};
}
