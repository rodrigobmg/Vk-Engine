GizmoBindingSet :: struct {
    viewpoint : GfxBindingUniformBuffer; @Binding(0) @VertexStage
    instances : GfxBindingStorageBuffer; @Binding(1) @VertexStage @AllowNull
} @BindingSet

g_gizmo_pipeline : GfxGraphicsPipeline;

CreateGizmoPipeline :: () {
    desc : GfxGraphicsPipelineDesc;
    desc.vertex_shader = GetVertexShader("gizmo");
    desc.fragment_shader = GetFragmentShader("gizmo");
    desc.rasterizer_state.cull_face = .None;
    desc.blend_states[0] = .{enabled=true};
    desc.depth_state = .{test_enabled=true, write_enabled=true};

    AddColorAttachment(*desc, .RGBA8UNorm);
    desc.depth_format = .Depth32Float;

    desc.vertex_input = MakeVertexInputDesc(StaticVertex, 0);

    desc.layout.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        g_binding_set_layouts.GizmoBindingSet,
    ];

    ok := CreateGfxGraphicsPipeline(*g_gizmo_pipeline, "Gizmo", desc);
    Assert(ok, "Could not create gizmo pipeline");
}

CreateGizmoTextures :: (ctx : *GizmoContext) {
    if !IsNull(*ctx.color_texture) {
        DestroyGfxTexture(*ctx.color_texture);
    }
    if !IsNull(*ctx.depth_texture) {
        DestroyGfxTexture(*ctx.depth_texture);
    }

    w, h := GetWindowPixelSize(g_window);

    desc : GfxTextureDesc;
    desc.type = .Texture2D;
    desc.pixel_format = .RGBA8UNorm;
    desc.width = xx w;
    desc.height = xx h;
    desc.usage = .ColorAttachment | .Sampled;

    ctx.color_texture = CreateGfxTexture("Gizmo Color", desc);
    Assert(!IsNull(*ctx.color_texture), "Could not create gizmo color texture");

    desc.pixel_format = .Depth32Float;
    desc.usage = .DepthStencilAttachment;

    ctx.depth_texture = CreateGfxTexture("Gizmo Depth", desc);
    Assert(!IsNull(*ctx.depth_texture), "Could not create gizmo depth texture");
}

GizmoPass :: (using ctx : *FrameRenderContext, gizmo_ctx : *GizmoContext) {
    Assert(gizmo_ctx != null);

    if IsNull(*g_gizmo_pipeline) {
        CreateGizmoPipeline();
    }

    AddTextureBarrier(cmd_buffer, .Undefined, .ColorAttachment, *gizmo_ctx.color_texture);
    AddTextureBarrier(cmd_buffer, .Undefined, .DepthStencilAttachment, *gizmo_ctx.depth_texture);

    w, h := GetWindowPixelSize(g_window);

    viewpoint_offset, viewpoint_size := AllocAndPackUniformFrameData(MakeViewpoint(gizmo_ctx.camera));
    instances_offset, instances_size := AllocAndPackStorageFrameData(gizmo_ctx.widgets);

    bindings := GizmoBindingSet.{
        viewpoint=.{buffer=FrameDataBuffer(), offset=xx viewpoint_offset, size=xx viewpoint_size},
        instances=.{buffer=FrameDataBuffer(), offset=xx instances_offset, size=xx instances_size},
    };

    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), bindings);

    pass_desc : GfxRenderPassDesc;
    AddColorAttachment(*pass_desc, *gizmo_ctx.color_texture);
    AddDepthAttachment(*pass_desc, *gizmo_ctx.depth_texture, store_op=.DontCare);
    ClearColor(*pass_desc, 0, Vec4f.{0,0,0,0});
    ClearDepth(*pass_desc, 1);

    pass := BeginGfxRenderPass(cmd_buffer, "Gizmo", pass_desc);
    {
        BindGraphicsPipeline(*pass, *g_gizmo_pipeline);
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(*pass, 1, *binding_set);

        prev_mesh : *Asset(Mesh);
        for gizmo_ctx.widgets {
            mesh := gizmo_ctx.meshes.all[it.mesh_id];
            if mesh != prev_mesh {
                BindVertexBuffer(*pass, 0, *mesh.vertex_buffer);
                BindIndexBuffer(*pass, .UInt32, *mesh.index_buffer);
                prev_mesh = mesh;
            }

            DrawIndexed(*pass, index_count=mesh.index_count, instance_count=1, base_instance=xx it_index);
        }
    }
    EndGfxRenderPass(*pass);

    AddTextureBarrier(cmd_buffer, .ColorAttachment, .ShaderReadOnly, *gizmo_ctx.color_texture);
}
