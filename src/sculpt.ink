module StudioSculpt;

import "rig.ink" as math;
import "noise.ink" as noise;
import "terrain.ink" as terrain;

record Box { half: math.Point, rounding: f64, }
record Lathe { height: f64, base: f64, slope: f64, }
record PowerLathe { height: f64, base: f64, slope: f64, exponent: f64, }
record Torus { major: f64, minor: f64, }

record Segment {
    start: math.Point,
    delta: math.Point,
    length_squared: f64,
    base: f64,
    tip: f64,
}

enum Form { Boxed(Box), Ellipsoid(math.Point), Turned(Lathe), Tube(List<Segment>), Ring(Torus), TurnedFromTip(Lathe), TurnedPower(PowerLathe), }

record Model {
    center: math.Point,
    frame: Option<math.Matrix>,
    bound: f64,
    form: Form,
}

pub fn boxed(center: math.Point, frame: Option<math.Matrix>, bound: f64, half: math.Point, rounding: f64) -> Model {
    return Model { center: center, frame: frame, bound: bound, form: Form.Boxed(Box { half: half, rounding: rounding }) };
}

pub fn ellipsoid(center: math.Point, frame: Option<math.Matrix>, bound: f64, radii: math.Point) -> Model {
    return Model { center: center, frame: frame, bound: bound, form: Form.Ellipsoid(radii) };
}

pub fn turned(center: math.Point, frame: Option<math.Matrix>, bound: f64, height: f64, base: f64, slope: f64) -> Model {
    return Model { center: center, frame: frame, bound: bound,
        form: Form.Turned(Lathe { height: height, base: base, slope: slope }) };
}

pub fn turned_from_tip(center: math.Point, frame: Option<math.Matrix>, bound: f64, height: f64, tip: f64, slope: f64) -> Model {
    return Model { center: center, frame: frame, bound: bound,
        form: Form.TurnedFromTip(Lathe { height: height, base: tip, slope: slope }) };
}

// The exponent is positive. Base and tip give the radii at the two caps.
pub fn turned_power(center: math.Point, frame: Option<math.Matrix>, height: f64, base: f64, tip: f64, exponent: f64) -> Model {
    let half = height * 0.5f64;
    let radius = math.max(base, tip);
    return Model { center: center, frame: frame, bound: sqrt(radius * radius + half * half),
        form: Form.TurnedPower(PowerLathe { height: height, base: base, slope: tip - base, exponent: exponent }) };
}

pub fn tube(center: math.Point, bound: f64, segments: List<Segment>) -> Model {
    return Model { center: center, frame: None, bound: bound, form: Form.Tube(segments) };
}

pub fn ring(center: math.Point, frame: Option<math.Matrix>, bound: f64, major: f64, minor: f64) -> Model {
    return Model { center: center, frame: frame, bound: bound, form: Form.Ring(Torus { major: major, minor: minor }) };
}

record Member {
    model: u32,
    group: u32,
    blend: f64,
    bump: f64,
    frequency: f64,
}

record SceneSpec {
    positive: List<Member>,
    negative: List<Member>,
}

fn abs(value: f64) -> f64 { return math.max(value, -value); }

fn box_distance(box: Box, p: math.Point) -> f64 {
    let x = abs(p.x) - box.half.x + box.rounding;
    let y = abs(p.y) - box.half.y + box.rounding;
    let z = abs(p.z) - box.half.z + box.rounding;
    let outside = math.magnitude(math.point(math.max(x, 0.0f64), math.max(y, 0.0f64), math.max(z, 0.0f64)));
    return outside + math.min(math.max(math.max(x, y), z), 0.0f64) - box.rounding;
}

fn ellipsoid_distance(r: math.Point, p: math.Point) -> f64 {
    if r.x == r.y && r.y == r.z { return math.magnitude(p) - r.x; }
    let k0 = math.magnitude(math.point(p.x / r.x, p.y / r.y, p.z / r.z));
    let k1 = math.magnitude(math.point(p.x / (r.x * r.x), p.y / (r.y * r.y), p.z / (r.z * r.z)));
    return if k1 > 1e-9f64 { k0 * (k0 - 1.0f64) / k1 } else { -math.min(math.min(r.x, r.y), r.z) };
}

fn lathe_radius(profile: Lathe, t: f64, from_tip: Bool) -> f64 {
    return profile.base + profile.slope * (if from_tip { 1.0f64 - t } else { t });
}

fn power_bits(exponent: f64) -> f64 {
    let word = u64_from_f64(exponent + 1023.0f64).fold(fn(bits) => bits, fn(unit) => 0);
    return f64_from_bits(wrapping_shl(word, 52));
}

fn unit_power(t: f64, exponent: f64) -> f64 {
    if t <= 0.0f64 || t >= 1.0f64 { return t; }
    let scaled = if t < 2.2250738585072014e-308f64 { t * 4503599627370496.0f64 } else { t };
    let bits = f64_bits(scaled);
    let e = f64_from_u64(wrapping_shr(bits, 52)) - (if scaled == t { 1023.0f64 } else { 1075.0f64 });
    let mantissa = f64_from_bits((bits & 4503599627370495) | 4607182418800017408);
    // Reduce the logarithm to a series with |z| <= tanh(log(2)/4).
    let halve = mantissa > 1.4142135623730951f64;
    let m = if halve { mantissa * 0.5f64 } else { mantissa };
    let k = if halve { e + 1.0f64 } else { e };
    let z = (m - 1.0f64) / (m + 1.0f64);
    let z2 = z * z;
    let tail = repeat(10, 0.0f64, fn(i) => fn(sum) => 1.0f64 / f64_from_u32(21 - 2 * i) + z2 * sum);
    let ln2 = 0.6931471805599453f64;
    let log = 2.0f64 * z * (1.0f64 + z2 * tail) + k * ln2;
    let y = exponent * log;
    if y < -745.1332191019412f64 { return 0.0f64; }
    let shift = floor(y / ln2 + 0.5f64);
    let reduced = (y - shift * 0.6931471803691238f64) - shift * 1.9082149292705877e-10f64;
    let series = repeat(14, 1.0f64, fn(i) => fn(sum) => 1.0f64 + reduced * sum / f64_from_u32(14 - i));
    let normal_shift = math.max(-1022.0f64, shift);
    return power_bits(normal_shift) * (series * power_bits(shift - normal_shift));
}

fn power_radius(profile: PowerLathe, t: f64) -> f64 {
    return profile.base + profile.slope * unit_power(t, profile.exponent);
}

fn lathe_distance(height: f64, radius: f64, p: math.Point) -> f64 {
    let dr = (sqrt(p.x * p.x + p.z * p.z) - radius) * 0.8f64;
    let dy = abs(p.y) - height * 0.5f64;
    let outside_r = math.max(dr, 0.0f64);
    let outside_y = math.max(dy, 0.0f64);
    return math.min(math.max(dr, dy), 0.0f64) + sqrt(outside_r * outside_r + outside_y * outside_y);
}

fn turned_distance(profile: Lathe, p: math.Point, from_tip: Bool) -> f64 {
    let radius = lathe_radius(profile, math.sat(p.y / profile.height + 0.5f64), from_tip);
    return lathe_distance(profile.height, radius, p);
}

fn power_distance(profile: PowerLathe, p: math.Point) -> f64 {
    let radius = power_radius(profile, math.sat(p.y / profile.height + 0.5f64));
    return lathe_distance(profile.height, radius, p);
}

fn tube_distance(segments: List<Segment>, p: math.Point) -> f64 {
    return foldl(segments, 1e9f64, fn(segment) => fn(best) => math.min(best, segment_distance(segment, p)));
}

fn segment_distance(segment: Segment, p: math.Point) -> f64 {
    let dx = p.x - segment.start.x;
    let dy = p.y - segment.start.y;
    let dz = p.z - segment.start.z;
    let axis = segment.delta;
    let t = math.sat((dx * axis.x + dy * axis.y + dz * axis.z) / segment.length_squared);
    let x = dx - t * axis.x;
    let y = dy - t * axis.y;
    let z = dz - t * axis.z;
    return sqrt(x * x + y * y + z * z) - math.mix(segment.base, segment.tip, t);
}

fn torus_distance(ring: Torus, p: math.Point) -> f64 {
    let q = sqrt(p.x * p.x + p.z * p.z) - ring.major;
    return sqrt(q * q + p.y * p.y) - ring.minor;
}

fn local_point(model: Model, p: math.Point) -> math.Point {
    let offset = math.sub(p, model.center);
    return model.frame.fold(fn(frame) => math.apply(frame, offset), fn(unit) => offset);
}

pub fn solid_distance(model: Model, p: math.Point) -> f64 {
    return match model.form {
        Form.Boxed(box) => box_distance(box, local_point(model, p)),
        Form.Ellipsoid(radii) => ellipsoid_distance(radii, local_point(model, p)),
        Form.Turned(profile) => turned_distance(profile, local_point(model, p), false),
        Form.TurnedFromTip(profile) => turned_distance(profile, local_point(model, p), true),
        Form.TurnedPower(profile) => power_distance(profile, local_point(model, p)),
        Form.Tube(segments) => tube_distance(segments, p),
        Form.Ring(ring) => torus_distance(ring, local_point(model, p)),
    };
}

fn bumped_distance(model: Model, member: Member, tables: noise.Noise, p: math.Point) -> f64 {
    let distance = solid_distance(model, p);
    if member.bump <= 0.0f64 { return distance; }
    if distance > member.bump + 0.25f64 { return distance - member.bump; }
    let n = member.frequency;
    let texture = noise.noise3(tables, p.x * n + f64_from_u32(member.group) * 3.7f64, p.y * n, p.z * n);
    return distance - member.bump * (texture * 1.5f64 - 0.75f64);
}

record Placed { geometry: Model, member: Member, id: u32, }
record Bounds { low: math.Point, high: math.Point, }
record Index { x: u32, y: u32, z: u32, }
record Grid {
    origin: math.Point,
    stride: f64,
    size: Index,
}
record Candidate {
    shape: Placed,
    low: Index,
    high: Index,
}
record Scene {
    positive: List<Candidate>,
    negative: List<Placed>,
    grid: Grid,
    buckets: List<List<Placed>>,
}
record Column {
    positive: List<Candidate>,
    negative: List<Placed>,
    grid: Grid,
}

fn no_model() -> Model {
    return Model { center: math.zero(), frame: None, bound: 0.0f64, form: Form.Tube([]) };
}
fn empty_placed() -> Placed {
    return Placed { geometry: no_model(), id: 0, member: Member { model: 0, group: 0, blend: 0.0f64, bump: 0.0f64, frequency: 0.0f64 } };
}

fn placed(models: List<Model>, member: Member, id: u32) -> Placed {
    return Placed { geometry: models.at_or(member.model, no_model()), member: member, id: id };
}

fn min_point(a: math.Point, b: math.Point) -> math.Point {
    return math.point(math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z));
}
fn max_point(a: math.Point, b: math.Point) -> math.Point {
    return math.point(math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z));
}

fn padded(placed: Placed) -> math.Point {
    let radius = placed.geometry.bound + placed.member.blend + 1.0f64;
    return math.point(radius, radius, radius);
}

fn union_bounds(row: Placed, current: Bounds) -> Bounds {
    let r = padded(row);
    return Bounds { low: min_point(math.sub(row.geometry.center, r), current.low),
        high: max_point(math.add(row.geometry.center, r), current.high) };
}

fn enclosing(rows: List<Placed>) -> Bounds {
    if length(rows) == 0 {
        return Bounds { low: math.zero(), high: math.point(1.0f64, 1.0f64, 1.0f64) };
    }
    let first = rows.at_or(0, empty_placed());
    return foldl(rows, Bounds { low: first.geometry.center, high: first.geometry.center },
        fn(row) => fn(bounds) => union_bounds(row, bounds));
}

fn index(x: f64) -> u32 { return u32_from_f64(x).fold(fn(value) => value, fn(unit) => 0); }

fn cube_root(value: f64) -> f64 {
    let initial = math.max(0.9f64, sqrt(value));
    return repeat(16, initial, fn(step) => fn(guess) =>
        (2.0f64 * guess + value / (guess * guess)) / 3.0f64);
}

fn dimension(extent: f64, step: f64) -> u32 {
    return index(math.max(1.0f64, ceil(extent / step)));
}

fn grid_geometry(bounds: Bounds) -> Grid {
    let extent = math.sub(bounds.high, bounds.low);
    let volume = extent.x * extent.y * extent.z / 50000.0f64;
    let step = if volume > 0.729f64 { math.max(0.9f64, cube_root(volume)) } else { 0.9f64 };
    let size = Index { x: dimension(extent.x, step), y: dimension(extent.y, step), z: dimension(extent.z, step) };
    return Grid { origin: bounds.low, stride: step, size: size };
}

fn bounded_index(value: f64, extent: u32) -> u32 {
    return index(math.max(0.0f64, math.min(value, f64_from_u32(extent - 1))));
}

fn bucket_point(grid: Grid, p: math.Point) -> math.Point {
    let delta = math.sub(p, grid.origin);
    return math.point(floor(delta.x / grid.stride), floor(delta.y / grid.stride), floor(delta.z / grid.stride));
}

fn bucket_limit(grid: Grid, p: math.Point) -> Index {
    let cell = bucket_point(grid, p);
    return Index { x: bounded_index(cell.x, grid.size.x), y: bounded_index(cell.y, grid.size.y),
        z: bounded_index(cell.z, grid.size.z) };
}

fn cover(grid: Grid, row: Placed) -> Candidate {
    let radius = padded(row);
    return Candidate { shape: row, low: bucket_limit(grid, math.sub(row.geometry.center, radius)),
        high: bucket_limit(grid, math.add(row.geometry.center, radius)) };
}

fn ordered(models: List<Model>, members: List<Member>) -> List<Placed> {
    let keys = members.map_indexed(fn(id) => fn(member) =>
        word_widen_u32_to_u64(member.group) * 4294967296 + word_widen_u32_to_u64(id)).sort();
    return keys.map(fn(key) => placed_id(models, members, word_narrow_u64_to_u32(key)));
}

fn placed_id(models: List<Model>, members: List<Member>, id: u32) -> Placed {
    return placed(models, members.at_or(id, empty_placed().member), id + 1);
}

pub fn prepare_scene(models: List<Model>, spec: SceneSpec) -> Scene {
    let positive = ordered(models, spec.positive);
    let negative = spec.negative.map_indexed(fn(i) => fn(member) => placed(models, member, i + 1));
    let grid = grid_geometry(enclosing(positive));
    return Scene { positive: positive.map(fn(shape) => cover(grid, shape)), negative: negative, grid: grid, buckets: [] };
}

fn horizontal_overlap(candidate: Candidate, x: f64, z: f64) -> Bool {
    return x >= f64_from_u32(candidate.low.x) && x <= f64_from_u32(candidate.high.x)
        && z >= f64_from_u32(candidate.low.z) && z <= f64_from_u32(candidate.high.z);
}

fn column_candidates(scene: Scene, x: f64, z: f64) -> List<Candidate> {
    return scene.positive.filter(fn(candidate) => horizontal_overlap(candidate, x, z));
}

fn vertical_overlap(candidate: Candidate, y: f64) -> Bool {
    return y >= f64_from_u32(candidate.low.y) && y <= f64_from_u32(candidate.high.y);
}

fn append_bake_column(buckets: Buffer<List<Placed>>, scene: Scene, i: u32) -> Buffer<List<Placed>> {
    let size = scene.grid.size;
    let column = column_candidates(scene, f64_from_u32(quot_or(i, size.z, 0)), f64_from_u32(rem_or(i, size.z, 0)));
    return repeat_until(size.y, buckets, fn(output) => false, fn(y) => fn(output) =>
        output.push(column.filter(fn(candidate) => vertical_overlap(candidate, f64_from_u32(y))).map(fn(candidate) => candidate.shape)));
}

// Baking revisits the same cells along thousands of surface and shadow rays.
// Store their ordered shape lists once, with the range index as a sparse fallback.
fn index_bake(scene: Scene) -> Scene {
    let size = scene.grid.size;
    let footprint_limit: u32 = quot_or(262144, size.y, 0);
    if length(scene.positive) == 0 || size.x > quot_or(footprint_limit, size.z, 0) { return scene; }
    let out: Buffer<List<Placed>> = Buffer.empty();
    let buckets = repeat_until(size.x * size.z, out, fn(output) => false,
        fn(i) => fn(output) => append_bake_column(output, scene, i)).freeze();
    return Scene { positive: scene.positive, negative: scene.negative, grid: scene.grid, buckets: buckets };
}

// A vertical ray stays in one horizontal bucket. Store each solid's inclusive
// bucket range and select its column once, without allocating a dense 3D grid.
fn scene_column(scene: Scene, x: f64, z: f64) -> Column {
    let grid = scene.grid;
    let cell = bucket_point(grid, math.point(x, grid.origin.y, z));
    let positive = column_candidates(scene, cell.x, cell.z);
    return Column { positive: positive, negative: scene.negative, grid: grid };
}

record Owner { id: u32, distance: f64, }
record Blend {
    best: Owner,
    group: u32,
    local: Owner,
    width: f64,
}

fn nearer(a: Owner, b: Owner) -> Owner { return if b.distance < a.distance { b } else { a }; }

fn push_group(current: Blend, member: Member) -> Blend {
    if current.group == member.group { return current; }
    return Blend { best: nearer(current.best, current.local), group: member.group,
        local: Owner { id: 0, distance: 1e9f64 }, width: member.blend };
}

fn local_join(a: f64, b: f64, width: f64) -> f64 {
    if width <= 0.0f64 || a >= 1e8f64 { return math.min(a, b); }
    let h = math.max(width - abs(a - b), 0.0f64) / width;
    return math.min(a, b) - h * h * width * 0.25f64;
}

fn touches(model: Model, p: math.Point, reach: f64) -> Bool {
    if reach <= 0.0f64 { return false; }
    let x = p.x - model.center.x;
    let y = p.y - model.center.y;
    let z = p.z - model.center.z;
    return x * x + y * y + z * z <= reach * reach;
}

fn union_one(tables: noise.Noise, point: math.Point, current: Blend, row: Placed) -> Blend {
    let next = push_group(current, row.member);
    let reach = math.min(next.best.distance, next.local.distance) + next.width + row.geometry.bound;
    if !touches(row.geometry, point, reach) { return next; }
    let d = bumped_distance(row.geometry, row.member, tables, point);
    if is_nan(d) { return next; }
    let winner = if d < next.local.distance { row.id } else { next.local.id };
    let surface = Owner { id: winner, distance: local_join(next.local.distance, d, next.width) };
    return Blend { best: next.best, group: next.group, local: surface, width: next.width };
}

// Surface zero is the terrain. Positive and cut IDs are separate lists
// with one-based indices in the author's SceneSpec.
record SurfaceHit { distance: f64, surface: u32, cut: u32, }

fn cut_one(tables: noise.Noise, point: math.Point, current: SurfaceHit, row: Placed) -> SurfaceHit {
    if !touches(row.geometry, point, row.geometry.bound + 0.5f64) { return current; }
    let cut = -bumped_distance(row.geometry, row.member, tables, point);
    return if cut > current.distance { SurfaceHit { distance: cut, surface: current.surface, cut: row.id } } else { current };
}

fn union_at(tables: noise.Noise, point: math.Point, bucket: f64, current: Blend, candidate: Candidate) -> Blend {
    if !vertical_overlap(candidate, bucket) { return current; }
    return union_one(tables, point, current, candidate.shape);
}

fn begin_union(ground: f64) -> Blend {
    let ground_id: u32 = if ground < 1e8f64 { 0 } else { 4294967295 };
    return Blend { best: Owner { id: ground_id, distance: ground },
        local: Owner { id: ground_id, distance: 1e9f64 }, group: 0, width: 0.0f64 };
}

fn finish_union(combined: Blend, negative: List<Placed>, tables: noise.Noise, point: math.Point) -> SurfaceHit {
    let winner = nearer(combined.best, combined.local);
    let hit = SurfaceHit { distance: math.min(1.0f64, winner.distance), surface: winner.id, cut: 0 };
    return foldl(negative, hit, fn(row) => fn(current) => cut_one(tables, point, current, row));
}

fn column_hit(column: Column, tables: noise.Noise, point: math.Point, ground: f64) -> SurfaceHit {
    let bucket = floor((point.y - column.grid.origin.y) / column.grid.stride);
    let combined = foldl(column.positive, begin_union(ground), fn(candidate) => fn(current) =>
        union_at(tables, point, bucket, current, candidate));
    return finish_union(combined, column.negative, tables, point);
}

fn scene_bucket(scene: Scene, point: math.Point) -> List<Placed> {
    let cell = bucket_point(scene.grid, point);
    let size = scene.grid.size;
    if cell.x < 0.0f64 || cell.y < 0.0f64 || cell.z < 0.0f64 ||
        cell.x >= f64_from_u32(size.x) || cell.y >= f64_from_u32(size.y) || cell.z >= f64_from_u32(size.z) { return []; }
    return scene.buckets.at_or((index(cell.x) * size.z + index(cell.z)) * size.y + index(cell.y), []);
}

pub fn scene_hit(scene: Scene, tables: noise.Noise, point: math.Point, ground: f64) -> SurfaceHit {
    if length(scene.buckets) == 0 { return column_hit(scene_column(scene, point.x, point.z), tables, point, ground); }
    let combined = foldl(scene_bucket(scene, point), begin_union(ground),
        fn(row) => fn(current) => union_one(tables, point, current, row));
    return finish_union(combined, scene.negative, tables, point);
}

pub fn scene_distance(scene: Scene, tables: noise.Noise, point: math.Point, ground: f64) -> f64 {
    return scene_hit(scene, tables, point, ground).distance;
}

record Ray { y: f64, distance: f64, }

fn vertical(column: Column, tables: noise.Noise, x: f64, z: f64, floor_y: f64, y: f64) -> Ray {
    let point = math.point(x, y, z);
    let height = terrain.distance_from_height(y, floor_y);
    return Ray { y: y, distance: column_hit(column, tables, point, height).distance };
}

// A solid start and a miss use the source sculptor's sentinel values.
pub fn trace_height(scene: Scene, tables: noise.Noise, x: f64, z: f64, floor_y: f64, origin: f64, depth: f64) -> f64 {
    let column = scene_column(scene, x, z);
    let start = vertical(column, tables, x, z, floor_y, origin);
    if start.distance < 0.02f64 { return 1e9f64; }
    let end = origin - depth;
    let ray = repeat_until(320, start, fn(ray) => ray.distance < 0.02f64 || ray.y <= end,
        fn(step) => fn(ray) => vertical(column, tables, x, z, floor_y, ray.y - math.max(ray.distance * 0.9f64, 0.02f64)));
    return if ray.distance < 0.02f64 { ray.y } else { -1e9f64 };
}
