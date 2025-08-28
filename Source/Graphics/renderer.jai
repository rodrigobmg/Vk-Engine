g_linear_clamp_sampler : GfxSampler;
g_nearest_clamp_sampler : GfxSampler;
g_material_texture_sampler : GfxSampler;

// Pipeline layout used to bind binding sets outside of any render pass at the beginning of the frame
g_dummy_frame_pipeline_layout : GfxPipelineLayout;

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

    sampler_desc = .{};
    sampler_desc.min_filter = .Linear;
    sampler_desc.mag_filter = .Linear;
    sampler_desc.mipmap_filter = .Linear;
    sampler_desc.u_address_mode = .Repeat;
    sampler_desc.v_address_mode = .Repeat;

    g_material_texture_sampler = CreateGfxSampler("Material Texture", sampler_desc);
    Assert(!IsNull(*g_material_texture_sampler), "Could not create material texture sampler");

    frame_layout_desc : GfxPipelineLayoutDesc;
    frame_layout_desc.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
    ];
    g_dummy_frame_pipeline_layout = CreateGfxPipelineLayout("Dummy Frame", frame_layout_desc);
    Assert(!IsNull(*g_dummy_frame_pipeline_layout), "Could not create dummy frame pipeline layout");

    InitGPUFrameProfiler(*g_gpu_profiler, 1000);
}

CleanupRenderer :: () {
    DestroyGPUFrameProfiler(*g_gpu_profiler);

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
    DestroyGfxSampler(*g_material_texture_sampler);

    DestroyGfxPipelineLayout(*g_dummy_frame_pipeline_layout);
}

CreateAllPipelines :: () {
    CreateCompositingPipeline();
    CreateSkyboxPipeline();
    CreateIrradianceMapPipeline();
    CreateEnvironmentMapPipeline();
    CreateBloomFilterComputePipeline();
    CreateBloomDownsampleComputePipeline();
    CreateBloomUpsampleComputePipeline();
    CreateKawaseBlurDownsampleComputePipeline();
    CreateKawaseBlurUpsampleComputePipeline();
    CreateDebugLinesPipeline();
    CreateGizmoPipeline();
    CreateGizmoLinesPipeline();
}

DestroyAllPipelines :: () {
    DestroyMaterialRenderPass(*g_forward_material_pass);
    DestroyMaterialRenderPass(*g_depth_prepass_material_pass);
    DestroyMaterialRenderPass(*g_shadow_map_material_pass);
    DestroyMaterialRenderPass(*g_point_shadow_map_material_pass);
    DestroyMaterialRenderPass(*g_entity_guid_material_pass);

    DestroyGfxGraphicsPipeline(*g_gizmo_lines_pipeline);
    DestroyGfxGraphicsPipeline(*g_gizmo_pipeline);
    DestroyGfxGraphicsPipeline(*g_debug_lines_pipeline);
    DestroyGfxComputePipeline(*g_kawase_blur_upsample_compute_pipeline);
    DestroyGfxComputePipeline(*g_kawase_blur_downsample_compute_pipeline);
    DestroyGfxComputePipeline(*g_bloom_upsample_compute_pipeline);
    DestroyGfxComputePipeline(*g_bloom_downsample_compute_pipeline);
    DestroyGfxComputePipeline(*g_bloom_filter_compute_pipeline);
    DestroyGfxGraphicsPipeline(*g_environment_map_pipeline);
    DestroyGfxGraphicsPipeline(*g_irradiance_map_pipeline);
    DestroyGfxGraphicsPipeline(*g_skybox_pipeline);

    DestroyGfxGraphicsPipeline(*g_compositing_pipeline);
    DestroyGfxSampler(*g_entity_guid_sampler);

    DestroyGfxTexture(*g_brdf_lut);
    DestroyGfxComputePipeline(*g_brdf_lut_compute_pipeline);
}

g_final_texture : GfxTexture;
g_color_texture : GfxTexture;
g_depth_texture : GfxTexture;

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
        CreateKawaseBlurTextures(*g_editor_background_blur, g_editor_settings.blur_effect_iterations, texture_desc, g_editor_settings.blur_effect_resolution_factor);
    }

    texture_desc.pixel_format = .Depth32Float;
    texture_desc.usage = .DepthStencilAttachment;

    g_depth_texture = CreateGfxTexture("Depth", texture_desc);
    Assert(!IsNull(*g_depth_texture), "Could not create depth texture");

    CreateEntityGUIDTextures();
    CreateBloomTextures();
    CreateGizmoTextures(*g_gizmo_ctx);
    CreateImGuiColorTexture();
}

DestroyRenderTargets :: () {
    DestroyKawaseBlur(*g_editor_background_blur);
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

GetNumComputeWorkGroupsForTexture :: (desc : GfxTextureAndViewDesc, mipmap_level : int, work_group_size : u32) -> x : u32, y : u32 {
    w, h := GetTextureMipSize(desc, mipmap_level);

    return (w  + work_group_size - 1) / work_group_size, (h + work_group_size - 1) / work_group_size;
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

MakeViewpoint :: inline (camera : *Camera) -> Viewpoint {
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

MeshToDraw :: struct {
    entity : *Entity;
    transform : Mat4f;
    vertex_buffer, index_buffer : *GfxBuffer;
    vertex_count, index_count : u32;
    static_bounds : AABB;
    material : *Asset(Material);
    cast_shadows : bool;
    cast_point_shadows : bool;
    is_skinned : bool;
    skinning_matrices : []Mat4f;
}

MakeMeshToDraw :: (entity : *Entity, component : *StaticMeshComponent) -> bool, MeshToDraw {
    if entity.flags & .Hidden || !component.mesh || IsNull(*component.mesh.vertex_buffer) || IsNull(*component.mesh.index_buffer) {
        return false, .{};
    }

    return true, .{
        entity=entity,
        transform=entity.world_transform,
        vertex_buffer=*component.mesh.vertex_buffer,
        index_buffer=*component.mesh.index_buffer,
        vertex_count=component.mesh.vertex_count,
        index_count=component.mesh.index_count,
        static_bounds=component.mesh.static_bounds,
        material=ifx component.material then component.material else g_default_material,
        cast_shadows=component.cast_shadows,
        cast_point_shadows=component.cast_point_shadows,
        is_skinned=false,
    };
}

MakeMeshToDraw :: (world : *World, component : *StaticMeshComponent) -> bool, MeshToDraw {
    entity := GetEntity(world, component.entity);
    if !entity {
        LogError("Could not get entity %", component.entity);
        return false, .{};
    }

    ok, mesh := MakeMeshToDraw(entity, component);
    return ok, mesh;
}

MakeMeshToDraw :: (entity : *Entity, component : *SkinnedMeshComponent) -> bool, MeshToDraw {
    if entity.flags & .Hidden || !component.mesh || IsNull(*component.mesh.vertex_buffer) || IsNull(*component.mesh.index_buffer) {
        return false, .{};
    }

    return true, .{
        entity=entity,
        transform=entity.world_transform,
        vertex_buffer=*component.mesh.vertex_buffer,
        index_buffer=*component.mesh.index_buffer,
        vertex_count=component.mesh.vertex_count,
        index_count=component.mesh.index_count,
        material=ifx component.material then component.material else g_default_material,
        cast_shadows=component.cast_shadows,
        cast_point_shadows=component.cast_point_shadows,
        is_skinned=true,
        skinning_matrices=component.skinning_matrices,
    };
}

MakeMeshToDraw :: (world : *World, component : *SkinnedMeshComponent) -> bool, MeshToDraw {
    entity := GetEntity(world, component.entity);
    if !entity {
        LogError("Could not get entity");
        return false, .{};
    }

    ok, mesh := MakeMeshToDraw(entity, component);
    return ok, mesh;
}

AllMeshesToDraw :: (world : *World, body : Code, flags : For_Flags) #expand {
    `it : MeshToDraw;
    `it_index : int;

    for * c, i : world.StaticMeshComponent_storage {
        defer it_index += 1;

        ok:, it = MakeMeshToDraw(world, c);
        if !ok {
            continue;
        }

        #insert(break=return) body;
    }

    for * c, i : world.SkinnedMeshComponent_storage {
        defer it_index += 1;

        ok:, it = MakeMeshToDraw(world, c);
        if !ok {
            continue;
        }

        #insert(break=return) body;
    }
}

RenderFrame :: (world : *World, camera : *Camera) {
    w, h := GetWindowPixelSize(g_window);

    BeginFrame();

    ProfilerBeginFrame(*g_gpu_profiler);

    ResetFrameDataAllocator();
    ResetBindingSetAllocators();

    ClearMeshBuffer(*g_mesh_buffer);

    frustum := MakePerspectiveFrustum(camera.transform, camera.fov_in_degrees, w / cast(float, h), camera.z_near, camera.z_far);
    for :AllMeshesToDraw world {
        if !it.is_skinned {
            aabb := GetTransformedAABB(it.transform, it.static_bounds);
            if !AABBIsInFrustum(aabb, frustum) {
                continue;
            }
        }

        position := TranslationVector(it.transform);
        depth := TransformPoint(camera.view, position).z;
        key := MakeMeshBufferKey(it, depth);
        PushMesh(*g_mesh_buffer, key, it);
    }

    SortMeshBuffer(*g_mesh_buffer);
    AllocDrawData(*g_mesh_buffer);

    ClearMeshBuffer(*g_selected_mesh_buffer);

    for * guid : g_editor_selected_entities {
        entity := GetEntity(world, guid);
        if !entity {
            continue;
        }

        for :AllStaticMeshComponents comp : entity {
            draw, it := MakeMeshToDraw(entity, comp);
            if !draw {
                continue;
            }

            aabb := GetTransformedAABB(it.transform, it.static_bounds);
            if !AABBIsInFrustum(aabb, frustum) {
                continue;
            }

            position := TranslationVector(it.transform);
            depth := TransformPoint(camera.view, position).z;
            key := MakeMeshBufferKey(it, depth);
            PushMesh(*g_selected_mesh_buffer, key, it);
        }

        for :AllSkinnedMeshComponents comp : entity {
            draw, it := MakeMeshToDraw(entity, comp);
            if !draw {
                continue;
            }

            position := TranslationVector(it.transform);
            depth := TransformPoint(camera.view, position).z;
            key := MakeMeshBufferKey(it, depth);
            PushMesh(*g_selected_mesh_buffer, key, it);
        }
    }

    SortMeshBuffer(*g_selected_mesh_buffer);
    AllocDrawData(*g_selected_mesh_buffer);

    for * world.DirectionalLightComponent_storage {
        if !it.cast_shadows {
            continue;
        }

        entity := GetEntity(world, it.entity);
        if !entity {
            continue;
        }

        if entity.flags & .Hidden {
            continue;
        }

        PopulateShadowMapMeshBuffer(world, *it.shadow_map, ForwardVector(entity.world_transform), camera.transform);
    }

    for * world.PointLightComponent_storage {
        if !it.cast_shadows {
            continue;
        }

        entity := GetEntity(world, it.entity);
        if !entity {
            continue;
        }

        if entity.flags & .Hidden {
            continue;
        }

        UpdatePointShadowMapFarPlane(it);
        PopulateShadowMapMeshBuffers(world, *it.shadow_map, TranslationVector(entity.world_transform));
    }

    ctx : FrameRenderContext;
    ctx.world = world;

    cmd_buffer := CreateGfxCommandBuffer("Main");
    ctx.cmd_buffer = *cmd_buffer;

    if IsNull(*g_brdf_lut) {
        RenderBRDFLUT(ctx.cmd_buffer);
    }

    num_directional_lights : u64 = xx world.DirectionalLightComponent_storage.count;
    directional_lights_size := GLSLStd430Size(DirectionalLight) * num_directional_lights;
    directional_lights_offset, directional_lights_ptr := AllocFrameData(directional_lights_size);
    shadow_map_index : s32 = 0;
    for * world.DirectionalLightComponent_storage {
        entity := GetEntity(world, it.entity);
        if !entity {
            continue;
        }

        if entity.flags & .Hidden {
            continue;
        }

        if it.cast_shadows && it.shadow_map.resolution == 0 {
            InitShadowMap(*it.shadow_map, Default_Shadow_Map_Resolution);
        }

        directional_light := DirectionalLight.{
            direction=ForwardVector(entity.world_transform),
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

    num_point_lights : u64 = xx world.PointLightComponent_storage.count;
    point_lights_size := GLSLStd430Size(PointLight) * num_point_lights;
    point_lights_offset, point_lights_ptr := AllocFrameData(point_lights_size);
    point_shadow_map_index : s32 = 0;
    for * world.PointLightComponent_storage {
        entity := GetEntity(world, it.entity);
        if !entity {
            continue;
        }

        if entity.flags & .Hidden {
            continue;
        }

        if it.cast_shadows && it.shadow_map.resolution == 0 {
            InitShadowMap(*it.shadow_map, Default_Point_Shadow_Map_Resolution);
        }

        point_light := PointLight.{
            position=TranslationVector(entity.world_transform),
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
        brdf_lut=.{texture=*g_brdf_lut, sampler=*g_linear_clamp_sampler},
        shadow_map_noise=.{texture=*g_shadow_map_noise_texture, sampler=*g_shadow_map_noise_sampler},
    };

    ctx.frame_binding_set = CreateGfxBindingSet(GlobalBindingSetAllocator(), frame_binding_set);
    BindGraphicsBindingSet(*cmd_buffer, *g_dummy_frame_pipeline_layout, 0, *ctx.frame_binding_set);
    BindComputeBindingSet(*cmd_buffer, *g_dummy_frame_pipeline_layout, 0, *ctx.frame_binding_set);

    TextureUploadPass(*cmd_buffer);
    GenerateEnvironmentMaps(*cmd_buffer);

    for * world.DirectionalLightComponent_storage {
        if !it.cast_shadows {
            continue;
        }

        entity := GetEntity(world, it.entity);
        if !entity {
            continue;
        }

        if entity.flags & .Hidden {
            continue;
        }

        ShadowMapPass(*ctx, *it.shadow_map, ForwardVector(entity.world_transform), camera);
    }

    for * world.PointLightComponent_storage {
        if !it.cast_shadows {
            continue;
        }

        entity := GetEntity(world, it.entity);
        if !entity {
            continue;
        }

        if entity.flags & .Hidden {
            continue;
        }

        PointShadowMapPass(*ctx, *it.shadow_map, TranslationVector(entity.world_transform));
    }

    AddTextureBarriers(*cmd_buffer, .Undefined, .ColorAttachment, .[*g_color_texture, *g_entity_guid_texture, *g_selected_entity_guid_texture]);
    AddTextureBarrier(*cmd_buffer, .Undefined, .DepthStencilAttachment, *g_depth_texture);

    DepthPrepass(*ctx, camera, *g_mesh_buffer);
    ForwardPass(*ctx, camera, *g_mesh_buffer);
    DebugLinesPass(*ctx, camera);
    SkyboxPass(*ctx, camera, ifx world.skybox && world.skybox.base_texture then *world.skybox.base_texture.texture);

    {
        BeginGfxDebugMarker(*cmd_buffer, "Entity Selection");
        defer EndGfxDebugMarker(*cmd_buffer);

        ProfileGPUZone(*cmd_buffer, *g_gpu_profiler, "Entity Selection");

        EntityGUIDPass(*ctx, *g_entity_guid_texture, *g_depth_texture, camera, *g_mesh_buffer);
        EntityGUIDPass(*ctx, *g_selected_entity_guid_texture, *g_selected_entities_depth_texture, camera, *g_selected_mesh_buffer);

        AddTextureBarrier(*cmd_buffer, .ColorAttachment, .TransferSrc, *g_entity_guid_texture);

        TransferEntityGUIDForReadback(*cmd_buffer);

        AddTextureBarrier(*cmd_buffer, .TransferSrc, .ShaderReadOnly, *g_entity_guid_texture);
    }

    AddTextureBarriers(*cmd_buffer, .ColorAttachment, .ShaderReadOnly, .[*g_selected_entity_guid_texture, *g_color_texture]);

    ComputeBloom(*ctx, *g_color_texture);

    if g_editor_settings.use_blur_effect {
        ComputeKawaseBlur(*cmd_buffer, *g_editor_background_blur, *g_color_texture);
    }

    AddTextureBarrier(*cmd_buffer, .Undefined, .ColorAttachment, *g_final_texture);

    GizmoPass(*ctx, *g_gizmo_ctx);
    ImGuiPass(*cmd_buffer, ImGui.GetDrawData());

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
