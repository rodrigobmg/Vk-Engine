g_entity_guid_texture : GfxTexture;
g_selected_entity_guid_texture : GfxTexture;
g_entity_guid_pipeline : GfxGraphicsPipeline;

CreateEntityGUIDTexture :: () {
    if !IsNull(*g_entity_guid_texture) {
        DestroyGfxTexture(*g_entity_guid_texture);
    }

    if !IsNull(*g_selected_entity_guid_texture) {
        DestroyGfxTexture(*g_selected_entity_guid_texture);
    }

    w, h := GetWindowPixelSize(g_window);

    texture_desc : GfxTextureDesc;
    texture_desc.type = .Texture2D;
    texture_desc.width = xx w;
    texture_desc.height = xx h;

    texture_desc.pixel_format = .RGBA32UInt;
    texture_desc.usage = .ColorAttachment | .Sampled;

    g_entity_guid_texture = CreateGfxTexture("Entity GUID", texture_desc);
    Assert(!IsNull(*g_entity_guid_texture), "Could not create entity GUID texture");

    g_selected_entity_guid_texture = CreateGfxTexture("Selected Entity GUID", texture_desc);
    Assert(!IsNull(*g_selected_entity_guid_texture), "Could not create entity GUID texture");
}

CreateEntityGUIDPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("mesh_geometry");
    desc.fragment_shader = GetFragmentShader("entity_guid");
    AddColorAttachment(*desc, g_entity_guid_texture.desc.pixel_format);
    desc.depth_format = g_depth_texture.desc.pixel_format;
    desc.depth_state = .{test_enabled=true, write_enabled=true};

    desc.vertex_input = MakeVertexInputDesc(StaticVertex, 0);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.ForwardPassBindingSet,
        g_binding_set_layouts.MeshBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_entity_guid_pipeline, "Entity GUID", desc);
    Assert(ok, "Could not create entity GUID pipeline");
}

EntityGUIDPass :: (using ctx : *FrameRenderContext, texture : *GfxTexture, depth_texture : *GfxTexture, camera : *Camera, mesh_buffer : *MeshBuffer) {
    if IsNull(*g_entity_guid_pipeline) {
        CreateEntityGUIDPipeline();
    }

    w, h := GetWindowPixelSize(g_window);

    viewpoints : [Max_Viewpoints]Viewpoint;
    viewpoints[0] = .{
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
    };
    viewpoints_offset, viewpoints_size := AllocAndPackUniformFrameData(viewpoints);

    pass_bindings := ForwardPassBindingSet.{
        viewpoints=.{buffer=FrameDataBuffer(), offset=xx viewpoints_offset, size=xx viewpoints_size},
    };

    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), pass_bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, texture);
    AddDepthAttachment(*pass_desc, depth_texture);
    ClearColor(*pass_desc, 0, Vec4u.{0,0,0,0});
    ClearDepth(*pass_desc, 1);

    pass := BeginGfxRenderPass(cmd_buffer, "Entity GUID", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_entity_guid_pipeline);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        for mesh_buffer.draw_calls {
            BindGraphicsBindingSet(*pass, 2, *it.binding_set);
            BindVertexBuffer(*pass, 0, it.vertex_buffer);
            BindIndexBuffer(*pass, .UInt32, it.index_buffer);

            DrawIndexed(*pass, it.index_count, it.instance_count);
        }
    }
    EndGfxRenderPass(*pass);
}
