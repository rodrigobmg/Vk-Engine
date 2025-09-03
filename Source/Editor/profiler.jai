g_show_cpu_profiler := false;
g_shown_events : [..]EditorProfilingEvent;
g_sorted_events : []EditorProfilingEvent;
g_editor_profiler_max_events : s32 = 50;

EditorProfilingEvent :: struct {
    start_time : Basic.Apollo_Time;
    end_time : Basic.Apollo_Time;
    name : string;
    filename : string;
    line_number : u32;
    thread_index : u32;
    parent : s32;
    children : [..]u32;
}

GetTotalTime :: (event : EditorProfilingEvent) -> Basic.Apollo_Time {
    return event.end_time - event.start_time;
}

GetSelfTime :: (event : EditorProfilingEvent) -> Basic.Apollo_Time {
    total_time := event.end_time - event.start_time;
    children_time : Basic.Apollo_Time;
    for event.children {
        child := g_shown_events[it];
        children_time += child.end_time - child.start_time;
    }

    return total_time - children_time;
}

#scope_file

BuildEventList :: () {
    SetParent :: (event : *EditorProfilingEvent, index : int) {
        if index < 0 {
            event.parent = -1;
            return;
        }

        parent := *g_shown_events[index];
        ArrayPush(*parent.children, xx ArrayGetIndex(g_shown_events, event));
        event.parent = xx index;
    }

    for * g_shown_events {
        Free(it.name.data);
        ArrayFree(*it.children);
    }

    ArrayClear(*g_shown_events);

    for g_cpu_profiler.profiled_threads {
        if it.frames.count <= 0 {
            continue;
        }

        thread_event_index := g_shown_events.count;
        frame := it.frames[it.frames.count - 1];
        for i : frame.first_event_index..frame.last_event_index {
            it := g_cpu_profiler.all_events[i];
            event := ArrayPush(*g_shown_events);
            event.name = StringClone(it.name);
            event.filename = it.filename;
            event.line_number = it.line_number;
            event.start_time = it.start_time;
            event.end_time = it.end_time;
            event.thread_index = it.thread_index;
            SetParent(event, thread_event_index + it.parent_index_relative_to_thread);
        }
    }

    Free(g_sorted_events.data);
    g_sorted_events = ArrayClone(g_shown_events);
}

Column_Name :: 0;
Column_Self_Time :: 1;
Column_Total_Time :: 2;
Column_Location :: 3;

SortEvents :: (specs : ImGui.TableSortSpecs) {
    Compare :: (a : EditorProfilingEvent, b : EditorProfilingEvent, specs : ImGui.TableSortSpecs) -> int {
        for i : 0..specs.SpecsCount - 1 {
            column_spec := specs.Specs[i];
            delta := 0;
            if column_spec.ColumnUserID == {
            case Column_Name;
                delta = StringCompare(a.name, b.name);

            case Column_Self_Time;
                time_a := GetSelfTime(a);
                time_b := GetSelfTime(b);
                delta = Basic.compare_apollo_times(time_a, time_b);

            case Column_Total_Time;
                time_a := GetTotalTime(a);
                time_b := GetTotalTime(b);
                delta = Basic.compare_apollo_times(time_a, time_b);

            case Column_Location;
                delta = StringCompare(
                    a.filename,
                    b.filename
                );

                if !delta {
                    delta = a.line_number - b.line_number;
                }
            }

            if delta > 0 {
                return ifx column_spec.SortDirection_ == xx ImGui.SortDirection.Ascending
                    then 1 else -1;
            }
            if delta < 0 {
                return ifx column_spec.SortDirection_ == xx ImGui.SortDirection.Ascending
                    then -1 else 1;
            }
        }

        return Basic.compare_apollo_times(a.start_time, b.start_time);
    } @NoProfile

    QuickSort(g_sorted_events, specs, Compare);
}

#scope_export

ShowCPUProfiler :: () {
    if !g_show_cpu_profiler {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{450, 700}, .FirstUseEver);
    if !ImGui.Begin("CPU Profiler", *g_show_cpu_profiler, flags=.HorizontalScrollbar) {
        return;
    }

    if !g_cpu_profiler.paused {
        BuildEventList();
    }

    PushButtonColor(.EmphasisButton);
    if ImGui.Button("Record") {
        ClearProfilingData(*g_cpu_profiler);
        ResumeProfiler(*g_cpu_profiler);
    }
    PopButtonColor();

    ImGui.SameLine();

    if ImGui.Button("Pause") {
        PauseProfiler(*g_cpu_profiler);
    }

    if g_cpu_profiler.paused {
        ImGui.SameLine();

        ImGui.Text("Paused");
    }

    ImGui.SliderInt("Max Events", *g_editor_profiler_max_events, 1, 100);

    table_flags := ImGui.TableFlags.Resizable | .RowBg | .ScrollY
        | .Sortable | .SortMulti | .Hideable | .Reorderable;
    if ImGui.BeginTable("Events", 4, table_flags) {
        defer ImGui.EndTable();

        ImGui.TableSetupColumn("Name", .NoHide, user_id=Column_Name);
        ImGui.TableSetupColumn("Self Time", .DefaultSort | .PreferSortDescending, user_id=Column_Self_Time);
        ImGui.TableSetupColumn("Total Time", .PreferSortDescending, user_id=Column_Total_Time);
        ImGui.TableSetupColumn("Location", user_id=Column_Location);
        ImGui.TableSetupScrollFreeze(0, 1); // Keep headers visible when scrolling
        ImGui.TableHeadersRow();

        sort_specs := ImGui.TableGetSortSpecs();
        if !g_cpu_profiler.paused || sort_specs && sort_specs.SpecsDirty {
            SortEvents(sort_specs);
            sort_specs.SpecsDirty = false;
        }

        for i : 0..Min(g_sorted_events.count, g_editor_profiler_max_events) - 1 {
            event := *g_sorted_events[i];
            ImGui.TableNextRow();
            ImGui.TableSetColumnIndex(Column_Name);
            ImGui.Text("%", event.name);

            ImGui.TableSetColumnIndex(Column_Self_Time);
            ImGui.Text("% ms", Basic.to_float64_seconds(GetSelfTime(event)) * 1000);

            ImGui.TableSetColumnIndex(Column_Total_Time);
            ImGui.Text("% ms", Basic.to_float64_seconds(GetTotalTime(event)) * 1000);

            ImGui.TableSetColumnIndex(Column_Location);
            ImGui.Text("%:%", event.filename, event.line_number);
        }
    }

    ClearProfilingData(*g_cpu_profiler); // We only use the last frame data, so clear it all
}
