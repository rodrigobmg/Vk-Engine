#load "mesh.jai";
#load "texture2d.jai";
#load "shader.jai";
#load "material.jai";
#load "mesh_buffer.jai";
#load "allocator.jai";
#load "binding_set_allocator.jai";

#load "forward_pass.jai";
#load "post_processing.jai";

#placeholder Shader_Binding_Set_Types;

IsInShaderBindingSetTypesArray :: (type : Type) -> bool {
    return ArrayFindFirst(Shader_Binding_Set_Types, type) != -1;
}

g_binding_set_layouts : struct {
    #insert -> string {
        builder : StringBuilder;

        for Shader_Binding_Set_Types {
            Appendln(*builder, "%1 : GfxBindingSetLayout;", it);
        }

        return StringBuilderBuild(*builder);
    }
}

CreateAllBindingSetLayouts :: () {
    #insert -> string {
        builder : StringBuilder;

        for Shader_Binding_Set_Types {
            Appendln(*builder, "g_binding_set_layouts.%1 = CreateGfxBindingSetLayout(%1);", it);
            Appendln(*builder, "Assert(!IsNull(*g_binding_set_layouts.%1), \"Could not create shader binding set layout for type %1\");", it);
        }

        return StringBuilderBuild(*builder);
    }
}

DestroyAllBindingSetLayouts :: () {
    #insert -> string {
        builder : StringBuilder;

        for Shader_Binding_Set_Types {
            Appendln(*builder, "DestroyGfxBindingSetLayout(*g_binding_set_layouts.%1);", it);
        }

        return StringBuilderBuild(*builder);
    }
}

g_final_texture : GfxTexture;
g_color_texture : GfxTexture;
g_depth_texture : GfxTexture;

CreateRenderTargets :: () {
    WaitForGPUIdle();

    if !IsNull(*g_final_texture) {
        DestroyGfxTexture(*g_final_texture);
    }

    if !IsNull(*g_color_texture) {
        DestroyGfxTexture(*g_color_texture);
    }

    if !IsNull(*g_depth_texture) {
        DestroyGfxTexture(*g_depth_texture);
    }

    w, h : s32;
    SDL_GetWindowSizeInPixels(g_window, *w, *h);

    texture_desc : GfxTextureDesc;
    texture_desc.type = .Texture2D;
    texture_desc.width = xx w;
    texture_desc.height = xx h;

    texture_desc.pixel_format = .RGBA8UNorm;
    texture_desc.usage = .ColorAttachment | .TransferSrc;

    g_final_texture = CreateGfxTexture("Final", texture_desc);
    Assert(!IsNull(*g_final_texture), "Could not create final texture");

    texture_desc.pixel_format = .RGBA16Float;
    texture_desc.usage = .ColorAttachment | .TransferSrc | .Sampled;

    g_color_texture = CreateGfxTexture("Color", texture_desc);
    Assert(!IsNull(*g_color_texture), "Could not create color texture");

    texture_desc.pixel_format = .Depth32Float;
    texture_desc.usage = .DepthStencilAttachment;

    g_depth_texture = CreateGfxTexture("Depth", texture_desc);
    Assert(!IsNull(*g_depth_texture), "Could not create depth texture");
}

DestroyRenderTargets :: () {
    DestroyGfxTexture(*g_final_texture);
    DestroyGfxTexture(*g_color_texture);
    DestroyGfxTexture(*g_depth_texture);
}

MeshEntity :: struct {
    #as using _ : Entity; @Serialize(1)

    mesh : *Asset(Mesh); @Serialize(2)
    material : *Asset(Material); @Serialize(3)
    cast_shadows := true; @Serialize(4)
} @Entity

DirectionalLightEntity :: struct {
    #as using _ : Entity; @Serialize(1)

    color : Vec3f; @Serialize(2)
    intensity : float; @Serialize(3)
    cast_shadows : bool; @Serialize(4)
} @Entity

PointLightEntity :: struct {
    #as using _ : Entity; @Serialize(1)

    color : Vec3f; @Serialize(2)
    intensity : float; @Serialize(3)
    cast_shadows : bool; @Serialize(4)
} @Entity

EmptyBindingSet :: struct {
} @BindingSet

FrameBindingSet :: struct {
    frame_info : GfxBindingUniformBuffer; @Binding(0) @VertexStage @FragmentStage
    directional_lights : GfxBindingStorageBuffer; @Binding(1) @FragmentStage @AllowNull
    point_lights : GfxBindingStorageBuffer; @Binding(2) @FragmentStage @AllowNull
} @BindingSet

FrameInfo :: struct {
    time : float;
    window_pixel_size : Vec2f;
    num_directional_lights : u32;
    num_point_lights : u32;
    camera_position : Vec3f;
    camera_view : Mat4f;
    camera_projection : Mat4f;
} @ShaderType

DirectionalLight :: struct {
    direction : Vec3f;
    color : Vec3f;
    intensity : float;
} @ShaderType

PointLight :: struct {
    position : Vec3f;
    color : Vec3f;
    intensity : float;
} @ShaderType

FrameRenderContext :: struct {
    world : *World;
    cmd_buffer : *GfxCommandBuffer;
    frame_binding_set : GfxBindingSet;
}

g_mesh_buffer : MeshBuffer;

RenderFrame :: (world : *World, camera : *Camera) {
    w, h : s32;
    SDL_GetWindowSizeInPixels(g_window, *w, *h);

    BeginFrame();

    ResetFrameDataAllocator();
    ResetBindingSetAllocators();

    ClearMeshBuffer(*g_mesh_buffer);

    for * world.MeshEntity_storage {
        if !it.mesh || !it.material {
            continue;
        }

        if IsNull(*it.mesh.vertex_buffer) || IsNull(*it.mesh.index_buffer) {
            continue;
        }

        position := TranslationVector(it.world_transform);
        depth := TransformPoint(camera.view, position).z;
        key := MakeMeshBufferKey(*it.mesh.vertex_buffer, *it.mesh.index_buffer, it.material, depth);
        PushMesh(*g_mesh_buffer, key, it.guid, *it.mesh.vertex_buffer, *it.mesh.index_buffer, it.mesh.vertex_count, it.mesh.index_count, it.world_transform, it.material);
    }

    SortMeshBuffer(*g_mesh_buffer);
    AllocDrawData(*g_mesh_buffer);

    ctx : FrameRenderContext;
    ctx.world = world;

    num_directional_lights : u64 = xx world.DirectionalLightEntity_storage.count;
    directional_lights_size := GLSLStd430Size(DirectionalLight) * num_directional_lights;
    directional_lights_offset, directional_lights_ptr := AllocFrameData(directional_lights_size);
    for world.DirectionalLightEntity_storage {
        directional_light := DirectionalLight.{
            direction=ForwardVector(it.world_transform),
            color=it.color,
            intensity=it.intensity,
        };
        directional_lights_ptr += PackToGLSLStd(directional_light, directional_lights_ptr, .Std430);
    }

    num_point_lights : u64 = xx world.PointLightEntity_storage.count;
    point_lights_size := GLSLStd430Size(PointLight) * num_point_lights;
    point_lights_offset, point_lights_ptr := AllocFrameData(point_lights_size);
    for world.PointLightEntity_storage {
        point_light := PointLight.{
            position=TranslationVector(it.world_transform),
            color=it.color,
            intensity=it.intensity,
        };
        point_lights_ptr += PackToGLSLStd(point_light, point_lights_ptr, .Std430);
    }

    frame_info := FrameInfo.{
        time=xx Basic.to_float64_seconds(Basic.current_time_monotonic()),
        window_pixel_size=.{xx w, xx h},
        num_point_lights=xx num_point_lights,
        num_directional_lights=xx num_directional_lights,
        camera_position=camera.position,
        camera_view=camera.view,
        camera_projection=camera.projection,
    };
    frame_info_offset, frame_info_size := AllocAndPackUniformFrameData(frame_info);

    frame_binding_set := FrameBindingSet.{
        frame_info=.{buffer=FrameDataBuffer(), offset=xx frame_info_offset, size=xx frame_info_size},
        directional_lights=.{buffer=FrameDataBuffer(), offset=xx directional_lights_offset, size=xx directional_lights_size},
        point_lights=.{buffer=FrameDataBuffer(), offset=xx point_lights_offset, size=xx point_lights_size},
    };

    ctx.frame_binding_set = CreateGfxBindingSet(GlobalBindingSetAllocator(), frame_binding_set);

    cmd_buffer := CreateGfxCommandBuffer("Main");
    ctx.cmd_buffer = *cmd_buffer;

    PerformPendingUploads(*cmd_buffer);

    AddTextureBarrier(*cmd_buffer, .Undefined, .ColorAttachment, *g_color_texture);
    AddTextureBarrier(*cmd_buffer, .Undefined, .DepthStencilAttachment, *g_depth_texture);

    BindGraphicsBindingSet(*cmd_buffer, *g_dummy_frame_pipeline_layout, 0, *ctx.frame_binding_set);

    ForwardPass(*ctx, *g_mesh_buffer);

    AddTextureBarrier(*cmd_buffer, .ColorAttachment, .ShaderReadOnly, *g_color_texture);
    AddTextureBarrier(*cmd_buffer, .Undefined, .ColorAttachment, *g_final_texture);

    PostProcessingPass(*ctx);

    AddTextureBarrier(*cmd_buffer, .ColorAttachment, .TransferSrc, *g_final_texture);

    SubmitGfxCommandBuffer(*cmd_buffer);

    SubmitFrame(*g_final_texture);
}

// Pipeline layout used to bind binding sets outside of any render pass at the beginning of the frame
g_dummy_frame_pipeline_layout : GfxPipelineLayout;

g_material_texture_sampler : GfxSampler;

CreateAllPipelines :: () {
    sampler_desc : GfxSamplerDesc;
    sampler_desc.min_filter = .Linear;
    sampler_desc.mag_filter = .Linear;
    sampler_desc.mipmap_filter = .Linear;
    sampler_desc.u_address_mode = .Repeat;
    sampler_desc.v_address_mode = .Repeat;

    g_material_texture_sampler = CreateGfxSampler("Material Texture", sampler_desc);
    Assert(!IsNull(*g_material_texture_sampler), "Could not create material texture sampler");

    frame_layout_desc : GfxPipelineLayoutDesc;
    frame_layout_desc.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
    ];
    g_dummy_frame_pipeline_layout = CreateGfxPipelineLayout("Dummy Frame", frame_layout_desc);
    Assert(!IsNull(*g_dummy_frame_pipeline_layout), "Could not create dummy frame pipeline layout");

    CreateForwardPassPipeline();
    CreatePostProcessingPassPipeline();
}

DestroyAllPipelines :: () {
    DestroyGfxPipelineLayout(*g_dummy_frame_pipeline_layout);

    DestroyGfxGraphicsPipeline(*g_forward_pass_pipeline);

    DestroyGfxGraphicsPipeline(*g_post_processing_pass_pipeline);
    DestroyGfxSampler(*g_post_processing_sampler);

    DestroyGfxSampler(*g_material_texture_sampler);
}
