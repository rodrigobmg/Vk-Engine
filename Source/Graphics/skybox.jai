SkyboxBindingSet :: struct {
    viewpoint : GfxBindingUniformBuffer; @Binding(0) @FragmentStage
    skybox : GfxBindingCombinedTextureSampler; @Binding(1) @FragmentStage
} @BindingSet

g_skybox_pipeline : GfxGraphicsPipeline;
g_skybox_sampler : GfxSampler;

CreateSkyboxPipeline :: () {
    if IsNull(*g_skybox_sampler) {
        desc : GfxSamplerDesc;
        desc.min_filter = .Linear;
        desc.mag_filter = .Linear;
        desc.mipmap_filter = .Linear;
        desc.u_address_mode = .Repeat;
        desc.v_address_mode = .ClampToEdge;

        g_skybox_sampler = CreateGfxSampler("Skybox", desc);
        Assert(!IsNull(*g_skybox_sampler), "Could not create skybox sampler");
    }

    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("background_screen_effect");
    desc.fragment_shader = GetFragmentShader("skybox");
    AddColorAttachment(*desc, g_color_texture.desc.pixel_format);
    desc.depth_format = g_depth_texture.desc.pixel_format;
    desc.depth_state = .{test_enabled=true};

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.SkyboxBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_skybox_pipeline, "Skybox", desc);
    Assert(ok, "Could not create skybox pipeline");
}

SkyboxPass :: (using ctx : *FrameRenderContext, camera : *Camera, skybox_texture : *GfxTexture) {
    if IsNull(*g_skybox_pipeline) {
        CreateSkyboxPipeline();
    }

    if !skybox_texture {
        return;
    }

    w, h := GetWindowPixelSize(g_window);

    viewpoint := MakeViewpoint(camera);
    viewpoint_offset, viewpoint_size := AllocAndPackUniformFrameData(viewpoint);

    pass_bindings := SkyboxBindingSet.{
        viewpoint=.{buffer=FrameDataBuffer(), offset=xx viewpoint_offset, size=xx viewpoint_size},
        skybox=.{texture=skybox_texture, sampler=*g_skybox_sampler},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), pass_bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_color_texture);
    AddDepthAttachment(*pass_desc, *g_depth_texture);

    pass := BeginGfxRenderPass(cmd_buffer, "Skybox", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_skybox_pipeline);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);
}
