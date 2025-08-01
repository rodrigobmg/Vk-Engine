#import "Hash_Set";

#load "editor_utils.jai";
#load "material_design_icons.jai";
#load "inspector.jai";
#load "file_browser.jai";

g_show_imgui_demo : bool;
g_show_world_settings : bool;
g_show_entity_outliner := true;
g_show_entity_inspector := true;
g_editor_camera : Camera;

g_editor_selected_entities : [..]EntityGUID;
g_editor_last_copied_entity_guid : EntityGUID;
g_editor_has_copied_entity_guid : bool;
g_editor_entity_filter_text : [100]u8;
g_editor_entity_filter_case_sensitive : bool;
g_editor_requested_load_world : bool;
g_editor_requested_save_world : bool;

Camera :: struct {
    position : Vec3f;
    target_yaw, target_pitch : float;
    yaw, pitch : float;
    rotation : Quatf;
    fov_in_degrees := 80.0;
    z_near := 0.1;
    z_far := 1000.0;
    transform : Mat4f;
    view : Mat4f;
    projection : Mat4f;

    speed_mult := 1.0;
    base_speed := 0.1;
    fast_speed := 1.0;
    rotation_speed := 0.2;
    rotation_smoothing := 0.3;
}

UpdateCamera :: (using camera : *Camera) {
    is_moving_camera := IsMouseButtonDown(.Right);
    is_moving_camera &= !ImGui.GetIO().WantCaptureMouse;
    is_moving_camera &= !ImGui.GetIO().WantCaptureKeyboard;
    if is_moving_camera {
        SDL_SetRelativeMouseMode(SDL_TRUE);

        if !IsKeyDown(.Ctrl) {
            movement_input : Vec3f;
            movement_input.x = GetKeyAxisValue(.A, .D);
            movement_input.y = GetKeyAxisValue(.Q, .E);
            movement_input.z = GetKeyAxisValue(.S, .W);
            movement_input = Normalized(movement_input);

            speed := ifx IsKeyDown(.Shift)
                then fast_speed
                else base_speed;

            speed *= speed_mult;

            // @Todo: delta timing
            position += speed * (
                RightVector(rotation) * movement_input.x +
                UpVector(rotation) * movement_input.y +
                ForwardVector(rotation) * movement_input.z
            );
        }

        rotation_delta := GetRawMouseDelta() * rotation_speed;

        target_yaw += ToRads(rotation_delta.x);
        target_pitch += ToRads(rotation_delta.y);
        target_pitch = Clamp(target_pitch, ToRads(-90), ToRads(90));

        yaw = Lerp(yaw, target_yaw, rotation_smoothing);
        pitch = Lerp(pitch, target_pitch, rotation_smoothing);

        rotation = QuatfFromEulerAnglesYXZ(.{x=pitch,y=yaw});
    } else {
        SDL_SetRelativeMouseMode(SDL_FALSE);
    }

    transform = Mat4fTranslate(position) * Mat4fFromQuat(rotation);
    view = Inverse(transform);

    w, h : s32;
    SDL_GetWindowSizeInPixels(g_window, *w, *h);

    aspect := w / cast(float, h);
    projection = Mat4fPerspectiveProjection(fov_in_degrees, aspect, z_near, z_far);
}

g_open_asset_browser_for : struct {
    asset_type : Type;
    pointer_to_pointer : **void;
};

OpenAssetBrowserPopupFor :: (asset_type : Type, pointer_to_pointer : **void) {
    Callback :: (browser : *FileBrowser, event : FileBrowserEvent, user_data : *void) {
        if !g_open_asset_browser_for.pointer_to_pointer {
            return;
        }

        if event.kind == .Submit {
            asset_type := g_open_asset_browser_for.asset_type;
            value_ptr := g_open_asset_browser_for.pointer_to_pointer;
            asset_filename := event.filename;

            RemoveRefDynamic(asset_type, value_ptr.*);
            value_ptr .* = null;

            if StringStartsWith(asset_filename, g_data_directory_absolute_path) {
                asset_filename = StringAdvance(asset_filename, g_data_directory_absolute_path.count);
                if asset_filename.count > 0 && asset_filename[0] == #char "/"
                    asset_filename = StringAdvance(asset_filename, 1);

                value_ptr.* = LoadAssetDynamic(asset_type, asset_filename);
            } else {
                LogError("Selected asset filename is not in the Data/ directory");
            }
        }

        if event.kind == .Submit || event.kind == .Cancel {
            g_open_asset_browser_for = .{};
        }
    }

    Asset_Type_Filters :: FileBrowserFilter.[
        .{"Meshes", ".mesh"},
        .{"Images", ".png;.jpg;.jpeg;.tga;.hdr"},
        .{"Materials", ".mat"},
    ];

    g_open_asset_browser_for.asset_type = asset_type;
    g_open_asset_browser_for.pointer_to_pointer = pointer_to_pointer;

    OpenFileBrowser("Select Asset", .{
        accept_button_text="Select Asset",
        initial_directory="Data",
        root_directories=.["Data"],
        filters=Asset_Type_Filters,
        flags=.DisallowNonExisting
    }, Callback);

    browser := GetFileBrowser("Select Asset");
    if asset_type == {
    case Mesh;
        browser.selected_filter = 0;
    case EnvironmentMap; #through;
    case Texture2D;
        browser.selected_filter = 1;
    case Material;
        browser.selected_filter = 2;
    case;
        browser.selected_filter = -1;
    }
}

InitEditor :: () {
    io := ImGui.GetIO();

    ImGui.StyleColorsDark();
    {
        style := ImGui.GetStyle();
        style.WindowRounding = 6;
        style.WindowMenuButtonPosition = .Right;
        style.ChildRounding = 3;
        style.FrameRounding = 4;
        style.PopupRounding = 3;
        style.GrabRounding = 4;
        style.TabRounding = 6;
        style.FramePadding = .{6, 6};
        style.SeparatorTextBorderSize = 1;
        style.FrameBorderSize = 1;
        style.ItemSpacing.y = 6;
        style.ItemInnerSpacing.x = 8;
        style.Colors[ImGui.Col.Border].w = 0.25;
        style.Colors[ImGui.Col.WindowBg].w = 1.0;
        style.Colors[ImGui.Col.PopupBg].w = 1.0;
    }

    {
        Base_Font_Size :: 16.0;

        io.Fonts.TexDesiredWidth = xx GetGfxLimits().max_texture_2d_dimension;

        scale_factor := GetWindowScaleFactor(g_window);
        font := io.Fonts.AddFontFromFileTTF(io.Fonts, "Data/Roboto-Regular.ttf", Base_Font_Size * scale_factor, null, io.Fonts.GetGlyphRangesDefault(io.Fonts));
        font.Scale = 1 / scale_factor;

        Icon_Font_Size :: #run Round(Base_Font_Size * 1.1);

        icons_config : ImGui.ImFontConfig;
        icons_config.Constructor(*icons_config);
        icons_config.MergeMode = true;
        icons_config.PixelSnapH = true;
        icons_config.GlyphOffset.y = 1.0;
        // icons_config.GlyphMinAdvanceX = Icon_Font_Size;

        Icon_Ranges :: ImGui.ImWchar.[Icon_Min_MDI, Icon_Max_MDI, 0];
        font = io.Fonts.AddFontFromFileTTF(io.Fonts, Font_Icon_Filename_MDI,
            Icon_Font_Size * scale_factor, *icons_config, Icon_Ranges.data);
        font.Scale = 1 / scale_factor;

        InitBigFileIconsFont();
    }
}

UpdateEditor :: (world : *World) {
    if ImGui.BeginMainMenuBar() {
        if ImGui.BeginMenu("World") {
            if ImGui.MenuItem("Load") {
                g_editor_requested_load_world = true;
            }
            if ImGui.MenuItem("Save", enabled=world.loaded_from_directory != "") {
                SaveWorldToDirectory(world, world.loaded_from_directory);
            }
            if ImGui.MenuItem("Save As") {
                g_editor_requested_save_world = true;
            }

            ImGui.EndMenu();
        }

        if ImGui.BeginMenu("Window") {
            if ImGui.MenuItem("ImGui Demo", selected=g_show_imgui_demo) {
                g_show_imgui_demo = true;
            }
            if ImGui.MenuItem("World Settings", selected=g_show_world_settings) {
                g_show_world_settings = true;
            }
            if ImGui.MenuItem("Entity Outliner", selected=g_show_entity_outliner) {
                g_show_entity_outliner = true;
            }
            if ImGui.MenuItem("Entity Inspector", selected=g_show_entity_inspector) {
                g_show_entity_inspector = true;
            }

            ImGui.EndMenu();
        }

        if world.loaded_from_directory {
            ImGui.Separator();
            ImGui.Text("%", world.loaded_from_directory);
        }

        ImGui.Separator();
        ImGui.Text("FPS: %/%/% (min/avg/max)", cast(int, 1 / g_max_frame_time), cast(int, 1 / g_avg_frame_time), cast(int, 1 / g_min_frame_time));

        ImGui.EndMainMenuBar();
    }

    if g_show_imgui_demo {
        ImGui.ShowDemoWindow(*g_show_imgui_demo);
    }

    // Make sure all selected entities are valid
    for * g_editor_selected_entities {
        if !GetEntity(world, it.*) {
            remove it;
        }
    }

    UpdateCamera(*g_editor_camera);
    ShowWorldSettings(world);
    ShowEntityOutliner(world);

    entity_to_inspect : *Entity;
    if g_editor_selected_entities.count == 1 {
        entity_to_inspect = GetEntity(world, g_editor_selected_entities[0]);
    }

    ShowEntityInspector(world, entity_to_inspect);

    if g_editor_requested_save_world {
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

        g_editor_requested_save_world = false;
    }

    if g_editor_requested_load_world {
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

        g_editor_requested_load_world = false;
    }

    UpdateAllFileBrowsers();
}

ShowWorldSettings :: (world : *World) {
    if !g_show_world_settings {
        return;
    }
}

CopyEntityGUID :: inline (guid : EntityGUID) {
    g_editor_last_copied_entity_guid = guid;
    g_editor_has_copied_entity_guid = true;

    SDL_SetClipboardText(CTPrint("%", guid));
}

DeselectEntity :: (entity : EntityGUID) {
    index := ArrayFindFirst(g_editor_selected_entities, entity);
    if index >= 0 {
        ArrayRemove(*g_editor_selected_entities, index);
    }
}

SelectEntity :: (entity : EntityGUID, add_to_selection := false, focus := true) {
    if !add_to_selection {
        ArrayClear(*g_editor_selected_entities);
    }

    if entity != Null_Entity_GUID {
        ArrayPushUnique(*g_editor_selected_entities, entity);
    }

    if focus {
        ImGui.FocusWindow(null);
    }
}

EntityIsSelected :: inline (entity : EntityGUID) -> bool {
    return ArrayFindFirst(g_editor_selected_entities, entity) != -1;
}

DuplicateEntity :: (world : *World, entity : *Entity, location := #caller_location) -> *Entity {
    serializer : Serializer;
    serializer.builder.allocator = Temp;

    SerializeEntity(*serializer, entity);

    str := StringBuilderBuild(*serializer ,, Temp);

    new_entity := SpawnEntity(world, GetEntityTypeId(entity.index));
    cached_guid := new_entity.guid;

    result := DeserializeEntity(str, new_entity);
    if !result.ok {
        LogError("There were errors when deserializing for duplicating entity:\n%:%: %",
            result.line_index, result.byte_index, result.error_msg);
    }

    new_entity.guid = cached_guid;
    UpdateWorldTransform(world, new_entity);

    if new_entity.name {
        name := new_entity.name;
        new_entity.name = "";
        SetEntityName(world, new_entity, name);
        Free(name.data);
    }

    if new_entity.parent != Null_Entity_GUID {
        parent_id := entity.parent;
        new_entity.parent = .{};

        parent, err := GetEntity(world, *parent_id);
        if !parent {
            LogError("Entity does not exist %", parent_id);
        } else {
            AttachEntity(world, new_entity, parent);
        }
    }

    return new_entity;
}

ShowEntityOutliner :: (world : *World) {
    if !g_show_entity_outliner {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{350, 700}, .FirstUseEver);
    if !ImGui.Begin("Entity Hierarchy", *g_show_entity_outliner) {
        return;
    }

    defer ImGui.EndChild();

    ImGui.InputText("Filter", g_editor_entity_filter_text.data, xx g_editor_entity_filter_text.count);
    ImGui.SameLine();
    Toggle("Aa", *g_editor_entity_filter_case_sensitive);

    ImGui.SetItemTooltip(ifx g_editor_entity_filter_case_sensitive
        then "Disable case sensitive filter"
        else "Enable case sensitive filter"
    );

    if ImGui.BeginCombo("###create_new_entity", "Create New Entity") {
        for i : 1..Entity_Types.count - 1 {
            type_id := cast(EntityTypeId, i);

            if ImGui.MenuItem(CTPrint("%", type_id)) {
                entity := SpawnEntity(world, type_id);
                SelectEntity(entity.guid);
            }
        }

        ImGui.EndCombo();
    }

    if !ImGui.BeginChild("Hierarchy", child_flags=.Border, window_flags=.HorizontalScrollbar) {
        return;
    }

    EntityGUIDSet :: HashSet(
        EntityGUID,
        hash_func = HashEntityGUID,
        comp_func = (a, b) => a == b
    );

    already_shown_entities : EntityGUIDSet;
    already_shown_entities.allocator = Temp;

    VisitEntity :: (world : *World, entity : *Entity, already_shown_entities : *EntityGUIDSet) {
        HashSetInsert(already_shown_entities, entity.guid);

        for entity.children {
            child := GetEntity(world, it);
            VisitEntity(world, child, already_shown_entities);
        }
    }

    ShowEntity :: (world : *World, entity : *Entity, already_shown_entities : *EntityGUIDSet) {
        if HashSetGetPtr(already_shown_entities, entity.guid) {
            return;
        }

        HashSetInsert(already_shown_entities, entity.guid);

        label := ifx entity.name
            then CStringClone(entity.name ,, Temp)
            else CTPrint("<%>##%", GetEntityTypeId(entity.index), entity.guid);

        flags := ImGui.TreeNodeFlags.OpenOnArrow | .SpanFullWidth;
        if entity.children.count == 0 {
            flags |= .Leaf;
        }

        if EntityIsSelected(entity.guid) {
            flags |= .Selected;
        }

        filter := MakeString(g_editor_entity_filter_text.data);
        pass_filter := FilterTest(g_editor_entity_filter_case_sensitive, entity.name, filter);
        pass_filter ||= FilterTest(g_editor_entity_filter_case_sensitive, TPrint("%", GetEntityTypeId(entity.index)), filter);
        pass_filter ||= FilterTest(g_editor_entity_filter_case_sensitive, TPrint("%", entity.guid), filter);

        opened : bool;
        if pass_filter {
            opened = ImGui.TreeNodeEx(label, flags);
            if entity.name {
                ImGui.SetItemTooltip("<%> % %", GetEntityTypeId(entity.index), entity.name, entity.guid);
            } else {
                ImGui.SetItemTooltip("<%> %", GetEntityTypeId(entity.index), entity.guid);
            }

            if ImGui.BeginPopupContextItem(CTPrint("%##context_menu", label)) {
                ImGui.BeginDisabled(entity.parent == Null_Entity_GUID);

                if ImGui.MenuItem("Detach") {
                    DetachEntity(world, entity);
                }

                ImGui.EndDisabled();

                if ImGui.MenuItem("Duplicate") {
                    DuplicateEntity(world, entity);
                }

                if ImGui.MenuItem("Delete") {
                    KillEntity(world, entity.guid);
                }

                if ImGui.MenuItem("Copy entity GUID") {
                    CopyEntityGUID(entity.guid);
                }

                ImGui.EndPopup();
            }

            if !ImGui.IsItemToggledOpen() && IsItemDoubleClicked() {
                SelectEntity(entity.guid);
                //FocusEntity(world, entity);
            }

            if ImGui.BeginDragDropSource() {
                if entity.name {
                    ImGui.Text("<%> % %", GetEntityTypeId(entity.index), entity.name, entity.guid);
                } else {
                    ImGui.Text("<%> %", GetEntityTypeId(entity.index), entity.guid);
                }

                ImGui.SetDragDropPayload("EntityGUID", *entity.guid, size_of(EntityGUID));
                ImGui.EndDragDropSource();
            }

            if ImGui.BeginDragDropTarget() {
                payload := ImGui.AcceptDragDropPayload("EntityGUID");
                if payload {
                    Assert(payload.DataSize == size_of(EntityGUID));
                    to_attach_guid := cast(*EntityGUID, payload.Data).*;

                    if to_attach_guid != entity.guid && to_attach_guid != Null_Entity_GUID {
                        to_attach := GetEntity(world, to_attach_guid);
                        AttachEntity(world, to_attach, entity);
                    }
                }

                ImGui.EndDragDropTarget();
            }
        }

        if opened {
            defer ImGui.TreePop();

            for entity.children {
                child := GetEntity(world, it);
                ShowEntity(world, child, already_shown_entities);
            }
        } else {
            // Make sure we still update the already_shown set so
            // entities don't show up later
            for entity.children {
                child := GetEntity(world, it);
                VisitEntity(world, child, already_shown_entities);
            }
        }
    }

    for :AllEntities entity : world {
        if entity.parent != Null_Entity_GUID {
            continue;
        }

        ShowEntity(world, entity, *already_shown_entities);
    }
}

ShowEntityInspector :: (world : *World, entity : *Entity) {
    if !g_show_entity_inspector || !entity {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{450, 700}, .FirstUseEver);
    if !ImGui.Begin("Entity Inspector", *g_show_entity_inspector, flags=.HorizontalScrollbar | .NoFocusOnAppearing) {
        return;
    }

    if !entity {
        ImGui.Text("No entity selected");
        return;
    }

    ImGui.PushID(entity);
    defer ImGui.PopID();

    if ImGui.Button("Delete") {
        KillEntity(world, entity.guid);
    }

    ImGui.SameLine();

    if ImGui.Button("Duplicate") {
        DuplicateEntity(world, entity);
        SelectEntity(entity.guid);
    }

    ImGui.LabelText("Type", "%", GetEntityTypeId(entity.index));

    name_buffer : [200]u8 = ---;
    name_len := Min(name_buffer.count - 1, entity.name.count);
    memcpy(name_buffer.data, entity.name.data, name_len);
    name_buffer[name_len] = 0;

    if ImGui.InputTextWithHint("Name", "Unnamed", name_buffer.data, name_buffer.count) {
        SetEntityName(world, entity, MakeString(name_buffer.data));
    }

    ShowInspector("GUID", world, entity.guid, notes=.["NotEditable"]);

    prev_parent := entity.parent;

    any : Any;
    any.type = cast(*Type_Info, GetEntityType(entity.index));
    any.value_pointer = entity;
    state := ShowInspector(null, world, any, notes=.["InspectorNoTree"]);

    if prev_parent != entity.parent {
        new_parent_id := entity.parent;
        entity.parent = prev_parent;

        if new_parent_id == Null_Entity_GUID {
            DetachEntity(world, entity);
        } else {
            new_parent := GetEntity(world, *new_parent_id);
            if new_parent {
                AttachEntity(world, entity, new_parent);
            }
        }
    }

    if state {
        UpdateWorldTransform(world, entity);
    }
}
