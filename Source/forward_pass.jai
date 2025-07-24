ForwardPassBindingSet :: struct {
    viewpoints : GfxBindingUniformBuffer; @Binding(0) @VertexStage @FragmentStage
    shadow_map : GfxBindingCombinedTextureSampler; @Binding(1) @FragmentStage @AllowNull
} @BindingSet

g_forward_pipeline : GfxGraphicsPipeline;

CreateForwardPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("mesh_geometry");
    desc.fragment_shader = GetFragmentShader("opaque_surface");
    desc.color_formats[0] = g_color_texture.desc.pixel_format;
    desc.depth_format = g_depth_texture.desc.pixel_format;
    desc.depth_state = .{test_enabled=true, write_enabled=true};

    desc.vertex_input = MakeVertexInputDesc(StaticVertex, 0);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.ForwardPassBindingSet,
        g_binding_set_layouts.MeshBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_forward_pipeline, "Forward", desc);
    Assert(ok, "Could not create forward pass pipeline");
}

ForwardPass :: (using ctx : *FrameRenderContext, camera : *Camera, mesh_buffer : *MeshBuffer) {
    if IsNull(*g_forward_pipeline) {
        CreateForwardPipeline();
    }

    w, h : s32;
    SDL_GetWindowSizeInPixels(g_window, *w, *h);

    viewpoints : [Max_Viewpoints]Viewpoint;
    viewpoints[0] = .{
        position=camera.position,
        right=RightVector(camera.rotation),
        up=UpVector(camera.rotation),
        direction=ForwardVector(camera.rotation),
        transform=camera.transform,
        view=camera.view,
        projection=camera.projection,
        view_projection=camera.projection * camera.view,
    };
    viewpoints_offset, viewpoints_size := AllocAndPackUniformFrameData(viewpoints);

    pass_bindings := ForwardPassBindingSet.{
        viewpoints=.{buffer=FrameDataBuffer(), offset=xx viewpoints_offset, size=xx viewpoints_size},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), pass_bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_color_texture);
    AddDepthAttachment(*pass_desc, *g_depth_texture, store_op=.DontCare);
    ClearColor(*pass_desc, 0, Vec4f.{0,0,0,1});
    ClearDepth(*pass_desc, 1);

    pass := BeginGfxRenderPass(cmd_buffer, "Forward Pass", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_forward_pipeline);
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
