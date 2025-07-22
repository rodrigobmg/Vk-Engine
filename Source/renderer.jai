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

g_color_texture : GfxTexture;
g_depth_texture : GfxTexture;

g_shaders : struct {
    mesh_vert : GfxShader;
    mesh_frag : GfxShader;
}

LoadAllShaders :: () -> bool {
    g_shaders.mesh_vert = LoadGfxShader("mesh.vert");
    if IsNull(*g_shaders.mesh_vert) {
        return false;
    }

    g_shaders.mesh_frag = LoadGfxShader("mesh.frag");
    if IsNull(*g_shaders.mesh_frag) {
        return false;
    }

    return true;
}

DestroyAllShaders :: () {
    DestroyGfxShader(*g_shaders.mesh_vert);
    DestroyGfxShader(*g_shaders.mesh_frag);
}

CreateRenderTargets :: () {
    WaitForGPUIdle();

    if !IsNull(*g_color_texture) {
        DestroyGfxTexture(*g_color_texture);
    }

    if !IsNull(*g_depth_texture) {
        DestroyGfxTexture(*g_depth_texture);
    }

    w, h : s32;
    SDL_GetWindowSizeInPixels(g_window, *w, *h);

    texture_desc : GfxTextureDesc;
    texture_desc.type = .Texture2D;
    texture_desc.width = xx w;
    texture_desc.height = xx h;

    texture_desc.pixel_format = .RGBA16Float;
    texture_desc.usage = .ColorAttachment | .TransferSrc;

    g_color_texture = CreateGfxTexture("Color", texture_desc);
    Assert(!IsNull(*g_color_texture), "Could not create color texture");

    texture_desc.pixel_format = .Depth32Float;
    texture_desc.usage = .DepthStencilAttachment;

    g_depth_texture = CreateGfxTexture("Depth", texture_desc);
    Assert(!IsNull(*g_depth_texture), "Could not create depth texture");
}

MeshEntity :: struct {
    #as using _ : Entity; @Serialize(1)

    mesh : *Asset(Mesh); @Serialize(2)
    material : *Asset(Material); @Serialize(3)
    cast_shadows := true; @Serialize(4)
} @Entity

DirectionalLightEntity :: struct {
    #as using _ : Entity; @Serialize(1)

    color : Vec3f; @Serialize(2)
    intensity : float; @Serialize(3)
    cast_shadows : bool; @Serialize(4)
} @Entity

PointLightEntity :: struct {
    #as using _ : Entity; @Serialize(1)

    color : Vec3f; @Serialize(2)
    intensity : float; @Serialize(3)
    cast_shadows : bool; @Serialize(4)
} @Entity

EmptyBindingSet :: struct {
} @BindingSet

FrameBindingSet :: struct {
    frame_info : GfxBindingUniformBuffer; @Binding(0) @VertexStage @FragmentStage
    // irradiance_map : GfxBindingCombinedTextureSampler; @Binding(1) @FragmentStage
    // environment_maps : GfxBindingCombinedTextureSampler; @Binding(2) @FragmentStage
} @BindingSet

FrameInfo :: struct {
    time : float;
    camera_position : Vec3f;
    camera_view : Mat4f;
    camera_projection : Mat4f;
} @ShaderType

FrameRenderContext :: struct {
    world : *World;
    cmd_buffer : *GfxCommandBuffer;
    frame_binding_set : GfxBindingSet;
}

g_mesh_buffer : MeshBuffer;
g_irradiance_map : GfxTexture;
g_environment_maps : GfxTexture;
g_environment_map_sampler : GfxSampler;

RenderFrame :: (world : *World, camera : *Camera) {
    ResetFrameDataAllocator();
    ResetBindingSetAllocators();

    ClearMeshBuffer(*g_mesh_buffer);

    for * world.MeshEntity_storage {
        if !it.mesh || !it.material {
            continue;
        }

        if IsNull(*it.mesh.vertex_buffer) || IsNull(*it.mesh.index_buffer) {
            continue;
        }

        position := TranslationVector(it.world_transform);
        depth := TransformPoint(camera.view, position).z;
        key := MakeMeshBufferKey(*it.mesh.vertex_buffer, *it.mesh.index_buffer, it.material, depth);
        PushMesh(*g_mesh_buffer, key, it.guid, *it.mesh.vertex_buffer, *it.mesh.index_buffer, it.mesh.vertex_count, it.mesh.index_count, it.world_transform, it.material);
    }

    SortMeshBuffer(*g_mesh_buffer);
    AllocDrawData(*g_mesh_buffer);

    ctx : FrameRenderContext;
    ctx.world = world;

    frame_info := FrameInfo.{
        time=xx Basic.to_float64_seconds(Basic.current_time_monotonic()),
        camera_position=camera.position,
        camera_view=camera.view,
        camera_projection=camera.projection,
    };
    frame_info_offset, frame_info_size := AllocAndPackUniformFrameData(frame_info);

    frame_binding_set := FrameBindingSet.{
        frame_info=.{buffer=FrameDataBuffer(), offset=xx frame_info_offset, size=xx frame_info_size},
        // irradiance_map=.{texture=*g_irradiance_map, sampler=*g_environment_map_sampler},
        // environment_maps=.{texture=*g_environment_maps, sampler=*g_environment_map_sampler},
    };
    ctx.frame_binding_set = CreateGfxBindingSet(GlobalBindingSetAllocator(), frame_binding_set);

    cmd_buffer := CreateGfxCommandBuffer("Main");
    ctx.cmd_buffer = *cmd_buffer;

    PerformPendingUploads(*cmd_buffer);

    AddTextureBarrier(*cmd_buffer, .Undefined, .ColorAttachment, *g_color_texture);

    BindGraphicsBindingSet(*cmd_buffer, *g_dummy_frame_pipeline_layout, 0, *ctx.frame_binding_set);

    ForwardPass(*ctx, *g_mesh_buffer);

    AddTextureBarrier(*cmd_buffer, .ColorAttachment, .TransferSrc, *g_color_texture);

    SubmitGfxCommandBuffer(*cmd_buffer);
}

g_forward_pass_pipeline : GfxGraphicsPipeline;

CreateForwardPassPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = *g_shaders.mesh_vert;
    desc.fragment_shader = *g_shaders.mesh_frag;
    desc.color_formats[0] = g_color_texture.desc.pixel_format;
    desc.depth_format = g_depth_texture.desc.pixel_format;
    desc.depth_state = .{test_enabled=true, write_enabled=true};

    desc.vertex_input = MakeVertexInputDesc(StaticVertex, 0);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.EmptyBindingSet,
        g_binding_set_layouts.MeshBindingSet,
    ];

    g_forward_pass_pipeline = CreateGfxGraphicsPipeline("Forward Pass", desc);
    Assert(!IsNull(*g_forward_pass_pipeline), "Could not create forward pass pipeline");
}

ForwardPass :: (using ctx : *FrameRenderContext, mesh_buffer : *MeshBuffer) {
    w, h : s32;
    SDL_GetWindowSizeInPixels(g_window, *w, *h);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_color_texture);
    AddDepthAttachment(*pass_desc, *g_depth_texture, store_op=.DontCare);
    ClearColor(*pass_desc, 0, Vec4f.{0,0,0,1});
    ClearDepth(*pass_desc, 1);

    pass := BeginGfxRenderPass(cmd_buffer, "Forward Pass", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_forward_pass_pipeline);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        for mesh_buffer.draw_calls {
            BindGraphicsBindingSet(*pass, 2, *it.binding_set);
            BindVertexBuffer(*pass, 0, it.vertex_buffer);
            BindIndexBuffer(*pass, .UInt32, it.index_buffer);

            DrawIndexed(*pass, it.index_count, it.instance_count);
        }
    }
    EndGfxRenderPass(*pass);
}

// Pipeline layout used to bind binding sets outside of any render pass at the beginning of the frame
g_dummy_frame_pipeline_layout : GfxPipelineLayout;

g_material_texture_sampler : GfxSampler;
g_default_base_color : *Asset(Texture2D);
g_default_normal_map : *Asset(Texture2D);
g_default_metallic_roughness_map : *Asset(Texture2D);
g_default_emissive : *Asset(Texture2D);

CreateAllPipelines :: () {
    sampler_desc : GfxSamplerDesc;
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

    CreateForwardPassPipeline();
}

DestroyAllPipelines :: () {
    DestroyGfxGraphicsPipeline(*g_forward_pass_pipeline);
    DestroyGfxPipelineLayout(*g_dummy_frame_pipeline_layout);

    DestroyGfxSampler(*g_material_texture_sampler);
}
