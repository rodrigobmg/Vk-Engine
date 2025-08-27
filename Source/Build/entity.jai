#import "Type_Utils";
#import "Sort";
#import "String";

#scope_file

g_generated_entity_code := false;
g_entity_type : *Type_Info;
g_entity_types_set : HashSet(*Type_Info_Struct);
g_entity_types : [..]*Type_Info_Struct;
g_entity_decls : [..]*Code_Declaration;

g_component_type : *Type_Info;
g_component_types_set : HashSet(*Type_Info_Struct);
g_component_types : [..]*Type_Info_Struct;
g_component_decls : [..]*Code_Declaration;

#scope_export

HandleDeclarationForEntity :: (decl : *Code_Declaration) {
    has_entity_note := false;
    has_component_note := false;
    for note : decl.notes {
        if note.text == "Entity" {
            has_entity_note = true;
        } else if note.text == "Component" {
            has_component_note = true;
        }
    }

    location := make_location(decl);

    if has_entity_note && has_component_note {
        compiler_report("Declaration has both @Component and @Entity notes.", location);
    }

    struct_type : *Type_Info_Struct;
    if decl.expression && decl.expression.kind == .STRUCT {
        struct_type = (cast(*Code_Struct) decl.expression).defined_type;
    }

    if decl.name == "Entity" && decl.enclosing_load.fully_pathed_filename == StringJoin(GetRootDirectory(), "Source/entity.jai") {
            g_entity_type = struct_type;
            LogMessage("Found Entity type");
    }

    if decl.name == "Component" && decl.enclosing_load.fully_pathed_filename == StringJoin(GetRootDirectory(), "Source/component.jai") {
        g_component_type = struct_type;
        LogMessage("Found Component type");
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

    if has_component_note {
        if struct_type {
            _, was_present := HashSetInsert(*g_component_types_set, struct_type);
            if !was_present {
                ArrayPush(*g_component_types, struct_type);
                ArrayPush(*g_component_decls, decl);
            }
        } else {
            compiler_report(
                "Declaration is marked @Component but is not a struct declaration.",
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

    if !g_component_type {
        ReportErrorsForUnresolvedIdentifiersInAllFiles(workspace);
        compiler_report("Component type is null when calling GenerateEntityCode.", mode=.ERROR_CONTINUABLE);
        return;
    }

    for g_entity_decls {
        TypecheckEntityStruct(cast(*Code_Struct) it.expression);
    }

    QuickSort(g_entity_types, (a, b) => StringCompare(a.name, b.name));
    QuickSort(g_entity_decls, (a, b) => StringCompare(a.name, b.name));

    for g_component_decls {
        TypecheckComponentStruct(cast(*Code_Struct) it.expression);
    }

    QuickSort(g_component_types, (a, b) => StringCompare(a.name, b.name));
    QuickSort(g_component_decls, (a, b) => StringCompare(a.name, b.name));

    builder : StringBuilder;

    Appendln(*builder, "Entity_Types :: Type.[");
    Appendln(*builder, "    void,");

    for g_entity_types {
        Appendln(*builder, "    %,", it.name);
    }

    Appendln(*builder, "];");

    Appendln(*builder, "Component_Types :: Type.[");
    Appendln(*builder, "    void,");

    for g_component_types {
        Appendln(*builder, "    %,", it.name);
    }

    Appendln(*builder, "];");

    add_build_string(StringBuilderBuild(*builder), workspace);

    LogMessage("Generated entity code");
}

IsSubclassType :: (info : *Type_Info, of : *Type_Info, first_call := true) -> bool {
    Assert(of != null);

    if !TypeIsStruct(info) {
        return false;
    }

    if info == of {
        return !first_call;
    }

    member := GetNonConstantStructMember(info, 0);
    if !member || !(member.flags & .AS) || !(member.flags & .USING) {
        return false;
    }

    if !IsSubclassType(member.type, of, false) {
        return false;
    }

    return true;
}

ContainsPointerTo :: (
    info : *Type_Info,
    predicate : (*Type_Info) -> bool,
    typecheck_stack : *[..]*Type_Info = null
) -> bool {
    stack : [..]*Type_Info;
    if !typecheck_stack {
        typecheck_stack = *stack;
    }

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
        info_struct := cast(*Type_Info_Struct, info);
        for info_struct.members {
            if ContainsPointerTo(it.type, predicate, typecheck_stack) {
                return true;
            }
        }

        return false;

    case .ARRAY;
        info_array := cast(*Type_Info_Array, info);
        return ContainsPointerTo(info_array.element_type, predicate, typecheck_stack);

    case .POINTER;
        info_pointer := cast(*Type_Info_Pointer, info);

        if predicate(info) {
            return true;
        }

        return ContainsPointerTo(info_pointer.pointer_to, predicate, typecheck_stack);

    case;
        return false;
    }
}

ContainsPointerToEntity :: (info : *Type_Info) -> bool {
    return ContainsPointerTo(info, predicate=(info) => info == g_entity_type || ArrayFindFirst(g_entity_types, xx info) != -1);
}

ContainsPointerToComponent :: (info : *Type_Info) -> bool {
    return ContainsPointerTo(info, predicate=(info) => info == g_component_type || ArrayFindFirst(g_component_types, xx info) != -1);
}

TypecheckEntityStruct :: (struct_node : *Code_Struct) {
    struct_type := struct_node.defined_type;

    if !IsSubclassType(struct_type, g_entity_type) {
        compiler_report("@Entity struct is not a substruct of type Entity.", make_location(struct_node));
    }

    for struct_node.block.members {
        decl := cast(*Code_Declaration) it;

        if !(decl.flags & .IS_CONSTANT) && ContainsPointerToEntity(it.type) {
            compiler_report("Entity struct contains a pointer to an entity, which is forbidden. An EntityGUID should be used to reference another entity.", loc = make_location(it));
        }
    }
}

TypecheckComponentStruct :: (struct_node : *Code_Struct) {
    struct_type := struct_node.defined_type;

    if !IsSubclassType(struct_type, g_component_type) {
        compiler_report("@Component struct is not a substruct of type Component.", make_location(struct_node));
    }

    for struct_node.block.members {
        decl := cast(*Code_Declaration) it;

        if !(decl.flags & .IS_CONSTANT) && ContainsPointerToEntity(it.type) {
            compiler_report("Entity struct contains a pointer to an entity, which is forbidden. An EntityGUID should be used to reference another entity.", loc = make_location(it));
        }

        // if !(decl.flags & .IS_CONSTANT) && ContainsPointerToComponent(it.type) {
        //     compiler_report("Component struct contains a pointer to a component, which is forbidden. An ComponentGUID should be used to reference another component.", loc = make_location(it));
        // }
    }
}
