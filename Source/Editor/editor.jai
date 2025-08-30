#import "Hash_Set";

#load "utils.jai";
#load "material_design_icons.jai";
#load "inspector.jai";
#load "file_browser.jai";
#load "gizmo.jai";
#load "world.jai";

Log_Editor :: Log_Section.{name="Editor"};

Editor_Background_Blur_Iterations :: 3;
Editor_Background_Blur_Resolution_Factor :: 0.75;

EditorSettings :: struct {
    entity_outline : EntityOutlineParams; @ShowInInspector @InspectorNoTree
    use_blur_effect := true; @ShowInInspector
    blur_effect_resolution_factor := 0.75; @ShowInInspector @FloatRange(0.1,1)
    blur_effect_iterations := 3; @ShowInInspector
} @ShaderType

EntityOutlineParams :: struct {
    thickness : float = 2; @ShowInInspector @FloatRange(1,5)
    covered_alpha : float = 0.4; @ShowInInspector @FloatRange(0,1)
    color : Vec4f = .{0.972, 1, 0.498, 1}; @ShowInInspector @ColorEdit
} @ShaderType

g_editor_background_blur : KawaseBlur;

g_editor_settings : EditorSettings;

EditorMainMenuCallback :: #type (*World);

g_editor_main_menus : [..]EditorMainMenuCallback;

RegisterEditorMainMenu :: (callback : EditorMainMenuCallback) -> bool {
    return ArrayPushUnique(*g_editor_main_menus, callback);
}

UnregisterEditorMainMenu :: (callback : EditorMainMenuCallback) -> bool {
    index := ArrayFindFirst(g_editor_main_menus, callback);
    if index < 0 {
        return false;
    }

    ArrayOrderedRemove(*g_editor_main_menus, index);
    return true;
}

#placeholder InitEditorMainMenus;

g_show_imgui_demo := false;
g_show_world_inspector := true;
g_show_entity_outliner := true;
g_show_entity_inspector := true;
g_show_engine_settings := false;
g_show_debug_window := false;
g_show_gpu_profiler := false;

g_editor_selected_entities : [..]EntityGUID;
g_editor_last_copied_entity_guid : EntityGUID;
g_editor_has_copied_entity_guid : bool;
g_editor_entity_filter_text : [100]u8;
g_editor_entity_filter_case_sensitive : bool;

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
    inv_projection : Mat4f;
    ortho_projection : Mat4f;
    inv_ortho_projection : Mat4f;

    speed_mult := 1.0;
    base_speed := 0.1;
    fast_speed := 1.0;
    rotation_speed := 0.2;
    rotation_smoothing := 0.3;
}

g_editor_camera : Camera;

UpdateCamera :: (using camera : *Camera) {
    is_moving_camera := IsMouseButtonDown(.Right);
    is_moving_camera &= !ImGui.GetIO().WantCaptureMouse;
    is_moving_camera &= !ImGui.GetIO().WantCaptureKeyboard;
    is_moving_camera &= g_gizmo_ctx.active_id == 0;
    if is_moving_camera {
        SDL_SetRelativeMouseMode(SDL_TRUE);

        if !IsKeyDown(.Ctrl) {
            movement_input : Vec3f;
            movement_input.x = GetKeyAxisValue(.A, .D);
            movement_input.y = GetKeyAxisValue(.Q, .E);
            movement_input.z = GetKeyAxisValue(.S, .W);
            movement_input = Normalized(movement_input);

            speed := ifx IsKeyDown(.Shift) then fast_speed else base_speed;

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

    w, h := GetWindowPixelSize(g_window);

    aspect := w / cast(float, h);
    projection = Mat4fPerspectiveProjection(fov_in_degrees, aspect, z_near, z_far);
    inv_projection = Inverse(projection);

    ortho_projection = Mat4fOrthographicProjection(0, xx w, xx h, 0, -1, 1);
    inv_ortho_projection = Inverse(ortho_projection);
}

RayFromScreenPoint :: (camera : *Camera, point : Vec2f) -> origin : Vec3f, direction : Vec3f {
    clip_space := (camera.ortho_projection * Vec4f.{point.x , point.y, 0, 1}).xy;

    view_space := camera.inv_projection * Vec4f.{xy=clip_space,z=0,w=1};
    view_space.z = 1;
    view_space.w = 0;

    origin := TranslationVector(camera.transform);
    direction := Normalized((camera.transform * view_space).xyz);

    return origin, direction;
}

RayFromMouse :: inline (camera : *Camera) -> origin : Vec3f, direction : Vec3f {
    mouse_x, mouse_y := GetMousePointPosition(g_window);
    origin, direction := RayFromScreenPoint(camera, .{xx mouse_x, xx mouse_y});

    return origin, direction;
}

WorldToCamera :: (camera : *Camera, point : Vec3f) -> is_behind : bool, Vec2f {
    proj := camera.projection * camera.view * Vec4f.{xyz=point,w=1};
    if proj.w < 0 {
        return true, .{};
    }

    proj /= proj.w;
    proj = camera.inv_ortho_projection * proj;

    return false, proj.xy;
}

g_open_asset_browser_for : struct {
    asset_type : Type;
    pointer_to_pointer : **void;
    allow_create : bool;
};

OpenAssetBrowserPopupFor :: (asset_type : Type, pointer_to_pointer : **void, allow_create : bool) {
    Callback :: (browser : *FileBrowser, event : FileBrowserEvent, user_data : *void) {
        if !g_open_asset_browser_for.pointer_to_pointer {
            return;
        }

        defer if event.kind == .Submit || event.kind == .Cancel {
            g_open_asset_browser_for = .{};
        }

        if event.kind == .Submit {
            asset_type := g_open_asset_browser_for.asset_type;
            value_ptr := g_open_asset_browser_for.pointer_to_pointer;
            asset_filename := event.filename;

            RemoveRefDynamic(asset_type, value_ptr.*);
            value_ptr.* = null;

            if !StringStartsWith(asset_filename, g_data_directory_absolute_path) {
                LogError("Selected asset filename is not in the Data/ directory");
                return;
            }

            asset_filename = StringAdvance(asset_filename, g_data_directory_absolute_path.count);
            if asset_filename.count > 0 && asset_filename[0] == #char "/" {
                asset_filename = StringAdvance(asset_filename, 1);
            }

            if event.exists {
                value_ptr.* = LoadAssetDynamic(asset_type, asset_filename);
            } else {
                value_ptr.* = AllocNewAssetDynamic(asset_type, asset_filename);
                if value_ptr.* {
                    SaveAssetDynamic(asset_type, value_ptr.*);
                }
            }
        }
    }

    Asset_Type_Filters :: FileBrowserFilter.[
        .{"Meshes", ".mesh"},
        .{"Images", ".png;.jpg;.jpeg;.tga;.hdr"},
        .{"Images (HDR)", ".hdr"},
        .{"Materials", ".mat"},
        .{"Animations", ".anim"},

        // Additional filters
        .{"Images (Non HDR)", ".png;.jpg;.jpeg;.tga"},
    ];

    g_open_asset_browser_for.asset_type = asset_type;
    g_open_asset_browser_for.pointer_to_pointer = pointer_to_pointer;
    g_open_asset_browser_for.allow_create = allow_create;

    OpenFileBrowser("Select Asset", .{
        accept_button_text="Select Asset",
        initial_directory="Data",
        root_directories=.["Data"],
        filters=Asset_Type_Filters,
    }, Callback);

    browser := GetFileBrowser("Select Asset");

    if allow_create {
        browser.flags &= ~.DisallowNonExisting;
    } else {
        browser.flags |= .DisallowNonExisting;
    }

    if asset_type == {
    case StaticMesh; #through;
    case SkinnedMesh;
        browser.selected_filter = 0;
    case Texture2D;
        browser.selected_filter = 1;
    case EnvironmentMap;
        browser.selected_filter = 2;
    case Material;
        browser.selected_filter = 3;
    case ArmatureAnimation;
        browser.selected_filter = 4;
    case;
        browser.selected_filter = -1;
    }
}

InitEditor :: () {
    LogSectionScope(*Log_Editor);

    InitGizmoContext(*g_gizmo_ctx);
    SetCamera(*g_gizmo_ctx, *g_editor_camera);

    io := ImGui.GetIO();

    // SetEditorStyleBasic();
    SetEditorStyleMoonlight();
    SetEditorStyleForBlurredBackground();

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

    InitEditorMainMenus();
}

CleanupEditor :: () {
    LogSectionScope(*Log_Editor);

    DestroyGizmoContext(*g_gizmo_ctx);
    DerefAsset(*g_material_editor_selected_material);
}

ShowGizmoControls :: (ctx : *GizmoContext) {
    if ImGui.MenuItem(CTPrint("%##gizmo_none", Icon_Select_MDI), selected=ctx.gizmo_type == .None) {
        ctx.gizmo_type = .None;
    }

    ImGui.SetItemTooltip("No gizmo");

    if ImGui.MenuItem(CTPrint("%##gizmo_translate", Icon_Cursor_Move_MDI), selected=ctx.gizmo_type == .Translate) {
        ctx.gizmo_type = .Translate;
    }

    ImGui.SetItemTooltip("Translate");

    if ImGui.MenuItem(CTPrint("%##gizmo_rotate", Icon_Rotate_Orbit_MDI), selected=ctx.gizmo_type == .Rotate) {
        ctx.gizmo_type = .Rotate;
    }

    ImGui.SetItemTooltip("Rotate");

    if ImGui.MenuItem(CTPrint("%##gizmo_scale", Icon_Resize_MDI), selected=ctx.gizmo_type == .Scale) {
        ctx.gizmo_type = .Scale;
    }

    ImGui.SetItemTooltip("Scale");

    ImGui.Separator();

    ImGui.Checkbox("Local", *ctx.gizmo_local);

    ImGui.SetNextItemWidth(80);
    ImGui_Ext.EnumCombo("Pivot", *ctx.gizmo_pivot);
}

UpdateEditor :: (world : *World) {
    LogSectionScope(*Log_Editor);

    ImGui.DockSpaceOverViewport(flags=.PassthruCentralNode);

    if ImGui.BeginMainMenuBar() {
        // Prepare basic menus so they appear in that specific order
        if ImGui.BeginMenu("World") {
            defer ImGui.EndMenu();
        }
        if ImGui.BeginMenu("Window") {
            defer ImGui.EndMenu();
        }
        if ImGui.BeginMenu("Tools") {
            defer ImGui.EndMenu();
        }

        if ImGui.BeginMenu("Window") {
            defer ImGui.EndMenu();

            if ImGui.MenuItem("World Inspector", selected=g_show_world_inspector) {
                g_show_world_inspector = true;
            }
            if ImGui.MenuItem("Entity Inspector", selected=g_show_entity_inspector) {
                g_show_entity_inspector = true;
            }
            if ImGui.MenuItem("Entity Outliner", selected=g_show_entity_outliner) {
                g_show_entity_outliner = true;
            }
            if ImGui.MenuItem("Material Editor", selected=g_show_material_editor) {
                g_show_material_editor = true;
            }
            if ImGui.MenuItem("Engine Settings", selected=g_show_engine_settings) {
                g_show_engine_settings = true;
            }
            if ImGui.MenuItem("GPU Profiler", selected=g_show_gpu_profiler) {
                g_show_gpu_profiler = true;
            }
            if ImGui.MenuItem("Debug", selected=g_show_debug_window) {
                g_show_debug_window = true;
            }
            if ImGui.MenuItem("ImGui Demo", selected=g_show_imgui_demo) {
                g_show_imgui_demo = true;
            }
        }

        for g_editor_main_menus {
            it(world);
        }

        if world.loaded_from_directory {
            ImGui.Separator();
            ImGui.Text("%", world.loaded_from_directory);
        }

        ImGui.Separator();
        ShowGizmoControls(*g_gizmo_ctx);

        ImGui.Separator();
        ImGui.Text("FPS: %/%/% (min/avg/max), % ms", cast(int, 1 / g_max_frame_time), cast(int, 1 / g_avg_frame_time), cast(int, 1 / g_min_frame_time), cast(int, g_last_frame_time * 1000));

        shader_failed_to_reload := 0;
        shader := "";
        for g_shaders {
            if it.failed_to_reload {
                shader_failed_to_reload += 1;
                shader = it.name;
            }
        }

        if shader_failed_to_reload > 0 {
            ImGui.Separator();

            ImGui.PushStyleColor(.Text, .{1,0,0,1});

            if shader_failed_to_reload == 1 {
                ImGui.Text("There were errors reloading shader '%'", shader);
            } else {
                ImGui.Text("There were errors reloading shaders");
            }

            ImGui.PopStyleColor();
        }

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
    // Update after camera, because this is where we check for mouse interaction
    UpdateGizmos(world, *g_gizmo_ctx);

    // Entity selection
    if !ImGui.GetIO().WantCaptureMouse && !GizmoHasMouse(*g_gizmo_ctx) && !IsMouseButtonDown(.Right) && IsMouseButtonPressed(.Left) {
        x, y := GetMousePixelPosition(g_window);
        entity := GetEntityAtPoint(world, x, y);
        if entity {
            if EntityIsSelected(entity.guid) {
                DeselectEntity(entity.guid);
            } else {
                SelectEntity(entity.guid, add_to_selection=IsKeyDown(.Shift));
            }
        } else if !IsKeyDown(.Shift) {
            ArrayClear(*g_editor_selected_entities);
        }
    }

    EntityGizmo(world, *g_gizmo_ctx);

    ShowWorldInspector(world);
    ShowEntityOutliner(world);
    ShowMaterialEditor();
    ShowEngineSettings();
    ShowGPUProfiler();
    ShowDebugWindow(world);

    entity_to_inspect : *Entity;
    if g_editor_selected_entities.count == 1 {
        entity_to_inspect = GetEntity(world, g_editor_selected_entities[0]);
    }

    ShowEntityInspector(world, entity_to_inspect);

    for :AllEntities entity : world {
        CallEntityCallback(world, entity, "OnEditorUpdate");

        if entity.flags & .Hidden {
            continue;
        }

        CallEntityCallback(world, entity, "OnDebugDraw");
    }

    for :AllComponents component : world {
        entity := GetEntity(world, component.entity);

        CallComponentCallback(world, entity, component, "OnEditorUpdate");

        if !entity || entity.flags & .Hidden {
            continue;
        }

        CallComponentCallback(world, entity, component, "OnDebugDraw");
    }

    UpdateAllFileBrowsers();
}

ShowWorldInspector :: (world : *World) {
    if !g_show_world_inspector {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{350, 500}, .FirstUseEver);
    if !ImGui.Begin("World Settings", *g_show_world_inspector) {
        return;
    }

    ImGui.SeparatorText(CStringClone(world.loaded_from_directory));

    ShowInspector("", world, world, .["InspectorNoTree"]);
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

GetNiceEntityTypeName :: inline (entity : *Entity) -> string {
    return GetNiceEntityTypeName(GetEntityTypeId(entity.index));
}

GetNiceEntityTypeName :: (type_id : EntityTypeId) -> string {
    #insert -> string {
        builder : StringBuilder;

        Appendln(*builder, "Entity_Nice_Type_Names :: string.[");
        Appendln(*builder, "    \"Invalid\",");

        for i : 1..Entity_Types.count - 1 {
            name := type_info(EntityTypeId).names[i];
            if StringEndsWith(name, "Entity") {
                name.count -= "Entity".count;
                if name.count > 0 && name[name.count - 1] == #char "_" {
                    name.count -= 1;
                }
            }

            Append(*builder, "    \"");

            for curr : name {
                Case :: enum {
                    NotAlpha;
                    Lower;
                    Upper;
                }

                GetCase :: (char : u8) -> Case {
                    if char >= #char "A" && char <= #char "Z" {
                        return .Upper;
                    }

                    if char >= #char "a" && char <= #char "z" {
                        return .Lower;
                    }

                    return .NotAlpha;
                }

                if it_index > 0 {
                    prev := name[it_index - 1];
                    if GetCase(prev) == .Lower && GetCase(curr) != .Lower {
                        Append(*builder, " ");
                    }
                }

                c := string.{data=*curr, count=1};
                Append(*builder, "%", c);
            }

            Appendln(*builder, "\",");
        }

        Appendln(*builder, "];");

        return StringBuilderBuild(*builder);
    }

    return Entity_Nice_Type_Names[type_id];
}

ShowEntityOutliner :: (world : *World) {
    if !g_show_entity_outliner {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{350, 700}, .FirstUseEver);
    if !ImGui.Begin("Entity Outliner", *g_show_entity_outliner) {
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
            name := GetNiceEntityTypeName(type_id);

            if ImGui.MenuItem(CStringClone(name ,, Temp)) {
                entity := SpawnEntity(world, type_id);
                SelectEntity(entity.guid);
            }
        }

        ImGui.EndCombo();
    }

    if !ImGui.BeginChild("Outliner", child_flags=.Border, window_flags=.HorizontalScrollbar) {
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
            else CTPrint("<%>##%", GetNiceEntityTypeName(entity), entity.guid);

        flags := ImGui.TreeNodeFlags.OpenOnArrow | .SpanFullWidth;
        if entity.children.count == 0 {
            flags |= .Leaf;
        }

        if EntityIsSelected(entity.guid) {
            flags |= .Selected;
        }

        filter := MakeString(g_editor_entity_filter_text.data);
        pass_filter := FilterTest(g_editor_entity_filter_case_sensitive, entity.name, filter);
        pass_filter ||= FilterTest(g_editor_entity_filter_case_sensitive, TPrint("%", GetNiceEntityTypeName(entity)), filter);
        pass_filter ||= FilterTest(g_editor_entity_filter_case_sensitive, TPrint("%", entity.guid), filter);

        opened : bool;
        if pass_filter {
            opened = ImGui.TreeNodeEx(label, flags);
            if entity.name {
                ImGui.SetItemTooltip("<%> % %", GetNiceEntityTypeName(entity), entity.name, entity.guid);
            } else {
                ImGui.SetItemTooltip("<%> %", GetNiceEntityTypeName(entity), entity.guid);
            }

            if ImGui.BeginPopupContextItem(CTPrint("%##context_menu", label)) {
                if ImGui.MenuItem("Detach", enabled=entity.parent != Null_Entity_GUID) {
                    DetachEntity(world, entity);
                }

                if ImGui.MenuItem("Duplicate") {
                    entity = DuplicateEntity(world, entity);
                    SelectEntity(entity.guid);
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
                    ImGui.Text("<%> % %", GetNiceEntityTypeName(entity), entity.name, entity.guid);
                } else {
                    ImGui.Text("<%> %", GetNiceEntityTypeName(entity), entity.guid);
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
    if !g_show_entity_inspector {
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
        entity = DuplicateEntity(world, entity);
        SelectEntity(entity.guid);
    }

    if BeginInspectorTable("entity_inspector") {
        defer ImGui.EndTable();

        BeginInspectorLine("Type");
        ImGui.Text("%", GetNiceEntityTypeName(entity));
        EndInspectorLine();

        name_buffer : [200]u8 = ---;
        name_len := Min(name_buffer.count - 1, entity.name.count);
        memcpy(name_buffer.data, entity.name.data, name_len);
        name_buffer[name_len] = 0;

        BeginInspectorLine("Name");

        if ImGui.InputTextWithHint("##entity_name", "Unnamed", name_buffer.data, name_buffer.count) {
            SetEntityName(world, entity, MakeString(name_buffer.data));
        }

        EndInspectorLine();

        ctx : InspectorContext;
        ctx.world = world;
        InitInspectorContext(*ctx, type_info(EntityGUID));

        ShowInspector("GUID", *ctx, entity.guid, notes=.["NotEditable"]);

        prev_parent := entity.parent;

        any : Any;
        any.type = cast(*Type_Info, GetEntityType(entity.index));
        any.value_pointer = entity;

        InitInspectorContext(*ctx, any.type);

        state := ShowInspector(null, *ctx, any, notes=.["InspectorNoTree"]);

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
}

g_show_material_editor : bool;
g_material_editor_selected_material : *Asset(Material);

OpenMaterialEditor :: (material : *Asset(Material)) {
    g_show_material_editor = true;

    DerefAsset(*g_material_editor_selected_material);
    g_material_editor_selected_material = AddRef(material);
}

ShowMaterialEditor :: () {
    if !g_show_material_editor {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{350, 500}, .FirstUseEver);
    if !ImGui.Begin("Material Editor", *g_show_material_editor) {
        return;
    }

    world : *World;
    ShowInspector("Selected Material", world, g_material_editor_selected_material, .["AllowCreateAsset"]);

    ImGui.Separator();

    if g_material_editor_selected_material {
        ShowInspector("", world, g_material_editor_selected_material.asset_data, .["InspectorNoTree"]);

        ImGui.Separator();
        ImGui.Spacing();

        if ImGui.Button("Reload", size=.{-1, 0}) {
            reloaded, asset := TryReloadAsset(*g_Material_asset_cache, g_material_editor_selected_material.asset_name);
            RemoveRef(asset); // TryReloadAsset adds a ref
        }

        if ImGui.Button("Save", size=.{-1, 0}) {
            SaveAsset(g_material_editor_selected_material);
        }
    } else {
        ImGui.Text("No material selected");
    }
}

ShowEngineSettings :: () {
    if !g_show_engine_settings {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{350, 500}, .FirstUseEver);
    if !ImGui.Begin("Engine Settings", *g_show_engine_settings) {
        return;
    }

    prev_editor_settings := g_editor_settings;
    ShowInspector("Editor", cast(*World, null), *g_editor_settings);

    if memcmp(*prev_editor_settings, *g_editor_settings, size_of(EditorSettings)) != 0 {
        if !g_editor_settings.use_blur_effect {
            DestroyKawaseBlur(*g_editor_background_blur);
        } else {
            w, h := GetWindowPixelSize(g_window);

            texture_desc : GfxTextureDesc;
            texture_desc.type = .Texture2D;
            texture_desc.pixel_format = .RGBA16Float;
            texture_desc.width = xx w;
            texture_desc.height = xx h;

            g_editor_settings.blur_effect_iterations = Clamp(g_editor_settings.blur_effect_iterations, 2, 10);

            CreateKawaseBlurTextures(*g_editor_background_blur, g_editor_settings.blur_effect_iterations, texture_desc, g_editor_settings.blur_effect_resolution_factor);
        }
    }

    ShowInspector("Gizmo", cast(*World, null), *g_gizmo_style);

    if ImGui.TreeNodeEx("Graphics") {
        ImGui.SeparatorText("Bloom");
        ShowInspector("", cast(*World, null), *g_bloom_params, .["InspectorNoTree"]);

        ImGui.TreePop();
    }
}

ShowGPUProfilerTimings :: () {
    ShowEvent :: (event : *GPUProfilingEvent) {
        label := CTPrint("% - % ms###%", event.name, event.elapsed_time_ms, event.index);
        flags := ImGui.TreeNodeFlags.DefaultOpen | .OpenOnArrow | .SpanFullWidth;
        if !event.first_child {
            flags |= .Leaf;
        }

        if ImGui.TreeNodeEx(label, flags) {
            defer ImGui.TreePop();

            child := event.first_child;
            while child
            {
                ShowEvent(child);
                child = child.next_sibling;
            }
        }
    }

    prev_format_float := context.print_style.default_format_float;
    defer context.print_style.default_format_float = prev_format_float;
    context.print_style.default_format_float.width = 6;
    context.print_style.default_format_float.trailing_width = 3;
    context.print_style.default_format_float.zero_removal = .NO;

    start_gpu_tick : u64 = 0xffffffffffffffff;
    end_gpu_tick : u64 = 0;
    for g_gpu_profiler.latest_frame {
        start_gpu_tick = Min(start_gpu_tick, it.start_gpu_tick);
        end_gpu_tick = Max(end_gpu_tick, it.end_gpu_tick);
    }

    total_frame_time := (end_gpu_tick - start_gpu_tick) * GetGfxLimits().timestamp_tick_period / 1000000.0;

    if ImGui.TreeNodeEx(CTPrint("Frame - % ms###profiler_frame_time", total_frame_time), .DefaultOpen | .OpenOnArrow | .SpanFullWidth) {
        for * g_gpu_profiler.latest_frame {
            if it.parent {
                continue;
            }

            ShowEvent(it);
        }

        ImGui.TreePop();
    }
}

ShowGPUFrameStatistics :: () {
    stats := GetGfxFrameStatistics();
    if BeginInspectorTable("gpu_frame_statistics", .NoReset) {
        defer ImGui.EndTable();

        BeginInspectorLine("Draw Calls");
        ImGui.Text("%", stats.num_draw_calls);
        EndInspectorLine();

        BeginInspectorLine("Dispatch Calls");
        ImGui.Text("%", stats.num_dispatch_calls);
        EndInspectorLine();

        BeginInspectorLine("Render Passes");
        ImGui.Text("%", stats.num_render_passes);
        EndInspectorLine();

        BeginInspectorLine("Compute Passes");
        ImGui.Text("%", stats.num_compute_passes);
        EndInspectorLine();

        BeginInspectorLine("Graphics Binding Set Binds");
        ImGui.Text("%", stats.num_graphics_binding_set_binds);
        EndInspectorLine();

        BeginInspectorLine("Compute Binding Set Binds");
        ImGui.Text("%", stats.num_compute_binding_set_binds);
        EndInspectorLine();

        BeginInspectorLine("Graphics Pipeline Binds");
        ImGui.Text("%", stats.num_graphics_pipeline_binds);
        EndInspectorLine();

        BeginInspectorLine("Compute Pipeline Binds");
        ImGui.Text("%", stats.num_compute_pipeline_binds);
        EndInspectorLine();

        BeginInspectorLine("Texture Barriers");
        ImGui.Text("%", stats.num_texture_barriers);
        EndInspectorLine();

        BeginInspectorLine("Memory Barriers");
        ImGui.Text("%", stats.num_memory_barriers);
        EndInspectorLine();

        BeginInspectorLine("Execution Barriers");
        ImGui.Text("%", stats.num_execution_barriers);
        EndInspectorLine();
    }
}

ShowGPUProfiler :: () {
    if !g_show_gpu_profiler {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{450, 700}, .FirstUseEver);
    if !ImGui.Begin("GPU Profiler", *g_show_gpu_profiler, flags=.HorizontalScrollbar) {
        return;
    }

    if ImGui.BeginTabBar("gpu_profiler") {
        if ImGui.BeginTabItem("Timings") {
            ShowGPUProfilerTimings();
            ImGui.EndTabItem();
        }

        if ImGui.BeginTabItem("Statistics") {
            ShowGPUFrameStatistics();
            ImGui.EndTabItem();
        }

        ImGui.EndTabBar();
    }
}

ShowDebugWindow :: (world : *World) {
    if !g_show_debug_window {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{450, 700}, .FirstUseEver);
    if !ImGui.Begin("Debug", *g_show_debug_window) {
        return;
    }

    if BeginInspectorTable("debug_info", .NoReset) {
        defer ImGui.EndTable();

        BeginInspectorLine("Num Point Lights");
        ImGui.Text("%", world.PointLightComponent_storage.count);
        EndInspectorLine();
    }
}
