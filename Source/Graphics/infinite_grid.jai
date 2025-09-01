InfiniteGridBindingSet :: struct {
    viewpoint : GfxBindingUniformBuffer; @Binding(0) @VertexStage
} @BindingSet

g_infinite_grid_pipeline : GfxGraphicsPipeline;

CreateInfiniteGridPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("infinite_grid");
    desc.fragment_shader = GetFragmentShader("infinite_grid");

    AddColorAttachment(*desc, g_color_texture.desc.pixel_format);
    desc.depth_format = g_depth_texture.desc.pixel_format;

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.InfiniteGridBindingSet,
    ];

    desc.rasterizer_state = .{cull_face=.None};
    desc.depth_state = .{test_enabled=true, write_enabled=true, compare_op=Depth_Compare_Op};
    desc.blend_states[0] = .{enabled=true};

    ok := CreateGfxGraphicsPipeline(*g_infinite_grid_pipeline, "Infinite Grid", desc);
    Assert(ok, "Could not create infinite grid pipeline");
}

InfiniteGridPass :: (using ctx : *FrameRenderContext, camera : *Camera) {
    if IsNull(*g_infinite_grid_pipeline) {
        CreateInfiniteGridPipeline();
    }

    w, h := GetWindowPixelSize(g_window);

    viewpoint_offset, viewpoint_size := AllocAndPackUniformFrameData(MakeViewpoint(camera));

    pass_bindings := InfiniteGridBindingSet.{
        viewpoint=.{buffer=FrameDataBuffer(), offset=xx viewpoint_offset, size=xx viewpoint_size},
    };
    pass_binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), pass_bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_color_texture);
    AddDepthAttachment(*pass_desc, *g_depth_texture);

    pass := BeginGfxRenderPass(cmd_buffer, "Infinite Grid", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_infinite_grid_pipeline);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *pass_binding_set);

        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);
}
