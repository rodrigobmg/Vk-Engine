#import "Linalg";

g_shader_types : [..]*Type_Info;

RemoveShaderPrefix :: (str : string) -> string {
    return ifx StringStartsWith(str, "Shader")
        then StringAdvance(str, "Shader".count)
        else str;
}

GetVectorTypeInfoByName :: (info : *Type_Info) -> is_vector_type : bool, T : *Type_Info, N : int {
    if info.type != .STRUCT {
        return false, null, 0;
    }

    struct_info := cast(*Type_Info_Struct, info);
    if struct_info.name != "Vector" {
        return false, null, 0;
    }

    T : *Type_Info;
    N : int;
    for struct_info.specified_parameters {
        if !(it.flags & .CONSTANT) {
            continue;
        }

        ptr := struct_info.constant_storage.data + it.offset_into_constant_storage;
        if it.name == {
        case "N";
            N = cast(*int, ptr).*;
        case "T";
            T = cast(**Type_Info, ptr).*;
        }
    }

    return true, T, N;
}

GetMatrixTypeInfoByName :: (info : *Type_Info) -> is_matrix_type : bool, T : *Type_Info, M : int, N : int {
    if info.type != .STRUCT {
        return false, null, 0, 0;
    }

    struct_info := cast(*Type_Info_Struct, info);
    if struct_info.name != "Matrix" {
        return false, null, 0, 0;
    }

    T : *Type_Info;
    M : int;
    N : int;
    for struct_info.specified_parameters {
        if !(it.flags & .CONSTANT) {
            continue;
        }

        ptr := struct_info.constant_storage.data + it.offset_into_constant_storage;
        if it.name == {
        case "M";
            M = cast(*int, ptr).*;
        case "N";
            N = cast(*int, ptr).*;
        case "T";
            T = cast(**Type_Info, ptr).*;
        }
    }

    return true, T, M, N;
}


HandleDeclarationForShaderCodegen :: (decl : *Code_Declaration) {
    has_shader_type_note := false;
    for note : decl.notes {
        if note.text == "ShaderType" {
            has_shader_type_note = true;
            break;
        }
    }

    if decl.expression && has_shader_type_note {
        if decl.expression.kind == .STRUCT {
            ArrayPush(*g_shader_types, cast(*Code_Struct, decl.expression).defined_type);
        } else if decl.expression.kind == .ENUM {
            ArrayPush(*g_shader_types, cast(*Code_Enum, decl.expression).external_type);
        }
    }
}

GenerateShaderCode :: (workspace : Workspace) {
    CompareTypeNames :: (a : *Type_Info, b : *Type_Info) -> int {
        a_name := ifx a.type == .STRUCT
            then cast(*Type_Info_Struct, a).name
            else cast(*Type_Info_Enum, a).name;
        b_name := ifx b.type == .STRUCT
            then cast(*Type_Info_Struct, b).name
            else cast(*Type_Info_Enum, b).name;

        return StringCompare(a_name, b_name);
    }

    QuickSort(g_shader_types, CompareTypeNames);

    GenerateGLSLShaderCode(workspace);

    ArrayClear(*g_shader_types);
}

GenerateGLSLShaderCode :: (workspace : Workspace) {
    // Make sure types are generated in order to respect C declaration rules
    PushType :: (types : *[..]*Type_Info, type : *Type_Info) {
        if type.type == .STRUCT {
            info_struct := cast(*Type_Info_Struct, type);
            for info_struct.members {
                if it.type.type == .STRUCT || it.type.type == .ENUM {
                    PushType(types, it.type);
                }
            }
        }

        for g_shader_types {
            if type == it {
                ArrayPushUnique(types, type);
                break;
            }
        }
    }

    shader_types_in_order : [..]*Type_Info;

    for g_shader_types {
        PushType(*shader_types_in_order, it);
    }

    defer LogMessage("Generated GLSL type definitions");

    builder : StringBuilder;

    if StringBuilderLength(*builder) == 0 {
        Appendln(*builder, "// This file was auto generated\n");
    }

    Appendln(*builder, "#ifndef SHADER_TYPES_GENERATED_GLSL");
    Appendln(*builder, "#define SHADER_TYPES_GENERATED_GLSL\n");

    for shader_types_in_order {
        if it.type == .ENUM {
            GenerateGLSLEnumDefinition(*builder, xx it);
            Append(*builder, "\n");
        } else if it.type == .STRUCT {
            GenerateGLSLStructDefinition(*builder, xx it);
            Append(*builder, ";\n\n");
        }
    }

    Appendln(*builder, "#endif");

    write_entire_file("Shaders/shader_types.generated.glsl", *builder);
}

GenerateGLSLEnumDefinition :: (builder : *StringBuilder, info : *Type_Info_Enum, indent := 0) {
    name := RemoveShaderPrefix(info.name);
    if info.name {
        Appendln(builder, "#define % int", name);
    }

    for i : 0..info.values.count - 1 {
        Appendln(builder, "#define %_% %", name, info.names[i], info.values[i]);
    }
}

AppendGLSLTypePrefix :: (builder : *StringBuilder, info : *Type_Info, indent := 0) {
    if info.type == {
    case .INTEGER;
        int_info := cast(*Type_Info_Integer, info);
        if int_info.signed {
            Append(builder, "int ");
        } else {
            Append(builder, "uint ");
        }
    case .BOOL;
        Append(builder, "bool ");
    case .FLOAT;
        if info.runtime_size == 4 {
            Append(builder, "float ");
        } else {
            Append(builder, "double ");
        }
    case .STRUCT;
        struct_info := cast(*Type_Info_Struct, info);
        if !struct_info.name {
            GenerateGLSLStructDefinition(builder, struct_info, indent);
            Append(builder, " ");
            return;
        }

        is_matrix_type, matrix_T, matrix_M, matrix_N := GetMatrixTypeInfoByName(info);
        is_vector_type, vector_T, vector_N := GetVectorTypeInfoByName(info);
        if is_vector_type {
            if vector_T.type == .INTEGER {
                if cast(*Type_Info_Integer, vector_T).signed {
                    Append(builder, "int% ", vector_N);
                } else {
                    Append(builder, "uint% ", vector_N);
                }
            } else if vector_T.type == .FLOAT {
                if vector_T.runtime_size == 4 {
                    Append(builder, "float% ", vector_N);
                } else {
                    Append(builder, "double% ", vector_N);
                }
            } else {
                Append(builder, "% ", RemoveShaderPrefix(struct_info.name));
            }
        } else if is_matrix_type {
            if matrix_T.type == .FLOAT {
                if matrix_T.runtime_size == 4 {
                    Append(builder, "float");
                } else {
                    Append(builder, "double");
                }

                Append(builder, "%x% ", matrix_M, matrix_N);
            } else {
                Append(builder, "% ", RemoveShaderPrefix(struct_info.name));
            }
        } else {
            Append(builder, "% ", RemoveShaderPrefix(struct_info.name));
        }

    case .ENUM;
        enum_info := cast(*Type_Info_Enum, info);
        if enum_info.name {
            Append(builder, "% ", RemoveShaderPrefix(enum_info.name));
        } else {
            Append(builder, "int ");
        }

    case .ARRAY;
        array_info := cast(*Type_Info_Array, info);
        AppendGLSLTypePrefix(builder, array_info.element_type, indent);
    }
}

AppendGLSLTypePostfix :: (builder : *StringBuilder, info : *Type_Info, indent := 0) {
    if info.type == {
    case .ARRAY;
        array_info := cast(*Type_Info_Array, info);
        if array_info.array_type == .FIXED {
            Append(builder, "[%]", array_info.array_count);
        } else {
            Append(builder, "[]");
        }

        AppendGLSLTypePostfix(builder, array_info.element_type, indent);
    }
}

GenerateGLSLStructDefinition :: (builder : *StringBuilder, info : *Type_Info_Struct, indent := 0) {
    if info.name {
        Appendln(builder, "struct % {", RemoveShaderPrefix(info.name));
    } else {
        Appendln(builder, "struct {");
    }

    highest_offset := -1;
    for info.members {
        if it.flags & .CONSTANT || it.offset_in_bytes <= highest_offset {
            continue;
        }

        highest_offset = it.offset_in_bytes;

        for i : 1..indent + 1 {
            Append(builder, "    ");
        }

        AppendGLSLTypePrefix(builder, it.type, indent + 1);
        Append(builder, it.name);
        AppendGLSLTypePostfix(builder, it.type, indent + 1);
        Appendln(builder, ";");
    }

    for i : 1..indent {
        Append(builder, "    ");
    }

    Append(builder, "}");
}
