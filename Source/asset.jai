#import "File_Watcher";

#placeholder Asset_Types;

Track_Asset_Reference_Locations :: true;
Default_Number_Of_Frames_Before_Unloading_Unreferenced_Assets :: 60;
Max_Assets_To_Unload_Per_Frame :: 2;

AssetCache :: struct (T : Type) {
    AssetType :: Asset(T);
    LoadProc :: #type (*T, data : []u8, name : string) -> bool;
    PostLoadProc :: #type (*T, name : string) -> bool;
    UnloadProc :: #type (*T);
    WriteProc :: #type (*StringBuilder, *T) -> bool;

    UnreferencedAsset :: struct {
        unreferenced_at_frame : int;
        asset : *AssetType;
    }

    initialized : bool;

    log_section : Log_Section;
    name : string;

    load_proc : LoadProc;
    post_load_proc : PostLoadProc;
    unload_proc : UnloadProc;
    write_proc : WriteProc;

    frame_counter : int;
    number_of_frames_before_unloading_unreferenced_assets := Default_Number_Of_Frames_Before_Unloading_Unreferenced_Assets;

    assets_by_name : HashMap(string, *AssetType);
    unreferenced_assets : HashMap(string, UnreferencedAsset);
    storage : PagedArray(AssetType, 20);

    defer_next_asset_loads : bool;
    pending_asset_loads : [..]*AssetType;
    parallel_load_group : Thread_Group;
}

#insert -> string {
    builder : StringBuilder;

    for Asset_Types {
        Appendln(*builder, "g_%1_asset_cache : AssetCache(%1);", it);
    }

    return StringBuilderBuild(*builder);
}

AssetFlags :: enum_flags u8 {
    FromMemory;
    Permanent; // Ref count is ignored and the asset is never freed
    DeferredLoad;
    LoadFailed;
}

AssetCommonData :: struct {
    asset_name : string; @NotEditable @Serialize(1)
    asset_flags : AssetFlags; @NotEditable
    ref_count : s32; @NotEditable
}

Asset :: struct (DataType : Type) {
    #as using asset_data : DataType; @HideInInspector
    #as using _ : AssetCommonData; @Serialize(1)
    asset_cache : *AssetCache(DataType); @HideInInspector

    #if Track_Asset_Reference_Locations {
        asset_reference_locations : [..]Source_Code_Location; @HideInInspector
    }
}

DummyAsset :: Asset(struct {});

GetAssetType :: (info : *Type_Info_Struct) -> *Type_Info {
    if info.type != .STRUCT {
        return null;
    }

    if TypeGetSourcePolymorph(info) != TypeGetSourcePolymorph(type_info(DummyAsset)) {
        return null;
    }

    for info.specified_parameters {
        if !(it.flags & .CONSTANT) {
            continue;
        }

        ptr := info.constant_storage.data + it.offset_into_constant_storage;
        if it.name == "DataType" {
            return (cast(**Type_Info) ptr).*;
        }
    }

    return null;
}

MakeVersionNumber :: inline (major : u32, minor : u32, patch : u32) -> u32 {
    Assert(minor < 100);
    Assert(patch < 100);

    return patch + minor * 100 + major * 10000;
}

GetVersionNumbers :: inline (version : u32) -> major : u32, minor : u32, patch : u32 {
    return version / 10000, (version / 100) % 10, version % 10;
}

DataDirectoryChangeCallback :: struct {
    proc : (*File_Watcher(void), *File_Change, *void);
    data : *void;
}

g_data_directory_absolute_path : string;
g_data_directory_watcher : File_Watcher;
g_data_directory_change_callbacks : [..]DataDirectoryChangeCallback;

FileWatcherCallback :: (watcher : *File_Watcher(void), change : *File_Change, data : *void) {
    for g_data_directory_change_callbacks {
        it.proc(watcher, change, it.data);
    }
}

RegisterDataDirectoryChangeCallback :: (proc : type_of(DataDirectoryChangeCallback.proc), data : *void) -> int {
    if !g_data_directory_watcher.callback {
        init(*g_data_directory_watcher, FileWatcherCallback, null, .ALL_EVENTS);

        if !add_directories(*g_data_directory_watcher, "Data") {
            LogError("Could not watch directory 'Data' for changes");
        }
    }

    cb := ArrayPush(*g_data_directory_change_callbacks);
    cb.data = data;
    cb.proc = proc;

    return g_data_directory_change_callbacks.count - 1;
}

UnregisterDataDirectoryChangeCallback :: (index : int) {
    ArrayOrderedRemove(*g_data_directory_change_callbacks, index);
}

ProcessDataDirectoryChanges :: () {
    process_changes(*g_data_directory_watcher);
}

InitAssetCache :: (
    cache : *$T/AssetCache,
    load_proc : cache.LoadProc,
    post_load_proc : cache.PostLoadProc,
    unload_proc : cache.UnloadProc,
    write_proc : cache.WriteProc
) {
    Assert(!cache.initialized, "Asset cache is already initialized");

    defer cache.initialized = true;

    if !g_data_directory_absolute_path {
        g_data_directory_absolute_path = StringClone(get_absolute_path("Data"));
        path_overwrite_separators(g_data_directory_absolute_path, #char "/");
    }

    cache.load_proc = load_proc;
    cache.post_load_proc = post_load_proc;
    cache.unload_proc = unload_proc;
    cache.write_proc = write_proc;
    cache.log_section.name = SPrint("Assets/%", T.T);

    LogSectionScope(*cache.log_section);

    init(*cache.parallel_load_group, g_num_worker_threads, #bake_arguments LoadAssetWorker(T=cache.T));
    cache.parallel_load_group.name = #run SPrint("Parallel Asset Loading (%)", cache.T);
    cache.parallel_load_group.logging = false;

    start(*cache.parallel_load_group);

    AssetCacheFileChangeCallback :: (watcher : *File_Watcher(void), change : *File_Change, data : *void) {
        using cache := cast(*T) data;
        asset_name := change.full_path;
        asset_name.data += "Data/".count;
        asset_name.count -= "Data/".count;

        ok, asset := TryReloadAsset(cache, asset_name);
        RemoveRef(asset);
    }

    RegisterDataDirectoryChangeCallback(AssetCacheFileChangeCallback, cache);
}

DestroyAllAssetCaches :: () {
    #insert -> string {
        builder : StringBuilder;

        for Asset_Types {
            Appendln(*builder, "DestroyAssetCache(*g_%_asset_cache);", it);
        }

        return StringBuilderBuild(*builder);
    }
}

DestroyAssetCache :: (using cache : *AssetCache) {
    Assert(cache.initialized, "Asset cache is not initialized");

    LogSectionScope(*log_section);

    start_time := Basic.current_time_monotonic();

    leaks := 0;
    for * storage {
        if !(it.asset_flags & .Permanent) && it.ref_count > 0  {
            LogWarning("Asset '%' is still referenced when destroying asset cache.", it.asset_name);
            leaks += 1;

            #if Track_Asset_Reference_Locations {
                builder : StringBuilder;
                builder.allocator = Temp;

                for loc : it.asset_reference_locations {
                    Appendln(*builder, "    %:%:%",
                        loc.fully_pathed_filename, loc.line_number, loc.character_number);
                }

                LogMessage("Here are all the places where this asset was referenced:\n%", StringBuilderBuild(*builder,, Temp));
            }
        }

        UnloadAsset(cache, it);
    }

    if leaks != 0 && !Track_Asset_Reference_Locations {
        LogMessage("Set Track_Asset_Reference_Locations to true to get more info about where these assets were used.");
    }

    end_time := Basic.current_time_monotonic();
    LogMessage("Unloaded all % assets in % ms", T, Basic.to_float64_seconds(end_time - start_time) * 1000);

    PagedArrayReset(*storage);
    HashMapFree(*unreferenced_assets);
    HashMapFree(*assets_by_name);
    ArrayFree(*pending_asset_loads);
    shutdown(*parallel_load_group);

    Free(log_section.name.data);

    cache.* = .{};
}

LoadAssetDynamic :: (data_type : Type, name : string, location := #caller_location) -> *void {
    #insert -> string {
        builder : StringBuilder;

        Appendln(*builder, "if data_type == {");
        for Asset_Types {
            Appendln(*builder, "case %1; return LoadAsset(*g_%1_asset_cache, name, location);", it);
        }
        Appendln(*builder, "}");

        return StringBuilderBuild(*builder);
    }

    LogError("Unhandled type % when attempting to load asset of a type known only at runtime", data_type);

    return null;
}

AddRefDynamic :: (data_type : Type, asset : *void, location := #caller_location) {
    #insert -> string {
        builder : StringBuilder;

        Appendln(*builder, "if data_type == {");
        for Asset_Types {
            Appendln(*builder, "case %1; AddRef(cast(*Asset(%1), asset), location);", it);
        }
        Appendln(*builder, "case; LogError(\"AddRefDynamic does not handle asset type \%\", data_type);");
        Appendln(*builder, "}");

        return StringBuilderBuild(*builder);
    }
}

RemoveRefDynamic :: (data_type : Type, asset : *void) {
    #insert -> string {
        builder : StringBuilder;

        Appendln(*builder, "if data_type == {");
        for Asset_Types {
            Appendln(*builder, "case %1; RemoveRef(cast(*Asset(%1), asset));", it);
        }
        Appendln(*builder, "case; LogError(\"RemoveRefDynamic does not handle asset type \%\", data_type);");
        Appendln(*builder, "}");

        return StringBuilderBuild(*builder);
    }
}

AddRef :: (using asset : *Asset, location := #caller_location) -> type_of(asset) {
    if asset_flags & .Permanent {
        return asset;
    }

    if ref_count == 0 {
        HashMapRemove(*asset_cache.unreferenced_assets, asset_name);
    }

    ref_count += 1;

    #if Track_Asset_Reference_Locations {
        tracked_location := false;
        for asset_reference_locations {
            if it.fully_pathed_filename == location.fully_pathed_filename
            && it.line_number == location.line_number
            && it.character_number == location.character_number {
                tracked_location = true;
                break;
            }
        }

        if !tracked_location {
            ArrayPush(*asset_reference_locations, location);
        }
    }

    return asset;
}

RemoveRef :: (using asset : *Asset) {
    if !asset {
        return;
    }

    if asset_flags & .Permanent {
        return;
    }

    Assert(ref_count > 0);

    ref_count -= 1;

    if ref_count == 0 {
        unreferenced := asset_cache.UnreferencedAsset.{
            unreferenced_at_frame=asset_cache.frame_counter,
            asset=asset
        };

        HashMapInsert(*asset_cache.unreferenced_assets, asset_name, unreferenced);
    }
}

UnloadAllUnreferencedAssets :: () {
    num_unloaded_assets := 0;

    #insert -> string {
        builder : StringBuilder;

        for Asset_Types {
            Appendln(*builder, "if Max_Assets_To_Unload_Per_Frame > 0 && num_unloaded_assets < Max_Assets_To_Unload_Per_Frame {");
            Appendln(*builder, "    num_unloaded_assets += UnloadAllUnreferencedAssets(*g_%_asset_cache, Max_Assets_To_Unload_Per_Frame - num_unloaded_assets);", it);
            Appendln(*builder, "}");
        }

        return StringBuilderBuild(*builder);
    }
}

UnloadAllUnreferencedAssets :: (using cache : *AssetCache, max_assets_to_unload := 0) -> int {
    Assert(cache.initialized, "Asset cache is not initialized");

    LogSectionScope(*log_section);

    defer frame_counter += 1;

    start_time := Basic.current_time_monotonic();

    num_unloaded_assets := 0;

    for unreferenced_assets {
        if max_assets_to_unload > 0 && num_unloaded_assets >= max_assets_to_unload {
            break;
        }

        if it.asset.asset_flags & .Permanent {
            LogError("Permanent asset is in unreferenced_assets map. This is not a fatal error but it still shouldn't happen.");
            remove it;
            continue;
        }

        if frame_counter - it.unreferenced_at_frame >= number_of_frames_before_unloading_unreferenced_assets {
            UnloadAsset(cache, it.asset);
            num_unloaded_assets += 1;
        }
    }

    end_time := Basic.current_time_monotonic();
    if num_unloaded_assets > 1 {
        LogMessage("Unloaded all unreferenced % assets in % ms", T, Basic.to_float64_seconds(end_time - start_time) * 1000);
    }

    return num_unloaded_assets;
}

GetLoadedAsset :: (cache : *AssetCache, name : string, location := #caller_location) -> *cache.AssetType {
    Assert(cache.initialized, "Asset cache is not initialized");

    asset := HashMapGet(*cache.assets_by_name, name);
    if asset {
        AddRef(asset, location);
        return asset;
    }

    return null;
}

#scope_file

AllocAsset :: (cache : *AssetCache, name : string, flags : AssetFlags = 0, location := #caller_location) -> *cache.AssetType {
    Assert(cache.initialized, "Asset cache is not initialized");

    asset := PagedArrayFindSlot(*cache.storage);
    asset.asset_name = StringClone(name ,, cache.assets_by_name.allocator);
    asset.asset_cache = cache;
    asset.asset_flags = flags;

    _, was_present := HashMapInsert(*cache.assets_by_name, asset.asset_name, asset);
    Assert(!was_present, "Overriding existing asset '%'", asset.asset_name);

    AddRef(asset, location);

    return asset;
}

FreeAsset :: (cache : *AssetCache, asset : *cache.AssetType) {
    Assert(cache.initialized, "Asset cache is not initialized");
    Assert(cache == asset.asset_cache);
    Assert(asset.ref_count == 0, "Freeing asset '%' but it is still referenced", asset.asset_name);
    Assert(asset.asset_flags & .Permanent == 0, "Freeing permanent asset '%'", asset.asset_name);

    asset_name := asset.asset_name;
    defer Free(asset.asset_name.data ,, cache.assets_by_name.allocator);

    #if Track_Asset_Reference_Locations {
        ArrayFree(*asset.asset_reference_locations);
    }

    PagedArrayFreeSlot(*cache.storage, asset);
    HashMapRemove(*cache.assets_by_name, asset.asset_name);
    HashMapRemove(*cache.unreferenced_assets, asset.asset_name);
}

UnloadAsset :: (cache : *AssetCache, asset : *cache.AssetType) {
    Assert(cache.initialized, "Asset cache is not initialized");
    Assert(cache.unload_proc != null);
    Assert(cache == asset.asset_cache);
    Assert(asset.ref_count == 0, "Unloading asset '%' but it is still referenced", asset.asset_name);
    Assert(asset.asset_flags & .Permanent == 0, "Unloading permanent asset '%'", asset.asset_name);

    start_time := Basic.current_time_monotonic();
    cache.unload_proc(asset);
    end_time := Basic.current_time_monotonic();
    LogContentMessage("Unloaded asset '%' in % ms", asset.asset_name, Basic.to_float64_seconds(end_time - start_time) * 1000);

    FreeAsset(cache, asset);
}

#scope_export

AllocNewAsset :: inline ($T : Type, name : string, flags : AssetFlags = 0, location := #caller_location) -> *Asset(T), is_new : bool  {
    cache := #insert #run SPrint("*g_%_asset_cache;", T);
    asset, is_new := AllocNewAsset(cache, name, flags, location);

    return asset, is_new;
}

AllocNewAsset :: (cache : *AssetCache, name : string, flags : AssetFlags = 0, location := #caller_location) -> *cache.AssetType, is_new : bool {
    Assert(cache.initialized, "Asset cache is not initialized");

    asset := GetLoadedAsset(cache, name, location);
    if asset {
        return asset, false;
    }

    return AllocAsset(cache, name, flags, location), true;
}

#scope_file

LoadPreallocatedAssetFromMemory :: (cache : *AssetCache, asset : *cache.AssetType, data : []u8) -> bool {
    Assert(cache.initialized, "Asset cache is not initialized");

    ok := cache.load_proc(asset, data, asset.asset_name);

    if !ok {
        LogContentError("Could not load asset '%'", asset.asset_name);

        asset.asset_flags |= .LoadFailed;
        cache.unload_proc(asset);

        return false;
    }

    return true;
}

#scope_export

AllocAndLoadAssetFromMemory :: (cache : *AssetCache, name : string, data : []u8, flags : AssetFlags = 0, location := #caller_location) -> *cache.AssetType {
    Assert(cache.initialized, "Asset cache is not initialized");
    Assert(cache.load_proc != null);

    start_time := Basic.current_time_monotonic();

    asset := AllocAsset(cache, name, flags | .FromMemory, location);
    if !LoadPreallocatedAssetFromMemory(cache, asset, data) {
        RemoveRef(asset);
        FreeAsset(cache, asset);

        return null;
    }

    if cache.post_load_proc {
        cache.post_load_proc(asset, name);
    }

    total_time := Basic.current_time_monotonic() - start_time;
    total_time_ms := Basic.to_float64_seconds(total_time) * 1000.0;

    LogContentMessage("Loaded asset '%' in % ms", asset.asset_name, total_time_ms);

    return asset;
}

LoadAsset :: inline ($T : Type, name : string, location := #caller_location) -> *Asset(T) {
    cache := #insert #run SPrint("*g_%_asset_cache;", T);
    return LoadAsset(cache, name, location);
}

LoadAsset :: (cache : *AssetCache, name : string, location := #caller_location) -> *cache.AssetType {
    Assert(cache.initialized, "Asset cache is not initialized");
    Assert(cache.load_proc != null);

    LogSectionScope(*cache.log_section);

    if cache.defer_next_asset_loads {
        asset, is_new := AllocNewAsset(cache, name, .DeferredLoad, location);
        if is_new {
            ArrayPushUnique(*cache.pending_asset_loads, asset);
        }

        return asset;
    }

    asset := GetLoadedAsset(cache, name, location);
    if asset {
        return asset;
    }

    filename := StringJoin("Data/", name,, Temp);

    file_contents, file_ok := read_entire_file(filename);
    defer Free(file_contents.data);

    if !file_ok {
        LogContentError("Failed to load asset '%' because of a file error", name);

        return null;
    }

    asset = AllocAndLoadAssetFromMemory(cache, name, xx file_contents, 0, location);
    if !asset {
        return null;
    }

    asset.asset_flags &= ~.FromMemory;

    return asset;
}

TryReloadAsset :: (cache : *AssetCache, name : string, location := #caller_location) -> bool, *cache.AssetType {
    Assert(cache.initialized, "Asset cache is not initialized");

    LogSectionScope(*cache.log_section);

    asset := GetLoadedAsset(cache, name, location);
    if !asset {
        return false, null;
    }

    if asset.asset_flags & .FromMemory {
        LogContentError("Cannot reload asset '%' because it was not loaded from a file", name);

        return false, asset;
    }

    filename := StringJoin("Data/", name,, Temp);
    file_contents, file_ok := read_entire_file(filename);
    defer Free(file_contents.data);

    if !file_ok {
        LogContentError("Failed to reload asset '%' because of a file error", name);

        return false, asset;
    }

    old_data := asset.asset_data;

    asset.asset_data = .{};
    ok := cache.load_proc(*asset.asset_data, xx file_contents, name);

    if !ok {
        cache.unload_proc(*asset.asset_data);
        asset.asset_data = old_data;

        LogContentError("Failed to reload asset '%'", name);

        return false, asset;
    }

    if cache.post_load_proc {
        cache.post_load_proc(*asset.asset_data, name);
    }

    new_data := asset.asset_data;
    asset.asset_data = old_data;

    cache.unload_proc(*asset.asset_data);

    asset.asset_data = new_data;

    LogContentMessage("Reloaded asset '%'", name);

    return true, asset;
}

// After this function is called, when requesting an asset load, the asset will be flagged
// as DeferredLoad and will be loaded when LoadPendingAssetsInParallel is called
DeferNextAssetLoads :: (cache : *AssetCache) {
    cache.defer_next_asset_loads = true;
}

DeferNextAssetLoadsForAllCaches :: () {
    #insert -> string {
        builder : StringBuilder;

        for Asset_Types {
            Appendln(*builder, "DeferNextAssetLoads(*g_%_asset_cache);", it);
        }

        return StringBuilderBuild(*builder);
    }
}

LoadAssetWorkerData :: struct ($T : Type) {
    elapsed_time : Basic.Apollo_Time;
    asset : *Asset(T);
}

LoadAssetWorker :: (group : *Thread_Group, thread : *Thread, work : *void, $T : Type) -> Thread_Continue_Status {
    using _ := cast(*LoadAssetWorkerData(T)) work;
    cache := asset.asset_cache;

    LogSectionScope(*cache.log_section);

    start_time := Basic.current_time_monotonic();

    asset.asset_flags &= ~.DeferredLoad;

    filename := StringJoin("Data/", asset.asset_name,, Temp);

    file_contents, file_ok := read_entire_file(filename);
    defer Free(file_contents.data);

    if !file_ok {
        asset.asset_flags |= .LoadFailed;
        LogContentError("Failed to load asset '%' because of a file error", asset.asset_name);
        return .CONTINUE;
    }

    _ := LoadPreallocatedAssetFromMemory(cache, asset, xx file_contents);

    elapsed_time = Basic.current_time_monotonic() - start_time;

    return .CONTINUE;
}

LoadPendingAssets :: () {
    LoadPendingAssetsSynchronously(*g_Material_asset_cache);

    #insert -> string {
        builder : StringBuilder;

        for Asset_Types {
            if it == Material {
                continue;
            }

            Appendln(*builder, "LoadPendingAssetsInParallel(*g_%_asset_cache);", it);
        }

        return StringBuilderBuild(*builder);
    }
}

LoadPendingAssetsSynchronously :: (using cache : *AssetCache) {
    LogSectionScope(*log_section);

    if !defer_next_asset_loads {
        LogError("Called LoadPendingAssetsSynchronously but DeferNextAssetLoads wasn't called before");
        return;
    }

    defer_next_asset_loads = false;

    for asset : pending_asset_loads {
        asset.asset_flags &= ~.DeferredLoad;

        filename := StringJoin("Data/", asset.asset_name,, Temp);

        file_contents, file_ok := read_entire_file(filename);
        defer Free(file_contents.data);

        if !file_ok {
            LogContentError("Failed to load asset '%' because of a file error", asset.asset_name);
            continue;
        }

        start_time := Basic.current_time_monotonic();

        ok := LoadPreallocatedAssetFromMemory(cache, asset, xx file_contents);
        if ok && cache.post_load_proc {
            cache.post_load_proc(asset, asset.asset_name);
        }

        total_time := Basic.current_time_monotonic() - start_time;
        total_time_ms := Basic.to_float64_seconds(total_time) * 1000.0;

        LogContentMessage("Loaded asset '%' in % ms", asset.asset_name, total_time_ms);

    }

    ArrayClear(*pending_asset_loads);
}

// Load all assets that have been requested after the call to DeferNextAssetLoads
// This just fires up all the threads in the thread group and waits for everything to be
// completed
LoadPendingAssetsInParallel :: (using cache : *AssetCache) {
    Assert(cache.initialized, "Asset cache is not initialized");

    LogSectionScope(*log_section);

    if !defer_next_asset_loads {
        LogError("Called LoadPendingAssetsInParallel but DeferNextAssetLoads wasn't called before");
        return;
    }

    defer_next_asset_loads = false;

    work : [..]LoadAssetWorkerData(T);
    work.allocator = Temp;
    ArrayReserve(*work, pending_asset_loads.count);

    for pending_asset_loads {
        w := ArrayPush(*work);
        w.asset = it;
        add_work(*parallel_load_group, w);
    }

    finished := 0;
    while finished < pending_asset_loads.count {
        results := get_completed_work(*parallel_load_group);
        finished += results.count;

        if cache.post_load_proc {
            for results {
                using _ := cast(*LoadAssetWorkerData(T)) it;
                if !(asset.asset_flags & .LoadFailed) {
                    start_time := Basic.current_time_monotonic();

                    cache.post_load_proc(asset, asset.asset_name);

                    elapsed_post_load := Basic.current_time_monotonic() - start_time;
                    total_time := elapsed_time + elapsed_post_load;
                    total_time_ms := Basic.to_float64_seconds(total_time) * 1000.0;

                    load_time_ms := Basic.to_float64_seconds(elapsed_time) * 1000.0;
                    post_load_time_ms := Basic.to_float64_seconds(elapsed_post_load) * 1000.0;

                    LogContentMessage("Loaded asset '%' in % ms (% parallel, % synchronous)",
                        asset.asset_name, total_time_ms, load_time_ms, post_load_time_ms);
                }
            }
        } else {
            for results {
                using _ := cast(*LoadAssetWorkerData(T)) it;
                if !(asset.asset_flags & .LoadFailed) {
                    total_time_ms := Basic.to_float64_seconds(elapsed_time) * 1000.0;
                    LogContentMessage("Loaded asset '%' in % ms", asset.asset_name, total_time_ms);
                }
            }
        }
    }

    ArrayClear(*pending_asset_loads);
}

SaveAsset :: (asset : *Asset) -> bool {
    if !asset {
        return false;
    }

    cache := asset.asset_cache;
    if !cache.write_proc {
        LogError("No write proc in asset cache");
        return false;
    }

    LogSectionScope(*cache.log_section);

    filename := StringJoin("Data/", asset.asset_name,, Temp);

    builder : StringBuilder;
    ok := cache.write_proc(*builder, asset);
    if !ok {
        StringBuilderFree(*builder);
        return false;
    }

    return write_entire_file(filename, *builder);
}

UnreferenceAllAssets :: (value : *$T)
#modify { return cast(*Type_Info, T).type == .STRUCT; } {
    #insert -> string {
        builder : StringBuilder;

        info := type_info(T);
        for info.members {
            if it.type.type == .STRUCT {
                Appendln(*builder, "UnreferenceAllAssets(*value.%);", it.name);
                continue;
            }

            if it.type.type != .POINTER {
                continue;
            }

            pointed_type := cast(*Type_Info_Pointer, it.type).pointer_to;
            if pointed_type.type != .STRUCT {
                continue;
            }

            if TypeGetSourcePolymorph(xx pointed_type) == TypeGetSourcePolymorph(type_info(DummyAsset)) {
                Appendln(*builder, "RemoveRef(value.%);", it.name);
            } else {
                Appendln(*builder, "UnreferenceAllAssets(value.%);", it.name);
            }
        }

        return StringBuilderBuild(*builder);
    }
}
