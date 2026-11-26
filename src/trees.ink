module StudioTrees;

import "brush.ink" as brush;
import "noise.ink" as noise;
import "rig.ink" as math;
import "sampling.ink" as sampling;
import "sculpt.ink" as sculpt;
import "terrain.ink" as terrain;

record Tree {
    base: math.Point, height: f64, radius: f64, lean: terrain.XZ, spacing: f64,
    roots: u32, limbs: u32, spread: f64, cluster_scale: f64, leaf_scale: f64, leaf_count: u32,
    leafy: Bool,
}
record Radius { kind: u32, base: f64, tip: f64, }
record Wood {
    points: List<math.Point>, radius: Radius, group: u32, spacing: f64, bump: f64, frequency: f64,
}
record Cluster { center: math.Point, radii: math.Point, band: Option<f64>, }
record Growth {
    wood: List<Wood>, tips: List<math.Point>, clusters: List<Cluster>, top: math.Point,
    scale: f64, leaf_count: u32, random: u32,
}

fn draw(random: u32, index: u32) -> f64 { return noise.fraction(noise.random_word(random, index)); }
fn advance(random: u32, count: u32) -> u32 { return random + count * 1831565813; }
fn range(random: u32, index: u32, lo: f64, hi: f64) -> f64 { return lo + (hi - lo) * draw(random, index); }

pub fn branch_radius(radius: Radius, t: f64) -> f64 {
    if radius.kind == 1 {
        let u = 1.0f64 - t;
        let square = u * u;
        return radius.base * (1.25f64 - 0.75f64 * t + 0.5f64 * (square * square * square));
    }
    if radius.kind == 2 { return math.max(radius.tip, radius.base * (1.0f64 - 0.7f64 * t)); }
    return math.mix(radius.base, radius.tip, t);
}

fn trunk(tree: Tree, twist: f64, t: f64) -> math.Point {
    let p = tree.base;
    let x = sampling.circle(t * 5.0f64 + twist).sine;
    let z = sampling.circle(t * 4.0f64 + twist).cosine;
    return math.point(p.x + tree.lean.x * tree.height * t * t + tree.radius * 0.9f64 * x * t,
        p.y + tree.height * t, p.z + tree.lean.z * tree.height * t * t + tree.radius * 0.9f64 * z * t);
}

fn stem(tree: Tree, twist: f64) -> Wood {
    let path = sampling.indexed(11).map(fn(i) => trunk(tree, twist, f64_from_u32(i) / 10.0f64));
    return Wood { points: path, radius: Radius { kind: 1, base: tree.radius, tip: 0.0f64 },
        group: 0, spacing: tree.spacing, bump: tree.radius * 0.5f64, frequency: 1.4f64 / tree.radius };
}

fn root_point(tree: Tree, turn: sampling.Circle, length: f64, t: f64) -> math.Point {
    let p = tree.base;
    return math.point(p.x + turn.cosine * length * t, p.y + tree.radius * 1.6f64 * (1.0f64 - t) * (1.0f64 - t) - 0.03f64,
        p.z + turn.sine * length * t);
}

fn root(tree: Tree, random: u32, k: u32) -> Wood {
    let turn = sampling.circle(f64_from_u32(k) / 5.0f64 * math.tau() + range(random, 0, -0.4f64, 0.4f64));
    let length = tree.radius * range(random, 1, 2.5f64, 4.5f64);
    return Wood { points: sampling.indexed(6).map(fn(i) => root_point(tree, turn, length, f64_from_u32(i) / 5.0f64)),
        radius: Radius { kind: 0, base: tree.radius * 0.55f64, tip: tree.radius * 0.12f64 },
        group: 0, spacing: tree.spacing, bump: 0.0f64, frequency: 0.0f64 };
}

fn normalize(p: math.Point) -> math.Point {
    let length = math.magnitude(p);
    let divisor = if length > 0.0f64 { length } else { 1.0f64 };
    return math.point(p.x / divisor, p.y / divisor, p.z / divisor);
}

record Walk { points: List<math.Point>, point: math.Point, direction: math.Point, random: u32, }

fn grow_step(step: Walk, length: f64, gnarl: f64, n: u32) -> Walk {
    let d = step.direction;
    let v = normalize(math.point(d.x + range(step.random, 0, -0.5f64, 0.5f64) * gnarl,
        d.y + range(step.random, 1, -0.5f64, 0.5f64) * gnarl * 0.5f64,
        d.z + range(step.random, 2, -0.5f64, 0.5f64) * gnarl));
    let divisor = f64_from_u32(n);
    let p = math.point(step.point.x + v.x * length / divisor, step.point.y + v.y * length / divisor,
        step.point.z + v.z * length / divisor);
    return Walk { points: step.points.concat([p]), point: p, direction: v, random: advance(step.random, 3) };
}

fn grow(start: math.Point, dir: math.Point, length: f64, gnarl: f64, n: u32, random: u32) -> Walk {
    let walk = Walk { points: [start], point: start, direction: normalize(dir), random: random };
    return repeat_until(n, walk, fn(step) => false, fn(i) => fn(step) => grow_step(step, length, gnarl, n));
}

fn at(points: List<math.Point>, t: f64) -> math.Point {
    let s = t * f64_from_u32(length(points) - 1);
    let i = sampling.sample_count(math.min(floor(s), f64_from_u32(length(points) - 2)));
    let a = points.at_or(i, math.zero());
    let b = points.at_or(i + 1, a);
    let u = s - f64_from_u32(i);
    return math.add(math.scale(a, 1.0f64 - u), math.scale(b, u));
}

fn branch(tree: Tree, walk: Walk, lr: f64, group: u32) -> Wood {
    let twig = group == 1;
    return Wood { points: walk.points,
        radius: Radius { kind: 2, base: if twig { lr * 0.5f64 } else { lr }, tip: if twig { 0.05f64 } else { 0.065f64 } },
        group: group, spacing: if twig { math.min(tree.spacing, 0.07f64) } else { tree.spacing }, bump: 0.0f64, frequency: 0.0f64 };
}

record Branches { wood: Buffer<Wood>, tips: Buffer<math.Point>, clusters: Buffer<Cluster>, random: u32, }
record Limb { walk: Walk, length: f64, radius: f64, lobe: f64, count: u32, }

fn twig(tree: Tree, limb: Limb, i: u32, out: Branches, collide: Bool) -> Branches {
    let random = out.random;
    let st = 0.35f64 + f64_from_u32(i) / f64_from_u32(limb.count) * 0.55f64;
    let p0 = at(limb.walk.points, st);
    let p1 = at(limb.walk.points, math.min(1.0f64, st + 0.05f64));
    let d = normalize(math.sub(p1, p0));
    let a = sampling.circle(draw(random, 0) * math.tau());
    let sub = grow(p0, math.point(d.x + a.cosine, d.y + range(random, 1, 0.25f64, 0.65f64), d.z + a.sine),
        limb.length * range(random, 2, 0.45f64, 0.75f64), 0.35f64, 3, advance(random, 3));
    let wood = if collide { out.wood } else { out.wood.push(branch(tree, sub, limb.radius, 1)) };
    let c = limb.lobe * range(sub.random, 0, 0.16f64, 0.27f64);
    let cluster = Cluster { center: at(sub.points, 0.95f64), radii: math.point(c * 1.2f64, c * 0.7f64, c * 1.2f64), band: None };
    return Branches { wood: wood, tips: out.tips, clusters: out.clusters.push(cluster), random: advance(sub.random, 1) };
}

fn grow_limb(tree: Tree, twist: f64, i: u32, out: Branches, collide: Bool, lobe: f64) -> Branches {
    let random = out.random;
    let step = f64_from_u32(i) / f64_from_u32(tree.limbs);
    let t = math.min(0.98f64, 0.55f64 + step * 0.42f64 + range(random, 0, -0.03f64, 0.03f64));
    let a = sampling.circle(step * math.tau() + range(random, 1, 0.0f64, 0.9f64));
    let length = tree.spread * range(random, 2, 0.62f64, 1.0f64) * (1.15f64 - t * 0.4f64);
    let lr = tree.radius * (0.62f64 - t * 0.25f64);
    let walk = grow(trunk(tree, twist, t), math.point(a.cosine, range(random, 3, 0.35f64, 0.9f64), a.sine),
        length, 0.3f64, 4, advance(random, 4));
    let wood = if collide { out.wood } else { out.wood.push(branch(tree, walk, lr, 0)) };
    let tips = out.tips.push(walk.point);
    if !tree.leafy { return Branches { wood: wood, tips: tips, clusters: out.clusters, random: walk.random }; }
    let count = 2 + sampling.sample_count(floor(draw(walk.random, 0) * 3.0f64));
    let limb = Limb { walk: walk, length: length, radius: lr, lobe: lobe, count: count };
    let base = Branches { wood: wood, tips: tips, clusters: out.clusters, random: advance(walk.random, 1) };
    let sub = repeat_until(count, base, fn(out) => false, fn(n) => fn(out) => twig(tree, limb, n, out, collide));
    let c = lobe * range(sub.random, 0, 0.2f64, 0.33f64);
    let cluster = Cluster { center: at(walk.points, 1.0f64), radii: math.point(c * 1.25f64, c * 0.72f64, c * 1.25f64), band: None };
    return Branches { wood: sub.wood, tips: sub.tips, clusters: sub.clusters.push(cluster), random: advance(sub.random, 1) };
}

record TreeBase { wood: List<Wood>, twist: f64, random: u32, }

fn tree_base(tree: Tree, random: u32) -> TreeBase {
    let twist = draw(random, 0) * 6.0f64;
    let after_twist = advance(random, 1);
    let wood = [stem(tree, twist)].concat(sampling.indexed(tree.roots).map(fn(i) => root(tree, advance(after_twist, i * 2), i)));
    return TreeBase { wood: wood, twist: twist, random: advance(after_twist, tree.roots * 2) };
}

pub fn tree_colliders(tree: Tree, random: u32) -> List<Wood> {
    return tree_base(tree, random).wood;
}

pub fn grow_tree(tree: Tree, random: u32, collide: Bool) -> Growth {
    let base = tree_base(tree, random);
    let twist = base.twist;
    let lobe = tree.spread * 0.8f64 * tree.cluster_scale;
    let initial = Branches { wood: buffer(base.wood), tips: Buffer.empty(), clusters: Buffer.empty(), random: base.random };
    let result = repeat_until(tree.limbs, initial, fn(out) => false, fn(i) => fn(out) => grow_limb(tree, twist, i, out, collide, lobe));
    let top = trunk(tree, twist, 1.0f64);
    let top_cluster = Cluster { center: math.point(top.x, top.y + lobe * 0.32f64, top.z),
        radii: math.point(lobe * 0.36f64, lobe * 0.24f64, lobe * 0.36f64), band: None };
    let clusters = if tree.leafy { result.clusters.push(top_cluster) } else { result.clusters };
    let size = tree.height / 6.2f64;
    let scale = if tree.leaf_scale > 0.0f64 { tree.leaf_scale } else { math.min(1.6f64, math.max(0.5f64, size)) };
    let ratio = size / scale;
    let count = if tree.leaf_count != 0 { tree.leaf_count } else { sampling.sample_count(floor(1900.0f64 * math.min(1.0f64, ratio * ratio) + 0.5f64)) };
    return Growth { wood: result.wood.freeze(), tips: result.tips.freeze(), clusters: clusters.freeze(), top: top,
        scale: scale, leaf_count: count, random: result.random };
}

record Tube { center: math.Point, bound: f64, segments: List<sculpt.Segment>, start: sampling.Endpoint, end: sampling.Endpoint, }
record Lengths { total: f64, ends: Buffer<f64>, }

fn point_at(points: List<math.Point>, index: u32) -> math.Point { return points.at_or(index, math.zero()); }

fn measure_step(points: List<math.Point>, i: u32, path: Lengths) -> Lengths {
    let total = path.total + math.magnitude(math.sub(point_at(points, i + 1), point_at(points, i)));
    return Lengths { total: total, ends: path.ends.push(total) };
}

fn tube_step(wood: Wood, ends: List<f64>, length: f64, i: u32, segments: Buffer<sculpt.Segment>) -> Buffer<sculpt.Segment> {
    let start = point_at(wood.points, i);
    let delta = math.sub(point_at(wood.points, i + 1), start);
    let square = math.dot(delta, delta);
    if square <= 1e-10f64 { return segments; }
    return segments.push(sculpt.Segment { start: start, delta: delta, length_squared: square,
        base: branch_radius(wood.radius, ends.at_or(i, 0.0f64) / length),
        tip: branch_radius(wood.radius, ends.at_or(i + 1, length) / length) });
}

pub fn wood_tube(wood: Wood) -> Tube {
    let count = length(wood.points);
    let steps = if count > 0 { count - 1 } else { 0 };
    let divisor = if count > 0 { f64_from_u32(count) } else { 1.0f64 };
    let radius = repeat_until(17, 0.0f64, fn(radius) => false, fn(i) => fn(radius) =>
        math.max(radius, branch_radius(wood.radius, f64_from_u32(i) / 16.0f64)));
    let center = foldl(wood.points, math.zero(), fn(p) => fn(c) =>
        math.add(c, math.point(p.x / divisor, p.y / divisor, p.z / divisor)));
    let bound = foldl(wood.points, 0.0f64, fn(p) => fn(br) => math.max(br, math.magnitude(math.sub(p, center))));
    let path = repeat_until(steps, Lengths { total: 0.0f64, ends: buffer([0.0f64]) }, fn(path) => false,
        fn(i) => fn(path) => measure_step(wood.points, i, path));
    let ends = path.ends.freeze();
    let empty: Buffer<sculpt.Segment> = Buffer.empty();
    let segments = repeat_until(steps, empty, fn(out) => false, fn(i) => fn(out) => tube_step(wood, ends, path.total, i, out));
    return Tube { center: center, bound: (bound + radius) + wood.bump, segments: segments.freeze(),
        start: sampling.Endpoint { center: point_at(wood.points, 0), radius: branch_radius(wood.radius, 0.0f64) },
        end: sampling.Endpoint { center: point_at(wood.points, steps), radius: branch_radius(wood.radius, 1.0f64) } };
}

record Lamp { position: math.Point, radius: f64, strength: f64, }
record CrownPaint { sun: math.Point, basic: List<u32>, lit: List<u32>, local: List<u32>, lamps: List<Lamp>, scale: f64, }
record CrownLeaf { mark: brush.Mark, phase: f64, }
record Crown { leaves: List<CrownLeaf>, random: u32, }

record Lobe { center: math.Point, radii: math.Point, weight: f64, phase: f64, band: f64, lamp: Bool, }
record CrownShape { center: math.Point, extent: f64, weight: f64, }
record Lobes { entries: Buffer<Lobe>, random: u32, }

fn crown_shape(clusters: List<Cluster>) -> CrownShape {
    let divisor = f64_from_u32(length(clusters));
    let center = foldl(clusters, math.zero(), fn(c) => fn(current) =>
        math.add(current, math.point(c.center.x / divisor, c.center.y / divisor, c.center.z / divisor)));
    let extent = foldl(clusters, 0.001f64, fn(c) => fn(current) => math.max(current, math.magnitude(math.sub(c.center, center))));
    let weight = foldl(clusters, 0.0f64, fn(c) => fn(total) => total + c.radii.x * c.radii.z);
    return CrownShape { center: center, extent: extent, weight: weight };
}

fn lamp_hits(lamp: Lamp, center: math.Point) -> Bool {
    let d = math.magnitude(math.sub(lamp.position, center));
    let falloff = 1.0f64 - d / lamp.radius;
    return d < lamp.radius && falloff * falloff * lamp.strength > 0.3f64;
}

fn add_lobe(cluster: Cluster, shape: CrownShape, paint: CrownPaint, lobes: Lobes) -> Lobes {
    let position = math.sub(cluster.center, shape.center);
    let band = cluster.band.fold(fn(value) => value, fn(unit) => math.sat(0.5f64 * draw(lobes.random, 1) + 0.25f64 +
        (0.5f64 * math.dot(position, paint.sun)) / shape.extent));
    let lamps = length(paint.local) > 0 && foldl(paint.lamps, false, fn(lamp) => fn(lit) => lit || lamp_hits(lamp, cluster.center));
    let lobe = Lobe { center: cluster.center, radii: cluster.radii, phase: draw(lobes.random, 0) * math.tau(),
        weight: cluster.radii.x * cluster.radii.z, band: band, lamp: lamps };
    let count: u32 = cluster.band.fold(fn(value) => 1, fn(unit) => 2);
    return Lobes { entries: lobes.entries.push(lobe), random: advance(lobes.random, count) };
}

fn contains(colors: List<u32>, color: u32) -> Bool {
    return foldl(colors, false, fn(candidate) => fn(found) => found || candidate == color);
}

fn unique(colors: List<u32>) -> List<u32> {
    return foldl(colors, [], fn(color) => fn(used) => if contains(used, color) { used } else { used.concat([color]) });
}

record Pick { index: u32, remaining: f64, }

fn select_lobe(lobes: List<Lobe>, roll: f64) -> Lobe {
    let last = length(lobes) - 1;
    let fallback = Lobe { center: math.zero(), radii: math.zero(), weight: 1.0f64, phase: 0.0f64, band: 0.0f64, lamp: false };
    let start = Pick { index: 0, remaining: roll - lobes.at_or(0, fallback).weight };
    let pick = repeat_until(last, start, fn(pick) => pick.remaining <= 0.0f64, fn(i) => fn(pick) =>
        Pick { index: i + 1, remaining: pick.remaining - lobes.at_or(i + 1, fallback).weight });
    return lobes.at_or(pick.index, fallback);
}

record SeedPoint { point: math.Point, random: u32, }

fn roll_point(random: u32) -> SeedPoint {
    return SeedPoint { point: math.point(draw(random, 0) * 2.0f64 - 1.0f64, draw(random, 1) * 2.0f64 - 1.0f64,
        draw(random, 2) * 2.0f64 - 1.0f64), random: advance(random, 3) };
}

fn inside_cube_sphere(point: SeedPoint) -> Bool { return math.dot(point.point, point.point) <= 1.0f64; }

fn inside_rect(p: math.Point, b: terrain.Rect) -> Bool {
    return p.x >= b.x0 && p.x < b.x1 && p.z >= b.z0 && p.z < b.z1;
}

record Canopy { marks: Buffer<CrownLeaf>, random: u32, }
record Style { sun: math.Point, colors: List<u32>, local: List<u32>, scale: f64, weight: f64, clip: Option<terrain.Rect>, }

fn crown_leaf(lobes: List<Lobe>, style: Style, canopy: Canopy) -> Canopy {
    let cluster = select_lobe(lobes, draw(canopy.random, 0) * style.weight);
    let seed = repeat_until(4294967295, roll_point(advance(canopy.random, 1)), fn(point) => inside_cube_sphere(point),
        fn(i) => fn(point) => roll_point(point.random));
    let p = seed.point;
    let swirl = sampling.circle(p.x * 5.0f64 + p.z * 4.0f64 + cluster.phase).sine;
    let wave = sampling.circle(p.z * 7.0f64 - p.y * 3.0f64).sine;
    let edge = 1.0f64 + 0.12f64 * swirl + 0.08f64 * wave;
    let rise = 1.0f64 + 0.12f64 * sampling.circle(p.x * 6.0f64 + cluster.phase).sine;
    let pos = math.add(cluster.center, math.point(p.x * cluster.radii.x * edge, p.y * cluster.radii.y * rise, p.z * cluster.radii.z * edge));
    if !style.clip.fold(fn(bounds) => inside_rect(pos, bounds), fn(unit) => true) { return Canopy { marks: canopy.marks, random: seed.random }; }
    let colors = if cluster.lamp { style.local } else { style.colors };
    let light = 0.24f64 + 0.2f64 * p.y + 0.24f64 * math.dot(p, style.sun) + 0.36f64 * cluster.band;
    let index = brush.tone_index(light * f64_from_u32(length(colors)) + (draw(seed.random, 0) - 0.5f64) * 1.1f64, length(colors) - 1);
    let size = (if draw(seed.random, 1) < 0.32f64 { 0.12f64 + draw(seed.random, 2) * 0.1f64 }
        else { 0.06f64 + draw(seed.random, 2) * 0.065f64 }) * 2.3f64 * style.scale;
    let normal = normalize(math.point(p.x, p.y + 0.25f64, p.z));
    let axis = brush.leaf_axis(normal, 0.3f64, draw(seed.random, 3) * math.tau());
    let leaf = CrownLeaf { mark: brush.mark(pos, axis, size * 1.15f64, size * 0.5f64, colors.at_or(index, 0)), phase: cluster.phase };
    return Canopy { marks: canopy.marks.push(leaf), random: advance(seed.random, 4) };
}

pub fn paint_crown(clusters: List<Cluster>, paint: CrownPaint, count: u32, clip: Option<terrain.Rect>, random: u32) -> Crown {
    let palette = unique(paint.basic.concat(paint.lit));
    if length(clusters) == 0 || length(palette) == 0 { return Crown { leaves: [], random: random }; }
    let shape = crown_shape(clusters);
    let prepared = foldl(clusters, Lobes { entries: Buffer.empty(), random: random }, fn(cluster) => fn(set) => add_lobe(cluster, shape, paint, set));
    let lobes = prepared.entries.freeze();
    let style = Style { sun: paint.sun, colors: palette, local: unique(paint.local), scale: paint.scale, weight: shape.weight, clip: clip };
    let initial = Canopy { marks: Buffer.empty(), random: prepared.random };
    let leaves = repeat_until(count, initial, fn(work) => false, fn(i) => fn(work) => crown_leaf(lobes, style, work));
    return Crown { leaves: leaves.marks.freeze(), random: leaves.random };
}

record LeafFall { center: math.Point, radius: f64, colors: List<u32>, }
record FallingLeaf { mark: brush.Mark, phase: f64, speed: f64, }
record Falling { leaves: List<FallingLeaf>, random: u32, }

fn falling_leaf(source: LeafFall, random: u32) -> FallingLeaf {
    let turn = sampling.circle(draw(random, 0) * math.tau());
    let d = sqrt(draw(random, 1)) * source.radius;
    let p = source.center;
    let position = math.point(p.x + turn.cosine * d, p.y, p.z + turn.sine * d);
    let axis = normalize(math.point(range(random, 2, -1.0f64, 1.0f64), range(random, 3, -0.3f64, 0.3f64), range(random, 4, -1.0f64, 1.0f64)));
    let color = source.colors.at_or(sampling.sample_count(floor(draw(random, 5) * f64_from_u32(length(source.colors)))), 0);
    return FallingLeaf { mark: brush.mark(position, axis, 0.08f64, 0.035f64, color), phase: draw(random, 6), speed: range(random, 7, 0.4f64, 0.8f64) };
}

pub fn falling_leaves(source: LeafFall, count: u32, random: u32) -> Falling {
    let leaves = sampling.indexed(count).map(fn(i) => falling_leaf(source, advance(random, i * 8)));
    return Falling { leaves: leaves, random: advance(random, count * 8) };
}
