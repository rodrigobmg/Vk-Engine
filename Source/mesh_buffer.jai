MeshInstance :: struct {
    entity_guid : Vec4u;
    transform : Mat4f;
    normal_transform : Mat3f;
    material : MaterialPerInstance;
} @ShaderType

MeshBuffer :: struct {
    Entry :: struct {
        key : u64;
        entity_guid : EntityGUID;
        vertex_buffer : *GfxBuffer;
        index_buffer : *GfxBuffer;
        vertex_count : u32;
        index_count : u32;
        transform : Mat4f;
        material : *Material;
    }

    DrawCall :: struct {
        vertex_buffer : *GfxBuffer;
        index_buffer : *GfxBuffer;
        vertex_count : u32;
        index_count : u32;
        instances_offset : u64;
        instance_count : u32;
        material : MaterialPerDrawCall;

        binding_set : GfxBindingSet;
    }

    meshes : [..]Entry;
    draw_calls : [..]DrawCall;
}

MeshBindingSet :: struct {
    mesh_instances : GfxBindingStorageBuffer; @Binding(0) @VertexStage @FragmentStage
    base_color : GfxBindingCombinedTextureSampler; @Binding(1) @FragmentStage
    normal_map : GfxBindingCombinedTextureSampler; @Binding(2) @FragmentStage
    metallic_roughness_map : GfxBindingCombinedTextureSampler; @Binding(3) @FragmentStage @AllowNull
    emissive : GfxBindingCombinedTextureSampler; @Binding(4) @FragmentStage
    depth_map : GfxBindingCombinedTextureSampler; @Binding(5) @FragmentStage @AllowNull
} @BindingSet

ClearMeshBuffer :: (buffer : *MeshBuffer) {
    ArrayClear(*buffer.meshes);
    ArrayClear(*buffer.draw_calls);
}

FreeMeshBuffer :: (buffer : *MeshBuffer) {
    ArrayFree(*buffer.meshes);
    ArrayFree(*buffer.draw_calls);
}

MakeMeshBufferKey :: (vertex_buffer : *GfxBuffer, index_buffer : *GfxBuffer, material : *Material, depth : float) -> u64 {
    mesh_buffers : [2]*GfxBuffer = .[vertex_buffer, index_buffer];

    textures : [5]*Asset(Texture2D) = .[
        material.base_color,
        material.normal_map,
        material.metallic_roughness_map,
        material.emissive,
        material.depth_map,
    ];

    mesh_buffers_hash := sdbm_hash(*mesh_buffers, size_of(type_of(mesh_buffers)));
    textures_hash := sdbm_hash(*textures, size_of(type_of(textures)));

    Depth_Offset :: 0;
    Depth_Bits :: 24;

    Mesh_Offset :: Depth_Offset + Depth_Bits;
    Mesh_Bits :: 16;

    Textures_Offset :: Mesh_Offset + Mesh_Bits;
    Textures_Bits :: 16;

    Material_Type_Offset :: Textures_Offset + Textures_Bits;
    Material_Type_Bits :: 8;

    End :: Material_Type_Offset + Material_Type_Bits;
    #assert End <= 64;

    result : u64;
    result |= (cast,no_check(u64, depth) & 0xffffff) << Depth_Offset; // 24 bits for depth
    result |= cast(u64, mesh_buffers_hash & 0xffff) << Mesh_Offset; // 16 bits for mesh
    result |= cast(u64, textures_hash & 0xffff) << Textures_Offset; // 16 bits for textures
    result |= cast(u64, material.type & 0xff) << Material_Type_Offset; // 8 bits for material type

    return result;
}

PushMesh :: (
    buffer : *MeshBuffer,
    key : u64,
    entity_guid : EntityGUID,
    vertex_buffer : *GfxBuffer,
    index_buffer : *GfxBuffer,
    vertex_count : u32,
    index_count : u32,
    transform : Mat4f,
    material : *Material
) {
    entry := ArrayPush(*buffer.meshes);
    entry.key = key;
    entry.entity_guid = entity_guid;
    entry.vertex_buffer = vertex_buffer;
    entry.index_buffer = index_buffer;
    entry.vertex_count = vertex_count;
    entry.index_count = index_count;
    entry.transform = transform;
    entry.material = material;
}

SortMeshBuffer :: (buffer : *MeshBuffer) {
    QuickSort(buffer.meshes, (a, b) => cast,no_check(int) a.key - cast,no_check(int) b.key);
}

CanInstantiateMeshes :: (a : MeshBuffer.Entry, b : MeshBuffer.Entry) -> bool {
    return a.vertex_buffer == b.vertex_buffer
        && a.index_buffer  == b.index_buffer
        && a.vertex_count  == b.vertex_count
        && a.index_count   == b.index_count
        && MakeMaterialPerDrawCall(a.material) == MakeMaterialPerDrawCall(b.material);
}

AllocDrawData :: (buffer : *MeshBuffer) {
    i := 0;
    while i < buffer.meshes.count {
        instance_count : u32 = 1;
        while i + instance_count < buffer.meshes.count #no_abc {
            if !CanInstantiateMeshes(buffer.meshes[i], buffer.meshes[i + instance_count]) {
                break;
            }

            instance_count += 1;
        }

        mesh := buffer.meshes[i];
        draw := ArrayPush(*buffer.draw_calls);
        draw.vertex_buffer = mesh.vertex_buffer;
        draw.index_buffer = mesh.index_buffer;
        draw.vertex_count = mesh.vertex_count;
        draw.index_count = mesh.index_count;
        draw.instance_count = instance_count;

        draw.material = MakeMaterialPerDrawCall(mesh.material);

        packed_instances : *void;
        draw.instances_offset, packed_instances
            = AllocFrameData(GLSLStd430Size(MeshInstance) * instance_count);

        for j : 0..instance_count - 1 #no_abc {
            mesh := buffer.meshes[i + j];

            instance : MeshInstance = ---;
            instance.entity_guid = cast(*Vec4u, *mesh.entity_guid).*;
            instance.transform = mesh.transform;
            instance.normal_transform = ToMat3f(Transposed(Inverse(mesh.transform)));
            instance.material = MakeMaterialPerInstance(mesh.material);

            PackToGLSLStd(instance, packed_instances, .Std430);
            packed_instances += GLSLStd430Size(MeshInstance);
        }

        bindings : MeshBindingSet;
        bindings.mesh_instances = .{buffer=FrameDataBuffer(), offset=xx draw.instances_offset, size=xx (GLSLStd430Size(MeshInstance) * instance_count)};
        bindings.base_color = .{
            texture=ifx mesh.material.base_color && !IsNull(*mesh.material.base_color.texture)
                then *mesh.material.base_color.texture
                else *g_default_base_color.texture,
            sampler=*g_material_texture_sampler
        };
        bindings.normal_map = .{
            texture=ifx mesh.material.normal_map && !IsNull(*mesh.material.normal_map.texture)
                then *mesh.material.normal_map.texture
                else *g_default_normal_map.texture,
            sampler=*g_material_texture_sampler
        };
        bindings.metallic_roughness_map = .{
            texture=ifx mesh.material.metallic_roughness_map then *mesh.material.metallic_roughness_map.texture,
            sampler=*g_material_texture_sampler
        };
        bindings.emissive = .{
            texture=ifx mesh.material.emissive && !IsNull(*mesh.material.emissive.texture)
                then *mesh.material.emissive.texture
                else *g_default_emissive.texture,
            sampler=*g_material_texture_sampler
        };
        bindings.depth_map = .{
            texture=ifx mesh.material.depth_map then *mesh.material.depth_map.texture,
            sampler=*g_material_texture_sampler
        };

        draw.binding_set = CreateGfxBindingSet(MeshBindingSetAllocator(), bindings);

        i += instance_count;
    }
}
