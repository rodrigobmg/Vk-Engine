// WARNING: if this file is renamed or moved, or if the Component struct is moved to
// another file, Build/entity.jai must be updated accordingly

#placeholder Component_Types;

#insert -> string {
    builder : StringBuilder;

    Appendln(*builder, "ComponentTypeId :: enum {");
    Appendln(*builder, "    Invalid :: 0;");

    for i : 1..Component_Types.count - 1 {
        Appendln(*builder, "    % :: %;", Component_Types[i], i);
    }

    Appendln(*builder, "}");

    return StringBuilderBuild(*builder);
};

Components_Per_Page :: 20;

ComponentStorage :: #bake_arguments PagedArray(Page_Size=Components_Per_Page);

Component :: struct {
    entity : EntityGUID;
    index : PagedArraySlotInfo;
    type_id : int;
}

IsInComponentTypesArray :: (type : Type) -> bool {
    for i : 1..Component_Types.count - 1 {
        if Component_Types[i] == type {
            return true;
        }
    }

    return false;
}

GetComponentTypeId :: (type : Type) -> ComponentTypeId {
    for Component_Types {
        if it == type {
            return cast(ComponentTypeId, it_index);
        }
    }

    return .Invalid;
}

GetComponentTypeId :: (component : *Component) -> ComponentTypeId {
    return cast(ComponentTypeId, component.type_id);
}

CreateComponent :: (world : *World, storage : *ComponentStorage($T), entity : EntityGUID) -> *T {
    component, index := PagedArrayFindSlot(storage);
    component.entity = entity;
    component.index = index;
    component.type_id = #run cast(int, GetComponentTypeId(T));

    #if #exists(T.OnCreate) {
        T.OnCreate(world, component);
    }

    return component;
}

DestroyComponent :: (world : *World, storage : *ComponentStorage($T), component : *T) {
    if !component {
        return;
    }

    UnreferenceAllAssets(component);

    #if #exists(T.OnDestroy) {
        T.OnDestroy(world, component);
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

AppendGetComponent :: (builder : *StringBuilder, name : string, entity : *Type_Info_Struct, component : *Type_Info_Struct) {
    found := false;
    for entity.members {
        // @Todo: handle array of components, structs containing components
        if it.type.type != .POINTER {
            continue;
        }

        type := cast(*Type_Info_Pointer, it.type).pointer_to;
        if type == component {
            Appendln(builder, "return %.%;", name, it.name);
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
GetComponent :: inline (entity : *$E, $T : Type) -> *T
#modify { return (E == Entity || IsInEntityTypesArray(E)) && IsInComponentTypesArray(T); } {
    #if E == Entity {
        #insert -> string {
            builder : StringBuilder;

            Appendln(*builder, "if GetEntityTypeId(entity.index) == {");

            for i : 1..Entity_Types.count - 1 {
                Appendln(*builder, "case .%1;", Entity_Types[i]);
                Appendln(*builder, "    e := cast(*%, entity);", Entity_Types[i]);
                AppendGetComponent(*builder, "e", xx cast(*Type_Info, Entity_Types[i]), type_info(T));
            }

            Appendln(*builder, "}");

            return StringBuilderBuild(*builder);
        }
    } else {
        #insert -> string {
            builder : StringBuilder;

            AppendGetComponent(*builder, "entity", type_info(E), type_info(T));

            return StringBuilderBuild(*builder);
        }
    }
}

CallComponentCallback :: inline (world : *World, component : *$T, $Callback : string)
#modify { return T == Component || IsInComponentTypesArray(T); } {
    #if T == Component {
        #insert -> string {
            builder : StringBuilder;

            Appendln(*builder, "if GetComponentTypeId(component) == {");
            for i : 1..Component_Types.count - 1 {
                type := Component_Types[i];
                Appendln(*builder, "case .%1; #if #exists(%1.%2) { %1.%2(world, xx component); }", type, Callback);
            }
            Appendln(*builder, "}");

            return StringBuilderBuild(*builder);
        }
    } else {
        #insert #run TPrint("#if #exists(T.%1) { T.%1(world, component); }", Callback);
    }
}

CallComponentCallback :: inline (world : *World, entity : *Entity, component : *$T, $Callback : string)
#modify { return T == Component || IsInComponentTypesArray(T); } {
    #if T == Component {
        #insert -> string {
            builder : StringBuilder;

            Appendln(*builder, "if GetComponentTypeId(component) == {");
            for i : 1..Component_Types.count - 1 {
                type := Component_Types[i];
                Appendln(*builder, "case .%1; #if #exists(%1.%2) { %1.%2(world, entity, xx component); }", type, Callback);
            }
            Appendln(*builder, "}");

            return StringBuilderBuild(*builder);
        }
    } else {
        #insert #run TPrint("#if #exists(T.%1) { T.%1(world, entity, component); }", Callback);
    }
}

AllEntityComponents :: ($T : Type, entity : *$E, body : Code, flags : For_Flags)
#modify { return (E == Entity || IsInEntityTypesArray(E)) && IsInComponentTypesArray(T); } #expand {
    `it : *T;
    `it_index := 0;

    #if E == Entity {
        #insert -> string {
            builder : StringBuilder;

            Appendln(*builder, "// AllComponents(T=%, E=%)", T, E);
            Appendln(*builder, "if GetEntityTypeId(entity.index) == {");

            comp := type_info(T);
            for i : 1..Entity_Types.count - 1 {
                Appendln(*builder, "case .%1;", Entity_Types[i]);

                info := cast(*Type_Info_Struct, Entity_Types[i]);
                for info.members {
                    if it.type.type != .POINTER {
                        continue;
                    }

                    type := cast(*Type_Info_Pointer, it.type).pointer_to;
                    if type == comp {
                        Appendln(*builder, "    it = cast(*%1, entity).%2;", Entity_Types[i], it.name);
                        Appendln(*builder, "    while it {");
                        Appendln(*builder, "        defer it_index += 1;");
                        Appendln(*builder, "        #insert(break=return, continue=break) body;");
                        Appendln(*builder, "        break;");
                        Appendln(*builder, "    }");
                    }
                }
            }

            Appendln(*builder, "}");

            return StringBuilderBuild(*builder);
        }
    } else {
        #insert -> string {
            builder : StringBuilder;

            Appendln(*builder, "// AllComponents(T=%, E=%)", T, E);

            comp := type_info(T);
            info := type_info(E);
            for info.members {
                if it.type.type != .POINTER {
                    continue;
                }

                type := cast(*Type_Info_Pointer, it.type).pointer_to;
                if type == comp {
                    Appendln(*builder, "it = entity.%;", it.name);
                    Appendln(*builder, "while it {");
                    Appendln(*builder, "    defer it_index += 1;");
                    Appendln(*builder, "    #insert(break=return, continue=break) body;");
                    Appendln(*builder, "    break;");
                    Appendln(*builder, "}");
                }
            }

            return StringBuilderBuild(*builder);
        }
    }
}
