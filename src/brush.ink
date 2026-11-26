module StudioBrush;

import "rig.ink" as math;
import "noise.ink" as noise;
import "sampling.ink" as sampling;
import "marks.ink" as marks;
import "gaussian.ink" as gaussian;

record Surface { position: math.Point, normal: math.Point, spacing: f64, tone: f64, }
record Mark { position: math.Point, axis: math.Point, along: f64, across: f64, pigment: u32, }
record Stroke { marks: List<Mark>, random: u32, }
record GrassPattern { tone: f64, height: f64, wear: f64, }
record Grass { height: f64, width: f64, fat: f64, shadow: f64, pattern: GrassPattern, }
record Leaf { lift: f64, length: f64, width: f64, jitter: f64, band: f64, ao: f64, sun: math.Point, }

pub fn brush_noise(seed: u32) -> noise.Noise {
    return noise.make_noise(seed ^ 2654435769);
}

fn draw(random: u32, index: u32) -> f64 { return noise.fraction(noise.random_word(random, index)); }
fn advance(random: u32, count: u32) -> u32 { return random + count * 1831565813; }

fn tone_index(value: f64, max: u32) -> u32 {
    let bounded = math.min(f64_from_u32(max), math.max(0.0f64, floor(value)));
    return u32_from_f64(bounded).fold(fn(index) => index, fn(unit) => 0);
}

fn mark(position: math.Point, axis: math.Point, along: f64, across: f64, pigment: u32) -> Mark {
    return Mark { position: position, axis: axis, along: along, across: across, pigment: pigment };
}

pub fn grass_pattern(tables: noise.Noise, p: math.Point) -> GrassPattern {
    return GrassPattern { tone: noise.noise3(tables, p.x * 0.33f64 + 11.3f64, p.z * 0.33f64 + 4.1f64, 4.2f64),
        height: noise.noise3(tables, p.x * 0.55f64 + 3.7f64, p.z * 0.55f64 + 8.9f64, 1.7f64),
        wear: noise.noise3(tables, p.x * 0.8f64 + 21.1f64, p.z * 0.8f64 + 2.3f64, 6.4f64) };
}

// The incoming word is the state before this stroke's first Mulberry32 draw.
pub fn paint_grass(surface: Surface, ramp: List<u32>, grass: Grass, random: u32) -> Stroke {
    let n = length(ramp);
    if n == 0 { return Stroke { marks: [], random: random }; }
    let sh = grass.shadow;
    let p = surface.position;
    let kf = surface.tone * f64_from_u32(n) + (grass.pattern.tone - 0.5f64) * 1.5f64 *
        (1.0f64 - 0.7f64 * sh) - 0.35f64 * sh;
    let k = tone_index(kf, n - 1);
    let mid = ramp.at_or(k, 0);
    let lo = ramp.at_or(if k == 0 { 0 } else { k - 1 }, mid);
    let hi = ramp.at_or(k + 1, mid);
    let sod = mark(p, surface.normal, surface.spacing * 0.3f64, surface.spacing * grass.fat, lo);
    let wear = grass.pattern.wear;
    let j: u32 = if wear > 0.7f64 { 1 } else { 0 };
    if j == 1 && draw(random, 0) < (wear - 0.7f64) * 6.0f64 {
        return Stroke { marks: [sod], random: advance(random, 1) };
    }
    let h = grass.height * 2.1f64 * (0.45f64 + 1.1f64 * grass.pattern.height) * (0.55f64 + 0.75f64 * draw(random, j));
    let w = grass.width * 1.9f64 * (0.8f64 + 0.5f64 * draw(random, j + 1));
    let x = (draw(random, j + 2) - 0.5f64) * 0.5f64;
    let z = (draw(random, j + 3) - 0.5f64) * 0.5f64;
    let l = sqrt(x * x + 1.0f64 + z * z);
    let axis = math.point(x / l, 1.0f64 / l, z / l);
    let low = if lo == mid { mid } else { if draw(random, j + 4) < 0.55f64 { lo } else { mid } };
    let last = j + if lo == mid { 4 } else { 5 };
    let high = if draw(random, last) < 0.3f64 + 0.5f64 * (kf - f64_from_u32(k)) { hi } else { mid };
    let root = mark(math.add(p, math.scale(math.scale(axis, h), 0.3f64)), axis, h * 0.34f64, w, low);
    let tip = mark(math.add(p, math.scale(math.scale(axis, h), 0.72f64)), axis, h * 0.3f64, w * 0.55f64, high);
    return Stroke { marks: [sod, root, tip], random: advance(random, last + 1) };
}

pub fn leaf_band(tables: noise.Noise, p: math.Point) -> f64 {
    return noise.noise3(tables, p.x * 0.8f64 + 3.3f64, p.y * 0.8f64 + 7.1f64, p.z * 0.8f64 + 1.9f64);
}

fn leaf_axis(n: math.Point, lift: f64, angle: f64) -> math.Point {
    let spin = sampling.circle(angle);
    let length = sqrt(n.z * n.z + n.x * n.x);
    let u = if length < 0.001f64 { math.point(1.0f64, 0.0f64, 0.0f64) }
        else { math.point(-n.z / length, 0.0f64, n.x / length) };
    let v = math.cross(n, u);
    let axis = math.add(math.add(math.scale(u, spin.cosine), math.scale(v, spin.sine)), math.scale(n, lift));
    let l = math.magnitude(axis);
    return if l > 0.0f64 { math.point(axis.x / l, axis.y / l, axis.z / l) } else { math.point(1.0f64, 0.0f64, 0.0f64) };
}

pub fn paint_leaf(surface: Surface, tones: List<u32>, leaf: Leaf, random: u32) -> Stroke {
    let count = length(tones);
    if count == 0 { return Stroke { marks: [], random: random }; }
    let n = surface.normal;
    let p = surface.position;
    let axis = leaf_axis(n, leaf.lift, draw(random, 0) * math.tau());
    let tone_count = f64_from_u32(count);
    if leaf.length != 0.0f64 {
        let k = tone_index(surface.tone * tone_count + (draw(random, 1) - 0.5f64) * leaf.jitter, count - 1);
        let shard = mark(math.add(p, math.scale(n, 0.04f64)), axis, leaf.length, leaf.width, tones.at_or(k, 0));
        return Stroke { marks: [shard], random: advance(random, 2) };
    }
    let li = 0.2f64 + 0.2f64 * n.y + 0.26f64 * math.max(-0.4f64, math.dot(n, leaf.sun)) +
        0.42f64 * leaf.band + 0.25f64 * (leaf.ao - 1.0f64);
    let k = tone_index(li * tone_count + (draw(random, 1) - 0.5f64) * 1.1f64, count - 1);
    let size = (if draw(random, 2) < 0.32f64 { 0.12f64 + draw(random, 3) * 0.1f64 }
        else { 0.06f64 + draw(random, 3) * 0.065f64 }) * 2.3f64 *
        math.min(1.1f64, math.max(0.45f64, surface.spacing * 5.2f64));
    let out = 0.04f64 + draw(random, 4) * size * 0.6f64;
    let shard = mark(math.add(p, math.scale(n, out)), axis, size * 1.15f64, size * 0.5f64, tones.at_or(k, 0));
    return Stroke { marks: [shard], random: advance(random, 5) };
}

fn brush_splat(m: Mark, palette: List<u32>) -> gaussian.WorldGaussian {
    let axial = marks.axial_mark(m.axis, m.along, m.across);
    let cov = axial.fold(fn(shaped) => shaped.covariance, fn(error) => marks.round_mark(m.across));
    return gaussian.WorldGaussian { position: math.to_vec3(m.position), covariance0: math.to_vec3(cov.first),
        covariance1: math.to_vec3(cov.rest), reach: 3.0, rgb: palette.at_or(m.pigment, 0), alpha: 3.0 };
}

pub fn brush_splats(stroke: Stroke, palette: List<u32>) -> List<gaussian.WorldGaussian> {
    return stroke.marks.map(fn(m) => brush_splat(m, palette));
}
