g_editor_show_debug_drawings := true;
g_editor_show_grid := true;

Camera :: struct {
    position := #run Normalized(Vec3f.{-1,1,-1}) * 10;
    target_yaw := #run ToRads(30.0);
    target_pitch := #run ToRads(30.0);
    yaw := #run ToRads(30.0);
    pitch := #run ToRads(30.0);
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
    is_moving_camera := IsMouseButtonDown(.Right) && !IsMouseButtonDown(.Left);
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
    } else {
        SDL_SetRelativeMouseMode(SDL_FALSE);
    }

    target_pitch = Clamp(target_pitch, ToRads(-90), ToRads(90));
    yaw = Lerp(yaw, target_yaw, rotation_smoothing);
    pitch = Lerp(pitch, target_pitch, rotation_smoothing);

    rotation = QuatfFromEulerAnglesYXZ(.{x=pitch,y=yaw});

    transform = Mat4fTranslate(position) * Mat4fFromQuat(rotation);
    view = Inverse(transform);

    w, h := GetWindowPixelSize(g_window);

    aspect := w / cast(float, h);

    if Reverse_Depth_Range {
        projection = Mat4fPerspectiveProjection(fov_in_degrees, aspect, z_far, z_near);
    } else {
        projection = Mat4fPerspectiveProjection(fov_in_degrees, aspect, z_near, z_far);
    }

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

g_editor_is_box_selecting_entities : bool;
g_editor_box_selection_start : Vec2i;

IsBoxSelectingEntities :: inline () -> bool {
    Selection_Threshold :: 4;
    mouse_x, mouse_y := GetMousePixelPosition(g_window);

    return g_editor_is_box_selecting_entities
        && Abs(g_editor_box_selection_start.x - mouse_x) >= Selection_Threshold
        && Abs(g_editor_box_selection_start.y - mouse_y) >= Selection_Threshold;
}

UpdateEntitySelection :: (world : *World) {
    // Entity selection
    if ImGui.GetIO().WantCaptureMouse || GizmoHasMouse(*g_gizmo_ctx) || IsMouseButtonDown(.Right) {
        return;
    }

    if IsMouseButtonPressed(.Left) {
        g_editor_is_box_selecting_entities = true;
        g_editor_box_selection_start.x, g_editor_box_selection_start.y = GetMousePixelPosition(g_window);
    }

    if IsMouseButtonReleased(.Left) {
        if g_editor_is_box_selecting_entities{
            mouse_x, mouse_y := GetMousePixelPosition(g_window);
            x1, y1, x2, y2 : s32;
            if IsBoxSelectingEntities() {
                x1 = Min(g_editor_box_selection_start.x, mouse_x);
                x2 = Max(g_editor_box_selection_start.x, mouse_x);
                y1 = Min(g_editor_box_selection_start.y, mouse_y);
                y2 = Max(g_editor_box_selection_start.y, mouse_y);
            } else {
                x1 = mouse_x;
                x2 = mouse_x;
                y1 = mouse_y;
                y2 = mouse_y;
            }

            scale_factor := GetWindowScaleFactor(g_window);
            x1 = xx (x1 * scale_factor);
            x2 = xx (x2 * scale_factor);
            y1 = xx (y1 * scale_factor);
            y2 = xx (y2 * scale_factor);

            if GetModState() != .Shift && GetModState() != .Ctrl | .Shift {
                ArrayClear(*g_editor_selected_entities);
            }

            for y : y1..y2 {
                for x : x1..x2 {
                    guid := GetEntityGUIDAtPoint(x, y);
                    if guid != Null_Entity_GUID {
                        if GetModState() == .Ctrl | .Shift {
                            DeselectEntity(guid);
                        } else {
                            SelectEntity(guid, add_to_selection=true);
                        }
                    }
                }
            }

            g_editor_is_box_selecting_entities = false;
        }
    }
}

UpdateEditorViewport :: (world : *World) {
    UpdateCamera(*g_editor_camera);
    // Update after camera, because this is where we check for mouse interaction
    UpdateGizmos(world, *g_gizmo_ctx);
    UpdateEntitySelection(world);

    EntityGizmo(world, *g_gizmo_ctx);

    w, h := GetWindowPointSize(g_window);
    window_flags := ImGui.WindowFlags.NoTitleBar | .NoResize | .NoScrollbar | .NoBackground
        | .NoInputs | .NoSavedSettings | .NoFocusOnAppearing | .NoBringToFrontOnFocus;
    ImGui.SetNextWindowPos(.{0,0});
    ImGui.SetNextWindowSize(.{xx w, xx h});
    if ImGui.Begin("Editor Overlay", flags=window_flags) {
        if IsBoxSelectingEntities() {
            mouse_x, mouse_y := GetMousePixelPosition(g_window);

            x1 := Min(g_editor_box_selection_start.x, mouse_x);
            y1 := Min(g_editor_box_selection_start.y, mouse_y);
            x2 := Max(g_editor_box_selection_start.x, mouse_x);
            y2 := Max(g_editor_box_selection_start.y, mouse_y);

            DrawSelectionBox(x1, x2, y1, y2);
        }
    }

    ImGui.End();
}

DrawSelectionBox :: (x1 : s32, x2 : s32, y1 : s32, y2 : s32) {
    draw_list := ImGui.GetWindowDrawList();

    Bg_Color :: Vec4f.{1,1,1,0.2};
    Outline_Color :: Vec4f.{1,1,1,1};
    Outline_Dash_Length :: 5.0;
    Outline_Dash_Space :: 5.0;
    Outline_Dash_Thickness :: 1.0;

    draw_list.AddRectFilled(draw_list, .{xx x1, xx y1}, .{xx x2, xx y2}, ImGui.ColorConvertFloat4ToU32(Bg_Color));

    AddDashedLine(draw_list,
        .{xx x1, xx y1}, .{xx x2, xx y1},
        Outline_Dash_Length, Outline_Dash_Space,
        ImGui.ColorConvertFloat4ToU32(Outline_Color),
        Outline_Dash_Thickness
    );
    AddDashedLine(draw_list,
        .{xx x1, xx y2}, .{xx x2, xx y2},
        Outline_Dash_Length, Outline_Dash_Space,
        ImGui.ColorConvertFloat4ToU32(Outline_Color),
        Outline_Dash_Thickness
    );
    AddDashedLine(draw_list,
        .{xx x1, xx y1}, .{xx x1, xx y2},
        Outline_Dash_Length, Outline_Dash_Space,
        ImGui.ColorConvertFloat4ToU32(Outline_Color),
        Outline_Dash_Thickness
    );
    AddDashedLine(draw_list,
        .{xx x2, xx y1}, .{xx x2, xx y2},
        Outline_Dash_Length, Outline_Dash_Space,
        ImGui.ColorConvertFloat4ToU32(Outline_Color),
        Outline_Dash_Thickness
    );
}
