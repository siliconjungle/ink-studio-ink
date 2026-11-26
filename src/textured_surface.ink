module StudioTexturedSurface;

import "rig.ink" as math;
import "rail.ink" as rail;
import "texture_address.ink" as texture;

record GridSize { columns: u32, rows: u32, }
record Triangle { a: u32, b: u32, c: u32, }
record Surface {
    divisions: GridSize, positions: List<Vec3<f32>>, uvs: List<Vec2<f32>>, triangles: List<Triangle>, flip: Bool,
}
record Bounds { x0: f64, x1: f64, z0: f64, z1: f64, }
record Heightfield { bounds: Bounds, surface: Surface, }
record Attachment { position: math.Point, normal: math.Point, }
record MaterialSample { attachment: Attachment, color: texture.Rgba, }
record Sampling { filter: String, horizontal: String, vertical: String, }
record ProfilePoint { x: f64, y: f64, }
record SweepFrame { position: math.Point, tangent: math.Point, right: Option<math.Point>, up: Option<math.Point>, }
record SweepAxes { position: math.Point, right: math.Point, up: math.Point, }
record Cell { a: u32, b: u32, c: u32, d: u32, s: f64, t: f64, }

fn grid_fits(size: GridSize, max_triangles: u32) -> Bool {
    return size.columns > 0 && size.rows > 0 && max_triangles >= 2 && max_triangles <= 2000000
        && size.columns <= quot_or(quot_or(max_triangles, 2, 0), size.rows, 0);
}

fn vertex_count(size: GridSize) -> u32 { return (size.columns + 1) * (size.rows + 1); }

fn u_at(size: GridSize, i: u32) -> f64 {
    return f64_from_u32(rem_or(i, size.columns + 1, 0)) / f64_from_u32(size.columns);
}

fn v_at(size: GridSize, i: u32) -> f64 {
    return f64_from_u32(quot_or(i, size.columns + 1, 0)) / f64_from_u32(size.rows);
}

fn triangle(a: u32, b: u32, c: u32, flip: Bool) -> Triangle {
    return if flip { Triangle { a: a, b: c, c: b } } else { Triangle { a: a, b: b, c: c } };
}

fn add_cell(size: GridSize, faces: Buffer<Triangle>, i: u32, flip: Bool) -> Buffer<Triangle> {
    let stride = size.columns + 1;
    let a = quot_or(i, size.columns, 0) * stride + rem_or(i, size.columns, 0);
    let b = a + 1;
    let c = a + stride;
    return faces.push(triangle(a, b, c, flip)).push(triangle(c, b, c + 1, flip));
}

fn finite(p: math.Point) -> Bool { return is_finite(p.x) && is_finite(p.y) && is_finite(p.z); }

fn unit_axis(axis: math.Point) -> math.Point {
    if !finite(axis) { return math.zero(); }
    let scale = math.max(math.max(math.max(axis.x, -axis.x), math.max(axis.y, -axis.y)), math.max(axis.z, -axis.z));
    if scale == 0.0f64 { return math.zero(); }
    let direction = math.point(axis.x / scale, axis.y / scale, axis.z / scale);
    let length = math.magnitude(direction);
    return if scale < 1e-10f64 / length { math.zero() } else { math.scale(direction, 1.0f64 / length) };
}

fn unpack(p: Vec3<f32>) -> math.Point {
    return math.point(f64_from_f32(p.x), f64_from_f32(p.y), f64_from_f32(p.z));
}

pub fn textured_grid(size: GridSize, max_triangles: u32, points: List<math.Point>, flip: Bool) -> Result<Surface, String> {
    if !grid_fits(size, max_triangles) { return Err("Surface grid exceeds the triangle budget"); }
    if length(points) != vertex_count(size) { return Err("Surface grid needs one point per vertex"); }
    let positions = points.map(fn(p) => math.to_vec3(p));
    if length(positions.filter(fn(p) => !finite(unpack(p)))) > 0 { return Err("Surface points exceed finite float storage"); }
    let uv = positions.map_indexed(fn(i) => fn(p) => vec2(f32_from_f64(u_at(size, i)), f32_from_f64(v_at(size, i))));
    let initial: Buffer<Triangle> = Buffer.empty();
    let faces = repeat_until(size.columns * size.rows, initial, fn(rows) => false,
        fn(i) => fn(rows) => add_cell(size, rows, i, flip));
    return Ok(Surface { divisions: size, positions: positions, uvs: uv, triangles: faces.freeze(), flip: flip });
}

fn cell(size: GridSize, u: f64, v: f64) -> Cell {
    let x = u * f64_from_u32(size.columns);
    let y = v * f64_from_u32(size.rows);
    let i = u32_from_f64(math.min(f64_from_u32(size.columns - 1), floor(x))).fold(fn(index) => index, fn(unit) => 0);
    let j = u32_from_f64(math.min(f64_from_u32(size.rows - 1), floor(y))).fold(fn(index) => index, fn(unit) => 0);
    let a = j * (size.columns + 1) + i;
    let c = a + size.columns + 1;
    return Cell { a: a, b: a + 1, c: c, d: c + 1, s: x - f64_from_u32(i), t: y - f64_from_u32(j) };
}

fn at(surface: Surface, i: u32) -> math.Point { return unpack(surface.positions.at_or(i, vec3(0.0, 0.0, 0.0))); }

fn mix_triangle(a: math.Point, b: math.Point, c: math.Point, weights: math.Point, flip: Bool) -> Attachment {
    let bp = math.sub(b, a);
    let cp = math.sub(c, a);
    let point = math.add(math.add(math.scale(a, weights.x), math.scale(b, weights.y)), math.scale(c, weights.z));
    let cross = math.cross(bp, cp);
    let length = math.magnitude(cross);
    let normal = if length > 1e-10f64 { math.scale(cross, (if flip { -1.0f64 } else { 1.0f64 }) / length) } else { math.zero() };
    return Attachment { position: point, normal: normal };
}

pub fn surface_at(surface: Surface, u: f64, v: f64) -> Result<Attachment, String> {
    let size = surface.divisions;
    if !grid_fits(size, 2000000) || length(surface.positions) != vertex_count(size)
        || !is_finite(u) || !is_finite(v) || u < 0.0f64 || u > 1.0f64 || v < 0.0f64 || v > 1.0f64 {
        return Err("Surface coordinates must be on a valid grid in [0,1]");
    }
    let address = cell(size, u, v);
    let s = address.s;
    let t = address.t;
    let attachment = if s + t <= 1.0f64 {
        mix_triangle(at(surface, address.a), at(surface, address.b), at(surface, address.c), math.point(1.0f64 - s - t, s, t), surface.flip)
    } else {
        mix_triangle(at(surface, address.d), at(surface, address.c), at(surface, address.b), math.point(s + t - 1.0f64, 1.0f64 - s, 1.0f64 - t), surface.flip)
    };
    return Ok(attachment);
}

pub fn surface_material_at(surface: Surface, image: texture.Raster, sampling: Sampling,
    u: f64, v: f64) -> Result<MaterialSample, String> {
    return texture.texture_settings(sampling.filter, sampling.horizontal, sampling.vertical).fold(fn(settings) =>
        painted_attachment(surface_at(surface, u, v), image, settings, u, v),
        fn(error) => Err(error));
}

fn painted_attachment(attachment: Result<Attachment, String>, image: texture.Raster, settings: texture.Settings,
    u: f64, v: f64) -> Result<MaterialSample, String> {
    return attachment.fold(fn(hit) => texture.sample_texture(image, settings, u, v).fold(
        fn(color) => Ok(MaterialSample { attachment: hit, color: color }), fn(error) => Err(error)), fn(error) => Err(error));
}

fn valid_bounds(box: Bounds) -> Bool {
    return is_finite(box.x0) && is_finite(box.x1) && is_finite(box.z0) && is_finite(box.z1) && box.x0 < box.x1 && box.z0 < box.z1;
}

pub fn textured_heightfield(box: Bounds, size: GridSize, max_triangles: u32, heights: List<f64>) -> Result<Heightfield, String> {
    if !valid_bounds(box) { return Err("Heightfield needs increasing finite XZ bounds"); }
    if !grid_fits(size, max_triangles) { return Err("Heightfield exceeds the triangle budget"); }
    if length(heights) != vertex_count(size) { return Err("Heightfield sample count does not match the grid"); }
    let points = heights.map_indexed(fn(i) => fn(y) => math.point(math.mix(box.x0, box.x1, u_at(size, i)), y, math.mix(box.z1, box.z0, v_at(size, i))));
    return textured_grid(size, max_triangles, points, false).fold(fn(surface) => Ok(Heightfield { bounds: box, surface: surface }), fn(error) => Err(error));
}

pub fn surface_height(field: Heightfield, x: f64, z: f64) -> Result<f64, String> {
    let b = field.bounds;
    if !valid_bounds(b) || !is_finite(x) || !is_finite(z) { return Err("Height query needs finite bounds and coordinates"); }
    let u = math.sat((x - b.x0) / (b.x1 - b.x0));
    let v = math.sat((b.z1 - z) / (b.z1 - b.z0));
    return surface_at(field.surface, u, v).fold(fn(sample) => Ok(sample.position.y), fn(error) => Err(error));
}

fn sweep_axes(frame: SweepFrame, world_up: math.Point) -> Option<SweepAxes> {
    let tangent = unit_axis(frame.tangent);
    let side = unit_axis(frame.right.fold(fn(v) => v, fn(unit) => math.cross(world_up, tangent)));
    let up = unit_axis(frame.up.fold(fn(v) => v, fn(unit) => math.cross(tangent, side)));
    if !finite(frame.position) || tangent == math.zero() || side == math.zero() || up == math.zero() {
        return None;
    }
    return Some(SweepAxes { position: frame.position, right: side, up: up });
}

fn sweep_point(frame: SweepAxes, profile: ProfilePoint) -> math.Point {
    return math.add(frame.position, math.add(math.scale(frame.right, profile.x), math.scale(frame.up, profile.y)));
}

fn append_sweep(points: Buffer<math.Point>, profile: List<ProfilePoint>, axes: SweepAxes) -> Buffer<math.Point> {
    return foldl(profile, points, fn(cross) => fn(out) => out.push(sweep_point(axes, cross)));
}

fn collect_axes(axes: Option<SweepAxes>, out: Buffer<SweepAxes>) -> Buffer<SweepAxes> {
    return axes.fold(fn(row) => out.push(row), fn(unit) => out);
}

pub fn textured_sweep(profile: List<ProfilePoint>, frames: List<SweepFrame>, world_up: math.Point,
    closed: Bool, max_triangles: u32) -> Result<Surface, String> {
    if length(profile) < 2 || length(frames) < 2 || !finite(world_up) || math.magnitude(world_up) < 1e-10f64 {
        return Err("Sweep needs a profile, frames, and a nonzero up axis");
    }
    let size = GridSize { columns: length(profile) - 1, rows: length(frames) - 1 };
    if !grid_fits(size, max_triangles) { return Err("Sweep exceeds the triangle budget"); }
    let initial: Buffer<SweepAxes> = Buffer.empty();
    let first = frames.at_or(0, SweepFrame { position: math.zero(), tangent: math.zero(), right: None, up: None });
    let prepared = repeat_until(length(frames), initial, fn(rows) => false, fn(i) => fn(rows) =>
        collect_axes(sweep_axes(if closed && i == size.rows { first } else { frames.at_or(i, first) }, world_up), rows)).freeze();
    if length(prepared) != length(frames) { return Err("Sweep frame needs finite nonzero axes"); }
    let empty: Buffer<math.Point> = Buffer.empty();
    let points = foldl(prepared, empty, fn(frame) => fn(rows) => append_sweep(rows, profile, frame));
    return textured_grid(size, max_triangles, points.freeze(), true);
}

pub fn rail_surface(path: rail.Path, profile: List<ProfilePoint>, rows: u32, world_up: math.Point,
    closed: Bool, max_triangles: u32) -> Result<Surface, String> {
    if length(profile) < 2 || path.length <= 0.0f64 || !is_finite(path.length)
        || !grid_fits(GridSize { columns: length(profile) - 1, rows: rows }, max_triangles) {
        return Err("Rail sweep needs finite arc length and fits within the triangle budget");
    }
    let empty: Buffer<SweepFrame> = Buffer.empty();
    let frames = repeat_until(rows + 1, empty, fn(out) => false, fn(i) => fn(out) =>
        rail.rail_at(path, path.length * f64_from_u32(i) / f64_from_u32(rows)).fold(
            fn(at) => out.push(SweepFrame { position: at.position, tangent: at.direction, right: None, up: None }),
            fn(unit) => out));
    return textured_sweep(profile, frames.freeze(), world_up, closed, max_triangles);
}
