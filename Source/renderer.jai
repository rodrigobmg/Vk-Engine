#load "mesh.jai";
#load "texture2d.jai";
#load "shader.jai";
#load "material.jai";
#load "mesh_buffer.jai";
#load "allocator.jai";
#load "binding_set_allocator.jai";

#load "forward_pass.jai";
#load "post_processing.jai";
#load "shadow_map.jai";

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
    aabb : AABB;
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

Max_Viewpoints :: 4;

Viewpoint :: struct {
    position : Vec3f;
    direction : Vec3f;
    right : Vec3f;
    up : Vec3f;
    transform : Mat4f;
    view : Mat4f;
    projection : Mat4f;
    view_projection : Mat4f;
} @ShaderType

FrameRenderContext :: struct {
    world : *World;
    cmd_buffer : *GfxCommandBuffer;
    frame_binding_set : GfxBindingSet;
}

g_mesh_buffer : MeshBuffer;
g_shadow_map : ShadowMap;

RenderFrame :: (world : *World, camera : *Camera) {
    w, h : s32;
    SDL_GetWindowSizeInPixels(g_window, *w, *h);

    BeginFrame();

    ResetFrameDataAllocator();
    ResetBindingSetAllocators();

    ClearMeshBuffer(*g_mesh_buffer);

    frustum := MakePerspectiveFrustum(camera.transform, camera.fov_in_degrees, w / cast(float, h), camera.z_near, camera.z_far);
    for * world.MeshEntity_storage {
        if !it.mesh || !it.material {
            continue;
        }

        if IsNull(*it.mesh.vertex_buffer) || IsNull(*it.mesh.index_buffer) {
            continue;
        }

        aabb := GetTransformedAABB(it.world_transform, it.mesh.static_bounds);
        if !AABBIsInFrustum(aabb, frustum) {
            continue;
        }

        position := TranslationVector(it.world_transform);
        depth := TransformPoint(camera.view, position).z;
        key := MakeMeshBufferKey(*it.mesh.vertex_buffer, *it.mesh.index_buffer, it.material, depth);
        PushMesh(*g_mesh_buffer, key, it.guid, *it.mesh.vertex_buffer, *it.mesh.index_buffer, it.mesh.vertex_count, it.mesh.index_count, it.world_transform, it.material);
    }

    SortMeshBuffer(*g_mesh_buffer);
    AllocDrawData(*g_mesh_buffer);

    PopulateShadowMapMeshBuffer(world, *g_shadow_map, camera.transform);

    ctx : FrameRenderContext;
    ctx.world = world;

    cmd_buffer := CreateGfxCommandBuffer("Main");
    ctx.cmd_buffer = *cmd_buffer;

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
    };
    frame_info_offset, frame_info_size := AllocAndPackUniformFrameData(frame_info);

    frame_binding_set := FrameBindingSet.{
        frame_info=.{buffer=FrameDataBuffer(), offset=xx frame_info_offset, size=xx frame_info_size},
        directional_lights=.{buffer=FrameDataBuffer(), offset=xx directional_lights_offset, size=xx directional_lights_size},
        point_lights=.{buffer=FrameDataBuffer(), offset=xx point_lights_offset, size=xx point_lights_size},
    };

    ctx.frame_binding_set = CreateGfxBindingSet(GlobalBindingSetAllocator(), frame_binding_set);

    PerformPendingUploads(*cmd_buffer);

    AddTextureBarrier(*cmd_buffer, .Undefined, .ColorAttachment, *g_color_texture);
    AddTextureBarrier(*cmd_buffer, .Undefined, .DepthStencilAttachment, *g_depth_texture);

    BindGraphicsBindingSet(*cmd_buffer, *g_dummy_frame_pipeline_layout, 0, *ctx.frame_binding_set);

    ForwardPass(*ctx, camera, *g_mesh_buffer);

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

    CreateForwardPipeline();
    CreatePostProcessingPipeline();
    CreateShadowMapPipeline();
}

DestroyAllPipelines :: () {
    DestroyGfxPipelineLayout(*g_dummy_frame_pipeline_layout);

    DestroyGfxGraphicsPipeline(*g_forward_pipeline);

    DestroyGfxGraphicsPipeline(*g_post_processing_pipeline);
    DestroyGfxSampler(*g_post_processing_sampler);

    DestroyGfxGraphicsPipeline(*g_shadow_map_pipeline);

    DestroyGfxSampler(*g_material_texture_sampler);
}

Plane :: struct {
    origin : Vec3f;
    normal : Vec3f;
}

MakePlane :: inline (origin : Vec3f, normal : Vec3f) -> Plane {
    return .{origin, Normalized(normal)};
}

SignedDistanceToPlane :: inline (point : Vec3f, plane : Plane) -> float {
    return Dot(plane.normal, point) - Dot(plane.normal, plane.origin);
}

AABB :: struct {
    center : Vec3f;
    half_extents : Vec3f;
}

Frustum :: struct {
    far_plane, near_plane : Plane;
    left_plane, right_plane : Plane;
    top_plane, bottom_plane : Plane;

    #place far_plane;
    planes : [6]Plane;
}

AABBIsInFrontOrOnPlane :: (aabb : AABB, plane : Plane) -> bool {
    r := aabb.half_extents.x * Abs(plane.normal.x)
        + aabb.half_extents.y * Abs(plane.normal.y)
        + aabb.half_extents.z * Abs(plane.normal.z);

    dist_to_plane := SignedDistanceToPlane(aabb.center, plane);

    return dist_to_plane > 0 || Abs(dist_to_plane) <= r;
}

AABBIsInFrustum :: inline (aabb : AABB, using frustum : Frustum) -> bool {
    return AABBIsInFrontOrOnPlane(aabb, left_plane)
        && AABBIsInFrontOrOnPlane(aabb, right_plane)
        && AABBIsInFrontOrOnPlane(aabb, top_plane)
        && AABBIsInFrontOrOnPlane(aabb, bottom_plane)
        && AABBIsInFrontOrOnPlane(aabb, near_plane)
        && AABBIsInFrontOrOnPlane(aabb, far_plane);
}

PointIsInFrustum :: inline (point : Vec3f, using frustum : Frustum) -> bool {
    return SignedDistanceToPlane(point, left_plane) >= 0
        && SignedDistanceToPlane(point, right_plane) >= 0
        && SignedDistanceToPlane(point, top_plane) >= 0
        && SignedDistanceToPlane(point, bottom_plane) >= 0
        && SignedDistanceToPlane(point, near_plane) >= 0
        && SignedDistanceToPlane(point, far_plane) >= 0;
}

MakePerspectiveFrustum :: (transform : Mat4f, fov_in_degrees : float, aspect_ratio : float, z_near : float, z_far : float) -> Frustum {
    inv_aspect_ratio := 1 / aspect_ratio;
    if !Math.is_finite(inv_aspect_ratio) {
        return .{};
    }

    half_near_v_side := z_near * Tan(ToRads(fov_in_degrees * 0.5));
    half_near_h_side := half_near_v_side * aspect_ratio;
    half_near_h_hypothenuse := Sqrt(z_near * z_near + half_near_h_side * half_near_h_side);
    half_near_v_hypothenuse := Sqrt(z_near * z_near + half_near_v_side * half_near_v_side);

    half_far_v_side := z_far * Tan(ToRads(fov_in_degrees * 0.5));
    half_far_h_side := half_far_v_side * aspect_ratio;
    half_far_h_hypothenuse := Sqrt(z_far * z_far + half_far_h_side * half_far_h_side);
    half_far_v_hypothenuse := Sqrt(z_far * z_far + half_far_v_side * half_far_v_side);

    right   := RightVector(transform);
    up      := UpVector(transform);
    forward := ForwardVector (transform);
    position := TranslationVector(transform);

    using result : Frustum = ---;
    near_plane   = MakePlane(position + z_near * forward, forward);
    far_plane    = MakePlane(position + z_far * forward, -forward);

    far_center := z_far * forward;

    far_right := far_center + right * half_far_h_side;
    far_left  := far_center - right * half_far_h_side;
    right_center := far_right - Normalized(far_right) * (half_far_h_hypothenuse - half_near_h_hypothenuse) * 0.5;
    left_center  := far_left - Normalized(far_left) * (half_far_h_hypothenuse - half_near_h_hypothenuse) * 0.5;

    right_plane  = MakePlane(position + right_center, Cross(far_right, up));
    left_plane   = MakePlane(position + left_center, Cross(up, far_left));

    far_top    := far_center + up * half_far_v_side;
    far_bottom := far_center - up * half_far_v_side;
    top_center    := far_top - Normalized(far_top) * (half_far_v_hypothenuse - half_near_v_hypothenuse) * 0.5;
    bottom_center := far_bottom - Normalized(far_bottom) * (half_far_v_hypothenuse - half_near_v_hypothenuse) * 0.5;

    top_plane    = MakePlane(position + top_center, Cross(right, far_top));
    bottom_plane = MakePlane(position + bottom_center, Cross(far_bottom, right));

    return result;
}

MakeOrthographicFrustum :: (transform : Mat4f, l : float, r : float, t : float, b : float, z_near : float, z_far : float) -> Frustum {
    forward := ForwardVector (transform);
    right   := RightVector(transform);
    up      := UpVector(transform);
    position := TranslationVector(transform);

    using result : Frustum = ---;
    near_plane = MakePlane(position + z_near * forward, forward);
    far_plane  = MakePlane(position + z_far * forward, -forward);

    forward_center := forward * (z_near + z_far) * 0.5;
    right_plane = MakePlane(position + forward_center + r * right, -right);
    left_plane  = MakePlane(position + forward_center + l * right, right);

    top_plane    = MakePlane(position + forward_center - t * up, -up);
    bottom_plane = MakePlane(position + forward_center - b * up, up);

    return result;
}

GetTransformedAABB :: (transform : Mat4f, aabb : AABB) -> AABB {
    //      e---g
    // a---c \  |
    // |\  |  \ |
    // | \ |   \|
    // |  \|h---f
    // d---b

    a := aabb.center - aabb.half_extents;
    f := aabb.center + aabb.half_extents;
    b := Vec3f.{f.x, f.y, a.z};
    c := Vec3f.{f.x, a.y, a.z};
    d := Vec3f.{a.x, f.y, a.z};
    e := Vec3f.{a.x, a.y, f.z};
    g := Vec3f.{f.x, a.y, f.z};
    h := Vec3f.{a.x, f.y, f.z};

    a = TransformPoint(transform, a);
    b = TransformPoint(transform, b);
    c = TransformPoint(transform, c);
    d = TransformPoint(transform, d);
    e = TransformPoint(transform, e);
    f = TransformPoint(transform, f);
    g = TransformPoint(transform, g);
    h = TransformPoint(transform, h);

    min := Min(Min(Min(Min(Min(Min(Min(a, b), c), d), e), f), g), h);
    max := Max(Max(Max(Max(Max(Max(Max(a, b), c), d), e), f), g), h);

    return .{center=(max + min) * 0.5, half_extents=(max - min) * 0.5};
}
