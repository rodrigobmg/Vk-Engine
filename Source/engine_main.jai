Debug_Vulkan_Allocations :: false;
Vulkan_Break_On_Error :: true;

Frame_Max_Wait :: Second_To_Nano * 4;

g_window : *SDL_Window;

g_console_logger : ConsoleLogger;

InitEngine :: () {
    InitConsoleLogger(*g_console_logger);
    SetContextLogger(*g_console_logger, ConsoleLoggerProc);
    g_console_logger.print_stack_trace = false;

    context.print_style.struct_printer = StructPrinter;

    g_num_cpus = System.get_number_of_processors(.ALL_LOGICAL);
    g_num_cpus = Clamp(g_num_cpus, 1, 200);
    g_default_num_worker_threads = Max(g_num_cpus - 1, 2);
    LogMessage("CPU Information: % logical CPUs, default worker thread count: %", g_num_cpus, g_default_num_worker_threads);

    LoadPreferences(*g_preferences, "engine.prefs");

    InitFrameProfiler(*g_cpu_profiler);

    g_window = SDL_CreateWindow("Vulkan", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, xx g_preferences.startup_window_width, xx g_preferences.startup_window_height, SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE);

    InitGfxContext(g_window);

    InitRenderer();
}

TerminateEngine :: () {
    CleanupRenderer();

    DestroyGfxContext();

    SDL_DestroyWindow(g_window);

    FreePreferences(*g_preferences);

    #if Basic.MEMORY_DEBUGGER {
        Basic.report_memory_leaks();
    }
}

#scope_file

g_num_cpus : s32;
g_default_num_worker_threads : s32;

#scope_export

GetNumCPUs :: inline () -> s32 {
    return g_num_cpus;
}

GetDefaultNumWorkerThreads :: inline () -> s32 {
    return g_default_num_worker_threads;
}

g_default_base_color : *Asset(Texture2D);
g_default_normal_map : *Asset(Texture2D);
g_default_metallic_roughness_map : *Asset(Texture2D);
g_default_emissive : *Asset(Texture2D);
g_default_environment_map : *Asset(EnvironmentMap);
g_default_material : *Asset(Material);

InitAssets :: () {
    InitAssetCache(
        *g_StaticMesh_asset_cache,
        load_proc=LoadStaticMeshFromMemory,
        post_load_proc=null,
        unload_proc=DestroyStaticMesh,
        write_proc=null
    );
    InitAssetCache(
        *g_SkinnedMesh_asset_cache,
        load_proc=LoadSkinnedMeshFromMemory,
        post_load_proc=null,
        unload_proc=DestroySkinnedMesh,
        write_proc=null
    );
    InitAssetCache(
        *g_ArmatureAnimation_asset_cache,
        load_proc=LoadArmatureAnimationFromMemory,
        post_load_proc=null,
        unload_proc=DestroyArmatureAnimation,
        write_proc=null
    );
    InitAssetCache(
        *g_Material_asset_cache,
        load_proc=LoadMaterialFromMemory,
        post_load_proc=null,
        unload_proc=DestroyMaterial,
        write_proc=WriteMaterial
    );
    InitAssetCache(
        *g_Texture2D_asset_cache,
        load_proc=LoadTexture2DFromMemory,
        post_load_proc=null,
        unload_proc=DestroyTexture2D,
        write_proc=null
    );
    InitAssetCache(
        *g_EnvironmentMap_asset_cache,
        load_proc=LoadEnvironmentMapFromMemory,
        post_load_proc=null,
        unload_proc=DestroyEnvironmentMap,
        write_proc=null
    );

    g_default_base_color = LoadAssetPermanent(Texture2D, "Default_BaseColor.png");
    g_default_normal_map = LoadAssetPermanent(Texture2D, "Default_Normal.png");
    g_default_metallic_roughness_map = LoadAssetPermanent(Texture2D, "Default_MetallicRoughness.png");
    g_default_emissive = LoadAssetPermanent(Texture2D, "Default_Emissive.png");
    g_default_environment_map = LoadAssetPermanent(EnvironmentMap, "Default_EnvironmentMap.png");
    g_default_material = LoadAssetPermanent(Material, "Default_Material.mat");
}

CleanupAssets :: () {
    DestroyAllAssetCaches();
}

#scope_file

g_last_frame_start_time : Basic.Apollo_Time;
g_frame_times : [120]float;
g_frame_time_index : int;

g_avg_frame_time : float = 1 / 60.0;
g_min_frame_time : float = 1 / 60.0;
g_max_frame_time : float = 1 / 60.0;
g_last_frame_time : float = 1 / 60.0;

UpdateFrameTime :: () {
    if g_last_frame_start_time != .{} {
        frame_end := Basic.current_time_monotonic();
        frame_time := Basic.to_float64_seconds(frame_end - g_last_frame_start_time);

        g_last_frame_time = xx frame_time;

        g_frame_times[g_frame_time_index] = xx frame_time;

        if g_frame_time_index == g_frame_times.count - 1 {
            g_frame_time_index = 0;

            min := F32_Inf;
            max := -F32_Inf;
            avg : float;
            for g_frame_times {
                min = Min(min, it);
                max = Max(max, it);
                avg += it;
            }

            avg /= g_frame_times.count;

            g_min_frame_time = min;
            g_max_frame_time = max;
            g_avg_frame_time = avg;
        } else {
            g_frame_time_index += 1;
        }
    };

    g_last_frame_start_time = Basic.current_time_monotonic();
}

#scope_export

GetFrameTimes :: inline () -> min : float, max : float, avg : float {
    return g_min_frame_time, g_max_frame_time, g_avg_frame_time;
}

GetDeltaTime :: inline () -> float {
    return g_last_frame_time;
}

g_should_quit := false;

EventCallback :: #type (SDL_Event);

#scope_file
g_event_callbacks : [..]EventCallback;
#scope_export

RegisterEventCallback :: (callback : EventCallback) -> bool {
    return ArrayPushUnique(*g_event_callbacks, callback);
}

UnregisterEventCallback :: (callback : EventCallback) -> bool {
    index := ArrayFindFirst(g_event_callbacks, callback);
    if index < 0 {
        return false;
    }

    ArrayOrderedRemove(*g_event_callbacks, index);
    return true;
}

EngineLoopStart :: () {
    UpdateFrameTime();

    Basic.memory_visualizer_per_frame_update();

    ResetTemporaryStorage();

    UpdateInputState();

    should_recreate_swapchain := false;
    event : SDL_Event;
    while SDL_PollEvent(*event) {
        if event.type == SDL_QUIT {
            g_should_quit = true;
        }

        ImGui_SDL.HandleWindowEvent(event);

        if event.type == SDL_WINDOWEVENT {
            if event.window.event == SDL_WINDOWEVENT_RESIZED
            || event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED
            || event.window.event == SDL_WINDOWEVENT_MINIMIZED {
                should_recreate_swapchain = true;
            }
        }

        HandleInputEvent(event);
        for g_event_callbacks {
            it(event);
        }
    }

    w, h := GetWindowPixelSize(g_window);

    if should_recreate_swapchain && w > 0 && h > 0 {
        CreateRenderTargets();
        RecreateSwapchain();
    }

    UnloadAllUnreferencedAssets();
    HandleShaderHotReloading();
    ProcessDataDirectoryChanges();
}

#placeholder Runtime_Tests;

ExecuteRuntimeTests :: () {
    #insert -> string {
        builder : StringBuilder;

        for Runtime_Tests {
            Appendln(*builder, "%();", it);
        }

        return StringBuilderBuild(*builder);
    }
}

#load "utils.jai";
#load "input.jai";
#load "serialize_deserialize.jai";
#load "asset.jai";
#load "entity.jai";
#load "component.jai";
#load "world.jai";
#load "preferences.jai";
#load "profiler.jai";

#load "Graphics/graphics.jai";
#load "Physics/physics.jai";
#load "Editor/editor.jai";

#load "Tests/flying_lights.jai";
#load "Tests/intersections.jai";

using Common :: #import "Common";
#poke_name Common operator==;

#import "SDL";
#import "Vulkan";
#import "Linalg";
#import "File";
#import "File_Utilities";
#import "Thread";
#import "Process";
#import "Hash_Map";
#import "Paged_Array";
#import "Type_Utils";
#import "String";
#import "Print_Vars";
System :: #import "System";
Math :: #import "Math";
Basic :: #import "Basic"()(MEMORY_DEBUGGER=false);
using,only(.["+","-","*","/","<",">","=="]) Basic;

ImGui :: #import "ImGui";
ImGui_Ext :: #import "ImGuiExt";
ImGui_SDL :: #import "ImGui/Impl/SDL";

#if OS == .WINDOWS {
    Win32 :: #import "Win32"(File_System=true);
}
