PostProcessingBindingSet :: struct {
    color_texture : GfxBindingCombinedTextureSampler; @Binding(0) @FragmentStage
    entity_guid_texture : GfxBindingCombinedTextureSampler; @Binding(1) @FragmentStage
    selected_entity_guid_texture : GfxBindingCombinedTextureSampler; @Binding(2) @FragmentStage
} @BindingSet

g_post_processing_pipeline : GfxGraphicsPipeline;
g_post_processing_sampler : GfxSampler;

CreatePostProcessingPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("screen_effect");
    desc.fragment_shader = GetFragmentShader("post_processing");
    AddColorAttachment(*desc, g_final_texture.desc.pixel_format);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.PostProcessingBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_post_processing_pipeline, "Post Processing", desc);
    Assert(ok, "Could not create post processing pipeline");
}

PostProcessingPass :: (using ctx : *FrameRenderContext) {
    if IsNull(*g_post_processing_sampler) {
        desc : GfxSamplerDesc;
        desc.min_filter = .Nearest;
        desc.mag_filter = .Nearest;
        desc.mipmap_filter = .Nearest;
        g_post_processing_sampler = CreateGfxSampler("Post Processing", desc);
    }

    if IsNull(*g_post_processing_pipeline) {
        CreatePostProcessingPipeline();
    }

    bindings := PostProcessingBindingSet.{
        color_texture=.{texture=*g_color_texture, sampler=*g_post_processing_sampler},
        entity_guid_texture=.{texture=*g_entity_guid_texture, sampler=*g_post_processing_sampler},
        selected_entity_guid_texture=.{texture=*g_selected_entity_guid_texture, sampler=*g_post_processing_sampler},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

    w, h := GetWindowPixelSize(g_window);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_final_texture, load_op=.DontCare);

    pass := BeginGfxRenderPass(cmd_buffer, "Post Processing", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_post_processing_pipeline);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *binding_set);
        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);
}
