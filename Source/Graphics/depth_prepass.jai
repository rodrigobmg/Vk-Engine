DepthPrepassBindingSet :: struct {
    viewpoints : GfxBindingUniformBuffer; @Binding(0) @VertexStage
} @BindingSet

g_depth_prepass_material_pass := MaterialRenderPass.{
    name="Depth Prepass",
    fragment_shader="DEPTH_ONLY",
    pipeline_template=.{
        depth_format=.Depth32Float,
        depth_state=.{test_enabled=true, write_enabled=true},
    },
};

DepthPrepass :: (using ctx : *FrameRenderContext, camera : *Camera, mesh_buffer : *MeshBuffer) {
    if !g_depth_prepass_material_pass.initialized {
        InitMaterialRenderPass(*g_depth_prepass_material_pass, *g_binding_set_layouts.DepthPrepassBindingSet);
    }

    w, h := GetWindowPixelSize(g_window);

    viewpoints : ViewpointsData;
    viewpoints.viewpoints[0] = MakeViewpoint(camera);
    viewpoints_offset, viewpoints_size := AllocAndPackUniformFrameData(viewpoints);

    pass_bindings := DepthPrepassBindingSet.{
        viewpoints=.{buffer=FrameDataBuffer(), offset=xx viewpoints_offset, size=xx viewpoints_size},
    };
    binding_set := CreateGfxBindingSet(GlobalBindingSetAllocator(), pass_bindings);

    pass_desc : GfxRenderPassDesc;
    AddDepthAttachment(*pass_desc, *g_depth_texture);
    ClearDepth(*pass_desc, 1);

    pass := BeginGfxRenderPass(cmd_buffer, "Depth Prepass", pass_desc);
    {
        SetViewport(*pass, .{width=xx w, height=xx h});
        SetScissor(*pass, .{w=xx w, h=xx h});

        BindGraphicsBindingSet(cmd_buffer, *g_depth_prepass_material_pass.pipeline_layout, 1, *binding_set);

        for mesh_buffer.draw_calls {
            pipeline := GetPipeline(*g_depth_prepass_material_pass, it);
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
