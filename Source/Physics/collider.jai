SphereColliderComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    radius : float = 1; @Serialize(2)

    OnDebugDraw :: (world : *World, entity : *Entity, using,except(entity) sphere : *SphereColliderComponent) {
        if EntityOrParentIsSelected(world, entity) {
            center := TranslationVector(entity.world_transform);
            DebugDrawSphereOutline(.{0,1,0,1}, center, radius);
        }
    }
} @Component @Category(Colliders)

RayIntersection :: (world : *World, sphere : *SphereColliderComponent, ray_origin : Vec3f, ray_direction : Vec3f, ray_length : float) -> RaycastResult {
    entity := GetEntity(world, sphere.entity_index);
    if !entity {
        return .{};
    }

    center := TranslationVector(entity.world_transform);
    // @Todo: take the full transform into account
    intersects, point, dist, normal := RayIntersectsSphere(ray_origin, ray_direction, ray_length, center, sphere.radius);

    return .{
        hit=intersects,
        entity=entity,
        collider=sphere,
        point=point,
        dist=dist,
        normal=normal,
    };
}

CapsuleColliderComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    height : float = 2; @Serialize(2)
    radius : float = 0.5; @Serialize(3)

    OnDebugDraw :: (world : *World, entity : *Entity, using,except(entity) capsule : *CapsuleColliderComponent) {
        if EntityOrParentIsSelected(world, entity) {
            center := TranslationVector(entity.world_transform);
            up := UpVector(entity.world_transform);
            DebugDrawCapsuleOutline(.{0,1,0,1}, center - up * height * 0.5, center + up * height * 0.5, radius);
        }
    }
} @Component @Category(Colliders)

RayIntersection :: (world : *World, capsule : *CapsuleColliderComponent, ray_origin : Vec3f, ray_direction : Vec3f, ray_length : float) -> RaycastResult {
    entity := GetEntity(world, capsule.entity_index);
    if !entity {
        return .{};
    }

    center := TranslationVector(entity.world_transform);
    up := UpVector(entity.world_transform);
    base := center - up * capsule.height * 0.5;
    tip  := center + up * capsule.height * 0.5;
    // @Todo: take the full transform into account
    intersects, point, dist, normal := RayIntersectsCapsule(ray_origin, ray_direction, ray_length, base, tip, capsule.radius);

    return .{
        hit=intersects,
        entity=entity,
        collider=capsule,
        point=point,
        dist=dist,
        normal=normal,
    };
}

BoxColliderComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    half_extents : Vec3f = .{1,1,1}; @Serialize(2)

    OnDebugDraw :: (world : *World, entity : *Entity, using,except(entity) box : *BoxColliderComponent) {
        if EntityOrParentIsSelected(world, entity) {
            DebugDrawBoxOutline(.{0,1,0,1}, .{0,0,0}, half_extents, entity.world_transform);
        }
    }
} @Component @Category(Colliders)

RayIntersection :: (world : *World, box : *BoxColliderComponent, ray_origin : Vec3f, ray_direction : Vec3f, ray_length : float) -> RaycastResult {
    entity := GetEntity(world, box.entity_index);
    if !entity {
        return .{};
    }

    intersects, point, dist, normal := RayIntersectsBox(ray_origin, ray_direction, ray_length, box.half_extents, entity.world_transform);

    return .{
        hit=intersects,
        entity=entity,
        collider=box,
        point=point,
        dist=dist,
        normal=normal,
    };
}

MeshColliderComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    mesh : *Asset(StaticMesh); @Serialize(2)
} @Component @Category(Colliders)

RayIntersection :: (world : *World, mesh : *MeshColliderComponent, ray_origin : Vec3f, ray_direction : Vec3f, ray_length : float) -> RaycastResult {
    entity := GetEntity(world, mesh.entity_index);
    if !entity {
        return .{};
    }

    intersects, point, dist, normal := RayIntersectsMesh(ray_origin, ray_direction, ray_length, mesh.mesh, entity.world_transform, entity.inv_world_transform);

    return .{
        hit=intersects,
        entity=entity,
        collider=mesh,
        point=point,
        dist=dist,
        normal=normal,
    };
}

RaycastResult :: struct {
    hit : bool;
    point : Vec3f;
    normal : Vec3f;
    dist := F32_Inf;
    entity : *Entity;
    collider : *Component;
}

RaycastAll :: (world : *World, ray_origin : Vec3f, ray_direction : Vec3f, ray_length : float, results : *[..]RaycastResult) -> bool {
    original_count := results.count;

    for * world.SphereColliderComponent_storage {
        hit := RayIntersection(world, it, ray_origin, ray_direction, ray_length);
        if hit.hit {
            ArrayPush(results, hit);
        }
    }
    for * world.CapsuleColliderComponent_storage {
        hit := RayIntersection(world, it, ray_origin, ray_direction, ray_length);
        if hit.hit {
            ArrayPush(results, hit);
        }
    }
    for * world.BoxColliderComponent_storage {
        hit := RayIntersection(world, it, ray_origin, ray_direction, ray_length);
        if hit.hit {
            ArrayPush(results, hit);
        }
    }
    for * world.MeshColliderComponent_storage {
        hit := RayIntersection(world, it, ray_origin, ray_direction, ray_length);
        if hit.hit {
            ArrayPush(results, hit);
        }
    }

    return results.count > original_count;
}

Raycast :: (world : *World, ray_origin : Vec3f, ray_direction : Vec3f, ray_length : float) -> RaycastResult {
    closest_hit : RaycastResult;
    for * world.SphereColliderComponent_storage {
        hit := RayIntersection(world, it, ray_origin, ray_direction, ray_length);
        if hit.hit && hit.dist < closest_hit.dist {
            closest_hit = hit;
        }
    }
    for * world.CapsuleColliderComponent_storage {
        hit := RayIntersection(world, it, ray_origin, ray_direction, ray_length);
        if hit.hit && hit.dist < closest_hit.dist {
            closest_hit = hit;
        }
    }
    for * world.BoxColliderComponent_storage {
        hit := RayIntersection(world, it, ray_origin, ray_direction, ray_length);
        if hit.hit && hit.dist < closest_hit.dist {
            closest_hit = hit;
        }
    }
    for * world.MeshColliderComponent_storage {
        hit := RayIntersection(world, it, ray_origin, ray_direction, ray_length);
        if hit.hit && hit.dist < closest_hit.dist {
            closest_hit = hit;
        }
    }

    return closest_hit;
}
