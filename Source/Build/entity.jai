#import "Type_Utils";
#import "Sort";
#import "String";

#scope_file

g_generated_entity_code := false;
g_entity_type : *Type_Info;
g_entity_types_set : HashSet(*Type_Info_Struct);
g_entity_types : [..]*Type_Info_Struct;
g_entity_decls : [..]*Code_Declaration;

#scope_export

HandleDeclarationForEntity :: (decl : *Code_Declaration) {
    has_entity_note := false;
    for note : decl.notes {
        if note.text == "Entity" {
            has_entity_note = true;
            break;
        }
    }

    location := make_location(decl);

    struct_type : *Type_Info_Struct;
    if decl.expression && decl.expression.kind == .STRUCT {
        struct_type = (cast(*Code_Struct) decl.expression).defined_type;
    }

    if decl.enclosing_load.fully_pathed_filename == StringJoin(GetRootDirectory(), "Source/entity.jai") {
        if decl.name == {
        case "Entity";
            g_entity_type = struct_type;
            LogMessage("Found Entity type");
        }
    }

    if has_entity_note {
        if struct_type {
            _, was_present := HashSetInsert(*g_entity_types_set, struct_type);
            if !was_present {
                ArrayPush(*g_entity_types, struct_type);
                ArrayPush(*g_entity_decls, decl);
            }
        } else {
            compiler_report(
                "Declaration is marked @Entity but is not a struct declaration.",
                location
            );
        }
    }
}

GenerateEntityCode :: (workspace : Workspace) {
    if g_generated_entity_code {
        return;
    }

    defer g_generated_entity_code = true;

    if !g_entity_type {
        ReportErrorsForUnresolvedIdentifiersInAllFiles(workspace);
        compiler_report("Entity type is null when calling GenerateEntityCode.", mode=.ERROR_CONTINUABLE);
        return;
    }

    for g_entity_decls {
        TypecheckEntityStruct(cast(*Code_Struct) it.expression);
    }

    QuickSort(g_entity_types, (a, b) => StringCompare(a.name, b.name));
    QuickSort(g_entity_decls, (a, b) => StringCompare(a.name, b.name));

    builder : StringBuilder;

    Appendln(*builder, "Entity_Types :: Type.[");
    Appendln(*builder, "    void,");

    for g_entity_types {
        Appendln(*builder, "    %,", it.name);
    }

    Appendln(*builder, "];");

    add_build_string(StringBuilderBuild(*builder), workspace);

    LogMessage("Generated entity code");
}

IsEntityType :: (info : *Type_Info, first_call := true) -> bool {
    Assert(g_entity_type != null, "Base Entity type is not set");

    if !TypeIsStruct(info) {
        return false;
    }

    if info == g_entity_type {
        return !first_call;
    }

    member := GetNonConstantStructMember(info, 0);
    if !member || !(member.flags & .AS) || !(member.flags & .USING) {
        return false;
    }

    if !IsEntityType(member.type, false) {
        return false;
    }

    return true;
}

ContainsEntityPointer :: (
    info : *Type_Info,
    typecheck_stack : *[..]*Type_Info
) -> bool {
    if ArrayFindLast(typecheck_stack.*, info) != -1 {
        return false;
    }

    prev_typecheck_stack_count := typecheck_stack.count;
    ArrayPush(typecheck_stack, info);

    defer {
        ArrayPop(typecheck_stack);
        Assert(typecheck_stack.count == prev_typecheck_stack_count);
    }

    if info.type == {
    case .STRUCT;
        info_struct := cast(*Type_Info_Struct) info;
        for info_struct.members {
            if ContainsEntityPointer(it.type, typecheck_stack) {
                return true;
            }
        }

        return false;

    case .ARRAY;
        info_array := cast(*Type_Info_Array) info;
        return ContainsEntityPointer(info_array.element_type, typecheck_stack);

    case .POINTER;
        info_pointer := cast(*Type_Info_Pointer) info;

        if info_pointer.pointer_to.type == .STRUCT {
            info_struct := cast(*Type_Info_Struct) info_pointer.pointer_to;
            if info_struct.name == "Entity" {
                return true;
            }

            if ArrayFindFirst(g_entity_types, info_struct) != -1 {
                return true;
            }
        }

        return ContainsEntityPointer(info_pointer.pointer_to, typecheck_stack);

    case;
        return false;
    }
}

TypecheckEntityStruct :: (struct_node : *Code_Struct) {
    typecheck_stack : [..]*Type_Info;

    struct_type := struct_node.defined_type;

    if !IsEntityType(struct_type) {
        compiler_report("@Entity struct is not a substruct of type Entity.", make_location(struct_node));
    }

    for struct_node.block.members {
        decl := cast(*Code_Declaration) it;

        if !(decl.flags & .IS_CONSTANT) && ContainsEntityPointer(it.type, *typecheck_stack) {
            compiler_report("Entity struct contains a pointer to an entity, which is forbidden. An EntityGUID should be used to reference another entity.", loc = make_location(it));
        }
    }
}
