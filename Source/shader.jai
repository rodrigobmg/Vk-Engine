Log_Shaders :: Log_Section.{name="Graphics/Shaders"};

LoadedShader :: struct {
    name : string;
    dependencies : [..]string;
    vertex_shader : GfxShader;
    fragment_shader : GfxShader;
    compute_shader : GfxShader;
    reload_callbacks : [..]ShaderReloadCallback;
    failed_to_reload : bool;
}

g_shader_file_watcher : File_Watcher;
g_shaders := LoadedShader.[
    .{name="kawase_blur_downsample"},
    .{name="kawase_blur_upsample"},
    .{name="gizmo"},
    .{name="debug_line"},
    .{name="point_shadow_map"},
    .{name="bloom_filter"},
    .{name="bloom_downsample"},
    .{name="bloom_upsample"},
    .{name="entity_guid"},
    .{name="imgui"},
    .{name="screen_effect"},
    .{name="background_screen_effect"},
    .{name="irradiance_map"},
    .{name="environment_map"},
    .{name="skybox"},
    .{name="brdf_lut"},
    .{name="compositing"},
    .{name="mesh_geometry"},
    .{name="opaque_surface"},
];

ShaderReloadCallback :: struct {
    proc : #type (shader : *LoadedShader, data : *void);
    data : *void;
}

operator== :: (a : ShaderReloadCallback, b : ShaderReloadCallback) -> bool {
    return a.proc == b.proc && a.data == b.data;
}

AddShaderReloadCallback :: (shader : *LoadedShader, callback : ShaderReloadCallback) {
    if !shader {
        return;
    }

    for shader.reload_callbacks {
        if it == callback {
            return;
        }
    }

    ArrayPush(*shader.reload_callbacks, callback);
}

AddShaderReloadCallback :: (shader : *GfxShader, callback : ShaderReloadCallback) {
    for * g_shaders {
        if *it.vertex_shader == shader || *it.fragment_shader == shader || *it.compute_shader == shader {
            AddShaderReloadCallback(it, callback);
        }
    }
}

GetVertexShader :: (name : string) -> *GfxShader {
    for * g_shaders {
        if it.name == name {
            if !IsNull(*it.vertex_shader) {
                return *it.vertex_shader;
            }

            Panic("No vertex shader named '%'", name);
            return null;
        }
    }

    Panic("No shader named '%'", name);
    return null;
}

GetFragmentShader :: (name : string) -> *GfxShader {
    for * g_shaders {
        if it.name == name {
            if !IsNull(*it.fragment_shader) {
                return *it.fragment_shader;
            }

            Panic("No fragment shader named '%'", name);
            return null;
        }
    }

    Panic("No shader named '%'", name);
    return null;
}

GetComputeShader :: (name : string) -> *GfxShader {
    for * g_shaders {
        if it.name == name {
            if !IsNull(*it.compute_shader) {
                return *it.compute_shader;
            }

            Panic("No compute shader named '%'", name);
            return null;
        }
    }

    Panic("No shader named '%'", name);
    return null;
}

LoadAllShaders :: () -> bool {
    LogSectionScope(*Log_Shaders);

    init(*g_shader_file_watcher, ShaderFileChangeCallback, events_to_watch=.MODIFIED);

    if !add_directories(*g_shader_file_watcher, "Shaders") {
        LogError("Could not watch Shaders directory for changes");
    }

    start_time := Basic.current_time_monotonic();

    for * g_shaders {
        if !ReloadShader(it) {
            return false;
        }
    }

    end_time := Basic.current_time_monotonic();

    LogMessage("Loaded all shaders in % s", Basic.to_float64_seconds(end_time - start_time));

    return true;
}

DestroyAllShaders :: () {
    for * g_shaders {
        if !IsNull(*it.vertex_shader) {
            DestroyGfxShader(*it.vertex_shader);
        }

        if !IsNull(*it.fragment_shader) {
            DestroyGfxShader(*it.fragment_shader);
        }

        if !IsNull(*it.compute_shader) {
            DestroyGfxShader(*it.compute_shader);
        }

        for it.dependencies {
            Free(it.data);
        }

        ArrayFree(*it.dependencies);
        ArrayFree(*it.reload_callbacks);
    }
}

HandleShaderHotReloading :: () {
    process_changes(*g_shader_file_watcher);
}

ShaderFileChangeCallback :: (watcher : *File_Watcher(void), change : *File_Change, user_data : *void) {
    LogSectionScope(*Log_Shaders);

    filename := get_absolute_path(change.full_path,, Temp);
    path_overwrite_separators(filename, #char "/");

    for * g_shaders {
        if ArrayFindFirst(it.dependencies, filename) != -1 {
            ReloadShader(it);
        }
    }
}

ReloadShader :: (shader : *LoadedShader) -> bool {
    LogSectionScope(*Log_Shaders);

    WaitForGPUIdle();

    dependencies : [..]string;
    defer {
        for dependencies {
            Free(it.data);
        }

        ArrayFree(*dependencies);
    }

    shader.failed_to_reload = false;

    vertex_filename := TPrint("Shaders/%.vert.glsl", shader.name);
    vertex_filename = get_absolute_path(vertex_filename ,, Temp, logger=IgnoreLogger);
    path_overwrite_separators(vertex_filename, #char "/");

    fragment_filename := TPrint("Shaders/%.frag.glsl", shader.name);
    fragment_filename = get_absolute_path(fragment_filename ,, Temp, logger=IgnoreLogger);
    path_overwrite_separators(fragment_filename, #char "/");

    compute_filename := TPrint("Shaders/%.comp.glsl", shader.name);
    compute_filename = get_absolute_path(compute_filename ,, Temp, logger=IgnoreLogger);
    path_overwrite_separators(compute_filename, #char "/");

    has_vertex_shader := file_exists(vertex_filename);
    has_fragment_shader := file_exists(fragment_filename);
    has_compute_shader := file_exists(compute_filename);

    if !has_vertex_shader && !has_fragment_shader && !has_compute_shader {
        LogError("No shader file for shader '%'", shader.name);
        shader.failed_to_reload = true;
        return false;
    }

    vertex_shader : GfxShader;
    defer if !IsNull(*vertex_shader) then DestroyGfxShader(*vertex_shader);

    fragment_shader : GfxShader;
    defer if !IsNull(*fragment_shader) then DestroyGfxShader(*fragment_shader);

    compute_shader : GfxShader;
    defer if !IsNull(*compute_shader) then DestroyGfxShader(*compute_shader);

    extra := string.[
        TPrint("-DNum_Environment_Map_Samples=%", g_preferences.environment_map_num_samples),
        TPrint("-DIrradiance_Map_Sample_Delta=%", g_preferences.irradiance_map_sample_delta),
    ];

    if has_vertex_shader {
        vertex_shader = LoadGfxShader(TPrint("%.vert", shader.name), extra, dependencies=*dependencies);

        if IsNull(*vertex_shader) {
            shader.failed_to_reload = true;
            return false;
        }
    }

    if has_fragment_shader {
        fragment_shader = LoadGfxShader(TPrint("%.frag", shader.name), extra, dependencies=*dependencies);

        if IsNull(*fragment_shader) {
            shader.failed_to_reload = true;
            return false;
        }
    }

    if has_compute_shader {
        compute_shader = LoadGfxShader(TPrint("%.comp", shader.name), extra, dependencies=*dependencies);

        if IsNull(*compute_shader) {
            shader.failed_to_reload = true;
            return false;
        }
    }

    Swap(*shader.dependencies, *dependencies);
    Swap(*shader.vertex_shader, *vertex_shader);
    Swap(*shader.fragment_shader, *fragment_shader);
    Swap(*shader.compute_shader, *compute_shader);

    for shader.reload_callbacks {
        it.proc(shader, it.data);
    }

    LogMessage("Loaded shader '%'", shader.name);

    return true;
}

CreateGfxGraphicsPipeline :: (pipeline : *GfxGraphicsPipeline, name : string, desc : GfxGraphicsPipelineDesc) -> bool {
    pipeline.* = CreateGfxGraphicsPipeline(name, desc);
    if IsNull(pipeline) {
        return false;
    }

    callback : ShaderReloadCallback;
    callback.proc = (shader, pipeline) => { DestroyGfxGraphicsPipeline(pipeline); };
    callback.data = pipeline;

    AddShaderReloadCallback(desc.vertex_shader, callback);
    AddShaderReloadCallback(desc.fragment_shader, callback);

    return true;
}

CreateGfxComputePipeline :: (pipeline : *GfxComputePipeline, name : string, desc : GfxComputePipelineDesc) -> bool {
    pipeline.* = CreateGfxComputePipeline(name, desc);
    if IsNull(pipeline) {
        return false;
    }

    callback : ShaderReloadCallback;
    callback.proc = (shader, pipeline) => { DestroyGfxComputePipeline(pipeline); };
    callback.data = pipeline;

    AddShaderReloadCallback(desc.shader, callback);

    return true;
}
