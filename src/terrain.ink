module StudioTerrain;

record HeightGrid {
    x0: f64,
    z0: f64,
    step: f64,
    width: u32,
    depth: u32,
    values: List<f32>,
}

record Rect { x0: f64, z0: f64, x1: f64, z1: f64, }
record XZ { x: f64, z: f64, }
record Surface { x: f64, y: f64, z: f64, }

fn index(x: f64) -> u32 { return u32_from_f64(x).fold(fn(value) => value, fn(unit) => 0); }

fn bounded(x: f64, high: f64) -> f64 {
    if x < 0.0f64 { return 0.0f64; }
    return if x > high { high } else { x };
}
fn at(grid: HeightGrid, x: u32, z: u32) -> f64 {
    return f64_from_f32(grid.values.at_or(z * grid.width + x, 0.0));
}

pub fn surface_height(grid: HeightGrid, x: f64, z: f64) -> f64 {
    if grid.width < 2 || grid.depth < 2 || !(grid.step > 0.0f64) { return 0.0f64; }
    let u = bounded((x - grid.x0) / grid.step, f64_from_u32(grid.width) - 1.001f64);
    let v = bounded((z - grid.z0) / grid.step, f64_from_u32(grid.depth) - 1.001f64);
    let i = index(u);
    let j = index(v);
    let fu = u - f64_from_u32(i);
    let fv = v - f64_from_u32(j);
    let low = at(grid, i, j) * (1.0f64 - fu) + at(grid, i + 1, j) * fu;
    let high = at(grid, i, j + 1) * (1.0f64 - fu) + at(grid, i + 1, j + 1) * fu;
    return low * (1.0f64 - fv) + high * fv;
}

fn distance_from_height(y: f64, ground: f64) -> f64 { return (y - ground) * 0.7f64; }

pub fn terrain_sdf(grid: HeightGrid, x: f64, y: f64, z: f64) -> f64 {
    return distance_from_height(y, surface_height(grid, x, z));
}

pub fn contact_height(grid: HeightGrid, x: f64, z: f64, distance: f64) -> f64 {
    return surface_height(grid, x, z) + distance / 0.7f64;
}

fn lattice_row(points: Buffer<XZ>, bounds: Rect, spacing: f64, row: f64) -> Buffer<XZ> {
    let offset = (row - floor(row / 2.0f64) * 2.0f64) * spacing * 0.5f64;
    let first = ceil((bounds.x0 - offset) / spacing);
    let count = index(ceil((bounds.x1 - offset) / spacing) - first) + 1;
    let z = row * (spacing * 0.87f64);
    return repeat_until(count, points, fn(result) => false, fn(i) => fn(result) =>
        append_candidate(result, (first + f64_from_u32(i)) * spacing + offset, z, bounds.x1));
}

fn append_candidate(points: Buffer<XZ>, x: f64, z: f64, limit: f64) -> Buffer<XZ> {
    return if x < limit { points.push(XZ { x: x, z: z }) } else { points };
}

// Adjacent rectangles use the same world-space indices, including negative rows.
pub fn terrain_lattice(bounds: Rect, spacing: f64) -> List<XZ> {
    if !(spacing > 0.0f64 && bounds.x0 < bounds.x1 && bounds.z0 < bounds.z1) { return []; }
    let stride = spacing * 0.87f64;
    let start = ceil(bounds.z0 / stride);
    let rows = index(ceil(bounds.z1 / stride) - start) + 1;
    let out: Buffer<XZ> = Buffer.empty();
    return repeat_until(rows, out, fn(samples) => false, fn(i) => fn(samples) =>
        append_row(samples, bounds, spacing, start + f64_from_u32(i))).freeze();
}

fn append_row(points: Buffer<XZ>, bounds: Rect, spacing: f64, row: f64) -> Buffer<XZ> {
    return if row * (spacing * 0.87f64) < bounds.z1 { lattice_row(points, bounds, spacing, row) } else { points };
}

pub fn sample_terrain(grid: HeightGrid, bounds: Rect, spacing: f64) -> List<Surface> {
    return terrain_lattice(bounds, spacing).map(fn(p) =>
        Surface { x: p.x, y: surface_height(grid, p.x, p.z), z: p.z });
}
