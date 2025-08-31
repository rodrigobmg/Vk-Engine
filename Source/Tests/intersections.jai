TestShapeEntity :: struct {
    #as using _ : Entity; @Serialize(1) @InspectorNoTree

    Shape :: enum {
        Point;
        Ray;
        Box;
        Sphere;
        Capsule;
        Mesh;
        Plane;
    }

    shape : Shape; @Serialize(2)
    sphere_radius := 1.0; @Serialize(4) @FloatRange(0.1,100)
    capsule_height := 2.0; @Serialize(5) @FloatRange(0.1,100)
    capsule_radius := 0.5; @Serialize(6) @FloatRange(0.1,100)
    mesh : *StaticMeshComponent; @Serialize(8)
    ray_length := 10.0; @Serialize(9)

    OnSpawn :: (world : *World, using entity : *TestShapeEntity) {
        mesh = CreateComponent(world, StaticMeshComponent, entity);
    }

    OnDespawn :: (world : *World, using entity : *TestShapeEntity) {
        DestroyComponent(world, mesh);
    }

    OnDebugDraw :: (world : *World, using entity : *TestShapeEntity) {
        position := TranslationVector(world_transform);
        if #complete shape == {
        case .Point;
            DebugDrawCross(.{1,1,1,1}, position, 0.1);

            for * world.TestShapeEntity_storage {
                if it.shape == {
                case .Box;
                case .Plane;
                case .Ray;
                case .Sphere;
                case .Capsule;
                case .Mesh;
                    if !mesh.mesh {
                        continue;
                    }
                }
            }
        case .Ray;
            direction := ForwardVector(world_transform);
            DebugDrawCross(.{1,1,1,1}, position, 0.1);
            DebugDrawLine(.{1,1,1,1}, position, position + direction * ray_length);

            intersects : bool;
            point : Vec3f;
            normal : Vec3f;
            for * world.TestShapeEntity_storage {
                if it.shape == {
                case .Box;
                    intersects, point, _, normal =
                        RayIntersectsBox(position, direction, ray_length, it.world_transform);

                case .Plane;
                case .Ray;
                case .Sphere;
                    intersects, point, _, normal =
                        RayIntersectsSphere(position, direction, ray_length, TranslationVector(it.world_transform), it.sphere_radius);

                case .Capsule;
                    capsule_normal := UpVector(it.world_transform);
                    capsule_center := TranslationVector(it.world_transform);
                    capsule_base := capsule_center - capsule_normal * it.capsule_height * 0.5;
                    capsule_tip := capsule_center + capsule_normal * it.capsule_height * 0.5;
                    intersects, point, _, normal =
                        RayIntersectsCapsule(position, direction, ray_length, capsule_base, capsule_tip, it.capsule_radius);

                case .Mesh;
                    if !it.mesh.mesh {
                        continue;
                    }

                    intersects, point, _, normal =
                        RayIntersectsMesh(position, direction, ray_length, it.mesh.mesh, it.world_transform);
                }

                if intersects {
                    DebugDrawCross(.{1,0,0,1}, point, 0.1);
                    DebugDrawLine(.{0,0,1,1}, point, point + normal * 0.2);
                }
            }
        case .Box;
            DebugDrawBoxOutline(.{1,1,1,1}, .{0,0,0}, .{1,1,1}, world_transform);
        case .Sphere;
            DebugDrawSphereOutline(.{1,1,1,1}, position, sphere_radius);
        case .Capsule;
            normal := UpVector(world_transform);
            DebugDrawCapsuleOutline(.{1,1,1,1}, position - normal * capsule_height * 0.5, position + normal * capsule_height * 0.5, capsule_radius);
        case .Mesh;
        case .Plane;
        }
    }
} @Entity

IntersectionMenu :: (world : *World) {
    if ImGui.BeginMenu("Tools") {
        defer ImGui.EndMenu();

        if ImGui.MenuItem("Spawn Lots of Points in a Sphere") {
            R :: 10;

            root := SpawnEntity(world, EmptyEntity, "Points");
            for i_lat : 0..R - 1 {
                lat := Lerp(-Pi * 0.5, Pi * 0.5, i_lat / cast(float, R));
                for i_lon : 0..R - 1 {
                    lon := Lerp(-Pi, Pi, i_lon / cast(float, R));

                    p := SphericalToCartesian(lon, lat);
                    direction := -p;
                    right, up := ForwardToOrthonormalBasis(direction);
                    rotation_matrix := Mat3fFromRightUpForward(right, up, direction);
                    rotation := QuatfFromMatrix(rotation_matrix);

                    point := SpawnEntity(world, TestShapeEntity, TPrint("Point % %", i_lat, i_lon));
                    point.shape = .Point;
                    point.local_position = p * 10;
                    point.local_rotation = rotation;
                    AttachEntity(world, point, root);
                }
            }
        }

        if ImGui.MenuItem("Spawn Lots of Rays in a Sphere") {
            R :: 10;

            root := SpawnEntity(world, EmptyEntity, "Rays");
            for i_lat : 0..R - 1 {
                lat := Lerp(-Pi * 0.5, Pi * 0.5, i_lat / cast(float, R));
                for i_lon : 0..R - 1 {
                    lon := Lerp(-Pi, Pi, i_lon / cast(float, R));

                    p := SphericalToCartesian(lon, lat);
                    direction := -p;
                    right, up := ForwardToOrthonormalBasis(direction);
                    rotation_matrix := Mat3fFromRightUpForward(right, up, direction);
                    rotation := QuatfFromMatrix(rotation_matrix);

                    ray := SpawnEntity(world, TestShapeEntity, TPrint("Ray % %", i_lat, i_lon));
                    ray.shape = .Ray;
                    ray.local_position = p * 10;
                    ray.local_rotation = rotation;
                    AttachEntity(world, ray, root);
                }
            }
        }
    }
} @EditorMainMenu
