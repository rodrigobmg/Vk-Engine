// How does bloom work:
// 1- render the image onto a lower resolution image, filter the pixels so that
// dark areas don't contribute much and bright areas contribute a lot
// 2- downsample the image using a filter from mipchain N to N+1, until the last
// 3- combined mipchain N+1 and mipchain N into

BloomParams :: struct {
    resolution_factor := Bloom_Resolution_Factor;
    brightness_threshold := 1.2;
} @ShaderType

Bloom_Resolution_Factor :: 0.75;
Bloom_Num_Downsample_Passes :: 6;

g_bloom_downsample_texture : GfxTexture;
g_bloom_downsample_levels : [Bloom_Num_Downsample_Passes + 1]GfxTexture;
g_bloom_upsample_texture : GfxTexture;
g_bloom_upsample_levels : [Bloom_Num_Downsample_Passes]GfxTexture;

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

    for i : 1..Bloom_Num_Downsample_Passes {
        BloomDownsamplePass(ctx, i);
    }

    // for < i : 0..Bloom_Num_Downsample_Passes - 1 {
    //     BloomUpsamplePass(ctx, i);
    // }
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

    AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *g_bloom_downsample_levels[level - 1]);
    AddTextureBarrier(cmd_buffer, .Undefined, .ColorAttachment, *g_bloom_downsample_levels[level]);

    bindings := BloomFilterBindingSet.{
        texture=.{texture=*g_bloom_downsample_levels[level - 1], sampler=*g_linear_clamp_sampler},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *g_bloom_downsample_levels[level]);

    w := g_bloom_downsample_texture.desc.width;
    h := g_bloom_downsample_texture.desc.height;
    for 1..level {
        w /= 2;
        h /= 2;
        w = Max(w, 1);
        h = Max(h, 1);
    }

    pass := BeginGfxRenderPass(cmd_buffer, "Bloom Downsample", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_bloom_filter_pipeline);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        Draw(*pass, vertex_count=6, instance_count=1);
    }
    EndGfxRenderPass(*pass);
}