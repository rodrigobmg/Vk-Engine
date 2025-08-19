Cos :: Math.cos;
Sin :: Math.sin;
Tan :: Math.tan;
Acos :: Math.acos;
Asin :: Math.asin;
Atan :: Math.atan;
Atan2 :: Math.atan2;
Sqrt :: Math.sqrt;
Floor :: Math.floor;
Ceil :: Math.ceil;

Tau :: Math.TAU;
Tau64 :: Math.TAU64;

Pi :: Math.PI;
Pi64 :: Math.PI64;

F32_Min :: Math.FLOAT32_MIN;
F32_Max :: Math.FLOAT32_MAX;
F32_Inf :: Math.FLOAT32_INFINITY;
F32_NaN :: Math.FLOAT32_NAN;
F64_Min :: Math.FLOAT64_MIN;
F64_Max :: Math.FLOAT64_MAX;
F64_Inf :: Math.FLOAT64_INFINITY;
F64_NaN :: Math.FLOAT64_NAN;
S8_Min :: Math.S8_MIN;
S8_Max :: Math.S8_MAX;
U8_Max :: Math.U8_MAX;
S16_Min :: Math.S16_MIN;
S16_Max :: Math.S16_MAX;
U16_Max :: Math.U16_MAX;
S32_Min :: Math.S32_MIN;
S32_Max :: Math.S32_MAX;
U32_Max :: Math.U32_MAX;
S64_Min :: Math.S64_MIN;
S64_Max :: Math.S64_MAX;
U64_Max :: Math.U64_MAX;

Rect :: struct (T : Type) {
    x, y, w, h : T;

    #place x;
    position : Vec2(T);
    size : Vec2(T);
}

operator == :: inline (a : $T/Rect, b : Rect) -> bool {
    return a.position == b.position && a.size == b.size;
}

Recti :: Rect(s32);
Rectf :: Rect(float);

ToRads :: inline (angle_in_degrees : float) -> float {
    return angle_in_degrees * Math.PI / 180.0;
} @NoProfile

ToDegs :: inline (angle_in_radians : float) -> float {
    return angle_in_radians * 180.0 / Math.PI;
} @NoProfile

AlignForward :: (x : u64, alignment : u64) -> u64 {
    Assert(alignment > 0, "Invalid alignment: %", alignment);

    return ((x + alignment - 1) / alignment) * alignment;
} @NoProfile

AlignForward :: (x : s64, alignment : s64) -> s64 {
    Assert(alignment > 0, "Invalid alignment: %", alignment);

    return ((x + alignment - 1) / alignment) * alignment;
} @NoProfile

StructPrinter :: (builder : *StringBuilder, any : Any, data : *void) -> bool {
    if any.type == type_info(EntityGUID) {
        guid := cast(*EntityGUID) any.value_pointer;
        if guid.* == Null_Entity_GUID {
            Append(builder, "(null entity)");
        } else {
            Append(builder, "%1%2", FormatIntHex(guid.high), FormatIntHex(guid.low));
        }

        return true;
    }

    return false;
} @NoProfile

ScopeLongFormStructFormat :: () #expand {
    prev := context.print_style.default_format_struct;
    `defer context.print_style.default_format_struct = prev;

    context.print_style.default_format_struct.use_long_form_if_more_than_this_many_members = 0;
    context.print_style.default_format_struct.use_newlines_if_long_form = true;
}

Pow :: Math.pow;

Log :: Math.log;

Log10 :: inline (x : float) -> float {
    return Log(x) / #run Log(10);
}

Log2 :: inline (x : float) -> float {
    return Log(x) / #run Log(2);
}

ParseNote :: (note : string) -> ok : bool, name : string, args : []string {
    open_paren := find_index_from_left(note, "(");
    if open_paren < 0 {
        return true, note, .[];
    }

    name := note;
    name.count = open_paren;

    close_paren := find_index_from_right(note, ")");
    if close_paren != note.count - 1 {
        return false, name, .[];
    }

    close_paren = find_index_from_left(note, ")");
    if close_paren != note.count - 1 {
        return false, name, .[];
    }


    args : [..]string;
    args.allocator = Temp;

    str := StringAdvance(note, open_paren + 1);
    i := 0;
    while i < str.count {
        next_comma := find_index_from_left(str, ",");
        if next_comma < 0 {
            next_comma = str.count - 1;
        }

        arg := str;
        arg.count = next_comma;
        arg = StringAdvance(arg, i);

        ArrayPush(*args, arg);

        i = next_comma + 1;
    }

    return true, name, args;
}

ParseNote :: (note : string, expect_name : string, $T : Type) -> bool, T {
    ParseArg :: ($T : Type, arg : string) -> ok : bool, value : T {
        #if T == {
        case bool;
            if arg == "true" {
                return true, true;
            }
            if arg == "false" {
                return true, false;
            }

            return false, false;

        case u8;
            value, ok, remainder := Basic.string_to_int(arg, T=T);
            ok &= remainder.count == 0;

            return ok, value;
        case s8;
            value, ok, remainder := Basic.string_to_int(arg, T=T);
            ok &= remainder.count == 0;

            return ok, value;
        case u16;
            value, ok, remainder := Basic.string_to_int(arg, T=T);
            ok &= remainder.count == 0;

            return ok, value;
        case s16;
            value, ok, remainder := Basic.string_to_int(arg, T=T);
            ok &= remainder.count == 0;

            return ok, value;
        case u32;
            value, ok, remainder := Basic.string_to_int(arg, T=T);
            ok &= remainder.count == 0;

            return ok, value;
        case s32;
            value, ok, remainder := Basic.string_to_int(arg, T=T);
            ok &= remainder.count == 0;

            return ok, value;
        case u64;
            value, ok, remainder := Basic.string_to_int(arg, T=T);
            ok &= remainder.count == 0;

            return ok, value;
        case s64;
            value, ok, remainder := Basic.string_to_int(arg, T=T);
            ok &= remainder.count == 0;

            return ok, value;

        case float32;
            value, ok, remainder := Basic.string_to_float(arg);
            ok &= remainder.count == 0;

            return ok, xx value;
        case float64;
            value, ok, remainder := Basic.string_to_float(arg);
            ok &= remainder.count == 0;

            return ok, xx value;

        case string;
            return true, arg;

        case;
            compiler_report(TPrint("Type % is not handled in ParseNote", T));
        }
    }

    dummy : T;
    ok, name, args := ParseNote(note);
    if !ok {
        return false, dummy;
    }

    if name != expect_name {
        return false, dummy;
    }

    #if T == void {
        return args.count == 0, dummy;
    } else {
        value : T;
        if args.count != 1 {
            return false, value;
        }

        ok, value = ParseArg(T, args[0]);

        return ok, value;
    }
}

GetNote :: (notes : []string, name : string, $T : Type = void) -> ok : bool, value : T {
    for notes {
        ok, value := ParseNote(it, name, T);
        if ok {
            return true, value;
        }
    }

    dummy : T;
    return false, dummy;
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

ProjectPointOnLine :: (point : Vec3f, line_origin : Vec3f, line_dir : Vec3f) -> Vec3f, t : float {
    t := Dot(point - line_origin, line_dir) / Dot(line_dir, line_dir);

    return line_origin + t * line_dir, t;
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

RayIntersectsMesh :: (ray_origin : Vec3f, ray_dir : Vec3f, ray_length : float, mesh : *Mesh, transform : Mat4f) -> intersects : bool, point : Vec3f, dist : float, normal : Vec3f, triangle_index : int {
    inv_transform := Inverse(transform);
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
