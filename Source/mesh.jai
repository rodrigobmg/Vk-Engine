StaticVertex :: struct {
    position : Vec3f;
    normal : Vec3f;
    tangent : Vec4f;
    tex_coords : Vec2f;
}

Mesh :: struct {
    vertices : []StaticVertex;
    indices : []u32;

    vertex_count : u32;
    index_count : u32;

    vertex_buffer : GfxBuffer;
    index_buffer : GfxBuffer;

    static_bounds : AABB;
} @Asset

MeshFileFlags :: enum_flags u32 {
    HasTangents;
    HasOctree;
}

LoadMeshFromMemory :: (mesh : *Mesh, data : []u8, name : string) -> bool {
    #import "Binary_Reader";

    reader := MakeBinaryReader(data);

    if EqualsString(*reader, "SKINNED_MESH") {
        LogError("Trying to load skinned mesh as static mesh");
        return false;
    }

    str, ok := ReadString(*reader, "STATIC_MESH".count);
    if !ok || str != "STATIC_MESH" {
        LogError("Not a static mesh file");
        return false;
    }

    version:, ok = ReadValue(*reader, u32);
    if !ok {
        LogError("Could not read file version");
        return false;
    }

    if version != 10000 {
        LogError("Unknown version %", version);
        return false;
    }

    flags:, ok = ReadValue(*reader, MeshFileFlags);
    if !ok {
        LogError("Could not read flags");
        return false;
    }

    vertex_count:, ok = ReadValue(*reader, u32);
    if !ok {
        LogError("Could not read vertex count");
        return false;
    }

    triangle_count:, ok = ReadValue(*reader, u32);
    if !ok {
        LogError("Could not read triangle count");
        return false;
    }

    index_count := triangle_count * 3;

    mesh.vertices = AllocArray(StaticVertex, vertex_count);
    mesh.vertex_count = xx vertex_count;

    mesh.indices = AllocArray(u32, index_count);
    mesh.index_count = xx index_count;

    ok = ReadArray(*reader, mesh.vertices);
    if !ok {
        LogError("Could not read vertices");
        return false;
    }

    ok = ReadArray(*reader, mesh.indices);
    if !ok {
        LogError("Could not read indices");
        return false;
    }

    if !(flags & .HasOctree) && !IsAtEnd(reader) {
        LogError("Trailing data (% bytes) in static mesh '%' file", reader.size - reader.offset, name);
    }

    if !(flags & .HasTangents) {
        CalculateTangents(mesh);
    }

    CalculateStaticBounds(mesh);

    if vertex_count > 0 {
        desc : GfxBufferDesc;
        desc.size = vertex_count * size_of(StaticVertex);
        desc.usage = .VertexBuffer;
        desc.memory_usage = .Upload;

        mesh.vertex_buffer = CreateGfxBuffer(TPrint("% vertices", name), desc);
        if IsNull(*mesh.vertex_buffer) {
            LogError("Could not create vertex buffer for mesh '%'", name);
            return false;
        }

        vmaCopyMemoryToAllocation(g_gfx_context.allocator, mesh.vertices.data, mesh.vertex_buffer.allocation, 0, desc.size);
    }

    if index_count > 0 {
        desc : GfxBufferDesc;
        desc.size = index_count * size_of(u32);
        desc.usage = .IndexBuffer;
        desc.memory_usage = .Upload;

        mesh.index_buffer = CreateGfxBuffer(TPrint("% indices", name), desc);
        if IsNull(*mesh.index_buffer) {
            LogError("Could not create index buffer for mesh '%'", name);
            return false;
        }

        vmaCopyMemoryToAllocation(g_gfx_context.allocator, mesh.indices.data, mesh.index_buffer.allocation, 0, desc.size);
    }

    return true;
}

DestroyMesh :: (using mesh : *Mesh) {
    Free(vertices.data);
    Free(indices.data);
    DestroyGfxBuffer(*vertex_buffer);
    DestroyGfxBuffer(*index_buffer);
    mesh.* = .{};
}

CalculateStaticBounds :: (using mesh : *Mesh) {
    min := Vec3f.{ F32_Inf,  F32_Inf,  F32_Inf};
    max := Vec3f.{-F32_Inf, -F32_Inf, -F32_Inf};
    for vertices {
        min = Min(min, it.position);
        max = Max(max, it.position);
    }

    static_bounds.center = (max + min) * 0.5;
    static_bounds.half_extents = (max - min) * 0.5;
}

CalculateTangents :: (using mesh : *Mesh) {
    if !vertices || !indices {
        return;
    }

    AllocatorScope(Temp);
    TemporaryStorageScope();

    Assert(indices.count % 3 == 0, "Mesh is not constituted of triangles");

    // From Foundations of Game Engine Development, Volume 2: Rendering by Eric Lengyel
    // Chapter 7.5
    temp_tangents := AllocArray(Vec3f, vertex_count, initialize = true);
    temp_bitangents := AllocArray(Vec3f, vertex_count, initialize = true);

    for tri : 0..indices.count / 3 - 1 {
        i0 := indices[tri * 3 + 0];
        i1 := indices[tri * 3 + 1];
        i2 := indices[tri * 3 + 2];

        p0 := vertices[i0].position;
        p1 := vertices[i1].position;
        p2 := vertices[i2].position;
        t0 := vertices[i0].tex_coords;
        t1 := vertices[i1].tex_coords;
        t2 := vertices[i2].tex_coords;

        e1 := p1 - p0;
        e2 := p2 - p0;
        x1 := t1.x - t0.x;
        x2 := t2.x - t0.x;
        y1 := t1.y - t0.y;
        y2 := t2.y - t0.y;

        inv_r := x1 * y2 - x2 * y1;
        // @Todo:
        if inv_r == 0 {
            continue;
        }

        r := 1.0 / inv_r;
        t := (e1 * y2 - e2 * y1) * r;
        b := (e2 * x1 - e1 * x2) * r;

        temp_tangents[i0] += t;
        temp_tangents[i1] += t;
        temp_tangents[i2] += t;
        temp_bitangents[i0] += b;
        temp_bitangents[i1] += b;
        temp_bitangents[i2] += b;
    }

    for * vert, i : vertices {
        t := temp_tangents[i];
        b := temp_bitangents[i];
        n := vert.normal;

        vert.tangent.xyz = Normalized(Reject(t, n));
        vert.tangent.w = ifx Dot(Cross(t, b), n) > 0 then 1.0 else -1.0;
    }
}
