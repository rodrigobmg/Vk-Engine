ProjectPointOnLine :: inline (point : Vec3f, line_origin : Vec3f, line_dir : Vec3f) -> Vec3f, t : float {
    t := Dot(point - line_origin, line_dir) / Dot(line_dir, line_dir);

    return line_origin + t * line_dir, t;
}

ProjectPointOnRay :: inline (point : Vec3f, ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float) -> Vec3f, t : float {
    t := Dot(point - ray_origin, ray_dir) / Dot(ray_dir, ray_dir);
    t = Clamp(t, 0, ray_length);

    return ray_origin + t * ray_dir, t;
}

ProjectPointOnPlane :: inline (point : Vec3f, plane_origin : Vec3f, plane_normal : Vec3f) -> Vec3f {
    dist := Dot(point - plane_origin, plane_normal);

    return point - dist * plane_normal;
}

ProjectPointOnSphere :: inline (point : Vec3f, sphere_center : Vec3f, sphere_radius : float) -> Vec3f {
    return sphere_center + Normalized(point - sphere_center) * sphere_radius;
}

ProjectPointOnCapsule :: (point : Vec3f, capsule_base : Vec3f, capsule_tip : Vec3f, capsule_radius : float) -> Vec3f {
    capsule_up, capsule_height := Normalized(capsule_tip - capsule_base);
    closest := ProjectPointOnRay(point, capsule_base + capsule_up * capsule_radius, capsule_up, capsule_height - capsule_radius * 2);
    closest += Normalized(point - closest) * capsule_radius;

    return closest;
}

PointIsInsideBox :: inline (point : Vec3f, box_center : Vec3f, box_half_extents : Vec3f) -> bool {
    return
        point.x >= box_center.x - box_half_extents.x &&
        point.x <= box_center.x + box_half_extents.x &&
        point.y >= box_center.y - box_half_extents.y &&
        point.y <= box_center.y + box_half_extents.y &&
        point.z >= box_center.z - box_half_extents.z &&
        point.z <= box_center.z + box_half_extents.z;
}

GetPointPenetrationInBox :: (point_inside_box : Vec3f, box_center : Vec3f, box_half_extents : Vec3f) -> Vec3f {
    min := -box_half_extents;
    max := box_half_extents;
    point := point_inside_box - box_center;

    dist := min.x - point.x;
    abs_dist := Abs(dist);
    min_dist := abs_dist;
    result := Vec3f.{dist, 0, 0};

    dist = max.x - point.x;
    abs_dist = Abs(dist);
    if abs_dist < min_dist {
        min_dist = abs_dist;
        result = .{dist, 0, 0};
    }

    dist = min.y - point.y;
    abs_dist = Abs(dist);
    if abs_dist < min_dist {
        min_dist = abs_dist;
        result = .{0, dist, 0};
    }

    dist = max.y - point.y;
    abs_dist = Abs(dist);
    if abs_dist < min_dist {
        min_dist = abs_dist;
        result = .{0, dist, 0};
    }

    dist = min.z - point.z;
    abs_dist = Abs(dist);
    if abs_dist < min_dist {
        min_dist = abs_dist;
        result = .{0, 0, dist};
    }

    dist = max.z - point.z;
    abs_dist = Abs(dist);
    if abs_dist < min_dist {
        min_dist = abs_dist;
        result = .{0, 0, dist};
    }

    return result;
}

ProjectPointOnBox :: inline (point : Vec3f, box_center : Vec3f, box_half_extents : Vec3f) -> Vec3f {
    if PointIsInsideBox(point, box_center, box_half_extents) {
        return point + GetPointPenetrationInBox(point, box_center, box_half_extents);
    }

    return Clamp(point, box_center - box_half_extents, box_center + box_half_extents);
}

ProjectPointOnBox :: inline (point : Vec3f, box_center : Vec3f, box_half_extents : Vec3f, orientation : Quatf) -> Vec3f {
    p := Rotate(point - box_center, Conjugate(orientation));
    p = ProjectPointOnBox(p, .{0,0,0}, box_half_extents);
    p = box_center + Rotate(p, orientation);

    return p;
}

PointIsOnTriangle :: (point : Vec3f, triangle_A : Vec3f, triangle_B : Vec3f, triangle_C : Vec3f, epsilon := 0.00001) -> bool
{
    // Move the triangle so that point is at the origin.
    // Construct the normals of the triangle PAB, PBC and PCA using the cross product.
    a, b, c := triangle_A, triangle_B, triangle_C;
    a -= point;
    b -= point;
    c -= point;

    u := Cross(b, c);
    v := Cross(c, a);
    w := Cross(a, b);

    // The point is on the triangle if the normals vectors lie in the same hemisphere (dot product).
    return Dot(u, v) >= 0 && Dot(u, w) >= 0;
}

RayIntersectsPlane :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, plane_origin : Vec3f, plane_normal : Vec3f) -> intersects : bool, point : Vec3f, dist : float, normal : Vec3f {
    denom := Dot(plane_normal, ray_dir);

    if !ApproxZero(denom, 0.0001) {
        q := plane_origin - ray_origin;
        t := Dot(q, plane_normal);
        sign := -Sign(t);
        t /= denom;

        if t >= 0 && t < ray_length {
            return true, ray_origin + ray_dir * t, t, sign * plane_normal;
        }
    }

    return false, .{}, 0, .{};
}

RayIntersectsSphere :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, sphere_center : Vec3f, sphere_radius : float) -> intersects : bool, point : Vec3f, dist : float, normal : Vec3f {
    sq_r := sphere_radius * sphere_radius;

    e := sphere_center - ray_origin;
    e_sq := Dot(e, e);

    a := Dot(e, ray_dir);
    sq_a := a * a;

    b := Abs(e_sq - sq_a);
    if b > sq_r {
        return false, .{}, 0, .{};
    }

    f := Sqrt(sq_r - b);

    if sq_r - e_sq + sq_a < 0 {
        return false, .{}, 0, .{};
    }

    dist := ifx e_sq < sq_r then a + f else a - f;
    if dist >= 0 && dist <= ray_length {
        point := ray_origin + ray_dir * dist;

        return true, point, dist, Normalized(point - sphere_center);
    }

    return false, .{}, 0, .{};
}

RayIntersectsCapsule :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, capsule_base : Vec3f, capsule_tip : Vec3f, capsule_radius : float) -> intersects : bool, point : Vec3f, dist : float, normal : Vec3f {
    capsule_up := Normalized(capsule_tip - capsule_base);
    capsule_A := capsule_base + capsule_up * capsule_radius;
    capsule_B := capsule_tip - capsule_up * capsule_radius;

    AB := capsule_B - capsule_A;
    AO := ray_origin - capsule_A;

    AB_dot_d := Dot(AB, ray_dir);
    AB_dot_AO := Dot(AB, AO);
    AB_dot_AB := Dot(AB, AB);

    m := AB_dot_d / AB_dot_AB;
    n := AB_dot_AO / AB_dot_AB;

    Q := ray_dir - AB * m;
    R := AO - AB * n;

    a := Dot(Q, Q);
    b := 2 * Dot(Q, R);
    c := Dot(R, R) - capsule_radius * capsule_radius;

    if ApproxZero(a, 0.00001) {
        A_ok, A_point, A_dist, A_normal := RayIntersectsSphere(ray_origin, ray_dir, ray_length, capsule_A, capsule_radius);
        if !A_ok {
            return false, .{}, 0, .{};
        }

        B_ok, B_point, B_dist, B_normal := RayIntersectsSphere(ray_origin, ray_dir, ray_length, capsule_B, capsule_radius);

        if B_dist < A_dist {
            return true, B_point, B_dist, B_normal;
        }

        return true, A_point, A_dist, A_normal;
    }

    discriminant := b * b - 4 * a * c;
    if discriminant < 0 {
        return false, .{}, 0, .{};
    }

    tmin := (-b - Sqrt(discriminant)) / (2 * a);
    tmax := (-b + Sqrt(discriminant)) / (2 * a);
    if tmin > tmax {
        Swap(*tmin, *tmax);
    }

    t := ifx tmin < 0 then tmax else tmin;
    K1 := t * m + n;
    if K1 < 0 || K1 > 1 {
        K1 = Clamp(K1, 0, 1);
        sphere_center := capsule_A + AB * K1;

        intersects, point, dist, normal := RayIntersectsSphere(ray_origin, ray_dir, ray_length, sphere_center, capsule_radius);

        return intersects, point, dist, normal;
    }

    if t < 0 || t > ray_length {
        return false, .{}, 0, .{};
    }

    point := ray_origin + ray_dir * t;

    point_on_capsule := capsule_A + AB * K1;
    normal := Normalized(point - point_on_capsule);

    return true, point, t, normal;
}

RayIntersectsBox :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, box_center : Vec3f, box_half_extents : Vec3f) -> intersects : bool, point : Vec3f, dist : float, normal : Vec3f {
    inv_dir := Vec3f.{1 / ray_dir.x, 1 / ray_dir.y, 1 / ray_dir.z};

    min := box_center - box_half_extents;
    max := box_center + box_half_extents;
    t1 := Scale(min - ray_origin, inv_dir);
    t2 := Scale(max - ray_origin, inv_dir);

    t_min := Min(t1, t2);
    t_max := Max(t1, t2);

    t_near := Max(Max(t_min.x, t_min.y), t_min.z);
    t_far := Min(Min(t_max.x, t_max.y), t_max.z);

    if t_near > t_far {
        return false, .{}, 0, .{};
    }

    t := ifx t_near < 0 then t_far else t_near;
    if t < 0 || t > ray_length {
        return false, .{}, 0, .{};
    }

    point := ray_origin + ray_dir * t;
    normal := Vec3f.{
        cast(float, t == t_min.x || t == t_max.x) * Sign(-inv_dir.x),
        cast(float, t == t_min.y || t == t_max.y) * Sign(-inv_dir.y),
        cast(float, t == t_min.z || t == t_max.z) * Sign(-inv_dir.z),
    };

    return true, point, t, normal;
}

RayIntersectsBox :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, box_center : Vec3f, box_half_extents : Vec3f, orientation : Quatf) -> intersects : bool, point : Vec3f, dist : float, normal : Vec3f {
    box_ray_origin := Rotate(ray_origin - box_center, Conjugate(orientation));
    box_ray_dir := Rotate(ray_dir, Conjugate(orientation));

    intersects, point, dist, normal := RayIntersectsBox(box_ray_origin, box_ray_dir, ray_length, .{0,0,0}, box_half_extents);
    if !intersects {
        return false, .{}, 0, .{};
    }

    point = box_center + Rotate(point, orientation);
    normal = Rotate(normal, orientation);

    return intersects, point, dist, normal;
}

RayIntersectsBox :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, transform : Mat4f) -> intersects : bool, point : Vec3f, dist : float, normal : Vec3f {
    inv_transform := Inverse(transform);
    model_space_ray_origin := TransformPoint(inv_transform, ray_origin);
    model_space_ray_dir := Normalized(TransformVector(inv_transform, ray_dir));

    intersects, point, dist, normal := RayIntersectsBox(model_space_ray_origin, model_space_ray_dir, ray_length, .{0,0,0}, .{1,1,1});
    if !intersects {
        return false, .{}, 0, .{};
    }

    point = TransformPoint(transform, point);
    normal = Normalized(TransformVector(transform, normal));
    dist = Distance(point, ray_origin);

    return dist < ray_length, point, dist, normal;
}

RayIntersectsTriangle :: RayIntersectsTriangleMollerTrumbore;

// Möller–Trumbore intersection algorithm
// https://en.wikipedia.org/wiki/M%C3%B6ller%E2%80%93Trumbore_intersection_algorithm
// https://youtu.be/fK1RPmF_zjQ
RayIntersectsTriangleMollerTrumbore :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, triangle_A : Vec3f, triangle_B : Vec3f, triangle_C : Vec3f) -> intersets : bool, point : Vec3f, dist : float, normal : Vec3f {
    AB := triangle_B - triangle_A;
    AC := triangle_C - triangle_A;
    ray_vs_AC := Cross(ray_dir, AC);
    det := Dot(AB, ray_vs_AC);

    // No epsilon because it can give false negatives
    // The original algorithm uses one, but it also uses double precision so there's that
    // If det is very close to 0, we'll probably end up with infinity/very large values for u or v, which
    // will return false because of `if u < 0 || u > 1` etc
    if det == 0 {
        return false, .{}, 0, .{};
    }

    inv_det := 1 / det;
    s := ray_origin - triangle_A;
    u := inv_det * Dot(s, ray_vs_AC);

    if u < 0 || u > 1 {
        return false, .{}, 0, .{};
    }

    s_vs_AB := Cross(s, AB);
    v := inv_det * Dot(ray_dir, s_vs_AB);

    if v < 0 || u + v > 1 {
        return false, .{}, 0, .{};
    }

    t := inv_det * Dot(AC, s_vs_AB);
    if t > 0 && t < ray_length {
        normal := Sign(det) * Normalized(Cross(AB, AC), epsilon=0);

        return true, ray_origin + t * ray_dir, t, normal;
    }

    return false, .{}, 0, .{};
}

RayIntersectsMesh :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, mesh : *StaticMesh, transform : Mat4f) -> intersects : bool, point : Vec3f, dist : float, normal : Vec3f, triangle_index : int {
    inv_transform := Inverse(transform);
    intersects, point, dist, normal, triangle_index := RayIntersectsMesh(ray_origin, ray_dir, ray_length, mesh, transform, inv_transform);

    return intersects, point, dist, normal, triangle_index;
}

RayIntersectsMesh :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, mesh : *StaticMesh, transform : Mat4f, inv_transform : Mat4f) -> intersects : bool, point : Vec3f, dist : float, normal : Vec3f, triangle_index : int {
    model_space_ray_origin := TransformPoint(inv_transform, ray_origin);
    model_space_ray_dir := Normalized(TransformVector(inv_transform, ray_dir));

    early_hit, early_point := RayIntersectsBox(model_space_ray_origin, model_space_ray_dir, F32_Inf, mesh.static_bounds.center, mesh.static_bounds.half_extents);
    if !early_hit || Distance(TransformPoint(transform, early_point), ray_origin) > ray_length {
        return false, .{}, 0, .{}, -1;
    }

    closest_hit : bool;
    closest_point, closest_normal : Vec3f;
    closest_dist := F32_Inf;
    triangle_index := -1;

    for mesh.triangles {
        hit, point, dist, normal
            := RayIntersectsTriangle(model_space_ray_origin, model_space_ray_dir, F32_Inf, it.p0, it.p1, it.p2);

        if hit && dist < closest_dist {
            closest_hit = true;
            closest_point = point;
            closest_normal = normal;
            closest_dist = dist;
            triangle_index = xx it_index;
        }
    }

    if !closest_hit {
        return false, .{}, 0, .{}, -1;
    }

    point := TransformPoint(transform, closest_point);
    normal := Normalized(TransformVector(transform, closest_normal));
    dist := Distance(point, ray_origin);

    return dist < ray_length, point, dist, normal, triangle_index;
}
