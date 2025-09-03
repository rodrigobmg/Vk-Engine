g_show_cpu_profiler := false;
g_shown_events : [..]ProfilingEvent;

ShowCPUProfiler :: () {
    if !g_show_cpu_profiler {
        return;
    }

    defer ImGui.End();

    ImGui.SetNextWindowSize(.{450, 700}, .FirstUseEver);
    if !ImGui.Begin("CPU Profiler", *g_show_cpu_profiler, flags=.HorizontalScrollbar) {
        return;
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

    table_flags := ImGui.TableFlags.Resizable | .RowBg | .PadOuterX | .ScrollY;
    if ImGui.BeginTable("Events", 2, table_flags) {
        defer ImGui.EndTable();

        ImGui.TableSetupColumn("Name");
        ImGui.TableSetupColumn("Self Time");
        ImGui.TableSetupScrollFreeze(0, 1); // Keep headers visible when scrolling
        ImGui.TableHeadersRow();

        if !g_cpu_profiler.paused {
            if g_cpu_profiler.profiled_threads.count <= 0 {
                return;
            }

            main_thread := g_cpu_profiler.profiled_threads[0];
            if main_thread.frames.count <= 0 {
                return;
            }

            last_frame := main_thread.frames[main_thread.frames.count - 1];

            ArrayClear(*g_shown_events);
            for i : last_frame.first_event_index..last_frame.last_event_index {
                event := g_cpu_profiler.all_events[i];
                ArrayPush(*g_shown_events, event);
            }

            QuickSort(g_shown_events, (a, b) => -Basic.compare_apollo_times(a.end_time - a.start_time, b.end_time - b.start_time));
        }

        for event : g_shown_events {
            ImGui.TableNextRow();
            ImGui.TableSetColumnIndex(0);
            ImGui.Text("%", event.name);

            ImGui.TableSetColumnIndex(1);
            self_time := Basic.to_float64_seconds(event.end_time - event.start_time);
            ImGui.Text("% ms", self_time * 1000);
        }
    }

    ClearProfilingData(*g_cpu_profiler); // We only use the last frame data, so clear it all
}
