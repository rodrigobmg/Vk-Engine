#import "Common";
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
using,only(.["+","-","*","/"]) Basic;

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

    speed_mult := 1.0;
    base_speed := 0.1;
    fast_speed := 1.0;
    rotation_speed := 0.2;
    rotation_smoothing := 0.3;
}

UpdateCamera :: (using camera : *Camera) {
    is_moving_camera := IsMouseButtonDown(.Right);
    if is_moving_camera {
        SDL_SetRelativeMouseMode(SDL_TRUE);

        if !IsKeyDown(.Ctrl) {
            movement_input : Vec3f;
            movement_input.x = GetKeyAxisValue(.A, .D);
            movement_input.y = GetKeyAxisValue(.Q, .E);
            movement_input.z = GetKeyAxisValue(.S, .W);
            movement_input = Normalized(movement_input);

            speed := ifx IsKeyDown(.Shift)
                then fast_speed
                else base_speed;

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

    w, h : s32;
    SDL_GetWindowSizeInPixels(g_window, *w, *h);

    aspect := w / cast(float, h);
    projection = Mat4fPerspectiveProjection(fov_in_degrees, aspect, z_near, z_far);
}

g_default_base_color : *Asset(Texture2D);
g_default_normal_map : *Asset(Texture2D);
g_default_metallic_roughness_map : *Asset(Texture2D);
g_default_emissive : *Asset(Texture2D);

LoadDefaultAssets :: () {
    g_default_base_color = LoadAsset(Texture2D, "Default_BaseColor.png");
    g_default_normal_map = LoadAsset(Texture2D, "Default_Normal.png");
    g_default_metallic_roughness_map = LoadAsset(Texture2D, "Default_MetallicRoughness.png");
    g_default_emissive = LoadAsset(Texture2D, "Default_Emissive.png");
}

UnloadDefaultAssets :: () {
    RemoveRef(g_default_base_color);
    RemoveRef(g_default_normal_map);
    RemoveRef(g_default_metallic_roughness_map);
    RemoveRef(g_default_emissive);
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
        write_proc=null
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

    LoadDefaultAssets();
    defer UnloadDefaultAssets();

    camera : Camera;
    world : World;
    defer DestroyWorld(*world);

    if g_preferences.startup_scene {
        LoadWorldFromDirectory(*world, g_preferences.startup_scene);
    }

    /*
    sun := SpawnEntity(*world, DirectionalLightEntity, "Sun");
    sun.color = .{1,1,1};
    sun.intensity = 1;
    sun.cast_shadows = true;
    // sun.local_rotation = QuatfLookAt(Normalized(Vec3f.{-0.1, -1, -1}), .{0,1,0});
    sun.local_rotation = QuatfLookAt(.{0,0,1}, .{0,1,0});
    UpdateWorldTransform(*world, sun);

    plane := SpawnEntity(*world, MeshEntity, "Pebbles");
    plane.mesh = LoadAsset(Mesh, "Plane.mesh");
    plane.material = LoadAsset(Material, "Pebbles.mat");
    plane.local_position.z = 4;
    plane.local_scale = .{4,4,4};
    // plane.local_rotation = QuatfFromAxisAngle(.{1,0,0}, -Pi * 0.5);
    UpdateWorldTransform(*world, plane);

    if true {
        damaged_helmet := SpawnEntity(*world, MeshEntity, "DamagedHelmet");
        damaged_helmet.mesh = LoadAsset(Mesh, "DamagedHelmet/DamagedHelmet.mesh");
        damaged_helmet.material = LoadAsset(Material, "DamagedHelmet/DamagedHelmet.mat");
        damaged_helmet.local_position.z = 5;
        damaged_helmet.local_rotation = QuatfFromAxisAngle(.{0,1,0}, Pi);
        UpdateWorldTransform(*world, damaged_helmet);
    } else {
        N :: 10;

        light := SpawnEntity(*world, PointLightEntity);
        light.color = .{1,1,1};
        light.intensity = 1;
        light.local_position = .{N * 0.25, N * 0.25, -4};
        UpdateWorldTransform(*world, light);

        light = SpawnEntity(*world, PointLightEntity);
        light.color = .{1,1,1};
        light.intensity = 1;
        light.local_position = .{N * 0.75, N * 0.25, -4};
        UpdateWorldTransform(*world, light);

        light = SpawnEntity(*world, PointLightEntity);
        light.color = .{1,1,1};
        light.intensity = 1;
        light.local_position = .{N * 0.25, N * 0.75, -4};
        UpdateWorldTransform(*world, light);

        light = SpawnEntity(*world, PointLightEntity);
        light.color = .{1,1,1};
        light.intensity = 1;
        light.local_position = .{N * 0.75, N * 0.75, -4};
        UpdateWorldTransform(*world, light);

        for i : 0..N - 1 {
            for j : 0..N - 1 {
                sphere := SpawnEntity(*world, MeshEntity);
                sphere.mesh = LoadAsset(Mesh, "Sphere.mesh");
                sphere.material = AllocNewAsset(Material, TPrint("Sphere % %", i, j));
                sphere.material.base_color_tint = .{1,0,0};
                sphere.material.metallic = i / cast(float, N - 1);
                sphere.material.roughness = j / cast(float, N - 1);
                sphere.local_position = .{i * 1.5, j * 1.5, 0};
                UpdateWorldTransform(*world, sphere);
            }
        }
    }
    */

    defer WaitForGPUIdle(); // Before destroying anything, we need to ensure all work is done

    frame_times : [60]float;
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

                Println("% avg, % min, % max", cast(int, 1 / avg), cast(int, 1 / max), cast(int, 1 / min));
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

            if event.type == SDL_WINDOWEVENT {
                if event.window.event == SDL_WINDOWEVENT_RESIZED
                || event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED
                || event.window.event == SDL_WINDOWEVENT_MINIMIZED {
                    should_recreate_swapchain = true;
                }
            }

            HandleInputEvent(event);
        }

        UnloadAllUnreferencedAssets();
        HandleShaderHotReloading();
        ProcessDataDirectoryChanges();

        UpdateCamera(*camera);

        // time := cast(float, Basic.to_float64_seconds(Basic.current_time_monotonic()));
        // sun.local_position = .{0,Sin(time * 0.1),Cos(time * 0.1)};
        // sun.local_rotation = QuatfLookAt(-sun.local_position, .{0,1,0});
        // UpdateWorldTransform(*world, sun);

        w, h : s32;
        SDL_GetWindowSizeInPixels(g_window, *w, *h);

        if should_recreate_swapchain && w > 0 && h > 0 {
            CreateRenderTargets();
            RecreateSwapchain();
        }

        RenderFrame(*world, *camera);
    }
}

#placeholder Runtime_Tests;

ExecuteRuntimeTests :: ()
{
    #insert -> string
    {
        builder : StringBuilder;

        for Runtime_Tests
        {
            Appendln(*builder, "% ();", it);
        }

        return StringBuilderBuild(*builder);
    }
}
