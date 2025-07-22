#scope_file

g_shader_binding_set_types : [..]*Type_Info_Struct;
g_generated_renderer_code : bool;

#scope_export

HandleDeclarationForRenderer :: (decl : *Code_Declaration) {
    has_shader_binding_set_note := false;
    for note : decl.notes {
        if note.text == "BindingSet" {
            has_shader_binding_set_note = true;
            break;
        }
    }

    if decl.expression && has_shader_binding_set_note {
        if decl.expression.kind == .STRUCT {
            ArrayPushUnique(*g_shader_binding_set_types, xx cast(*Code_Struct, decl.expression).defined_type);
        }
    }
}

GenerateRendererCode :: (workspace : Workspace) {
    if g_generated_renderer_code {
        return;
    }

    defer g_generated_renderer_code = true;

    builder : StringBuilder;

    Appendln(*builder, "Shader_Binding_Set_Types :: Type.[");
    for g_shader_binding_set_types {
        Appendln(*builder, "    %,", it.name);
    }
    Appendln(*builder, "];");

    add_build_string(StringBuilderBuild(*builder), workspace);

    LogMessage("Generated renderer code");
}
