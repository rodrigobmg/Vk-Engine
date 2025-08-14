PostProcessingBindingSet :: struct {
    color_texture : GfxBindingCombinedTextureSampler; @Binding(0) @FragmentStage
    bloom_texture : GfxBindingCombinedTextureSampler; @Binding(1) @FragmentStage
    entity_guid_texture : GfxBindingCombinedTextureSampler; @Binding(2) @FragmentStage
    selected_entity_guid_texture : GfxBindingCombinedTextureSampler; @Binding(3) @FragmentStage
    gizmo_texture : GfxBindingCombinedTextureSampler; @Binding(4) @FragmentStage
    imgui_texture : GfxBindingCombinedTextureSampler; @Binding(5) @FragmentStage
} @BindingSet

g_post_processing_pipeline : GfxGraphicsPipeline;
g_entity_guid_sampler : GfxSampler;

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
    if IsNull(*g_entity_guid_sampler) {
        desc : GfxSamplerDesc;
        desc.min_filter = .Nearest;
        desc.mag_filter = .Nearest;
        g_entity_guid_sampler = CreateGfxSampler("Entity GUID", desc);
    }

    if IsNull(*g_post_processing_pipeline) {
        CreatePostProcessingPipeline();
    }

    bindings := PostProcessingBindingSet.{
        color_texture=.{texture=*g_color_texture, sampler=*g_linear_clamp_sampler},
        bloom_texture=.{texture=GetFinalBloomTexture(), sampler=*g_linear_clamp_sampler},
        entity_guid_texture=.{texture=*g_entity_guid_texture, sampler=*g_entity_guid_sampler},
        selected_entity_guid_texture=.{texture=*g_selected_entity_guid_texture, sampler=*g_entity_guid_sampler},
        gizmo_texture=.{texture=*g_gizmo_ctx.color_resolve, sampler=*g_linear_clamp_sampler},
        imgui_texture=.{texture=*g_imgui_color_texture, sampler=*g_nearest_clamp_sampler},
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
