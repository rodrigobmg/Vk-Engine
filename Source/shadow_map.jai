Num_Shadow_Map_Cascades :: 4;

#assert Num_Shadow_Map_Cascades <= Max_Viewpoints;

Shadow_Map_Cascade_Sizes : [Num_Shadow_Map_Cascades]float : .[5,20,50,200];

Shadow_Map_Depth_Extent_Factor :: 6.0;

Shadow_Map_Noise_Size :: 32;
Num_Shadow_Map_Sqrt_Samples :: 8;
Num_Shadow_Map_Samples :: Num_Shadow_Map_Sqrt_Samples * Num_Shadow_Map_Sqrt_Samples;
Shadow_Map_Forward_Offset :: 1.0;

ShadowMap :: struct {
    resolution : u32;
    light_direction : Vec3f;
    mesh_buffer : MeshBuffer;
    depth_texture : GfxTexture;
}

InitShadowMap :: (shadow_map : *ShadowMap, resolution : u32) {
    shadow_map.resolution = resolution;

    desc : GfxTextureDesc;
    desc.type = .Texture2DArray;
    desc.pixel_format = .Depth32Float;
    desc.usage = .DepthStencilAttachment | .Sampled;
    desc.width = resolution;
    desc.height = resolution;
    desc.array_length = Num_Shadow_Map_Cascades;

    shadow_map.depth_texture = CreateGfxTexture("Shadow Map", desc);
    Assert(!IsNull(*shadow_map.depth_texture), "Could not create shadow map texture");
}

DestroyShadowMap :: (shadow_map : *ShadowMap) {
    DestroyGfxTexture(*shadow_map.depth_texture);
}

GetShadowMapViewpoint :: (shadow_map : *ShadowMap, viewpoint_transform : Mat4f, level : int) -> Viewpoint {
    size := Shadow_Map_Cascade_Sizes[level];
    depth := size * Shadow_Map_Depth_Extent_Factor;

    center := TranslationVector(viewpoint_transform) + ForwardVector(viewpoint_transform) * size * 0.5 * Shadow_Map_Forward_Offset;

    viewpoint : Viewpoint;
    viewpoint.projection = Mat4fOrthographicProjection(-size * 0.5, size * 0.5, -size * 0.5, size * 0.5, -depth * 0.5, depth * 0.5);

    viewpoint.transform = Mat4fLookAt(center, center + shadow_map.light_direction, .{1,0,0});
    viewpoint.position = TranslationVector(viewpoint.transform);
    viewpoint.right = RightVector(viewpoint.transform);
    viewpoint.up = UpVector(viewpoint.transform);
    viewpoint.direction = ForwardVector(viewpoint.transform);
    viewpoint.view = Inverse(viewpoint.transform);
    viewpoint.view_projection = viewpoint.projection * viewpoint.view;

    return viewpoint;
}

GetShadowMapFrustum :: (shadow_map : *ShadowMap, viewpoint_transform : Mat4f, level : int) -> Frustum {
    size := Shadow_Map_Cascade_Sizes[level];
    depth := size * Shadow_Map_Depth_Extent_Factor;

    center := TranslationVector(viewpoint_transform) + ForwardVector(viewpoint_transform) * size * 0.5 * Shadow_Map_Forward_Offset;

    light_transform := Mat4fLookAt(center, center + shadow_map.light_direction, .{1,0,0});

    return MakeOrthographicFrustum(
        light_transform,
        -size * 0.5, size * 0.5,
        -size * 0.5, size * 0.5,
        -depth * 0.5, depth * 0.5
    );
}

PopulateShadowMapMeshBuffer :: (world : *World, shadow_map : *ShadowMap, viewpoint_transform : Mat4f) {
    ClearMeshBuffer(*shadow_map.mesh_buffer);

    frustums : [Num_Shadow_Map_Cascades]Frustum = ---;
    for * frustums {
        it.* = GetShadowMapFrustum(shadow_map, viewpoint_transform, it_index);
    }

    viewpoints : [Num_Shadow_Map_Cascades]Viewpoint = ---;
    for * viewpoints {
        it.* = GetShadowMapViewpoint(shadow_map, viewpoint_transform, it_index);
    }

    for * world.MeshEntity_storage {
        if !it.mesh || !it.material {
            continue;
        }

        if IsNull(*it.mesh.vertex_buffer) || IsNull(*it.mesh.index_buffer) {
            continue;
        }

        aabb := GetTransformedAABB(it.world_transform, it.mesh.static_bounds);

        is_inside_frustum := false;
        for frustum : frustums {
            if AABBIsInFrustum(aabb, frustum) {
                is_inside_frustum = true;
                break;
            }
        }

        if is_inside_frustum {
            position := TranslationVector(it.world_transform);
            depth := TransformPoint(viewpoints[0].view, position).z;
            key := MakeMeshBufferKey(*it.mesh.vertex_buffer, *it.mesh.index_buffer, it.material, depth);
            PushMesh(*shadow_map.mesh_buffer, key, it.guid, *it.mesh.vertex_buffer, *it.mesh.index_buffer, it.mesh.vertex_count, it.mesh.index_count, it.world_transform, it.material);
        }
    }

    SortMeshBuffer(*shadow_map.mesh_buffer);
    AllocDrawData(*shadow_map.mesh_buffer);
}

g_shadow_map_pipeline : GfxGraphicsPipeline;

CreateShadowMapPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("shadow_map_mesh_geometry");
    desc.depth_format = g_depth_texture.desc.pixel_format;
    desc.depth_state = .{test_enabled=true, write_enabled=true};

    desc.vertex_input = MakeVertexInputDesc(StaticVertex, 0);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.ForwardPassBindingSet,
        g_binding_set_layouts.MeshBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_shadow_map_pipeline, "Shadow Map", desc);
    Assert(ok, "Could not create shadow map pipeline");
}

ShadowMapPass :: (using ctx : *FrameRenderContext, shadow_map : *ShadowMap, camera : *Camera) {
    if IsNull(*g_shadow_map_pipeline) {
        CreateShadowMapPipeline();
    }

    viewpoints : [Max_Viewpoints]Viewpoint = ---;
    for i : 0..Num_Shadow_Map_Cascades - 1 {
        viewpoints[i] = GetShadowMapViewpoint(shadow_map, camera.transform, i);
    }

    viewpoints_offset, viewpoints_size := AllocAndPackUniformFrameData(viewpoints);

    pass_bindings := ForwardPassBindingSet.{
        viewpoints=.{buffer=FrameDataBuffer(), offset=xx viewpoints_offset, size=xx viewpoints_size},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), pass_bindings);

    pass_desc : GfxRenderPassDesc;
    AddDepthAttachment(*pass_desc, *shadow_map.depth_texture);
    ClearDepth(*pass_desc, 1);

    pass := BeginGfxRenderPass(cmd_buffer, "Shadow Map", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_shadow_map_pipeline);
        SetViewport(*pass, .{width=xx shadow_map.resolution, height=xx shadow_map.resolution});
        SetScissor(*pass, .{w=xx shadow_map.resolution, h=xx shadow_map.resolution});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        for shadow_map.mesh_buffer.draw_calls {
            BindGraphicsBindingSet(*pass, 2, *it.binding_set);
            BindVertexBuffer(*pass, 0, it.vertex_buffer);
            BindIndexBuffer(*pass, .UInt32, it.index_buffer);

            DrawIndexed(*pass, it.index_count, it.instance_count * Num_Shadow_Map_Cascades);
        }
    }
    EndGfxRenderPass(*pass);
}
