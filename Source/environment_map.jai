Num_Environment_Map_Levels :: 6;

EnvironmentMap :: struct {
    base_texture : *Asset(Texture2D);
    irradiance_map : GfxTexture;
    environment_map : GfxTexture;
    environment_levels : [Num_Environment_Map_Levels]GfxTexture;
} @Asset

LoadEnvironmentMapFromMemory :: (map : *EnvironmentMap, data : []u8, name : string) -> bool {
    map.base_texture = LoadAsset(Texture2D, name);
    if !map.base_texture {
        return false;
    }

    desc : GfxTextureDesc;
    desc.type = .Texture2D;
    desc.pixel_format = .RGBA8UNorm;
    desc.usage = .Sampled | .ColorAttachment;
    desc.width = map.base_texture.width / 4;
    desc.height = map.base_texture.height / 4;

    map.irradiance_map = CreateGfxTexture(TPrint("% irradiance", name), desc);
    if IsNull(*map.irradiance_map) {
        return false;
    }

    desc.width = map.base_texture.width / 2;
    desc.height = map.base_texture.height / 2;
    desc.num_mipmap_levels = Num_Environment_Map_Levels;

    map.environment_map = CreateGfxTexture(TPrint("% environment", name), desc);
    if IsNull(*map.environment_map) {
        return false;
    }

    for i : 0..Num_Environment_Map_Levels - 1 {
        view_desc : GfxTextureViewDesc;
        view_desc.type = desc.type;
        view_desc.pixel_format = desc.pixel_format;
        view_desc.first_mipmap_level = xx i;

        map.environment_levels[i] = CreateGfxTextureView(TPrint("% environment %", name, i), view_desc, *map.environment_map);
        if IsNull(*map.environment_map) {
            return false;
        }
    }

    ArrayPush(*g_environment_maps_to_generate, map);

    return true;
}

DestroyEnvironmentMap :: (map : *EnvironmentMap) {
    for g_environment_maps_to_generate {
        if it == map {
            remove it;
            break;
        }
    }

    RemoveRef(map.base_texture);

    for * map.environment_levels {
        DestroyGfxTextureView(it);
    }

    DestroyGfxTexture(*map.environment_map);

    DestroyGfxTexture(*map.irradiance_map);
}

g_environment_maps_to_generate : [..]*EnvironmentMap;

g_irradiance_map_pipeline : GfxGraphicsPipeline;
g_environment_map_pipeline : GfxGraphicsPipeline;

EnvironmentMapBindingSet :: struct {
    texture : GfxBindingCombinedTextureSampler; @Binding(0) @FragmentStage
} @BindingSet

CreateIrradianceMapPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("screen_effect");
    desc.fragment_shader = GetFragmentShader("irradiance_map");
    AddColorAttachment(*desc, .RGBA8UNorm);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.EnvironmentMapBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_irradiance_map_pipeline, "Irradiance Map", desc);
    Assert(ok, "Could not create irradiance map pipeline");
}

CreateEnvironmentMapPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("environment_map");
    desc.fragment_shader = GetFragmentShader("environment_map");
    AddColorAttachment(*desc, .RGBA8UNorm);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.EnvironmentMapBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_environment_map_pipeline, "Environment Map", desc);
    Assert(ok, "Could not create environment map pipeline");
}

GenerateEnvironmentMaps :: (cmd_buffer : *GfxCommandBuffer) {
    defer ArrayClear(*g_environment_maps_to_generate);

    BeginGfxDebugMarker(cmd_buffer, "Generate Environment Maps");
    defer EndGfxDebugMarker(cmd_buffer);

    for g_environment_maps_to_generate {
        bindings := EnvironmentMapBindingSet.{
            texture=.{texture=it.base_texture, sampler=*g_skybox_sampler},
        };
        binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

        AddTextureBarriers(cmd_buffer, .Undefined, .ColorAttachment, .[*it.irradiance_map, *it.environment_map]);

        pass_desc : GfxRenderPassDesc;
        AddColorAttachment(*pass_desc, *it.irradiance_map, load_op=.DontCare);

        pass := BeginGfxRenderPass(cmd_buffer, "Generate Irradiance Map", pass_desc);
        {
            BindGraphicsPipeline(*pass, *g_irradiance_map_pipeline);
            SetViewport(*pass, .{width=xx it.irradiance_map.desc.width, height=xx it.irradiance_map.desc.height});
            SetScissor(*pass, .{w=xx it.irradiance_map.desc.width, h=xx it.irradiance_map.desc.height});

            BindGraphicsBindingSet(*pass, 1, *binding_set);

            Draw(*pass, vertex_count=6, instance_count=1);
        }
        EndGfxRenderPass(*pass);

        w := it.environment_map.desc.width;
        h := it.environment_map.desc.height;
        for level : 0..Num_Environment_Map_Levels - 1 {
            source_texture := ifx level == 0
                then *it.base_texture.texture
                else *it.environment_levels[level - 1];
            bindings := EnvironmentMapBindingSet.{
                texture=.{texture=source_texture, sampler=*g_skybox_sampler},
            };
            binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

            pass_desc : GfxRenderPassDesc;
            AddColorAttachment(*pass_desc, *it.environment_levels[level], load_op=.DontCare);

            pass := BeginGfxRenderPass(cmd_buffer, TPrint("Generate Environment Map %", level), pass_desc);
            {
                BindGraphicsPipeline(*pass, *g_environment_map_pipeline);
                SetViewport(*pass, .{width=xx w, height=xx h});
                SetScissor(*pass, .{w=xx w, h=xx h});

                BindGraphicsBindingSet(*pass, 1, *binding_set);

                Draw(*pass, vertex_count=6, instance_count=1, base_instance=xx level);
            }
            EndGfxRenderPass(*pass);

            AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *it.environment_levels[level]);

            w /= 2;
            h /= 2;
        }

        AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *it.irradiance_map);
    }
}
