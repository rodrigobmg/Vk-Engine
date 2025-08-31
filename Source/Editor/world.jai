WorldMenu :: (world : *World) {
    if ImGui.BeginMenu("World") {
        defer ImGui.EndMenu();

        if ImGui.MenuItem("New") {
            DestroyWorld(world);
        }
        if ImGui.MenuItem("Load") {
            Callback :: (browser : *FileBrowser, event : FileBrowserEvent, user_data : *void) {
                if event.kind == .Submit {
                    LoadWorldFromDirectory(xx user_data, event.filename);
                }
            }

            OpenFileBrowser("Load World", params=.{
                accept_button_text="Open Folder",
                initial_directory="Data/Scenes/",
                root_directories=.["Data"],
                flags=.SelectDirectory | .DisallowNonExisting
            }, Callback, world);
        }
        if ImGui.MenuItem("Save", enabled=world.loaded_from_directory != "") {
            SaveWorldToDirectory(world, world.loaded_from_directory);
        }
        if ImGui.MenuItem("Save As") {
            Callback :: (browser : *FileBrowser, event : FileBrowserEvent, user_data : *void) {
                if event.kind == .Submit {
                    SaveWorldToDirectory(xx user_data, event.filename);
                }
            }

            OpenFileBrowser("Save World", params=.{
                accept_button_text="Save To Folder",
                initial_directory="Data/Scenes/",
                root_directories=.["Data"],
                flags=.SelectDirectory
            }, Callback, world);
        }
    }
} @EditorMainMenu

AllEntitiesWithEditorIcon :: #bake_arguments AllEntitiesWithCallback(Callback="GetEditorIcon");
AllComponentsWithEditorIcon :: #bake_arguments AllComponentsWithCallback(Callback="GetEditorIcon");

GetEditorIcon :: inline (world : *World, entity : *$T) -> *Asset(Texture2D), *Asset(Material)
#modify { return T == Entity || IsInEntityTypesArray(T); } {
    icon : *Asset(Texture2D);
    #if T == Entity {
        #insert -> string {
            builder : StringBuilder;

            Appendln(*builder, "if GetEntityTypeId(entity.index) == {");
            for i : 1..Entity_Types.count - 1 {
                type := Entity_Types[i];
                Appendln(*builder, "case .%1; #if #exists(%1.GetEditorIcon) { icon = %1.GetEditorIcon(world, xx entity); }", type);
            }
            Appendln(*builder, "}");

            return StringBuilderBuild(*builder);
        }
    } else {
        #if #exists(T.GetEdiorIcon) {
            icon = T.GetEditorIcon(world, entity);
        }
    }

    if !icon {
        return null, null;
    }

    material, is_new := AllocNewAsset(Material, TPrint("%.mat", icon.asset_name), .FromMemory | .Permanent);
    if is_new {
        material.type = .Unlit;
        material.base_color = icon;
    }

    return icon, material;
}

GetEditorIcon :: inline (world : *World, entity : *Entity, component : *$T) -> *Asset(Texture2D), *Asset(Material)
#modify { return T == Component || IsInComponentTypesArray(T); } {
    icon : *Asset(Texture2D);
    #if T == Component {
        #insert -> string {
            builder : StringBuilder;

            Appendln(*builder, "if GetComponentTypeId(component) == {");
            for i : 1..Component_Types.count - 1 {
                type := Component_Types[i];
                Appendln(*builder, "case .%1; #if #exists(%1.GetEditorIcon) { icon = %1.GetEditorIcon(world, entity, xx component); }", type);
            }
            Appendln(*builder, "}");

            return StringBuilderBuild(*builder);
        }
    } else {
        #if #exists(T.GetEdiorIcon) {
            icon = T.GetEditorIcon(world, entity, component);
        }
    }

    if !icon {
        return null, null;
    }

    material, is_new := AllocNewAsset(Material, TPrint("%.mat", icon.asset_name), .FromMemory | .Permanent);
    if is_new {
        material.type = .Unlit;
        material.base_color = icon;
    }

    return icon, material;
}

g_entity_hide_editor_icon : [Entity_Types.count]bool;
g_component_hide_editor_icon : [Component_Types.count]bool;

WorldShowMenu :: (world : *World) {
    if ImGui.BeginMenu("Show") {
        defer ImGui.EndMenu();

        if ImGui.MenuItem("Debug Draw", selected=g_editor_show_debug_drawings) {
            g_editor_show_debug_drawings = !g_editor_show_debug_drawings;
        }

        if ImGui.MenuItem("Grid", selected=g_editor_show_grid) {
            g_editor_show_grid = !g_editor_show_grid;
        }

        if ImGui.BeginMenu("Icons") {
            defer ImGui.EndMenu();

            if ImGui.MenuItem("All") {
                for * g_entity_hide_editor_icon {
                    it.* = false;
                }
                for * g_component_hide_editor_icon {
                    it.* = false;
                }
            }

            if ImGui.MenuItem("None") {
                for * g_entity_hide_editor_icon {
                    it.* = true;
                }
                for * g_component_hide_editor_icon {
                    it.* = true;
                }
            }

            ImGui.Separator();

            for i : 1..Entity_Types.count - 1 {
                info := cast(*Type_Info_Struct, Entity_Types[i]);
                has_icon := false;
                for info.members {
                    if it.name == "GetEditorIcon" {
                        has_icon = true;
                        break;
                    }
                }

                name := GetNiceEntityTypeName(cast(EntityTypeId, i));
                if ImGui.MenuItem(CStringClone(name ,, Temp), selected=!g_entity_hide_editor_icon[i], enabled=has_icon) {
                    g_entity_hide_editor_icon[i] = !g_entity_hide_editor_icon[i];
                }
            }

            ImGui.Separator();

            for i : 1..Component_Types.count - 1 {
                info := cast(*Type_Info_Struct, Component_Types[i]);
                has_icon := false;
                for info.members {
                    if it.name == "GetEditorIcon" {
                        has_icon = true;
                        break;
                    }
                }

                name := GetNiceComponentTypeName(cast(ComponentTypeId, i));
                if ImGui.MenuItem(CStringClone(name ,, Temp), selected=!g_component_hide_editor_icon[i], enabled=has_icon) {
                    g_component_hide_editor_icon[i] = !g_component_hide_editor_icon[i];
                }
            }
        }
    }
} @EditorMainMenu

ShouldShowEntityEditorIcon :: inline (type : EntityTypeId) -> bool {
    return !g_entity_hide_editor_icon[type];
}

ShouldShowComponentEditorIcon :: inline (type : ComponentTypeId) -> bool {
    return !g_component_hide_editor_icon[type];
}
