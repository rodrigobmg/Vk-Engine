// WARNING: if this file is renamed or moved, or if the Component struct is moved to
// another file, Build/entity.jai must be updated accordingly

#placeholder Component_Types;

#assert Component_Types.count <= 256; // The type id must fit in a u8

Components_Per_Page :: 20;

ComponentStorage :: #bake_arguments PagedArray(Page_Size=Components_Per_Page);

Component :: struct {
    index : PagedArraySlotInfo;
    entity : EntityGUID;
}

IsInComponentTypesArray :: (type : Type) -> bool {
    for i : 1..Component_Types.count - 1 {
        if Component_Types[i] == type {
            return true;
        }
    }

    return false;
}

CreateComponent :: (world : *World, storage : *ComponentStorage, entity : EntityGUID) -> *storage.T {
    component, index := PagedArrayFindSlot(storage);
    component.entity = entity;
    component.index = index;

    #if #exists(storage.T.OnCreate) {
        component.OnCreate(world, component);
    }

    return component;
}

DestroyComponent :: (world : *World, storage : *ComponentStorage, component : *storage.T) {
    #if #exists(storage.T.OnDestroy) {
        component.OnDestroy(world, component);
    }

    PagedArrayFreeSlot(storage, component.index);
}

CreateComponent :: (world : *World, $T : Type, entity : EntityGUID) -> *T
#modify { return IsInComponentTypesArray(T); } {
    storage := #insert #run TPrint("*world.%_storage;", T);
    return CreateComponent(world, storage, entity);
}

DestroyComponent :: (world : *World, component : *$T)
#modify { return IsInComponentTypesArray(T); } {
    storage := #insert #run TPrint("*world.%_storage;", T);
    DestroyComponent(world, storage, component);
}

#scope_file

AppendGetComponent :: (builder : *StringBuilder, entity : *Type_Info_Struct, component : *Type_Info_Struct) {
    found := false;
    for entity.members {
        // @Todo: handle array of components, structs containing components
        if it.type.type != .POINTER {
            continue;
        }

        type := cast(*Type_Info_Pointer, it.type).pointer_to;
        if type == component {
            Appendln(builder, "return *entity.%;", it.name);
            found = true;
            break;
        }
    }

    if !found {
        Appendln(builder, "return null;");
    }
}

#scope_export

// @Todo: Handle multiple components
GetComponent :: (entity : *Entity, $T : Type) -> *T
#modify { return IsInComponentTypesArray(T); } {
    #insert -> string {
        builder : StringBuilder;

        Appendln(*builder, "if GetEntityTypeId(entity.index) == {");

        for i : 1..Entity_Types.count - 1 {
            Appendln(*builder, "case .%1;", Entity_Types[i]);
            AppendGetComponent(*builder, cast(*Type_Info, Entity_Types[i]), type_info(T));
        }

        Appendln(*builder, "}");

        return StringBuilderBuild(*builder);
    }

    return null;
}

GetComponent :: inline (entity : *$E, $T : Type) -> *T
#modify { return IsInEntityTypesArray(E) && IsInComponentTypesArray(T); } {
    #insert -> string {
        builder : StringBuilder;

        AppendGetComponent(*builder, type_info(E), type_info(T));

        return StringBuilderBuild(*builder);
    }
}
