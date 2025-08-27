MaterialType :: enum u8 {
    Opaque;
} @ShaderType

Num_Material_Types :: #run type_info(MaterialType).values.count;

Material :: struct {
    type : MaterialType; @Serialize(1)
    base_color_tint : Vec3f = .{1,1,1}; @Serialize(2) @ColorEdit
    base_color : *Asset(Texture2D); @Serialize(3)
    normal_map : *Asset(Texture2D); @Serialize(4)
    metallic : float; @Serialize(5) @FloatRange(0,1)
    roughness : float; @Serialize(6) @FloatRange(0,1)
    metallic_roughness_map : *Asset(Texture2D); @Serialize(7)
    emissive_tint : Vec3f = .{1,1,1}; @Serialize(8) @ColorEdit
    emissive : *Asset(Texture2D); @Serialize(9)
    emissive_strength : float; @Serialize(10)
    depth_map : *Asset(Texture2D); @Serialize(11)
    depth_map_scale : float; @Serialize(12)
} @Asset

MaterialFlags :: enum_flags {
    HasMetallicRoughness;
    HasDepthMap;
} @ShaderType

MakeMaterialFlags :: inline (material : Material) -> MaterialFlags {
    result : MaterialFlags;
    if material.metallic_roughness_map {
        result |= .HasMetallicRoughness;
    }
    if material.depth_map {
        result |= .HasDepthMap;
    }

    return result;
}

MaterialPerInstance :: struct {
    type : MaterialType;
    flags : MaterialFlags;
    base_color_tint : Vec3f;
    metallic : float;
    roughness : float;
    emissive_tint : Vec3f;
    emissive_strength : float;
    depth_map_scale : float;
} @ShaderType

operator== :: inline (a : MaterialPerInstance, b : MaterialPerInstance) -> bool {
    return memcmp(*a, *b, size_of(MaterialPerInstance)) == 0;
}

MakeMaterialPerInstance :: inline (material : *Material) -> MaterialPerInstance {
    return .{
        type=material.type,
        flags=MakeMaterialFlags(material),
        base_color_tint=material.base_color_tint,
        metallic=material.metallic,
        roughness=material.roughness,
        emissive_tint=material.emissive_tint,
        emissive_strength=material.emissive_strength,
        depth_map_scale=material.depth_map_scale,
    };
}

MaterialPerDrawCall :: struct {
    type : MaterialType;
    base_color : *Asset(Texture2D);
    normal_map : *Asset(Texture2D);
    metallic_roughness_map : *Asset(Texture2D);
    emissive : *Asset(Texture2D);
    depth_map : *Asset(Texture2D);
}

operator== :: inline (a : MaterialPerDrawCall, b : MaterialPerDrawCall) -> bool {
    return memcmp(*a, *b, size_of(MaterialPerInstance)) == 0;
}

MakeMaterialPerDrawCall :: inline (material : *Material) -> MaterialPerDrawCall {
    return .{
        type=material.type,
        base_color=material.base_color,
        normal_map=material.normal_map,
        metallic_roughness_map=material.metallic_roughness_map,
        emissive=material.emissive,
        depth_map=material.depth_map,
    };
}

LoadMaterialFromMemory :: (material : *Material, data : []u8, name : string) -> bool {
    any : Any;
    any.value_pointer = material;
    any.type = type_info(Material);
    result := DeserializeAny(cast(string, data), any);
    if !result.ok {
        LogError("There were errors when loading material '%'\nAt line %: %", name, result.line_index + 1, result.error_msg);
    }

    return true;
}

WriteMaterial :: (builder : *StringBuilder, material : *Material) -> bool {
    serializer : Serializer;
    serializer.builder = builder.*;
    defer builder.* = serializer.builder;

    SerializeAny(*serializer, material.*);

    return true;
}

DestroyMaterial :: (material : *Material) {
    DerefAsset(*material.base_color);
    DerefAsset(*material.normal_map);
    DerefAsset(*material.metallic_roughness_map);
    DerefAsset(*material.emissive);
    DerefAsset(*material.depth_map);
    material.* = .{};
}
