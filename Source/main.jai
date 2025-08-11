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
System :: #import "System";
Math :: #import "Math";
Basic :: #import "Basic"()(MEMORY_DEBUGGER=false);
using,only(.["+","-","*","/","<",">","=="]) Basic;

ImGui :: #import "ImGui";
ImGui_SDL :: #import "ImGui/Impl/SDL";

#if OS == .WINDOWS {
    Win32 :: #import "Win32"(File_System=true);
}

#load "math_and_utils.jai";
#load "vk_initialization.jai";
#load "abstraction_layer.jai";
#load "glsl_packing.jai";
#load "input.jai";
#load "serialize_deserialize.jai";
#load "asset.jai";
#load "entity.jai";
#load "renderer.jai";
#load "preferences.jai";
#load "editor.jai";

Debug_Vulkan_Allocations :: false;
Vulkan_Break_On_Error :: true;

Append   :: StringBuilderAppend;
Appendln :: StringBuilderAppendLine;

SDL_GetWindowSizeInPixels :: (win: *SDL_Window, w: *s32, h: *s32) #foreign SDL2;

g_window : *SDL_Window;

g_preferences : Preferences;

g_num_cpus : s32;
g_num_worker_threads : s32;

Second_To_Nano :: 1000000000;
Frame_Max_Wait :: Second_To_Nano * 4;

g_default_base_color : *Asset(Texture2D);
g_default_normal_map : *Asset(Texture2D);
g_default_metallic_roughness_map : *Asset(Texture2D);
g_default_emissive : *Asset(Texture2D);
g_default_environment_map : *Asset(EnvironmentMap);
g_default_material : *Asset(Material);

g_avg_frame_time : float = 1 / 60.0;
g_min_frame_time : float = 1 / 60.0;
g_max_frame_time : float = 1 / 60.0;

LoadDefaultAssets :: () {
    g_default_base_color = LoadAsset(Texture2D, "Default_BaseColor.png");
    g_default_normal_map = LoadAsset(Texture2D, "Default_Normal.png");
    g_default_metallic_roughness_map = LoadAsset(Texture2D, "Default_MetallicRoughness.png");
    g_default_emissive = LoadAsset(Texture2D, "Default_Emissive.png");
    g_default_environment_map = LoadAsset(EnvironmentMap, "Default_EnvironmentMap.png");
    g_default_material = LoadAsset(Material, "Default_Material.mat");
}

UnloadDefaultAssets :: () {
    DerefAsset(*g_default_base_color);
    DerefAsset(*g_default_normal_map);
    DerefAsset(*g_default_metallic_roughness_map);
    DerefAsset(*g_default_emissive);
    DerefAsset(*g_default_environment_map);
    DerefAsset(*g_default_material);
}

main :: () {
    console_logger : ConsoleLogger;
    console_logger.print_stack_trace = false;
    InitConsoleLogger(*console_logger);
    SetContextLogger(*console_logger, ConsoleLoggerProc);

    context.print_style.struct_printer = StructPrinter;

    defer #if Basic.MEMORY_DEBUGGER {
        Basic.report_memory_leaks();
    }

    g_num_cpus = System.get_number_of_processors(.ALL_LOGICAL);
    g_num_cpus = Clamp(g_num_cpus, 1, 200);
    g_num_worker_threads = Max(g_num_cpus - 1, 2);
    LogMessage("CPU Information: % logical CPUs, default worker thread count: %", g_num_cpus, g_num_worker_threads);

    if file_exists("engine.prefs") {
        LoadPreferences(*g_preferences, "engine.prefs");
    }

    defer FreePreferences(*g_preferences);

    {
        ScopeLongFormStructFormat();
        LogMessage("Preferences: %", g_preferences ,, log_section=*Log_Preferences);
    }

    g_window = SDL_CreateWindow("Vulkan", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, xx g_preferences.startup_window_width, xx g_preferences.startup_window_height, SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE);
    defer SDL_DestroyWindow(g_window);

    InitGfxContext(g_window);
    defer DestroyGfxContext();

    InitRenderer();
    defer CleanupRenderer();

    InitAssetCache(
        *g_Mesh_asset_cache,
        load_proc=LoadMeshFromMemory,
        post_load_proc=null,
        unload_proc=DestroyMesh,
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

    defer DestroyAllAssetCaches();

    ImGui.CreateContext();
    defer ImGui.DestroyContext();

    InitEditor();
    defer CleanupEditor();

    ImGui_SDL.Init(g_window);
    defer ImGui_SDL.Terminate();

    InitImGuiRenderer();
    defer DestroyImGuiRenderer();

    LoadDefaultAssets();
    defer UnloadDefaultAssets();

    world : World;
    defer DestroyWorld(*world);

    if g_preferences.startup_scene {
        LoadWorldFromDirectory(*world, g_preferences.startup_scene);
    }

    defer WaitForGPUIdle(); // Before destroying anything, we need to ensure all work is done

    frame_times : [120]float;
    frame_time_index : int;
    quit := false;
    while !quit {
        frame_start := Basic.current_time_monotonic();
        defer {
            frame_end := Basic.current_time_monotonic();
            frame_time := Basic.to_float64_seconds(frame_end - frame_start);
            frame_times[frame_time_index] = xx frame_time;

            if frame_time_index == frame_times.count - 1 {
                frame_time_index = 0;

                min := F32_Inf;
                max := -F32_Inf;
                avg : float;
                for frame_times {
                    min = Min(min, it);
                    max = Max(max, it);
                    avg += it;
                }

                avg /= frame_times.count;

                g_min_frame_time = min;
                g_max_frame_time = max;
                g_avg_frame_time = avg;
            } else {
                frame_time_index += 1;
            }
        };

        Basic.memory_visualizer_per_frame_update();

        ResetTemporaryStorage();

        UpdateInputState();

        resized := false;
        should_recreate_swapchain := false;
        event : SDL_Event;
        while SDL_PollEvent(*event) {
            if event.type == SDL_QUIT {
                quit = true;
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
        }

        w, h := GetWindowPixelSize(g_window);

        if should_recreate_swapchain && w > 0 && h > 0 {
            CreateRenderTargets();
            RecreateSwapchain();
        }

        UnloadAllUnreferencedAssets();
        HandleShaderHotReloading();
        ProcessDataDirectoryChanges();

        DestroyKilledEntities(*world);

        ImGui_SDL.NewFrame();
        ImGui.NewFrame();

        UpdateEditor(*world);

        ImGui.Render();

        RenderFrame(*world, *g_editor_camera);
    }
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
