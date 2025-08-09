// How does bloom work:
// 1- render the image onto a lower resolution image, filter the pixels so that
// dark areas don't contribute much and bright areas contribute a lot
// 2- downsample the image using a filter from mipmap level N to N+1, until the last mipmap level
// 3- progressively upsample the result and add the downsample of the same resolution
// The more downsample iterations there are the brighter the result is, so we divide the blend intensity by the number of
// iterations to keep consistent results

// See: Kawase blur filter

// @Todo:
// Additionally, we can apply a single pass gaussian blur to each downsample level to get less fireflies and an overall more
// qualitative result

BloomParams :: struct {
    resolution_factor := Bloom_Resolution_Factor;
    brightness_threshold := 1.4; @ShowInInspector @FloatRange(0,10) @Step(0.01)
    brightness_soft_threshold := 0.5; @ShowInInspector @FloatRange(0,1) @Step(0.01)
    blend_intensity := 0.5; @ShowInInspector @FloatRange(0,10) @Step(0.01)
    filter_radius := 1.0; @ShowInInspector @FloatRange(0,10) @Step(0.01)
} @ShaderType

g_bloom_params : BloomParams;

Bloom_Resolution_Factor :: 0.75;
Bloom_Num_Downsample_Passes :: 7;

g_bloom_downsample_texture : GfxTexture;
g_bloom_downsample_levels : [Bloom_Num_Downsample_Passes + 1]GfxTexture;
g_bloom_upsample_texture : GfxTexture;
g_bloom_upsample_levels : [Bloom_Num_Downsample_Passes]GfxTexture;

GetFinalBloomTexture :: inline () -> *GfxTexture {
    return *g_bloom_upsample_levels[0];
}

CreateBloomTextures :: () {
    if !IsNull(*g_bloom_downsample_texture) {
        for * g_bloom_downsample_levels {
            DestroyGfxTextureView(it);
        }

        DestroyGfxTexture(*g_bloom_downsample_texture);
    }

    if !IsNull(*g_bloom_upsample_texture) {
        for * g_bloom_upsample_levels {
            DestroyGfxTextureView(it);
        }

        DestroyGfxTexture(*g_bloom_upsample_texture);
    }

    w, h := GetWindowPixelSize(g_window);
    w = Max(cast(s32, w * Bloom_Resolution_Factor), 1);
    h = Max(cast(s32, h * Bloom_Resolution_Factor), 1);

    texture_desc : GfxTextureDesc;
    texture_desc.type = .Texture2D;
    texture_desc.width = xx w;
    texture_desc.height = xx h;
    texture_desc.num_mipmap_levels = Bloom_Num_Downsample_Passes + 1;

    texture_desc.pixel_format = .RGBA16Float;
    texture_desc.usage = .ColorAttachment | .Sampled;

    g_bloom_downsample_texture = CreateGfxTexture("Bloom Downsample", texture_desc);
    Assert(!IsNull(*g_bloom_downsample_texture), "Could not create bloom downsample texture");

    for * g_bloom_downsample_levels {
        view_desc : GfxTextureViewDesc;
        view_desc.type = .Texture2D;
        view_desc.pixel_format = .RGBA16Float;
        view_desc.first_mipmap_level = xx it_index;
        view_desc.num_mipmap_levels = 1;

        it.* = CreateGfxTextureView(TPrint("Bloom Downsample %", it_index), view_desc, *g_bloom_downsample_texture);
        Assert(!IsNull(it), "Could not create bloom downsample texture view for level %", it_index);
    }

    texture_desc.num_mipmap_levels = Bloom_Num_Downsample_Passes;

    g_bloom_upsample_texture = CreateGfxTexture("Bloom Upsample", texture_desc);
    Assert(!IsNull(*g_bloom_downsample_texture), "Could not create bloom upsample texture");

    for * g_bloom_upsample_levels {
        view_desc : GfxTextureViewDesc;
        view_desc.type = .Texture2D;
        view_desc.pixel_format = .RGBA16Float;
        view_desc.first_mipmap_level = xx it_index;
        view_desc.num_mipmap_levels = 1;

        it.* = CreateGfxTextureView(TPrint("Bloom Upsample %", it_index), view_desc, *g_bloom_upsample_texture);
        Assert(!IsNull(it), "Could not create bloom upsample texture view for level %", it_index);
    }
}

DestroyBloomTextures :: () {
    for * g_bloom_downsample_levels {
        DestroyGfxTextureView(it);
    }

    DestroyGfxTexture(*g_bloom_downsample_texture);

    for * g_bloom_upsample_levels {
        DestroyGfxTextureView(it);
    }

    DestroyGfxTexture(*g_bloom_upsample_texture);
}

RenderBloom :: (using ctx : *FrameRenderContext, color_texture : *GfxTexture) {
    BeginGfxDebugMarker(cmd_buffer, "Bloom");
    defer EndGfxDebugMarker(cmd_buffer);

    BloomFilterPass(ctx, color_texture);

    AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *g_bloom_downsample_levels[0]);

    for i : 1..Bloom_Num_Downsample_Passes {
        BloomDownsamplePass(ctx, i);

        AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *g_bloom_downsample_levels[i]);
    }

    for #v2 < i : 0..Bloom_Num_Downsample_Passes - 1 {
        BloomUpsamplePass(ctx, i);

        AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *g_bloom_upsample_levels[i]);
    }
}

BloomFilterBindingSet :: struct {
    texture : GfxBindingCombinedTextureSampler; @Binding(0) @FragmentStage
} @BindingSet

g_bloom_filter_pipeline : GfxGraphicsPipeline;

CreateBloomFilterPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("screen_effect");
    desc.fragment_shader = GetFragmentShader("bloom_filter");
    AddColorAttachment(*desc, g_color_texture.desc.pixel_format);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.BloomFilterBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_bloom_filter_pipeline, "Bloom Filter", desc);
    Assert(ok, "Could not create bloom filter pipeline");
}

BloomFilterPass :: (using ctx : *FrameRenderContext, color_texture : *GfxTexture) {
    if IsNull(*g_bloom_filter_pipeline) {
        CreateBloomFilterPipeline();
    }

    AddTextureBarrier(cmd_buffer, .Undefined, .ColorAttachment, *g_bloom_downsample_levels[0]);

    bindings := BloomFilterBindingSet.{
        texture=.{texture=color_texture, sampler=*g_linear_clamp_sampler},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_bloom_downsample_levels[0]);

    pass := BeginGfxRenderPass(cmd_buffer, "Bloom Filter", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_bloom_filter_pipeline);
        SetViewport(*pass, .{width=xx g_bloom_downsample_texture.desc.width, height=xx g_bloom_downsample_texture.desc.height});
        SetScissor(*pass, .{w=xx g_bloom_downsample_texture.desc.width, h=xx g_bloom_downsample_texture.desc.height});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);
}

g_bloom_downsample_pipeline : GfxGraphicsPipeline;

CreateBloomDownsamplePipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("screen_effect");
    desc.fragment_shader = GetFragmentShader("bloom_downsample");
    AddColorAttachment(*desc, g_color_texture.desc.pixel_format);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.BloomFilterBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_bloom_downsample_pipeline, "Bloom Downsample", desc);
    Assert(ok, "Could not create bloom downsample pipeline");
}

BloomDownsamplePass :: (using ctx : *FrameRenderContext, level : int) {
    if IsNull(*g_bloom_downsample_pipeline) {
        CreateBloomDownsamplePipeline();
    }

    AddTextureBarrier(cmd_buffer, .Undefined, .ColorAttachment, *g_bloom_downsample_levels[level]);

    w := g_bloom_downsample_texture.desc.width;
    h := g_bloom_downsample_texture.desc.height;
    for 0..level - 1 {
        w = Max(w / 2, 1);
        h = Max(h / 2, 1);
    }

    bindings := BloomFilterBindingSet.{
        texture=.{texture=*g_bloom_downsample_levels[level - 1], sampler=*g_linear_clamp_sampler},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_bloom_downsample_levels[level]);

    pass := BeginGfxRenderPass(cmd_buffer, "Bloom Downsample", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_bloom_downsample_pipeline);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);
}

BloomUpsampleBindingSet :: struct {
    texture : GfxBindingCombinedTextureSampler; @Binding(0) @FragmentStage
    previous_upsampled_texture : GfxBindingCombinedTextureSampler; @Binding(1) @FragmentStage
} @BindingSet

g_bloom_upsample_pipeline : GfxGraphicsPipeline;

CreateBloomUpsamplePipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("screen_effect");
    desc.fragment_shader = GetFragmentShader("bloom_upsample");
    AddColorAttachment(*desc, g_color_texture.desc.pixel_format);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.BloomUpsampleBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_bloom_upsample_pipeline, "Bloom Upsample", desc);
    Assert(ok, "Could not create bloom upsample pipeline");
}

BloomUpsamplePass :: (using ctx : *FrameRenderContext, level : int) {
    if IsNull(*g_bloom_upsample_pipeline) {
        CreateBloomUpsamplePipeline();
    }

    AddTextureBarrier(cmd_buffer, .Undefined, .ColorAttachment, *g_bloom_upsample_levels[level]);

    w := g_bloom_upsample_texture.desc.width;
    h := g_bloom_upsample_texture.desc.height;
    for 0..level - 1 {
        w = Max(w / 2, 1);
        h = Max(h / 2, 1);
    }

    bindings := BloomUpsampleBindingSet.{
        texture=.{texture=*g_bloom_downsample_levels[level], sampler=*g_linear_clamp_sampler},
    };

    if level == g_bloom_upsample_levels.count - 1 {
        bindings.previous_upsampled_texture=.{texture=*g_bloom_downsample_levels[level + 1], sampler=*g_linear_clamp_sampler};
    } else {
        bindings.previous_upsampled_texture=.{texture=*g_bloom_upsample_levels[level + 1], sampler=*g_linear_clamp_sampler};
    }

    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_bloom_upsample_levels[level]);

    pass := BeginGfxRenderPass(cmd_buffer, "Bloom Upsample", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_bloom_upsample_pipeline);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);
}
