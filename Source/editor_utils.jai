InteractionState :: enum_flags {
    Started;
    Interacting;
    Cancelled;
    Submitted;
}

LastItemInteractionState :: inline () -> InteractionState {
    result : InteractionState;

    if ImGui.IsItemActive() {
        result |= .Interacting;
    }
    if ImGui.IsItemActivated() {
        result |= .Started;
    }
    if ImGui.IsItemDeactivatedAfterEdit() {
        result |= .Submitted;
    } else if ImGui.IsItemDeactivated() {
        result |= .Cancelled;
    }

    return result;
}

IsItemDoubleClicked :: (mouse_button : ImGui.MouseButton = .Left) -> bool {
    return ImGui.IsMouseDoubleClicked(mouse_button) && ImGui.IsItemHovered(.None);
}

LayoutHorizontal :: () {
    window := ImGui.GetCurrentWindow();
    window.DC.LayoutType_ = .Horizontal;
}
@NoProfile

LayoutVertical :: () {
    window := ImGui.GetCurrentWindow();

    if window.DC.LayoutType_ == .Horizontal {
        ImGui.NewLine();
    }

    window.DC.LayoutType_ = .Vertical;
}
@NoProfile

PushStyleCompact :: inline () {
    style := ImGui.GetStyle();
    ImGui.PushStyleVar(.FramePadding, .{style.FramePadding.x, Round(style.FramePadding.y * 0.5)});
    ImGui.PushStyleVar(.ItemSpacing, .{Round(style.ItemSpacing.x * 0.6), Round(style.ItemSpacing.y * 0.6)});
}
@NoProfile

PopStyleCompact :: inline () {
    ImGui.PopStyleVar(2);
}
@NoProfile

HelpMarker :: (fmt_str : string, args : ..Any) {
    ImGui.TextDisabled(Icon_Help_Circle_Outline_MDI);
    if ImGui.BeginItemTooltip() {
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35);
        ImGui.Text(fmt_str, ..args);
        ImGui.PopTextWrapPos();
        ImGui.EndTooltip();
    }
}
@PrintLike
@NoProfile

SameLineSeparator :: () {
    window := ImGui.GImGui.CurrentWindow;
    if window.SkipItems {
        return;
    }

    same_line := window.DC.IsSameLine;

    flags := ifx same_line || window.DC.LayoutType_ == .Horizontal
        then ImGui.SeparatorFlags.Vertical
        else ImGui.SeparatorFlags.Horizontal;

    if window.DC.CurrentColumns {
        flags |= .SpanAllColumns;
    }

    ImGui.SeparatorEx(flags, 1);

    if same_line {
        ImGui.SameLine();
    }
}
@NoProfile

FilterTest :: (case_sensitive : bool, str : string, filter : string) -> bool {
    if filter.count > 0 {
        if case_sensitive && !contains(str, filter) {
            return false;
        }
        if !case_sensitive && !contains_nocase(str, filter) {
            return false;
        }
    }

    return true;
}
@NoProfile

IconCheckbox :: (
    label : string, value : *bool,
    unchecked := Icon_Checkbox_Blank_MDI,
    intermediate := Icon_Checkbox_Intermediate_MDI,
    checked := Icon_Checkbox_Marked_MDI
) -> bool {
    window := ImGui.GetCurrentWindow();
    if window.SkipItems {
        return false;
    }

    g := ImGui.GImGui;
    style := g.Style_;
    id := window.GetID(window, label);

    icon_size := ImGui.CalcTextSize(unchecked, true);
    label_size := ImGui.CalcTextSize(label, true);

    pos := window.DC.CursorPos;
    total_bb := ImGui.ImRect.{pos, pos};
    total_bb.Max.x += icon_size.x + ifx label_size.x > 0 then style.ItemInnerSpacing.x + label_size.x;
    total_bb.Max.y += label_size.y + style.FramePadding.y * 2;

    ImGui.ItemSize(total_bb.Max - total_bb.Min, style.FramePadding.y);
    if !ImGui.ItemAdd(total_bb, id) {
        return false;
    }

    hovered, held : bool;
    pressed := ImGui.ButtonBehavior(total_bb, id, *hovered, *held);
    if pressed {
        value.* = !value.*;
        ImGui.MarkItemEdited(id);
    }

    ImGui.RenderNavHighlight(total_bb, id);

    icon := unchecked;
    mixed_value := (g.LastItemData_.InFlags & .MixedValue) != 0;
    if mixed_value {
        icon = intermediate;
    } else if value.* {
        icon = checked;
    }

    check_pos := Vec2f.{pos.x, pos.y + style.FramePadding.y};

    ImGui.RenderText(check_pos, icon);

    label_pos := Vec2f.{pos.x + icon_size.x + style.ItemInnerSpacing.x, pos.y + style.FramePadding.y};

    if g.LogEnabled {
        ImGui.LogRenderedText(*label_pos, ifx mixed_value then "[~]" else ifx value.* then "[x]" else "[ ]");
    }

    if label_size.x > 0 {
        ImGui.RenderText(label_pos, label);
    }

    return pressed;
}
@NoProfile

Toggle :: (label : *u8, value : *bool) -> bool {
    Assert(value != null);

    frame_bg := ImGui.GetStyle().Colors[ImGui.Col.FrameBg];
    frame_bg_hovered := ImGui.GetStyle().Colors[ImGui.Col.FrameBgHovered];
    frame_bg_active := ImGui.GetStyle().Colors[ImGui.Col.FrameBgActive];

    if value.* {
        ImGui.PushStyleColor(.Button, frame_bg_active);
        ImGui.PushStyleColor(.ButtonActive, frame_bg_active);
    } else {
        ImGui.PushStyleColor(.Button, frame_bg);
        ImGui.PushStyleColor(.ButtonActive, frame_bg_active);
    }

    ImGui.PushStyleColor(.ButtonHovered, frame_bg_hovered);

    defer ImGui.PopStyleColor(3);

    pressed := ImGui.Button(label);
    if pressed {
        value.* = !value.*;
    }

    return pressed;
}
@NoProfile

SelectableButton :: (label : *u8, selected : bool, size := Vec2f.{0,0}) -> bool {
    frame_bg := ImGui.GetStyle().Colors[ImGui.Col.FrameBg];
    frame_bg_hovered := ImGui.GetStyle().Colors[ImGui.Col.FrameBgHovered];
    frame_bg_active := ImGui.GetStyle().Colors[ImGui.Col.FrameBgActive];

    if selected {
        ImGui.PushStyleColor(.Button, frame_bg_active);
        ImGui.PushStyleColor(.ButtonActive, frame_bg_active);
    } else {
        ImGui.PushStyleColor(.Button, frame_bg);
        ImGui.PushStyleColor(.ButtonActive, frame_bg_active);
    }

    ImGui.PushStyleColor(.ButtonHovered, frame_bg_hovered);

    defer ImGui.PopStyleColor(3);

    pressed := ImGui.Button(label, size);

    return pressed;
}
@NoProfile

ClickableText :: (text : string) -> bool {
    window := ImGui.GetCurrentWindow();
    if window.SkipItems {
        return false;
    }

    g := ImGui.GImGui;

    text_pos := Vec2f.{window.DC.CursorPos.x, window.DC.CursorPos.y + window.DC.CurrLineTextBaseOffset};

    id := ImGui.GetID(text);

    rendered_text := text;
    rendered_text.count = cast(s64) (ImGui.FindRenderedTextEnd(text) - text.data);

    text_size := ImGui.CalcTextSize(rendered_text, false);

    bb := ImGui.ImRect.{text_pos, text_pos + text_size};
    ImGui.ItemSize(text_size, 0);
    if !ImGui.ItemAdd(bb, id)
        return false;

    hovered : bool;
    held : bool;
    pressed := ImGui.ButtonBehavior(bb, id, *hovered, *held, 0);

    draw_list := ImGui.GetWindowDrawList();

    color : Vec4f = ---;
    if held && hovered {
        color = ImGui.GetStyle().Colors[ImGui.Col.ButtonActive];
    } else if hovered {
        color = ImGui.GetStyle().Colors[ImGui.Col.ButtonHovered];
    } else {
        color = ImGui.GetStyle().Colors[ImGui.Col.Text];
    }

    ucolor := ImGui.ColorConvertFloat4ToU32(color);

    draw_list.AddText(draw_list, bb.Min, ucolor, rendered_text);

    if hovered {
        p0 := Vec2f.{bb.Min.x, bb.Max.y};
        p1 := Vec2f.{bb.Max.x, bb.Max.y};

        draw_list.AddLine(draw_list, p0, p1, ucolor, 1);
    }

    return pressed;
}
@NoProfile

LabelTextButton :: (label : *u8, fmt : string, args : ..Any) -> bool {
    window := ImGui.GetCurrentWindow();
    if window.SkipItems {
        return false;
    }

    style := ImGui.GetStyle();
    w := ImGui.CalcItemWidth();

    value_text := TPrint(fmt, ..args);
    value_size := ifx value_text then ImGui.CalcTextSize(value_text, false);
    label_size := ImGui.CalcTextSize(label, null, true);

    pos := window.DC.CursorPos;
    value_bb := ImGui.ImRect.{
        pos,
        pos + .{w, value_size.y + style.FramePadding.y * 2}
    };
    total_bb := ImGui.ImRect.{
        pos,
        pos + .{
            w + ifx label_size.x > 0 then style.ItemInnerSpacing.x + label_size.x,
            Max(value_size.y, label_size.y) + style.FramePadding.y * 2
        }
    };

    ImGui.ItemSize(total_bb.Max - total_bb.Min, style.FramePadding.y);
    id := window.GetID(window, label, null);
    if !ImGui.ItemAdd(value_bb, id) {
        return false;
    }

    pressed := ImGui.ButtonBehavior(value_bb, id, null, null);
    ImGui.SetItemTooltip("%", value_text);

    if value_text {
        ImGui.RenderTextClipped(
            value_bb.Min + style.FramePadding, value_bb.Max,
            value_text,
            *value_size, .{0,0}
        );
    }

    if label_size.x > 0 {
        ImGui.RenderText(.{value_bb.Max.x + style.ItemInnerSpacing.x, value_bb.Min.y + style.FramePadding.y}, label);
    }

    return pressed;
}
@PrintLike
@NoProfile

TypeInfoToImGuiDataType :: inline (info : *Type_Info) -> ImGui.DataType {
    if info == type_info(u8) {
        return .U8;
    }
    if info == type_info(s8) {
        return .S8;
    }
    if info == type_info(u16) {
        return .U16;
    }
    if info == type_info(s16) {
        return .S16;
    }
    if info == type_info(u32) {
        return .U32;
    }
    if info == type_info(s32) {
        return .S32;
    }
    if info == type_info(u64) {
        return .U64;
    }
    if info == type_info(s64) {
        return .S64;
    }
    if info == type_info(float) {
        return .Float;
    }
    if info == type_info(float64) {
        return .Double;
    }

    Panic("Invalid type info");
    return 0;
}
@NoProfile

DragVector :: (label : *u8, values : []$T, step : float = 1, show_labels := false) -> InteractionState, activated : bool, edited_value : int
#modify { return TypeIsNumeric(T); } {
    #if T == {
    case u8;      Data_Type :: ImGui.DataType.U8;
    case s8;      Data_Type :: ImGui.DataType.S8;
    case u16;     Data_Type :: ImGui.DataType.U16;
    case s16;     Data_Type :: ImGui.DataType.S16;
    case u32;     Data_Type :: ImGui.DataType.U32;
    case s32;     Data_Type :: ImGui.DataType.S32;
    case u64;     Data_Type :: ImGui.DataType.U64;
    case s64;     Data_Type :: ImGui.DataType.S64;
    case float;   Data_Type :: ImGui.DataType.Float;
    case float64; Data_Type :: ImGui.DataType.Double;
    }

    state, activated, edited_value := DragVector(label, Data_Type, values.data, xx values.count, step, show_labels);

    return state, activated, edited_value;
}
@NoProfile

DragVector :: (label : *u8, data_type : ImGui.DataType, values : *void, count : s32, step : float = 1, show_labels := false) -> InteractionState, activated : bool, edited_value : int {
    Assert(count < 5);

    ImGui.PushID(label);
    defer ImGui.PopID();

    window := ImGui.GetCurrentWindow();
    style := ImGui.GetStyle();
    ImGui.PushMultiItemsWidths(count, ImGui.CalcItemWidth());

    line_height := ImGui.GetFrameHeight();
    label_size : Vec2f;
    if show_labels {
        label_size = .{line_height * 0.9, line_height};
    } else {
        label_size = .{Max(style.FrameRounding, 4), line_height};
    }

    Labels :: string.["X","Y","Z","W"];
    Invisible_Labels :: string.["##X","##Y","##Z","##W"];
    Colors :: Vec4f.[
        .{0.878, 0.102, 0.102, 1},
        .{0.243, 0.729, 0.078, 1},
        .{0.102, 0.125, 0.878, 1},
        .{0.831, 0.667, 0.114, 1},
    ];

    data_type_size := 0;
    if data_type == {
    case .U8; #through;
    case .S8;
        data_type_size = 1;
    case .U16; #through;
    case .S16;
        data_type_size = 2;
    case .U32; #through;
    case .S32;
        data_type_size = 4;
    case .U64; #through;
    case .S64;
        data_type_size = 8;
    case .Float;
        data_type_size = 4;
    case .Double;
        data_type_size = 8;
    }

    state : InteractionState;
    modified := false;
    activated := false;
    edited_value := -1;
    g := ImGui.GImGui;
    for i : 0..count - 1 {
        label_bb : ImGui.ImRect;
        label_bb.Min = window.DC.CursorPos;
        label_bb.Max = label_bb.Min + label_size;

        dummy_size := label_size - .{style.FrameRounding, 0};
        ImGui.ItemSize(dummy_size, style.FramePadding.y);

        ImGui.SameLine(spacing=0);

        ImGui.SetNextItemWidth(window.DC.ItemWidth - dummy_size.x);

        ImGui.DragScalar(Invisible_Labels[i].data, data_type, values + data_type_size * i, step);
        item_state := LastItemInteractionState();
        if item_state {
            edited_value = i;
        }

        state |= item_state;
        activated |= ImGui.IsItemActivated();

        col := ImGui.ColorConvertFloat4ToU32(Colors[i]);
        RenderFrameExt(label_bb.Min, label_bb.Max, col, true, style.FrameRounding, .RoundCornersLeft);
        if show_labels {
            ImGui.RenderTextClipped(
                label_bb.Min + style.FramePadding, label_bb.Max - style.FramePadding,
                Labels[i], null,
                style.ButtonTextAlign, *label_bb
            );
        }

        ImGui.SameLine();

        ImGui.PopItemWidth();
    }

    ImGui.Text("%", to_string(label));

    return state, activated, edited_value;
}
@NoProfile

RenderFrameExt :: (min : Vec2f, max : Vec2f, fill_col : u32, border := true, rounding := 0.0, flags : ImGui.ImDrawFlags = 0) {
    window := ImGui.GetCurrentWindow();
    draw_list := window.DrawList;
    draw_list.AddRectFilled(draw_list, min, max, fill_col, rounding, flags);

    border_size := ImGui.GetStyle().FrameBorderSize;
    if border && border_size > 0 {
        draw_list.AddRect(draw_list,
            min + .{1,1}, max + .{1,1},
            ImGui.GetColorU32(.BorderShadow),
            rounding, flags, border_size
        );
        draw_list.AddRect(draw_list,
            min, max,
            ImGui.GetColorU32(.Border),
            rounding, flags, border_size
        );
    }
}
@NoProfile
