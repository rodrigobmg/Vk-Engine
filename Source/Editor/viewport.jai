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

UpdateEditorViewport :: (world : *World) {
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
}
