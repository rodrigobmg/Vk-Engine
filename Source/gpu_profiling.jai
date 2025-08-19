// @Todo: make sure the device supports timestamp queries
// @Todo: make this thread safe
// https://docs.vulkan.org/samples/latest/samples/api/timestamp_queries/README.html

GPUFrameProfiler :: struct {
    query_pools : [Gfx_Num_Frames_In_Flight]VkQueryPool;
    query_results : []u64;
    query_pool_capacity : u32;
    events_for_frame : [Gfx_Num_Frames_In_Flight][]GPUProfilingEvent;
    num_events_for_frame : [Gfx_Num_Frames_In_Flight]int;
    recorded_frames : [..][]GPUProfilingEvent;
    frame_index : int;
}

GPUProfilingEvent :: struct {
    name : string;
    index : int;
    start_gpu_time : u64 = 0xffffffffffffffff;
    end_gpu_time : u64 = 0xffffffffffffffff;
    elapsed_time_ms : float64;
}

InitGPUFrameProfiler :: (profiler : *GPUFrameProfiler, max_events : int) {
    profiler.* = .{};

    pool_create_info : VkQueryPoolCreateInfo;
    pool_create_info.queryType = .TIMESTAMP;
    pool_create_info.queryCount = xx (max_events * 2);
    for * profiler.query_pools {
        result := vkCreateQueryPool(g_gfx_context.device, *pool_create_info, g_vk_alloc_callbacks, it);
        Assert(result == .SUCCESS, "Could not create query pool for GPU frame profiler");
    }

    profiler.query_results = AllocArray(u64, max_events * 2);

    profiler.query_pool_capacity = xx (max_events * 2);

    for * profiler.events_for_frame {
        it.* = AllocArray(GPUProfilingEvent, max_events);
    }

    ArrayReserve(*profiler.recorded_frames, 1000);
}

DestroyGPUFrameProfiler :: (profiler : *GPUFrameProfiler) {
    for profiler.recorded_frames {
        Free(it.data);
    }

    ArrayFree(*profiler.recorded_frames);

    for profiler.events_for_frame {
        Free(it.data);
    }

    Free(profiler.query_results.data);

    for profiler.query_pools {
        vkDestroyQueryPool(g_gfx_context.device, it, g_vk_alloc_callbacks);
    }

    profiler.* = .{};
}

ProfilerBeginFrame :: (profiler : *GPUFrameProfiler) {
    profiler.frame_index += 1;

    // Only query results starting at the third frame, because frames prior don't have anything
    if profiler.frame_index >= 3 {
        vkGetQueryPoolResults(g_gfx_context.device, profiler.query_pools[g_gfx_context.frame_in_flight], 0, profiler.query_pool_capacity, profiler.query_pool_capacity * size_of(u64), profiler.query_results.data, size_of(u64), ._64_BIT);

        frame := ArrayPush(*profiler.recorded_frames);
        frame.* = AllocArray(GPUProfilingEvent, profiler.num_events_for_frame[g_gfx_context.frame_in_flight]);
        for * frame.* {
            it.* = profiler.events_for_frame[g_gfx_context.frame_in_flight][it_index];
            it.start_gpu_time = profiler.query_results[it_index * 2 + 0];
            it.end_gpu_time   = profiler.query_results[it_index * 2 + 1];
            it.elapsed_time_ms = (it.end_gpu_time - it.start_gpu_time) * GetGfxLimits().timestamp_tick_period / 1000000.0;
        }
    }

    vkResetQueryPool(g_gfx_context.device, profiler.query_pools[g_gfx_context.frame_in_flight], 0, profiler.query_pool_capacity);

    profiler.num_events_for_frame[g_gfx_context.frame_in_flight] = 0;
}

ProfilerBeginEvent :: (cmd_buffer : *GfxCommandBuffer, profiler : *GPUFrameProfiler, name : string) -> *GPUProfilingEvent {
    if profiler.num_events_for_frame[g_gfx_context.frame_in_flight] >= profiler.events_for_frame[g_gfx_context.frame_in_flight].count {
        return null;
    }

    event := *profiler.events_for_frame[g_gfx_context.frame_in_flight][profiler.num_events_for_frame[g_gfx_context.frame_in_flight]];
    event.name = name;
    event.index = profiler.num_events_for_frame[g_gfx_context.frame_in_flight];

    vkCmdWriteTimestamp(cmd_buffer.cmd_buffer, .TOP_OF_PIPE_BIT, profiler.query_pools[g_gfx_context.frame_in_flight], xx (event.index * 2));
    profiler.num_events_for_frame[g_gfx_context.frame_in_flight] += 1;

    return event;
}

ProfilerEndEvent :: (cmd_buffer : *GfxCommandBuffer, profiler : *GPUFrameProfiler, event : *GPUProfilingEvent) {
    if !event {
        return;
    }

    vkCmdWriteTimestamp(cmd_buffer.cmd_buffer, .BOTTOM_OF_PIPE_BIT, profiler.query_pools[g_gfx_context.frame_in_flight], xx (event.index * 2 + 1));
}
