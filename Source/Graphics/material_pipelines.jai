// We have many pipelines to manage to render our meshes with different materials:
// num material types * num passes * num variations (wireframe * skinned * ...)
// This system creates pipelines for all the variations and for a given render pass
// based on a template desc and a description of the shaders each material type uses

MaterialDesc :: struct {
    vertex_shader : string;
    shading_fragment_shader : string;

    Num_Material_Fragment_Shaders :: 1;

    #place shading_fragment_shader;
    fragment_shaders : [Num_Material_Fragment_Shaders]string;
}

g_material_descs : [Num_Material_Types]MaterialDesc = .[
    .{vertex_shader="mesh_geometry", shading_fragment_shader="opaque_surface"},
];

MaterialPipelineFlags :: enum_flags {
    Skinned;
}

Num_Material_Pipelines :: #run -> int {
    count := type_info(MaterialPipelineFlags).values.count;
    return count * count + 1;
}

MaterialPipelines :: [Num_Material_Pipelines]GfxGraphicsPipeline;

CreateMaterialPipelines :: (name : string, template : GfxGraphicsPipelineDesc, pass_binding_set_layout : *GfxBindingSetLayout, vertex_shader : string, fragment_shader : string) -> *MaterialPipelines {
    pipelines := Alloc(MaterialPipelines);

    for * pipelines.* {
        flags := cast(MaterialPipelineFlags, it_index);

        desc : GfxGraphicsPipelineDesc;

        if flags & .Skinned {
            desc.vertex_shader = GetVertexShader(TPrint("skinned_%", vertex_shader));
        } else {
            desc.vertex_shader = GetVertexShader(vertex_shader);
        }

        if fragment_shader {
            desc.fragment_shader = GetFragmentShader(fragment_shader);
        }

        if flags & .Skinned {
            desc.vertex_input = MakeVertexInputDesc(SkinnedVertex, 0);
        } else {
            desc.vertex_input = MakeVertexInputDesc(StaticVertex, 0);
        }

        desc.rasterizer_state = template.rasterizer_state;
        desc.depth_state = template.depth_state;
        desc.stencil_state = template.stencil_state;
        memcpy(desc.blend_states.data, template.blend_states.data, size_of(type_of(template.blend_states)));

        desc.num_color_attachments = template.num_color_attachments;

        memcpy(desc.color_formats.data, template.color_formats.data, size_of(type_of(template.color_formats)));
        desc.depth_format = template.depth_format;
        desc.stencil_format = template.stencil_format;

        desc.layout.binding_sets = .[
            g_binding_set_layouts.FrameBindingSet,
            pass_binding_set_layout,
            g_binding_set_layouts.MeshBindingSet,
        ];

        ok := CreateGfxGraphicsPipeline(it, TPrint("% (%)", name, flags), desc);
        Assert(ok, "Could not create material pipeline (%, %)", name, flags);
    }

    return pipelines;
}

DestroyMaterialPipelines :: (pipelines : *MaterialPipelines) {
    for * pipelines.* {
        DestroyGfxGraphicsPipeline(it);
    }

    Free(pipelines);
}

MaterialPipelinesKey :: struct {
    vertex_shader : string;
    fragment_shader : string;
}

CompMaterialPipelinesKey :: (a : MaterialPipelinesKey, b : MaterialPipelinesKey) -> bool {
    return a.vertex_shader == b.vertex_shader && a.fragment_shader == b.fragment_shader;
}

HashMaterialPipelinesKey :: (key : MaterialPipelinesKey) -> u64 {
    h := fnv1a_hash(key.vertex_shader.data, key.vertex_shader.count);
    if key.fragment_shader {
        h = fnv1a_hash(key.fragment_shader.data, key.fragment_shader.count, h);
    }

    return h;
}

MaterialRenderPass :: struct {
    initialized : bool;

    name : string;

    // The shader name or one of the following special values:
    // FORWARD_SHADING will use MaterialDesc.shading_fragment_shader
    fragment_shader : string;

    pipeline_template : GfxGraphicsPipelineDesc;

    // Binding set bound for the whole pass at slot 1. 0 is always FrameBindingSet and 2 is always MeshBindingSet
    binding_set_layout : *GfxBindingSetLayout;
    pipeline_layout : GfxPipelineLayout;

    pipelines : HashMap(
        MaterialPipelinesKey, *MaterialPipelines,
        hash_func=HashMaterialPipelinesKey, comp_func=CompMaterialPipelinesKey
    );
}

InitMaterialRenderPass :: (pass : *MaterialRenderPass, binding_set_layout : *GfxBindingSetLayout) {
    Assert(!pass.initialized, "Material pass is already initialized");

    pass.binding_set_layout = binding_set_layout;

    layout_desc : GfxPipelineLayoutDesc;
    layout_desc.binding_sets = .[
        g_binding_set_layouts.FrameBindingSet,
        binding_set_layout,
        g_binding_set_layouts.MeshBindingSet,
    ];

    pass.pipeline_layout = CreateGfxPipelineLayout(pass.name, layout_desc);
    Assert(!IsNull(*pass.pipeline_layout), "Could not create material pass '%' pipeline layout", pass.name);

    pass.initialized = true;
}

DestroyMaterialRenderPass :: (pass : *MaterialRenderPass) {
    DestroyGfxPipelineLayout(*pass.pipeline_layout);
    pass.pipeline_layout = .{};

    for pass.pipelines {
        DestroyMaterialPipelines(it);
    }

    HashMapFree(*pass.pipelines);

    pass.initialized = false;
}

GetPipeline :: (pass : *MaterialRenderPass, type : MaterialType, flags : MaterialPipelineFlags) -> *GfxGraphicsPipeline {
    vertex_shader := g_material_descs[type].vertex_shader;
    fragment_shader : string;

    if pass.fragment_shader == {
    case "FORWARD_SHADING";
        fragment_shader = g_material_descs[type].shading_fragment_shader;
    case;
        fragment_shader = pass.fragment_shader;
    }

    pipelines := HashMapGet(*pass.pipelines, .{vertex_shader, fragment_shader});
    if !pipelines {
        pipelines = CreateMaterialPipelines(pass.name, pass.pipeline_template, pass.binding_set_layout, vertex_shader, fragment_shader);
        HashMapInsert(*pass.pipelines, .{vertex_shader, fragment_shader}, pipelines);
    }

    return *pipelines.*[flags];
}
