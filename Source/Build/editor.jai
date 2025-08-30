#scope_file

g_generated_editor_code := false;

g_editor_main_menus : [..]string;

#scope_export

HandleDeclarationForEditor :: (decl : *Code_Declaration) {
    has_editor_main_menu_note := false;
    for note : decl.notes {
        if note.text == "EditorMainMenu" {
            has_editor_main_menu_note = true;
        }
    }

    location := make_location(decl);

    if has_editor_main_menu_note {
        if !decl.expression || decl.expression.kind != .PROCEDURE_HEADER {
            compiler_report("Declaration is marked @EditorMainMenu but is not a procedure declaration.", location);
        }

        ArrayPush(*g_editor_main_menus, decl.name);
    }
}

GenerateEditorCode :: (workspace : Workspace) {
    if g_generated_editor_code {
        return;
    }

    defer g_generated_editor_code = true;

    builder : StringBuilder;

    Appendln(*builder, "InitEditorMainMenus :: () {");

    for g_editor_main_menus {
        Appendln(*builder, "    RegisterEditorMainMenu(%);", it);
    }

    Appendln(*builder, "}");

    add_build_string(StringBuilderBuild(*builder), workspace);

    LogMessage("Generated editor code");
}
