#scope_file

g_generated_editor_code := false;

EditorMenu :: struct {
    path : string;
    callback_name : string;
}

g_editor_menus : [..]EditorMenu;

#scope_export

HandleDeclarationForEditor :: (decl : *Code_Declaration) {
    has_editor_menu_note := false;
    editor_menu_path : string;
    for note : decl.notes {
        if StringStartsWith(note.text, "EditorMenu(") && StringEndsWith(note.text, ")") {
            editor_menu_path = StringAdvance(note.text, "EditorMenu(".count);
            editor_menu_path.count -= 1;
            has_editor_menu_note = true;
        }
    }

    location := make_location(decl);

    if has_editor_menu_note {
        if !decl.expression || decl.expression.kind != .PROCEDURE_HEADER {
            compiler_report("Declaration is marked @EditorMenu but is not a procedure declaration.", location);
        }

        menu : EditorMenu;
        menu.path = editor_menu_path;
        menu.callback_name = decl.name;
        ArrayPush(*g_editor_menus, menu);
    }
}

GenerateEditorCode :: (workspace : Workspace) {
    if g_generated_editor_code {
        return;
    }

    defer g_generated_editor_code = true;

    builder : StringBuilder;

    Appendln(*builder, "InitEditorMenus :: () {");

    for g_editor_menus {
        Appendln(*builder, "    RegisterEditorMenu(\"%\", %);", it.path, it.callback_name);
    }

    Appendln(*builder, "}");

    add_build_string(StringBuilderBuild(*builder), workspace);

    LogMessage("Generated editor code");
}
