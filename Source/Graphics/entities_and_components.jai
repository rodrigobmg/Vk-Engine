StaticMeshComponent :: struct {
    #as using _ : SpatialComponent; @Serialize(1) @InspectorNoTree

    mesh : *Asset(StaticMesh); @Serialize(2)
    material : *Asset(Material); @Serialize(3)
    cast_shadows := true; @Serialize(4)
    cast_point_shadows := false; @Serialize(5)
} @Component

AllStaticMeshComponents :: #bake_arguments AllEntityComponents(T=StaticMeshComponent);

SkinnedMeshComponent :: struct {
    #as using _ : SpatialComponent; @Serialize(1) @InspectorNoTree

    mesh : *Asset(SkinnedMesh); @Serialize(2)
    material : *Asset(Material); @Serialize(3)
    cast_shadows := true; @Serialize(4)
    cast_point_shadows := false; @Serialize(5)
    skinning_matrices : []Mat4f;

    OnDestroy :: (world : *World, using comp : *SkinnedMeshComponent) {
        Free(skinning_matrices.data);
    }
} @Component

AllSkinnedMeshComponents :: #bake_arguments AllEntityComponents(T=SkinnedMeshComponent);

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

    OnDespawn :: (world : *World, using entity : *AnimatedMeshEntity) {
        DestroyComponent(world, mesh);
        FreeArmaturePose(*pose);
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
            animation_time += GetDeltaTime() * animation_frames_per_second;
        } else {
            ResetToBindPose(*pose);
            animation_time = 0;
        }

        CalculatePoseTransforms(*pose);
        SetPose(mesh, *pose);
    }
} @Entity
