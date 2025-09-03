g_show_cpu_profiler := false;
g_shown_events : [..]EditorProfilingEvent;
g_editor_profiler_max_events : s32 = 100;

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

GetTotalTime :: (event : *EditorProfilingEvent) -> float {
    return xx Basic.to_float64_seconds(event.end_time - event.start_time);
}

GetSelfTime :: (event : *EditorProfilingEvent) -> float {
    total_time := event.end_time - event.start_time;
    children_time : Basic.Apollo_Time;
    for event.children {
        child := g_shown_events[it];
        children_time += child.end_time - child.start_time;
    }

    return xx Basic.to_float64_seconds(total_time - children_time);
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

    if ImGui.Button("Record") {
        ClearProfilingData(*g_cpu_profiler);
        ResumeProfiler(*g_cpu_profiler);
    }

    ImGui.SameLine();

    if ImGui.Button("Pause") {
        PauseProfiler(*g_cpu_profiler);
    }

    if g_cpu_profiler.paused {
        ImGui.SameLine();

        ImGui.Text("Paused");
    }

    ImGui.SliderInt("Max Events", *g_editor_profiler_max_events, 1, Max_Profiling_Events_Per_Frame);

    table_flags := ImGui.TableFlags.Resizable | .RowBg | .PadOuterX | .ScrollY;
    if ImGui.BeginTable("Events", 3, table_flags) {
        defer ImGui.EndTable();

        ImGui.TableSetupColumn("Name");
        ImGui.TableSetupColumn("Self Time");
        ImGui.TableSetupColumn("Total Time");
        ImGui.TableSetupScrollFreeze(0, 1); // Keep headers visible when scrolling
        ImGui.TableHeadersRow();

        for i : 0..Min(g_shown_events.count, g_editor_profiler_max_events) - 1 {
            event := *g_shown_events[i];
            ImGui.TableNextRow();
            ImGui.TableSetColumnIndex(0);
            ImGui.Text("%", event.name);

            ImGui.TableSetColumnIndex(1);
            ImGui.Text("% ms", GetSelfTime(event) * 1000);

            ImGui.TableSetColumnIndex(2);
            ImGui.Text("% ms", GetTotalTime(event) * 1000);

        }
    }

    ClearProfilingData(*g_cpu_profiler); // We only use the last frame data, so clear it all
}
