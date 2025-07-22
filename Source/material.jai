MaterialType :: enum u8 {
    Opaque;
} @ShaderType

Material :: struct {
    type : MaterialType; @Serialize(1)
    base_color_tint : Vec3f = .{1,1,1}; @Serialize(2)
    base_color : *Asset(Texture2D); @Serialize(3)
    normal_map : *Asset(Texture2D); @Serialize(4)
    metallic : float; @Serialize(5);
    roughness : float; @Serialize(6);
    metallic_roughness_map : *Asset(Texture2D); @Serialize(7)
    emissive_tint : Vec3f = .{1,1,1}; @Serialize(8)
    emissive : *Asset(Texture2D); @Serialize(9)
    emissive_strength : float; @Serialize(10)
} @Asset

MaterialPerInstance :: struct {
    type : MaterialType;
    base_color_tint : Vec3f;
    emissive_tint : Vec3f;
    emissive_strength : float;
} @ShaderType

operator== :: inline (a : MaterialPerInstance, b : MaterialPerInstance) -> bool {
    return memcmp(*a, *b, size_of(MaterialPerInstance)) == 0;
}

MakeMaterialPerInstance :: inline (material : *Material) -> MaterialPerInstance {
    return .{
        type=material.type,
        base_color_tint=material.base_color_tint,
        emissive_tint=material.emissive_tint,
        emissive_strength=material.emissive_strength,
    };
}

MaterialPerDrawCall :: struct {
    type : MaterialType;
    base_color : *Asset(Texture2D);
    normal_map : *Asset(Texture2D);
    metallic_roughness_map : *Asset(Texture2D);
    emissive : *Asset(Texture2D);
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

DestroyMaterial :: (material : *Material) {
    RemoveRef(material.base_color);
    RemoveRef(material.normal_map);
    RemoveRef(material.metallic_roughness_map);
    RemoveRef(material.emissive);
    material.* = .{};
}
