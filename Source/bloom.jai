// How does bloom work:
// 1- render the image onto a lower resolution image, filter the pixels so that
// dark areas don't contribute much and bright areas contribute a lot
// 2- downsample the image using a filter from mipmap level N to N+1, until the last mipmap level
// 3- progressively upsample the result and add the downsample of the same resolution
// The more downsample iterations there are the brighter the result is, so we divide the blend intensity by the number of
// iterations to keep consistent results

// See: Kawase blur filter

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
    texture_desc.usage = .Sampled | .Storage;

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

Bloom_Compute_Work_Group_Size :: 16;

GetNumComputeWorkGroupsForTexture :: (desc : GfxTextureAndViewDesc, mipmap_level : int, work_group_size : u32) -> x : u32, y : u32 {
    w, h := GetTextureMipSize(desc, mipmap_level);
    size_x := w / work_group_size + cast(u32, w % work_group_size != 0);
    size_y := h / work_group_size + cast(u32, h % work_group_size != 0);

    return size_x, size_y;
}

BloomComputeBindingSet :: struct {
    src_image : GfxBindingStorageImage; @Binding(0) @ComputeStage
    dst_image : GfxBindingStorageImage; @Binding(1) @ComputeStage
} @BindingSet

BloomUpsampleComputeBindingSet :: struct {
    previous_upsampled_image : GfxBindingStorageImage; @Binding(0) @ComputeStage
    same_size_downsampled_image : GfxBindingStorageImage; @Binding(1) @ComputeStage
    dst_image : GfxBindingStorageImage; @Binding(2) @ComputeStage
} @BindingSet

g_bloom_filter_compute_pipeline : GfxComputePipeline;
g_bloom_downsample_compute_pipeline : GfxComputePipeline;
g_bloom_upsample_compute_pipeline : GfxComputePipeline;

CreateBloomFilterComputePipeline :: () {
    desc : GfxComputePipelineDesc;
    desc.shader = GetComputeShader("bloom_filter");
    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.BloomComputeBindingSet,
    ];

    ok := CreateGfxComputePipeline(*g_bloom_filter_compute_pipeline, "Bloom Filter", desc);
    Assert(ok, "Could not create bloom filter compute pipeline");
}

CreateBloomDownsampleComputePipeline :: () {
    desc : GfxComputePipelineDesc;
    desc.shader = GetComputeShader("bloom_downsample");
    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.BloomComputeBindingSet,
    ];

    ok := CreateGfxComputePipeline(*g_bloom_downsample_compute_pipeline, "Bloom Downsample", desc);
    Assert(ok, "Could not create bloom downsample compute pipeline");
}

CreateBloomUpsampleComputePipeline :: () {
    desc : GfxComputePipelineDesc;
    desc.shader = GetComputeShader("bloom_upsample");
    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.BloomUpsampleComputeBindingSet,
    ];

    ok := CreateGfxComputePipeline(*g_bloom_upsample_compute_pipeline, "Bloom Upsample", desc);
    Assert(ok, "Could not create bloom upsample compute pipeline");
}

ComputeBloom :: (using ctx : *FrameRenderContext, color_texture : *GfxTexture) {
    BeginGfxDebugMarker(cmd_buffer, "Bloom");
    defer EndGfxDebugMarker(cmd_buffer);

    if IsNull(*g_bloom_filter_compute_pipeline) {
        CreateBloomFilterComputePipeline();
    }
    if IsNull(*g_bloom_downsample_compute_pipeline) {
        CreateBloomDownsampleComputePipeline();
    }
    if IsNull(*g_bloom_upsample_compute_pipeline) {
        CreateBloomUpsampleComputePipeline();
    }

    AddTextureBarriers(cmd_buffer, .Undefined, .General, .[*g_bloom_downsample_texture, *g_bloom_upsample_texture]);

    pass := BeginGfxComputePass(cmd_buffer, "Bloom Filter");
    {
        BindComputePipeline(*pass, *g_bloom_filter_compute_pipeline);

        bindings := BloomComputeBindingSet.{
            src_image=.{color_texture},
            dst_image=.{*g_bloom_downsample_levels[0]},
        };

        num_groups_x, num_groups_y := GetNumComputeWorkGroupsForTexture(g_bloom_downsample_texture.desc, 0, Bloom_Compute_Work_Group_Size);

        binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);
        BindComputeBindingSet(*pass, 1, *binding_set);
        Dispatch(*pass, num_groups_x, num_groups_y, num_groups_z=1);
    }
    EndGfxComputePass(*pass);

    pass = BeginGfxComputePass(cmd_buffer, "Bloom Downsample");
    {
        BindComputePipeline(*pass, *g_bloom_downsample_compute_pipeline);

        for i : 0..Bloom_Num_Downsample_Passes - 1 {
            bindings := BloomComputeBindingSet.{
                src_image=.{*g_bloom_downsample_levels[i]},
                dst_image=.{*g_bloom_downsample_levels[i + 1]},
            };

            binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);
            BindComputeBindingSet(*pass, 1, *binding_set);

            num_groups_x, num_groups_y := GetNumComputeWorkGroupsForTexture(g_bloom_downsample_texture.desc, i + 1, Bloom_Compute_Work_Group_Size);

            Dispatch(*pass, num_groups_x, num_groups_y, num_groups_z=1);
            AddBarrier(cmd_buffer);
        }
    }
    EndGfxComputePass(*pass);

    pass = BeginGfxComputePass(cmd_buffer, "Bloom Upsample");
    {
        BindComputePipeline(*pass, *g_bloom_upsample_compute_pipeline);

        for #v2 < i : 0..Bloom_Num_Downsample_Passes - 1 {
            bindings := BloomUpsampleComputeBindingSet.{
                same_size_downsampled_image=.{*g_bloom_downsample_levels[i]},
                dst_image=.{*g_bloom_upsample_levels[i]},
            };

            if i == g_bloom_upsample_levels.count - 1 {
                bindings.previous_upsampled_image = .{*g_bloom_downsample_levels[i + 1]};
            } else {
                bindings.previous_upsampled_image = .{*g_bloom_upsample_levels[i + 1]};
            }

            binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);
            BindComputeBindingSet(*pass, 1, *binding_set);

            num_groups_x, num_groups_y := GetNumComputeWorkGroupsForTexture(g_bloom_upsample_texture.desc, i, Bloom_Compute_Work_Group_Size);

            Dispatch(*pass, num_groups_x, num_groups_y, num_groups_z=1);
            AddBarrier(cmd_buffer);
        }
    }
    EndGfxComputePass(*pass);

    AddTextureBarrier(cmd_buffer, .General, .ShaderReadOnly, GetFinalBloomTexture());
}
