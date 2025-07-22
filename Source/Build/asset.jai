#scope_file

g_generated_asset_code := false;
g_asset_types_set : HashSet(*Type_Info_Struct);
g_asset_types : [..]*Type_Info_Struct;
g_asset_decls : [..]*Code_Declaration;

#scope_export

HandleDeclarationForAsset :: (decl : *Code_Declaration) {
    has_asset_cache_note := false;
    for note : decl.notes {
        if note.text == "Asset" {
            has_asset_cache_note = true;
            break;
        }
    }

    location := make_location(decl);

    struct_type : *Type_Info_Struct;
    if decl.expression && decl.expression.kind == .STRUCT {
        struct_type = (cast(*Code_Struct) decl.expression).defined_type;
    }

    if has_asset_cache_note {
        if struct_type {
            _, was_present := HashSetInsert(*g_asset_types_set, struct_type);
            if !was_present {
                ArrayPush(*g_asset_types, struct_type);
                ArrayPush(*g_asset_decls, decl);
            }
        } else {
            compiler_report(
                "Declaration is marked @Asset but is not a struct declaration.",
                location
            );
        }
    }
}

GenerateAssetCode :: (workspace : Workspace) {
    if g_generated_asset_code {
        return;
    }

    defer g_generated_asset_code = true;

    QuickSort(g_asset_types, (a, b) => StringCompare(a.name, b.name));
    QuickSort(g_asset_decls, (a, b) => StringCompare(a.name, b.name));

    builder : StringBuilder;

    Appendln(*builder, "Asset_Types :: Type.[");
    for g_asset_types {
        Appendln(*builder, "    %,", it.name);
    }
    Appendln(*builder, "];");

    add_build_string(StringBuilderBuild(*builder), workspace);

    LogMessage("Generated asset code");
}
