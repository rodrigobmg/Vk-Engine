StaticMeshComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    mesh : *Asset(StaticMesh); @Serialize(2)
    material : *Asset(Material); @Serialize(3)
    cast_shadows := true; @Serialize(4)
    cast_point_shadows := false; @Serialize(5)
} @Component

AllStaticMeshComponents :: #bake_arguments AllComponents(T=StaticMeshComponent);

SkinnedMeshComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    mesh : *Asset(SkinnedMesh); @Serialize(2)
    material : *Asset(Material); @Serialize(3)
    cast_shadows := true; @Serialize(4)
    cast_point_shadows := false; @Serialize(5)
    skinning_matrices : []Mat4f;

    OnDestroy :: (world : *World, using comp : *SkinnedMeshComponent) {
        Free(skinning_matrices.data);
    }
} @Component

AllSkinnedMeshComponents :: #bake_arguments AllComponents(T=SkinnedMeshComponent);

SetPose :: (using component : *SkinnedMeshComponent, pose : *ArmaturePose) {
    if !pose.mesh {
        return;
    }

    if pose.mesh != mesh {
        LogError("Mismatching mesh when setting pose ('%' vs '%')", mesh.asset_name, pose.mesh.asset_name);
    }

    CalculateSkinningMatrices(pose, *skinning_matrices);
}

StaticMeshEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    mesh : *StaticMeshComponent; @Serialize(2)

    OnSpawn :: (world : *World, entity : *StaticMeshEntity) {
        entity.mesh = CreateComponent(world, StaticMeshComponent, entity);
    }

    OnDespawn :: (world : *World, entity : *StaticMeshEntity) {
        DestroyComponent(world, entity.mesh);
    }
} @Entity

AnimatedMeshEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    mesh : *SkinnedMeshComponent; @Serialize(2)

    animation : *Asset(ArmatureAnimation); @Serialize(3)
    animation_frames_per_second := 30.0; @Serialize(4)
    animation_time : float;
    pose : ArmaturePose;

    OnSpawn :: (world : *World, entity : *AnimatedMeshEntity) {
        entity.mesh = CreateComponent(world, SkinnedMeshComponent, entity);
    }

    OnDespawn :: (world : *World, entity : *AnimatedMeshEntity) {
        DestroyComponent(world, entity.mesh);
    }

    OnEditorUpdate :: (world : *World, using entity : *AnimatedMeshEntity) {
        if pose.mesh != mesh.mesh {
            FreeArmaturePose(*pose);

            if mesh {
                InitArmaturePose(*pose, mesh.mesh);
            }
        }

        if !mesh.mesh {
            return;
        }

        if animation {
            SampleAnimation(animation, animation_time, *pose);
            animation_time += g_last_frame_time * animation_frames_per_second;
        } else {
            ResetToBindPose(*pose);
            animation_time = 0;
        }

        CalculatePoseTransforms(*pose);
        SetPose(mesh, *pose);
    }
} @Entity

DirectionalLightComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    color : Vec3f = .{1,1,1}; @Serialize(2) @ColorEdit
    intensity : float = 1; @Serialize(3) @FloatRange(0,1000)
    cast_shadows : bool; @Serialize(4)
    shadow_map : ShadowMap;

    OnDestroy :: (world : *World, using component : *DirectionalLightComponent) {
        DestroyShadowMap(*shadow_map);
    }
} @Component

DirectionalLightEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    light : *DirectionalLightComponent; @Serialize(2)

    OnSpawn :: (world : *World, light : *DirectionalLightEntity) {
        light.light = CreateComponent(world, DirectionalLightComponent, light);
    }

    OnDespawn :: (world : *World, light : *DirectionalLightEntity) {
        DestroyComponent(world, light.light);
    }

    OnDebugDraw :: (world : *World, using entity : *DirectionalLightEntity) {
        if EntityIsSelected(guid) {
            position := TranslationVector(world_transform);
            right := RightVector(world_transform);
            up := UpVector(world_transform);
            direction := ForwardVector(world_transform);

            p0 := position + right * 0.3;
            p1 := position - right * 0.3;
            p2 := position + up * 0.3;
            p3 := position - up * 0.3;

            DebugDrawCircleOutline(.{1,1,1,1}, position, right, up, 0.3);
            DebugDrawLine(.{1,1,1,1}, p0, p0 + direction);
            DebugDrawLine(.{1,1,1,1}, p1, p1 + direction);
            DebugDrawLine(.{1,1,1,1}, p2, p2 + direction);
            DebugDrawLine(.{1,1,1,1}, p3, p3 + direction);
        }
    }
} @Entity

PointLightComponent :: struct {
    #as using _ : Component; @Serialize(1) @InspectorNoTree

    color : Vec3f = .{1,1,1}; @Serialize(2) @ColorEdit
    intensity : float = 1; @Serialize(3) @FloatRange(0,1000)
    cast_shadows : bool; @Serialize(4)
    shadow_map : PointShadowMap;

    OnDestroy :: (world : *World, using component : *PointLightComponent) {
        DestroyShadowMap(*shadow_map);
    }
} @Component

PointLightEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    light : *PointLightComponent; @Serialize(2)

    OnSpawn :: (world : *World, light : *PointLightEntity) {
        light.light = CreateComponent(world, PointLightComponent, light);
    }

    OnDespawn :: (world : *World, light : *PointLightEntity) {
        DestroyComponent(world, light.light);
    }

    OnDebugDraw :: (world : *World, using entity : *PointLightEntity) {
        if EntityIsSelected(guid) {
            position := TranslationVector(world_transform);
            distance := GetPointLightAttenuationDistance(light.intensity, light.intensity * Global_Point_Light_Intensity_Threshold);
            DebugDrawSphereOutline(.{0,1,0,1}, position, distance);
        }
    }
} @Entity

Global_Point_Light_Intensity_Threshold :: 0.001;

GetPointLightAttenuationDistance :: (intensity : float, intensity_threshold : float) -> float {
    // Light intensity at distance D for base intensity I is I/D^2
    // Solve for I/D^2 < T
    //   I/D^2 < T
    //   I < T*D^2
    //   0 < T*D^2-I
    //   T*D^2-I > 0

    return (4 * intensity * intensity_threshold) / (2 * intensity_threshold);
}
