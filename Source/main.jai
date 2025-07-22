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

#load "vk_initialization.jai";
#load "abstraction_layer.jai";
#load "glsl_packing.jai";
#load "mesh.jai";
#load "texture2d.jai";
#load "input.jai";
#load "serialize_deserialize.jai";
#load "asset.jai";
#load "entity.jai";
#load "renderer.jai";
#load "material.jai";
#load "mesh_buffer.jai";
#load "allocator.jai";
#load "binding_set_allocator.jai";

Vulkan_Break_On_Error :: true;

Append   :: StringBuilderAppend;
Appendln :: StringBuilderAppendLine;

SDL_GetWindowSizeInPixels :: (win: *SDL_Window, w: *s32, h: *s32) #foreign SDL2;

g_window : *SDL_Window;

g_num_cpus : s32;
g_num_worker_threads : s32;

Nano_To_Second :: 1000000000;

g_color_texture : GfxTexture;
g_depth_texture : GfxTexture;

g_shaders : struct {
    mesh_vert : GfxShader;
    mesh_frag : GfxShader;
}

LoadAllShaders :: () -> bool {
    g_shaders.mesh_vert = LoadGfxShader("mesh.vert");
    if IsNull(*g_shaders.mesh_vert) {
        return false;
    }

    g_shaders.mesh_frag = LoadGfxShader("mesh.frag");
    if IsNull(*g_shaders.mesh_frag) {
        return false;
    }

    return true;
}

DestroyAllShaders :: () {
    DestroyGfxShader(*g_shaders.mesh_vert);
    DestroyGfxShader(*g_shaders.mesh_frag);
}

Rect :: struct (T : Type) {
    x, y, w, h : T;

    #place x;
    position : Vec2(T);
    size : Vec2(T);
}

operator == :: inline (a : $T/Rect, b : Rect) -> bool {
    return a.position == b.position && a.size == b.size;
}

Recti :: Rect(s32);
Rectf :: Rect(float);

CreateRenderTargets :: () {
    WaitForGPUIdle();

    if !IsNull(*g_color_texture) {
        DestroyGfxTexture(*g_color_texture);
    }

    if !IsNull(*g_depth_texture) {
        DestroyGfxTexture(*g_depth_texture);
    }

    w, h : s32;
    SDL_GetWindowSizeInPixels(g_window, *w, *h);

    texture_desc : GfxTextureDesc;
    texture_desc.type = .Texture2D;
    texture_desc.width = xx w;
    texture_desc.height = xx h;

    texture_desc.pixel_format = .RGBA16Float;
    texture_desc.usage = .ColorAttachment | .TransferSrc;

    g_color_texture = CreateGfxTexture("Color", texture_desc);
    Assert(!IsNull(*g_color_texture), "Could not create color texture");

    texture_desc.pixel_format = .Depth32Float;
    texture_desc.usage = .DepthStencilAttachment;

    g_depth_texture = CreateGfxTexture("Depth", texture_desc);
    Assert(!IsNull(*g_depth_texture), "Could not create depth texture");
}

ToRads :: inline (angle_in_degrees : float) -> float {
    return angle_in_degrees * Math.PI / 180.0;
} @NoProfile

ToDegs :: inline (angle_in_radians : float) -> float {
    return angle_in_radians * 180.0 / Math.PI;
} @NoProfile

Camera :: struct {
    position : Vec3f;
    target_yaw, target_pitch : float;
    yaw, pitch : float;
    rotation : Quatf;
    fov_in_degrees : float = 80;
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
    projection = Mat4fPerspectiveProjection(fov_in_degrees, aspect, 0.1, 1000);
}

AlignForward :: (x : u64, alignment : u64) -> u64 {
    Assert(alignment > 0, "Invalid alignment: %", alignment);

    return ((x + alignment - 1) / alignment) * alignment;
} @NoProfile

AlignForward :: (x : s64, alignment : s64) -> s64 {
    Assert(alignment > 0, "Invalid alignment: %", alignment);

    return ((x + alignment - 1) / alignment) * alignment;
} @NoProfile

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

    g_window = SDL_CreateWindow("Vulkan", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, 1920, 1080, SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE);
    defer SDL_DestroyWindow(g_window);

    InitGfxContext(g_window);
    defer CleanupGfxContext();

    defer DestroyAllShaders();
    if !LoadAllShaders() {
        Basic.exit(1);
    }

    defer DestroyGfxTexture(*g_color_texture);
    defer DestroyGfxTexture(*g_depth_texture);
    CreateRenderTargets();

    CreateAllBindingSetLayouts();
    defer DestroyAllBindingSetLayouts();

    CreateAllPipelines();
    defer DestroyAllPipelines();

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

    defer DestroyAllAssetCaches();

    g_default_base_color = LoadAsset(Texture2D, "Default_BaseColor.png");
    defer RemoveRef(g_default_base_color);

    g_default_normal_map = LoadAsset(Texture2D, "Default_Normal.png");
    defer RemoveRef(g_default_normal_map);

    g_default_metallic_roughness_map = LoadAsset(Texture2D, "Default_MetallicRoughness.png");
    defer RemoveRef(g_default_metallic_roughness_map);

    g_default_emissive = LoadAsset(Texture2D, "Default_Emissive.png");
    defer RemoveRef(g_default_emissive);

    for * g_frame_data_allocators {
        InitFrameDataAllocator(it, TPrint("Frame Data %", it_index), Frame_Data_Capacity);
    }

    defer for * g_frame_data_allocators {
        DestroyFrameDataAllocator(it);
    }

    InitBindingSetAllocators();
    defer DestroyBindingSetAllocators();

    defer DestroyAllUploadData();

    mesh := LoadAsset(Mesh, "DamagedHelmet.mesh");
    defer RemoveRef(mesh);

    camera : Camera;
    world : World;
    defer DestroyWorld(*world);

    LoadWorldFromDirectory(*world, "Data/Scenes/Sponza.scene");

    damaged_helmet := SpawnEntity(*world, MeshEntity, "DamagedHelmet");
    damaged_helmet.mesh = LoadAsset(Mesh, "DamagedHelmet/DamagedHelmet.mesh");
    damaged_helmet.material = LoadAsset(Material, "DamagedHelmet/DamagedHelmet.mat");
    damaged_helmet.local_position.y = 5;
    damaged_helmet.local_rotation = QuatfFromAxisAngle(.{0,1,0}, Pi * 0.5);
    UpdateWorldTransform(*world, damaged_helmet);

    defer WaitForGPUIdle(); // Before destroying anything, we need to ensure all work is done

    quit := false;
    while !quit {
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

        UpdateCamera(*camera);

        w, h : s32;
        SDL_GetWindowSizeInPixels(g_window, *w, *h);

        if should_recreate_swapchain && w > 0 && h > 0 {
            CreateRenderTargets();
            RecreateSwapchain();
        }

        BeginFrame();

        RenderFrame(*world, *camera);

        SubmitFrame(*g_color_texture);
    }
}

StructPrinter :: (builder : *StringBuilder, any : Any, data : *void) -> bool {
    if any.type == type_info(EntityGUID) {
        guid := cast(*EntityGUID) any.value_pointer;
        if guid.* == Null_Entity_GUID {
            Append(builder, "(null entity)");
        } else {
            Append(builder, "%1%2", FormatIntHex(guid.high), FormatIntHex(guid.low));
        }

        return true;
    }

    return false;
} @NoProfile

ScopeLongFormStructFormat :: () #expand {
    prev := context.print_style.default_format_struct;
    `defer context.print_style.default_format_struct = prev;

    context.print_style.default_format_struct.use_long_form_if_more_than_this_many_members = 0;
    context.print_style.default_format_struct.use_newlines_if_long_form = true;
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

Cos :: Math.cos;
Sin :: Math.sin;
Tan :: Math.tan;
Acos :: Math.acos;
Asin :: Math.asin;
Atan :: Math.atan;
Atan2 :: Math.atan2;
Sqrt :: Math.sqrt;
Floor :: Math.floor;
Ceil :: Math.ceil;

Tau :: Math.TAU;
Tau64 :: Math.TAU64;

Pi :: Math.PI;
Pi64 :: Math.PI64;

F32_Min :: Math.FLOAT32_MIN;
F32_Max :: Math.FLOAT32_MAX;
F32_Inf :: Math.FLOAT32_INFINITY;
F32_NaN :: Math.FLOAT32_NAN;
F64_Min :: Math.FLOAT64_MIN;
F64_Max :: Math.FLOAT64_MAX;
F64_Inf :: Math.FLOAT64_INFINITY;
F64_NaN :: Math.FLOAT64_NAN;
S8_Min :: Math.S8_MIN;
S8_Max :: Math.S8_MAX;
U8_Max :: Math.U8_MAX;
S16_Min :: Math.S16_MIN;
S16_Max :: Math.S16_MAX;
U16_Max :: Math.U16_MAX;
S32_Min :: Math.S32_MIN;
S32_Max :: Math.S32_MAX;
U32_Max :: Math.U32_MAX;
S64_Min :: Math.S64_MIN;
S64_Max :: Math.S64_MAX;
U64_Max :: Math.U64_MAX;

Log :: Math.log;

Log10 :: inline (x : float) -> float {
    return Log(x) / #run Log(10);
}

Log2 :: inline (x : float) -> float {
    return Log(x) / #run Log(2);
}
