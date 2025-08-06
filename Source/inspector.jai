// @Todo: IntRange

CustomInspector :: struct {
    proc : CustomInspectorProc;
    data : *void;
}

InspectorContext :: struct {
    world : *World;
    toplevel_struct_type : *Type_Info_Struct;
    toplevel_struct_default_init_ptr : *void;
    absolute_offset : s64;
}

InitInspectorContext :: (using ctx : *InspectorContext, type : *Type_Info) {
    absolute_offset = 0;

    if type.type == .STRUCT {
        toplevel_struct_type = xx type;

        if toplevel_struct_type.initializer {
            toplevel_struct_default_init_ptr = Alloc(toplevel_struct_type.runtime_size ,, Temp);
            toplevel_struct_type.initializer(toplevel_struct_default_init_ptr);
        }
    }
}

ResetInspectorContext :: (using ctx : *InspectorContext) {
    toplevel_struct_type = null;
    toplevel_struct_default_init_ptr = null;
    absolute_offset = 0;
}

IsDefaultValue :: (using ctx : *InspectorContext, value : Any) -> bool {
    if !toplevel_struct_default_init_ptr {
        for i : 0..value.type.runtime_size - 1 {
            if cast(*u8, value.value_pointer)[i] != 0 {
                return false;
            }
        }

        return true;
    }

    return memcmp(value.value_pointer, toplevel_struct_default_init_ptr + absolute_offset, value.type.runtime_size) == 0;
}

ResetValue :: (using ctx : *InspectorContext, value : Any) {
    if !toplevel_struct_default_init_ptr {
        memset(value.value_pointer, 0, value.type.runtime_size);
        return;
    }

    memcpy(value.value_pointer, toplevel_struct_default_init_ptr + absolute_offset, value.type.runtime_size);
}

ResetButton :: (using ctx : *InspectorContext, value : Any) -> InteractionState {
    if IsDefaultValue(ctx, value) {
        return 0;
    }

    ImGui.SameLine();

    state : InteractionState;
    if ImGui.Button(Icon_Refresh_MDI) {
        ResetValue(ctx, value);

        state |= .Started;
        state |= .Submitted;
    }

    ImGui.SetItemTooltip("Reset value to default");

    return state;
}

// @Todo: move notes array to InspectorContext
CustomInspectorProc :: #type (label : *u8, ctx : *InspectorContext, any : Any, notes : []string, data : *void) -> InteractionState;

g_custom_inspectors_initialized : bool;
g_custom_inspectors : HashMap(*Type_Info, CustomInspector);

GetCustomInspectorForType :: inline (type : *Type_Info) -> *CustomInspector {
    result := HashMapGetPtr(*g_custom_inspectors, type);
    if result {
        return result;
    }

    if type.type == .STRUCT {
        poly_source := TypeGetSourcePolymorph(xx type);
        if poly_source {
            return HashMapGetPtr(*g_custom_inspectors, poly_source);
        }
    }

    return null;
}

RegisterCustomInspector :: (type : Type, proc : CustomInspectorProc, data : *void) -> bool {
    return RegisterCustomInspector(cast(*Type_Info) type, proc, data);
}

RegisterCustomInspector :: (type : *Type_Info, proc : CustomInspectorProc, data : *void) -> bool {
    inspector, exists := HashMapInsert(*g_custom_inspectors, type);
    if exists {
        return false;
    }

    inspector.proc = proc;
    inspector.data = data;

    return true;
}

UnregisterCustomInspector :: (type : Type) -> bool {
    return UnregisterCustomInspector(cast(*Type_Info) type);
}

UnregisterCustomInspector :: (type : *Type_Info) -> bool {
    return HashMapRemove(*g_custom_inspectors, type);
}

InspectEntityGUID :: (label : *u8, using ctx : *InspectorContext, any : Any, notes : []string, data : *void) -> InteractionState {
    guid := cast(*EntityGUID) any.value_pointer;

    g := ImGui.GetCurrentContext();

    not_editable := ArrayFindFirst(notes, "NotEditable") != -1;

    LabelTextButton(label, "%", guid.*);
    state := LastItemInteractionState();

    if !not_editable {
        ImGui.SetItemTooltip("Drag and drop EntityGUID");
    }

    if ImGui.BeginDragDropSource() {
        ImGui.Text("Entity %", guid.*);

        ImGui.SetDragDropPayload("EntityGUID", guid, size_of(EntityGUID));
        ImGui.EndDragDropSource();
    }

    if !not_editable && !(g.LastItemData_.InFlags & .Disabled) && ImGui.BeginDragDropTarget() {
        payload := ImGui.AcceptDragDropPayload("EntityGUID");
        if payload {
            Assert(payload.DataSize == size_of(EntityGUID));
            guid.* = (cast(*EntityGUID) payload.Data).*;

            state |= .Started;
            state |= .Submitted;
        }

        ImGui.EndDragDropTarget();
    }

    if ImGui.BeginPopupContextItem(CTPrint("Entity %###context_menu", guid.*)) {
        ImGui.BeginDisabled(guid.* == Null_Entity_GUID);
        if ImGui.MenuItem("Open In Inspector") {
            SelectEntity(guid, focus=false);
        }
        ImGui.EndDisabled();

        if ImGui.MenuItem("Copy entity GUID") {
            CopyEntityGUID(guid.*);
        }

        if !not_editable {
            ImGui.BeginDisabled(!g_editor_has_copied_entity_guid);
            if ImGui.MenuItem("Paste entity GUID") {
                guid.* = g_editor_last_copied_entity_guid;
                state |= .Started;
                state |= .Submitted;
            }
            ImGui.EndDisabled();

            if ImGui.MenuItem("Clear") {
                guid.* = .{};
                state |= .Started;
                state |= .Submitted;
            }
        }

        ImGui.EndPopup();
    }

    if !not_editable {
        state |= ResetButton(ctx, any);
    }

    return state;
}

InspectAssetPointer :: (label : *u8, using ctx : *InspectorContext, any : Any, notes : []string, data : *void) -> InteractionState {
    imgui_ctx := ImGui.GetCurrentContext();
    info_pointer := cast(*Type_Info_Pointer, Devariantize(any.type));
    info_asset := cast(*Type_Info_Struct, info_pointer.pointer_to);
    asset_type := cast(*Type, *GetAssetType(info_asset)).*;
    value := cast(**AssetCommonData, any.value_pointer).*;

    if !label {
        label = "<unnamed field>";
    }

    if !value {
        LabelTextButton(label, "(null % asset)", asset_type);
    } else {
        LabelTextButton(label, "%", value.asset_name);
    }

    if IsItemDoubleClicked() {
        OpenAssetBrowserPopupFor(asset_type, cast(**void, any.value_pointer));
    }

    if ImGui.BeginDragDropSource() {
        if !value {
            ImGui.Text("% asset (null)", asset_type);
        } else {
            ImGui.Text("% asset '%'", asset_type, value.asset_name);
        }

        payload_type := CTPrint("%", asset_type);
        ImGui.SetDragDropPayload(payload_type, any.value_pointer, size_of(*void));
        ImGui.EndDragDropSource();
    }

    state := LastItemInteractionState();

    not_editable := ArrayFindFirst(notes, "NotEditable") != -1;
    if !not_editable && !(imgui_ctx.LastItemData_.InFlags & .Disabled) && ImGui.BeginDragDropTarget() {
        payload_type := CTPrint("%", asset_type);
        asset_payload := ImGui.AcceptDragDropPayload(payload_type);
        if asset_payload {
            Assert(asset_payload.DataSize == size_of(*void));

            RemoveRefDynamic(asset_type, value);

            cast(**void, any.value_pointer).* = cast(**void, asset_payload.Data).*;

            new_asset := cast(**void, any.value_pointer).*;
            if new_asset {
                AddRefDynamic(asset_type, new_asset);
            }

            state |= .Started;
            state |= .Submitted;
        }

        asset_name_payload := ImGui.AcceptDragDropPayload("Asset Name");
        if asset_name_payload {
            asset_name := MakeString(cast(*u8) asset_name_payload.Data);

            RemoveRefDynamic(asset_type, value);

            new_asset := LoadAssetDynamic(asset_type, asset_name);
            cast(**void, any.value_pointer).* = new_asset;

            state |= .Started;
            state |= .Submitted;
        }

        ImGui.EndDragDropTarget();
    }

    if ImGui.BeginPopupContextItem(CTPrint("Asset %###context_menu", asset_type)) {
        if !not_editable && ImGui.MenuItem("Clear") {
            RemoveRefDynamic(asset_type, value);
            cast(**void, any.value_pointer).* = null;

            state |= .Started;
            state |= .Submitted;
        }

        if ImGui.MenuItem("Re-export asset", enabled=value != null) {
            if !SaveAssetDynamic(asset_type, value) {
                LogError("Could not save asset '%'", value.asset_name);
            }
        }

        if asset_type == Material {
            if ImGui.MenuItem("Open In Material Editor", enabled=value != null) {
                OpenMaterialEditor(xx value);
            }
        }

        ImGui.EndPopup();
    }

    if !not_editable {
        old_asset := cast(**void, any.value_pointer).*;
        state |= ResetButton(ctx, any);
        new_asset := cast(**void, any.value_pointer).*;

        if old_asset && old_asset != new_asset {
            RemoveRefDynamic(asset_type, old_asset);
        }

        if new_asset && old_asset != new_asset {
            AddRefDynamic(asset_type, new_asset);
        }
    }

    return state;
}

InspectAsset :: (label : *u8, using ctx : *InspectorContext, any : Any, notes : []string, data : *void) -> InteractionState {
    asset := cast(*AssetCommonData) any.value_pointer;
    if label {
        ImGui.LabelText(label, asset.asset_name);
    } else {
        ImGui.LabelText("<unnamed field>", asset.asset_name);
    }

    return 0;
}

InspectQuatfAsEulerAngles :: (label : *u8, using ctx : *InspectorContext, any : Any, notes : []string, data : *void) -> InteractionState {
    return InspectQuaternionAsEulerAngles(label, ctx, cast(*Quatf) any.value_pointer, notes, data);
}

InspectQuatdAsEulerAngles :: (label : *u8, using ctx : *InspectorContext, any : Any, notes : []string, data : *void) -> InteractionState {
    return InspectQuaternionAsEulerAngles(label, ctx, cast(*Quatd) any.value_pointer, notes, data);
}

InspectQuaternionAsEulerAngles :: (label : *u8, using ctx : *InspectorContext, q : *$Q/Quat, notes : []string, data : *void) -> InteractionState {
    storage := ImGui.GetStateStorage();
    current_euler_x_store := ImGui.GetID(CTPrint("%.current.x", label));
    current_euler_y_store := ImGui.GetID(CTPrint("%.current.y", label));
    current_euler_z_store := ImGui.GetID(CTPrint("%.current.z", label));
    dragging_store := ImGui.GetID(CTPrint("%.dragging", label));

    Rotation_Order :: EulerAnglesRotationOrder.YXZ;

    euler_angles : Vec3(Q.T);
    if storage.GetBool(storage, dragging_store, false) {
        euler_angles = .{
            xx storage.GetFloat(storage, current_euler_x_store),
            xx storage.GetFloat(storage, current_euler_y_store),
            xx storage.GetFloat(storage, current_euler_z_store),
        };
    } else {
        euler_angles = ToEulerAngles(q, Rotation_Order);
        euler_angles = ToDegs(euler_angles);
    }

    // Just for aesthetic
    for * euler_angles.n {
        if it.* == -0.0 {
            it.* = 0.0;
        }
    }

    state, _, edited_value := DragVector(label, euler_angles.n, step=0.1);

    ImGui.SameLine();

    if ImGui.Button(Icon_Refresh_MDI) {
        q.* = .{};
        return .Started | .Submitted;
    }

    if edited_value >= 0 {
        storage.SetBool(storage, dragging_store, true);
        storage.SetFloat(storage, current_euler_x_store, xx euler_angles.x);
        storage.SetFloat(storage, current_euler_y_store, xx euler_angles.y);
        storage.SetFloat(storage, current_euler_z_store, xx euler_angles.z);

        q.* = QuatFromEulerAnglesOrdered(ToRads(euler_angles), Rotation_Order);
    } else {
        storage.SetBool(storage, dragging_store, false);
    }

    return state;
}

InitCustomInspectors :: () {
    RegisterCustomInspector(EntityGUID, InspectEntityGUID, null);
    RegisterCustomInspector(TypeGetSourcePolymorph(type_info(Asset(struct{}))), InspectAsset, null);
    RegisterCustomInspector(Quatf, InspectQuatfAsEulerAngles, null);
    RegisterCustomInspector(Quatd, InspectQuatdAsEulerAngles, null);

    g_custom_inspectors_initialized = true;
}

Capitalize :: (str : string) -> string {
    first_letter := true;
    for i : 0..str.count - 1 {
        if Basic.is_alpha(str[i]) {
            if first_letter {
                str[i] = Basic.to_upper(str[i]);
                first_letter = false;
            }
        }

        if str[i] == #char "_" {
            str[i] = #char " ";
            first_letter = true;
        }
    }

    return str;
}

ShowInspector :: (label : *u8, world : *World, any : Any, notes : []string = .[], use_custom_inspector := true) -> InteractionState {
    type := Devariantize(any.type);

    ctx : InspectorContext;
    ctx.world = world;
    InitInspectorContext(*ctx, any.type);

    return ShowInspector(label, *ctx, any, notes, use_custom_inspector);
}

ShowInspector :: (label : *u8, using ctx : *InspectorContext, any : Any, notes : []string = .[], use_custom_inspector := true) -> InteractionState {
    if !g_custom_inspectors_initialized {
        InitCustomInspectors();
    }

    ImGui.PushID(any.value_pointer);
    defer ImGui.PopID();

    old_ctx := ctx.*;
    defer ctx.* = old_ctx;

    if !label {
        label = "<unnamed field>";
    }

    custom_inspector := ifx use_custom_inspector then GetCustomInspectorForType(any.type);
    if custom_inspector {
        return custom_inspector.proc(label, ctx, any, notes, custom_inspector.data);
    }

    type := Devariantize(any.type);
    ptr := any.value_pointer;

    no_tree := ArrayFindFirst(notes, "InspectorNoTree") != -1;

    custom_inspector = ifx use_custom_inspector then GetCustomInspectorForType(any.type);
    if custom_inspector {
        return custom_inspector.proc(label, ctx, any, notes, custom_inspector.data);
    }

    if (type == type_info(Vec3f) || type == type_info(Vec4f))
    && ArrayFindFirst(notes, "ColorEdit") != -1 {
        if type == type_info(Vec3f) {
            ImGui.ColorEdit3(label, (cast(*[3]float) ptr));
        } else {
            ImGui.ColorEdit4(label, (cast(*[4]float) ptr));
        }

        state := LastItemInteractionState();
        state |= ResetButton(ctx, any);

        return state;
    }

    if #complete type.type == {
    case .BOOL;
        ImGui.Checkbox(label, cast(*bool) ptr);
        state := LastItemInteractionState();
        state |= ResetButton(ctx, any);

        return state;

    case .INTEGER;
        int_info := cast(*Type_Info_Integer) type;
        if int_info.signed {
            if type.runtime_size == {
            case 1; ImGui.DragScalar(label, .S8, ptr);
            case 2; ImGui.DragScalar(label, .S16, ptr);
            case 4; ImGui.DragScalar(label, .S32, ptr);
            case 8; ImGui.DragScalar(label, .S64, ptr);
            }
        } else {
            if type.runtime_size == {
            case 1; ImGui.DragScalar(label, .U8, ptr);
            case 2; ImGui.DragScalar(label, .U16, ptr);
            case 4; ImGui.DragScalar(label, .U32, ptr);
            case 8; ImGui.DragScalar(label, .U64, ptr);
            }
        }

        state := LastItemInteractionState();
        state |= ResetButton(ctx, any);

        return state;

    case .FLOAT;
        min, max : float64;
        has_range := false;

        for notes {
            // @Todo: Use GetNote/ParseNote
            if StringStartsWith(it, "FloatRange(") && it[it.count - 1] == #char ")" {
                str := StringAdvance(it, "FloatRange(".count);
                str.count -= 1;

                val, ok, remainder := Basic.string_to_float64(str);
                if !ok || remainder.count == 0 || remainder[0] != #char "," {
                    break;
                }

                str = StringAdvance(remainder, 1);
                val2:, ok, remainder = Basic.string_to_float64(str);
                if !ok || remainder.count > 0 {
                    break;
                }

                min = val;
                max = val2;
                has_range = true;

                break;
            }
        }

        if type.runtime_size == 4 {
            speed := 0.1;
            min32 := cast(float) min;
            max32 := cast(float) max;
            p_min, p_max : *float;
            if has_range {
                p_min = *min32;
                p_max = *max32;
                speed = Abs(max32 - min32) / 20.0;
            }

            ImGui.DragScalar(label, .Float, ptr, v_speed=speed, p_min=p_min, p_max=p_max);
        } else {
            speed := 0.1;
            p_min, p_max : *float64;
            if has_range {
                p_min = *min;
                p_max = *max;
                speed = cast(float) Abs(max - min) / 20.0;
            }

            ImGui.DragScalar(label, .Double, ptr, p_min=p_min, p_max=p_max);
        }

        state := LastItemInteractionState();
        state |= ResetButton(ctx, any);

        return state;

    case .STRUCT;
        struct_info := cast(*Type_Info_Struct) type;
        if struct_info.textual_flags & .UNION {
            return 0;
        }

        ImGui.PushID(ptr);
        defer ImGui.PopID();

        if !toplevel_struct_type {
            InitInspectorContext(ctx, struct_info);
        }

        state : InteractionState;
        is_vector, vector_T, vector_N := GetVectorTypeInfo(struct_info);
        if is_vector {
            state = DragVector(label, TypeInfoToImGuiDataType(vector_T), ptr, xx vector_N, 0.01);
            state |= ResetButton(ctx, any);

            return state;
        }

        opened := true;
        if !no_tree {
            opened = ImGui.TreeNodeEx(label);
        }

        if opened {
            highest_offset := -1;
            for struct_info.members {
                if it.flags & .CONSTANT || it.offset_in_bytes <= highest_offset {
                    continue;
                }

                no_custom_inspector := false;
                not_editable := false;
                member_no_tree := false;
                color_edit := false;
                found_serialize_note := false;
                show_in_inspector := false;
                for note : it.notes {
                    if StringStartsWith(note, "Serialize(") {
                        found_serialize_note = true;
                    }

                    if note == {
                    case "ShowInInspector";
                        show_in_inspector = true;
                    case "HideInInspector";
                        continue it;
                    case "NoCustomInspector";
                        no_custom_inspector = true;
                    case "NotEditable";
                        not_editable = true;
                    case "InspectorNoTree";
                        member_no_tree = true;
                    case "ColorEdit";
                        color_edit = true;
                    }
                }

                if !found_serialize_note && !show_in_inspector {
                    continue it;
                }

                highest_offset = it.offset_in_bytes;

                ImGui.BeginDisabled(not_editable);
                defer ImGui.EndDisabled();

                item : Any;
                item.type = it.type;
                item.value_pointer = ptr + it.offset_in_bytes;
                member_label := ifx it.name && it.name != "_" then CStringClone(it.name ,, Temp);
                member_label = Capitalize(MakeString(member_label)).data;

                if member_no_tree {
                    if member_label {
                        ImGui.SeparatorText(member_label);
                    } else {
                        ImGui.Separator();
                    }
                }

                absolute_offset = old_ctx.absolute_offset + it.offset_in_bytes;

                state |= ShowInspector(member_label, ctx, item, notes=it.notes, use_custom_inspector=!no_custom_inspector);
            }
        }

        if !no_tree && opened {
            ImGui.TreePop();
        }

        return state;

    case .POINTER;
        info_pointer := cast(*Type_Info_Pointer, type);
        value := cast(**void, ptr).*;

        ResetInspectorContext(ctx); // Reset context, ResetValue assumes data to be continuous so we cannot go through pointers

        // Special case for *Asset types
        if info_pointer.pointer_to.type == .STRUCT
        && TypeGetSourcePolymorph(xx info_pointer.pointer_to) == TypeGetSourcePolymorph(type_info(DummyAsset)) {
            return InspectAssetPointer(label, ctx, any, notes, null);
        } else if !value {
            if label {
                ImGui.LabelText(label, "(null)");
            } else {
                ImGui.LabelText("<unnamed field>", "(null)");
            }

            return 0;
        }

        pointer : Any;
        pointer.type = info_pointer.pointer_to;
        pointer.value_pointer = value;

        return ShowInspector(label, ctx, pointer, notes=notes, use_custom_inspector=use_custom_inspector);

    case .STRING;
        ImGui.LabelText(label, "%", any);

    case .ARRAY;
        array_info := cast(*Type_Info_Array) type;
        array_data := null;
        array_count := -1;
        resizable := false;

        if array_info.array_type == {
        case .FIXED;
            array_data = ptr;
            array_count = array_info.array_count;
        case .VIEW;
            array_data = (cast(*Array_View_64) ptr).data;
            array_count = (cast(*Array_View_64) ptr).count;
            ResetInspectorContext(ctx); // Reset context, ResetValue assumes data to be continuous so we cannot go through pointers
        case .RESIZABLE;
            array_data = (cast(*Resizable_Array) ptr).data;
            array_count = (cast(*Resizable_Array) ptr).count;
            resizable = true;
            ResetInspectorContext(ctx); // Reset context, ResetValue assumes data to be continuous so we cannot go through pointers
        }

        state : InteractionState;

        opened := true;
        if !no_tree {
            opened = ImGui.TreeNodeEx(label);
        }

        if opened {
            for i : 0..array_info.array_count - 1 {
                item : Any;
                item.value_pointer = ptr + i * array_info.element_type.runtime_size;
                item.type = array_info.element_type;
                item_label : *u8;

                if no_tree {
                    if !label {
                        item_label = CTPrint("<unnamed field> [%]", i);
                    } else {
                        item_label = CTPrint("% [%]", MakeString(label), i);
                    }
                } else {
                    item_label = CTPrint("[%]", i);
                }

                absolute_offset = old_ctx.absolute_offset + i * array_info.element_type.runtime_size;

                state |= ShowInspector(item_label, ctx, item, notes=notes, use_custom_inspector=use_custom_inspector);
            }
        }

        if !no_tree && opened {
            ImGui.TreePop();
        }

        return state;

    case .ENUM;
        enum_info := cast(*Type_Info_Enum) type;

        current_value := 0;
        if enum_info.runtime_size == {
        case 1; current_value = cast(s64) (cast(*s8)  ptr).*;
        case 2; current_value = cast(s64) (cast(*s16) ptr).*;
        case 4; current_value = cast(s64) (cast(*s32) ptr).*;
        case 8; current_value = cast(s64) (cast(*s64) ptr).*;
        }

        state : InteractionState;
        if ImGui.BeginCombo(label, CTPrint("%", any)) {
            for enum_info.values {
                name := enum_info.names[it_index];
                if ImGui.MenuItem(CStringClone(name ,, Temp), selected=current_value == it) {
                    if enum_info.runtime_size == {
                    case 1; (cast(*s8)  ptr).* = xx it;
                    case 2; (cast(*s16) ptr).* = xx it;
                    case 4; (cast(*s32) ptr).* = xx it;
                    case 8; (cast(*s64) ptr).* = xx it;
                    }

                }

                state |= LastItemInteractionState();
            }

            ImGui.EndCombo();
        }

        state |= ResetButton(ctx, any);

        return state;

    // Below are the types we cannot inspect
    case .ANY;
    case .VARIANT;
    case .PROCEDURE;
    case .OVERLOAD_SET;
    case .POLYMORPHIC_VARIABLE;
    case .TYPE;
    case .CODE;
    case .VOID;
    case .UNTYPED_ENUM;
    case .UNTYPED_LITERAL;
    }

    return 0;
}
