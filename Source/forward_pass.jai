g_forward_pass_pipeline : GfxGraphicsPipeline;

CreateForwardPassPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("mesh");
    desc.fragment_shader = GetFragmentShader("mesh");
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

    DestroyPipelineOnShaderReload(*g_forward_pass_pipeline);
}

ForwardPass :: (using ctx : *FrameRenderContext, mesh_buffer : *MeshBuffer) {
    if IsNull(*g_forward_pass_pipeline) {
        CreateForwardPassPipeline();
    }

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

