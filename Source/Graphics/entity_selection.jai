g_entity_guid_texture : GfxTexture;
g_selected_entity_guid_texture : GfxTexture;
g_selected_entities_depth_texture : GfxTexture;
g_entity_guid_readback_buffers : [Gfx_Num_Frames_In_Flight]GfxBuffer;
g_entity_guid_readback_ptrs : [Gfx_Num_Frames_In_Flight]*EntityGUID;

CreateEntityGUIDTextures :: () {
    if !IsNull(*g_entity_guid_texture) {
        DestroyGfxTexture(*g_entity_guid_texture);
    }

    if !IsNull(*g_selected_entity_guid_texture) {
        DestroyGfxTexture(*g_selected_entity_guid_texture);
    }

    if !IsNull(*g_selected_entities_depth_texture) {
        DestroyGfxTexture(*g_selected_entities_depth_texture);
    }

    for * g_entity_guid_readback_buffers {
        if !IsNull(it) {
            DestroyGfxBuffer(it);
        }
    }

    w, h := GetWindowPixelSize(g_window);

    texture_desc : GfxTextureDesc;
    texture_desc.type = .Texture2D;
    texture_desc.width = xx w;
    texture_desc.height = xx h;

    texture_desc.pixel_format = .RGBA32UInt;
    texture_desc.usage = .ColorAttachment | .Sampled | .TransferSrc;

    g_entity_guid_texture = CreateGfxTexture("Entity GUID", texture_desc);
    Assert(!IsNull(*g_entity_guid_texture), "Could not create entity GUID texture");

    texture_desc.usage &= ~.TransferSrc;

    g_selected_entity_guid_texture = CreateGfxTexture("Selected Entity GUID", texture_desc);
    Assert(!IsNull(*g_selected_entity_guid_texture), "Could not create entity GUID texture");

    texture_desc.pixel_format = .Depth32Float;
    texture_desc.usage = .DepthStencilAttachment;

    g_selected_entities_depth_texture = CreateGfxTexture("Selected Entities Depth", texture_desc);
    Assert(!IsNull(*g_selected_entities_depth_texture), "Could not create selected entities depth texture");

    for * g_entity_guid_readback_buffers {
        buffer_desc : GfxBufferDesc;
        buffer_desc.size = xx (w * h * size_of([4]u32));
        buffer_desc.usage = .TransferDst;
        buffer_desc.memory_usage = .Readback;

        it.* = CreateGfxBuffer(TPrint("Entity GUID Readback %", it_index), buffer_desc);
        Assert(!IsNull(it), "Could not create entity GUID readback buffer");

        alloc_info : VmaAllocationInfo;
        vmaGetAllocationInfo(g_gfx_context.allocator, it.allocation, *alloc_info);
        Assert(alloc_info.pMappedData != null);

        g_entity_guid_readback_ptrs[it_index] = alloc_info.pMappedData;
    }
}

EntityGUIDPassBindingSet :: struct {
    viewpoints : GfxBindingUniformBuffer; @Binding(0) @VertexStage
} @BindingSet

g_entity_guid_material_pass := MaterialRenderPass.{
    name="Entity GUID",
    fragment_shader="ENTITY_GUID",
    pipeline_template=.{
        num_color_attachments=1,
        color_formats[0]=.RGBA32UInt,
        depth_format=.Depth32Float,
        rasterizer_state=.{winding_order=Winding_Order},
        depth_state=.{test_enabled=true, write_enabled=true, compare_op=Depth_Compare_Op},
    },
};

EntityGUIDPass :: (using ctx : *FrameRenderContext, texture : *GfxTexture, depth_texture : *GfxTexture, camera : *Camera, mesh_buffer : *MeshBuffer) {
    if !g_entity_guid_material_pass.initialized {
        InitMaterialRenderPass(*g_entity_guid_material_pass, *g_binding_set_layouts.EntityGUIDPassBindingSet);
    }

    w, h := GetWindowPixelSize(g_window);

    viewpoints : ViewpointsData;
    viewpoints.viewpoints[0] = MakeViewpoint(camera);
    viewpoints_offset, viewpoints_size := AllocAndPackUniformFrameData(viewpoints);

    pass_bindings := EntityGUIDPassBindingSet.{
        viewpoints=.{buffer=FrameDataBuffer(), offset=xx viewpoints_offset, size=xx viewpoints_size},
    };

    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), pass_bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, texture);
    AddDepthAttachment(*pass_desc, depth_texture);
    ClearColor(*pass_desc, 0, Vec4u.{0,0,0,0});
    ClearDepth(*pass_desc, Depth_Clear);

    pass := BeginGfxRenderPass(cmd_buffer, "Entity GUID", pass_desc);
    {
        SetViewport(*pass, .{width=xx w, height=xx h, min_depth=Depth_Range_Min, max_depth=Depth_Range_Max});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(cmd_buffer, *g_entity_guid_material_pass.pipeline_layout, 1, *binding_set);

        for mesh_buffer.draw_calls {
            pipeline := GetPipeline(*g_entity_guid_material_pass, it);
            BindGraphicsPipeline(*pass, pipeline);

            BindGraphicsBindingSet(*pass, 2, *it.binding_set);
            BindVertexBuffer(*pass, 0, it.vertex_buffer);

            if it.index_buffer {
                BindIndexBuffer(*pass, .UInt32, it.index_buffer);
                DrawIndexed(*pass, it.index_count, it.instance_count);
            } else {
                Draw(*pass, it.vertex_count, it.instance_count);
            }
        }
    }
    EndGfxRenderPass(*pass);
}

TransferEntityGUIDForReadback :: (cmd_buffer : *GfxCommandBuffer) {
    pass := BeginGfxCopyPass(cmd_buffer, "Transfer Entity GUIDs for Readback");
    {
        CopyTextureToBuffer(*pass, *g_entity_guid_texture, *g_entity_guid_readback_buffers[g_gfx_context.frame_in_flight]);
    }
    EndGfxCopyPass(*pass);
}

GetEntityGUIDAtPoint :: (x : int, y : int) -> EntityGUID {
    w, h := GetWindowPixelSize(g_window);
    if x < 0 || x >= w || y < 0 || y >= h {
        return Null_Entity_GUID;
    }

    frame_index := g_gfx_context.frame_in_flight;
    frame_index += Gfx_Num_Frames_In_Flight - 1;
    frame_index %= Gfx_Num_Frames_In_Flight;

    return g_entity_guid_readback_ptrs[frame_index][y * w + x];
}

GetEntityAtPoint :: (world : *World, x : int, y : int) -> *Entity {
    guid := GetEntityGUIDAtPoint(x, y);
    if guid == Null_Entity_GUID {
        return null;
    }

    return GetEntity(world, *guid);
}
