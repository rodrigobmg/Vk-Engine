Log_Shaders :: Log_Section.{name="Graphics/Shaders"};

LoadedShader :: struct {
    name : string;
    dependencies : [..]string;
    vertex_shader : GfxShader;
    fragment_shader : GfxShader;
    reload_callbacks : [..]ShaderReloadCallback;
    failed_to_reload : bool;
}

g_shader_file_watcher : File_Watcher;
g_shaders := LoadedShader.[
    .{name="screen_effect"},
    .{name="post_processing"},
    .{name="mesh"},
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
            if !ReloadShader(it) {
                it.failed_to_reload = true;
            }
        }
    }
}

ReloadShader :: (shader : *LoadedShader) -> bool {
    LogSectionScope(*Log_Shaders);

    dependencies : [..]string;
    defer {
        for dependencies {
            Free(it.data);
        }

        ArrayFree(*dependencies);
    }

    vertex_filename := TPrint("Shaders/%.vert.glsl", shader.name);
    vertex_filename = get_absolute_path(vertex_filename ,, Temp);
    path_overwrite_separators(vertex_filename, #char "/");

    fragment_filename := TPrint("Shaders/%.frag.glsl", shader.name);
    fragment_filename = get_absolute_path(fragment_filename ,, Temp);
    path_overwrite_separators(fragment_filename, #char "/");

    has_vertex_shader := file_exists(vertex_filename);
    has_fragment_shader := file_exists(fragment_filename);

    if !has_vertex_shader && !has_fragment_shader {
        LogError("No shader file for shader '%'", shader.name);
        return false;
    }

    vertex_shader : GfxShader;
    defer if !IsNull(*vertex_shader) then DestroyGfxShader(*vertex_shader);

    fragment_shader : GfxShader;
    defer if !IsNull(*fragment_shader) then DestroyGfxShader(*fragment_shader);

    if has_vertex_shader {
        vertex_shader = LoadGfxShader(TPrint("%.vert", shader.name));
        ArrayPush(*dependencies, StringClone(vertex_filename));

        if IsNull(*vertex_shader) {
            return false;
        }
    }

    if has_fragment_shader {
        fragment_shader = LoadGfxShader(TPrint("%.frag", shader.name));
        ArrayPush(*dependencies, StringClone(fragment_filename));

        if IsNull(*fragment_shader) {
            return false;
        }
    }

    Swap(*shader.dependencies, *dependencies);
    Swap(*shader.vertex_shader, *vertex_shader);
    Swap(*shader.fragment_shader, *fragment_shader);

    for shader.reload_callbacks {
        it.proc(shader, it.data);
    }

    LogMessage("Loaded shader '%' (%)", shader.name, ifx has_vertex_shader && has_fragment_shader then "vertex and fragment" else ifx has_vertex_shader then "vertex only" else ifx has_fragment_shader then "fragment only");

    return true;
}

DestroyPipelineOnShaderReload :: (pipeline : *GfxGraphicsPipeline) {
    callback : ShaderReloadCallback;
    callback.proc = (shader, pipeline) => { WaitForGPUIdle(); DestroyGfxGraphicsPipeline(pipeline); };
    callback.data = pipeline;

    if pipeline.desc.vertex_shader {
        for * g_shaders {
            if *it.vertex_shader == pipeline.desc.vertex_shader {
                AddShaderReloadCallback(it, callback);
                break;
            }
        }
    }

    if pipeline.desc.fragment_shader {
        for * g_shaders {
            if *it.fragment_shader == pipeline.desc.fragment_shader {
                AddShaderReloadCallback(it, callback);
                break;
            }
        }
    }
}
