module StudioTextureAddress;

import "rig.ink" as math;

enum Edge { Clamp, Transparent, Wrap, Mirror, }
enum Filter { Nearest, Linear, }

record Settings { filter: Filter, horizontal: Edge, vertical: Edge, }
record Raster { width: u32, height: u32, pixels: List<Vec4<f32>>, }
record Rgba { red: f64, green: f64, blue: f64, alpha: f64, }
record Samples { rows: Buffer<Vec4<f32>>, valid: Bool, }

fn edge(name: String) -> Option<Edge> {
    if name == "clamp" { return Some(Edge.Clamp); }
    if name == "transparent" { return Some(Edge.Transparent); }
    if name == "wrap" { return Some(Edge.Wrap); }
    if name == "mirror" { return Some(Edge.Mirror); }
    return None;
}

fn filter(name: String) -> Option<Filter> {
    if name == "nearest" { return Some(Filter.Nearest); }
    if name == "linear" { return Some(Filter.Linear); }
    return None;
}

pub fn texture_settings(mode: String, edge_u: String, edge_v: String) -> Result<Settings, String> {
    let error: Result<Settings, String> = Err("Texture addressing needs a valid filter and edge policies");
    return filter(mode).fold(fn(kind) => edge(edge_u).fold(fn(u) => edge(edge_v).fold(fn(v) =>
        Ok(Settings { filter: kind, horizontal: u, vertical: v }), fn(unit) => error), fn(unit) => error), fn(unit) => error);
}

fn wrap(coordinate: f64, span: f64) -> f64 { return coordinate - floor(coordinate / span) * span; }

fn address(coordinate: f64, limit: u32, mode: Edge) -> Option<u32> {
    let span = f64_from_u32(limit);
    if mode == Edge.Transparent && (coordinate < 0.0f64 || coordinate >= span) { return None; }
    let index = match mode {
        Edge.Clamp => math.max(0.0f64, math.min(span - 1.0f64, coordinate)),
        Edge.Transparent => coordinate,
        Edge.Wrap => wrap(coordinate, span),
        Edge.Mirror => mirror(coordinate, span),
    };
    return u32_from_f64(index);
}

fn mirror(coordinate: f64, span: f64) -> f64 {
    let p = wrap(coordinate, 2.0f64 * span);
    return if p < span { p } else { 2.0f64 * span - 1.0f64 - p };
}

fn dimensions(w: u32, h: u32, limit: u32) -> Bool {
    return w > 0 && h > 0 && w <= quot_or(limit, h, 0);
}

fn coordinate(v: f64) -> Bool { return is_finite(v) && v >= -16384.0f64 && v <= 16384.0f64; }

fn transparent() -> Rgba { return Rgba { red: 0.0f64, green: 0.0f64, blue: 0.0f64, alpha: 0.0f64 }; }

fn pack_row(raw: List<f64>, channels: u32, i: u32, old: Samples) -> Samples {
    let j = i * channels;
    let u = raw.at_or(j, 0.0f64);
    let v = raw.at_or(j + 1, 0.0f64);
    let coverage = if channels == 3 { raw.at_or(j + 2, 0.0f64) } else { 1.0f64 };
    if !coordinate(u) || !coordinate(v) || !is_finite(coverage) || coverage < 0.0f64 || coverage > 1.0f64 {
        return Samples { ..old, valid: false };
    }
    return Samples { valid: true, rows: old.rows.push(vec4(f32_from_f64(u), f32_from_f64(v), f32_from_f64(coverage), 0.0)) };
}

pub fn pack_texture_addresses(width: u32, height: u32, channels: u32, raw: List<f64>) -> Result<List<Vec4<f32>>, String> {
    if !dimensions(width, height, 1048576) || (channels != 2 && channels != 3) || length(raw) != width * height * channels {
        return Err("Texture address field needs 2 or 3 aligned channels within its pixel budget");
    }
    let initial = Samples { rows: Buffer.empty(), valid: true };
    let packed = repeat_until(width * height, initial, fn(old) => !old.valid, fn(i) => fn(old) => pack_row(raw, channels, i, old));
    return if packed.valid { Ok(packed.rows.freeze()) } else { Err("Invalid texture coordinate or coverage") };
}

fn blend(color: Rgba, ink: Vec4<f32>, weight: f64) -> Rgba {
    return Rgba { red: color.red + f64_from_f32(ink.x) * weight, green: color.green + f64_from_f32(ink.y) * weight,
        blue: color.blue + f64_from_f32(ink.z) * weight, alpha: color.alpha + f64_from_f32(ink.w) * weight };
}

fn include(data: Raster, settings: Settings, x: f64, y: f64, weight: f64, color: Rgba) -> Rgba {
    if weight == 0.0f64 { return color; }
    let u = address(x, data.width, settings.horizontal);
    let v = address(y, data.height, settings.vertical);
    return u.fold(fn(col) => v.fold(fn(row) =>
        blend(color, data.pixels.at_or(row * data.width + col, vec4(0.0, 0.0, 0.0, 0.0)), weight),
        fn(unit) => color), fn(unit) => color);
}

fn f32_value(value: f64) -> f64 { return f64_from_f32(f32_from_f64(value)); }

fn read(data: Raster, settings: Settings, u: f64, v: f64) -> Rgba {
    let px = f32_value(u * f64_from_u32(data.width));
    let py = f32_value(v * f64_from_u32(data.height));
    if settings.filter == Filter.Nearest { return include(data, settings, floor(px), floor(py), 1.0f64, transparent()); }
    let x = f32_value(px - 0.5f64);
    let y = f32_value(py - 0.5f64);
    let i = floor(x);
    let j = floor(y);
    let a = x - i;
    let b = y - j;
    let top_left = include(data, settings, i, j, (1.0f64 - a) * (1.0f64 - b), transparent());
    let top = include(data, settings, i + 1.0f64, j, a * (1.0f64 - b), top_left);
    let bottom_left = include(data, settings, i, j + 1.0f64, (1.0f64 - a) * b, top);
    return include(data, settings, i + 1.0f64, j + 1.0f64, a * b, bottom_left);
}

pub fn sample_texture(data: Raster, settings: Settings, u: f64, v: f64) -> Result<Rgba, String> {
    if !dimensions(data.width, data.height, 4294967295) || length(data.pixels) != data.width * data.height {
        return Err("Texture needs one RGBA texel per pixel");
    }
    if !coordinate(u) || !coordinate(v) { return Err("Invalid texture address coordinate"); }
    return Ok(read(data, settings, u, v));
}
