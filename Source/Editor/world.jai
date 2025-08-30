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
