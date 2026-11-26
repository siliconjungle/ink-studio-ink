module StudioMarks;

import "rig.ink" as math;
import "gaussian.ink" as gaussian;

record Covariance {
    first: math.Point,
    rest: math.Point,
}

record AxialMark {
    normal: math.Point,
    covariance: Covariance,
}

fn covariance(xx: f64, xy: f64, xz: f64, yy: f64, yz: f64, zz: f64) -> Covariance {
    return Covariance { first: math.point(xx, xy, xz), rest: math.point(yy, yz, zz) };
}

pub fn round_mark(radius: f64) -> Covariance {
    let variance = radius * radius;
    return covariance(variance, 0.0f64, 0.0f64, variance, 0.0f64, variance);
}

fn magnitude_axis(axis: math.Point) -> f64 {
    return math.max(math.max(math.max(axis.x, -axis.x), math.max(axis.y, -axis.y)), math.max(axis.z, -axis.z));
}

fn mark_normal(axis: math.Point) -> math.Point {
    let norm_error = math.dot(axis, axis) - 1.0f64;
    if math.max(norm_error, -norm_error) <= 8.881784197001252e-16f64 { return axis; }
    let scale = magnitude_axis(axis);
    let unit = math.point(axis.x / scale, axis.y / scale, axis.z / scale);
    return math.scale(unit, 1.0f64 / math.magnitude(unit));
}

pub fn axial_mark(axis: math.Point, along: f64, across: f64) -> Result<AxialMark, String> {
    if !is_finite(axis.x) || !is_finite(axis.y) || !is_finite(axis.z) || magnitude_axis(axis) == 0.0f64 {
        return Err("Splat axis must be finite and nonzero");
    }
    let n = mark_normal(axis);
    let p = across * across;
    let d = along * along - p;
    let shape = covariance(p + d * n.x * n.x, d * n.x * n.y, d * n.x * n.z,
        p + d * n.y * n.y, d * n.y * n.z, p + d * n.z * n.z);
    return Ok(AxialMark { normal: n, covariance: shape });
}

fn term(square: math.Point, a: math.Point, b: math.Point) -> f64 {
    return square.x * a.x * b.x + square.y * a.y * b.y + square.z * a.z * b.z;
}

pub fn surface_mark(normal: math.Point, tangent: math.Point, along: f64, across: f64, thickness: f64) -> Covariance {
    let across_axis = math.cross(normal, tangent);
    let xx = math.point(tangent.x, across_axis.x, normal.x);
    let yy = math.point(tangent.y, across_axis.y, normal.y);
    let zz = math.point(tangent.z, across_axis.z, normal.z);
    let square = math.point(along * along, across * across, thickness * thickness);
    return covariance(term(square, xx, xx), term(square, xx, yy), term(square, xx, zz),
        term(square, yy, yy), term(square, yy, zz), term(square, zz, zz));
}

pub fn reflect_splat(row: gaussian.WorldGaussian, level: f64, drift: f64, color: u32, alpha: f32) -> gaussian.WorldGaussian {
    let dy = f64_from_f32(row.position.y) - level;
    return gaussian.WorldGaussian {
        position: vec3(f32_from_f64(f64_from_f32(row.position.x) + drift), f32_from_f64(level - dy), row.position.z),
        covariance0: vec3(row.covariance0.x, -row.covariance0.y, row.covariance0.z),
        covariance1: vec3(row.covariance1.x, -row.covariance1.y, row.covariance1.z),
        reach: row.reach, rgb: color, alpha: alpha,
    };
}
