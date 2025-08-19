// Technique used in bloom, though for bloom we upsample differently

KawaseBlur :: struct {
    downsample_texture : GfxTexture;
    downsample_levels : []GfxTexture;
    upsample_texture : GfxTexture;
    upsample_levels : []GfxTexture;
}

GetFinalTexture :: inline (using blur : *KawaseBlur) -> *GfxTexture {
    return *upsample_levels[0];
}

CreateKawaseBlurTextures :: (using blur : *KawaseBlur, num_iterations : int, base_texture_desc : GfxTextureDesc, resolution_factor : float) {
    DestroyKawaseBlur(blur);

    desc : GfxTextureDesc;
    desc.type = .Texture2D;
    desc.pixel_format = base_texture_desc.pixel_format;
    desc.width = Max(cast(u32, base_texture_desc.width * resolution_factor) / 2, 1);
    desc.height = Max(cast(u32, base_texture_desc.height * resolution_factor) / 2, 1);
    desc.num_mipmap_levels = xx num_iterations;
    desc.usage = .ColorAttachment | .Sampled;

    downsample_texture = CreateGfxTexture("Kawase Downsample", desc);

    desc.width = base_texture_desc.width;
    desc.height = base_texture_desc.height;
    upsample_texture = CreateGfxTexture("Kawase Upsample", desc);

    downsample_levels = AllocArray(GfxTexture, num_iterations);
    upsample_levels = AllocArray(GfxTexture, num_iterations);

    for i : 0..num_iterations - 1 {
        view_desc : GfxTextureViewDesc;
        view_desc.type = .Texture2D;
        view_desc.pixel_format = desc.pixel_format;
        view_desc.first_mipmap_level = xx i;

        downsample_levels[i] = CreateGfxTextureView(TPrint("Kawase Downsample %", i), view_desc, *downsample_texture);
        upsample_levels[i] = CreateGfxTextureView(TPrint("Kawase Upsample %", i), view_desc, *upsample_texture);
    }
}

DestroyKawaseBlur :: (using blur : *KawaseBlur) {
    for * downsample_levels {
        QueueDestroyGfxTextureView(it);
    }
    for * upsample_levels {
        QueueDestroyGfxTextureView(it);
    }

    Free(downsample_levels.data);
    Free(upsample_levels.data);

    if !IsNull(*downsample_texture) {
        QueueDestroyGfxTexture(*downsample_texture);
    }
    if !IsNull(*upsample_texture) {
        QueueDestroyGfxTexture(*upsample_texture);
    }

    blur.* = .{};
}

KawaseBlurBindingSet :: struct {
    texture : GfxBindingCombinedTextureSampler; @Binding(0) @FragmentStage
} @BindingSet

g_kawase_blur_downsample_pipeline : [#run type_info(GfxPixelFormat).values.count]GfxGraphicsPipeline;
g_kawase_blur_upsample_pipeline : [#run type_info(GfxPixelFormat).values.count]GfxGraphicsPipeline;

CreateKawaseBlurDownsamplePipeline :: (pixel_format : GfxPixelFormat) {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("screen_effect");
    desc.fragment_shader = GetFragmentShader("kawase_blur_downsample");
    AddColorAttachment(*desc, pixel_format);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.KawaseBlurBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_kawase_blur_downsample_pipeline[pixel_format], TPrint("Kawase Downsample, %", pixel_format), desc);
    Assert(ok, "Could not create kawase blur downsample pipeline for pixel format %", pixel_format);
}

CreateKawaseBlurUpsamplePipeline :: (pixel_format : GfxPixelFormat) {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("screen_effect");
    desc.fragment_shader = GetFragmentShader("kawase_blur_upsample");
    AddColorAttachment(*desc, pixel_format);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.KawaseBlurBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_kawase_blur_upsample_pipeline[pixel_format], TPrint("Kawase Upsample, %", pixel_format), desc);
    Assert(ok, "Could not create kawase blur upsample pipeline for pixel format %", pixel_format);
}

KawaseBlurDownsample :: (cmd_buffer : *GfxCommandBuffer, blur : *KawaseBlur, base_texture : *GfxTexture, level : int) {
    if IsNull(*g_kawase_blur_downsample_pipeline[blur.downsample_texture.desc.pixel_format]) {
        CreateKawaseBlurDownsamplePipeline(blur.downsample_texture.desc.pixel_format);
    }

    AddTextureBarrier(cmd_buffer, .Undefined, .ColorAttachment, *blur.downsample_levels[level]);

    w := blur.downsample_texture.desc.width;
    h := blur.downsample_texture.desc.height;
    for 0..level - 1 {
        w = Max(w / 2, 1);
        h = Max(h / 2, 1);
    }

    bindings := KawaseBlurBindingSet.{
        texture=.{texture=ifx level == 0 then base_texture else *blur.downsample_levels[level - 1], sampler=*g_linear_clamp_sampler},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *blur.downsample_levels[level]);

    pass := BeginGfxRenderPass(cmd_buffer, "Kawase Blur Downsample", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_kawase_blur_downsample_pipeline[blur.downsample_texture.desc.pixel_format]);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);

    AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *blur.downsample_levels[level]);
}

KawaseBlurUpsample :: (cmd_buffer : *GfxCommandBuffer, blur : *KawaseBlur, level : int) {
    if IsNull(*g_kawase_blur_upsample_pipeline[blur.upsample_texture.desc.pixel_format]) {
        CreateKawaseBlurUpsamplePipeline(blur.upsample_texture.desc.pixel_format);
    }

    AddTextureBarrier(cmd_buffer, .Undefined, .ColorAttachment, *blur.upsample_levels[level]);

    w := blur.upsample_texture.desc.width;
    h := blur.upsample_texture.desc.height;
    for 0..level - 1 {
        w = Max(w / 2, 1);
        h = Max(h / 2, 1);
    }

    bindings := KawaseBlurBindingSet.{
        texture=.{sampler=*g_linear_clamp_sampler},
    };
    if level == blur.upsample_levels.count - 1 {
        bindings.texture.texture = *blur.downsample_levels[blur.downsample_levels.count - 1];
    } else {
        bindings.texture.texture = *blur.upsample_levels[level + 1];
    }

    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *blur.upsample_levels[level]);

    pass := BeginGfxRenderPass(cmd_buffer, "Kawase Blur Upsample", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_kawase_blur_upsample_pipeline[blur.upsample_texture.desc.pixel_format]);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);

    AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *blur.upsample_levels[level]);
}

RenderKawaseBlur :: (cmd_buffer : *GfxCommandBuffer, blur : *KawaseBlur, base_texture : *GfxTexture) {
    BeginGfxDebugMarker(cmd_buffer, "Kawase Blur");
    defer EndGfxDebugMarker(cmd_buffer);

    ProfileGPUZone(cmd_buffer, *g_gpu_profiler, "Kawase Blur");

    for i : 0..blur.downsample_levels.count - 1 {
        KawaseBlurDownsample(cmd_buffer, blur, base_texture, i);
    }

    for #v2 < i : 0..blur.upsample_levels.count - 1 {
        KawaseBlurUpsample(cmd_buffer, blur, i);
    }
}
