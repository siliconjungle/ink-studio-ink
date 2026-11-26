module StudioSampling;

import "rig.ink" as math;
import "sculpt.ink" as sculpt;

record Circle { cosine: f64, sine: f64, }

fn sine_polynomial(x: f64, q: f64) -> f64 {
    let hi = 1.0f64 / 6227020800.0f64 - q / 1307674368000.0f64;
    let mid = 1.0f64 / 362880.0f64 + q * (-1.0f64 / 39916800.0f64 + q * hi);
    return x * (1.0f64 + q * (-1.0f64 / 6.0f64 + q *
        (1.0f64 / 120.0f64 + q * (-1.0f64 / 5040.0f64 + q * mid))));
}

fn cosine_polynomial(q: f64) -> f64 {
    let hi = 1.0f64 / 479001600.0f64 + q * (-1.0f64 / 87178291200.0f64 + q / 20922789888000.0f64);
    let mid = -1.0f64 / 3628800.0f64 + q * hi;
    return 1.0f64 + q * (-0.5f64 + q *
        (1.0f64 / 24.0f64 + q * (-1.0f64 / 720.0f64 + q * (1.0f64 / 40320.0f64 + q * mid))));
}

// Split pi/2 so the high product stays exact for the turns used by the
// Fibonacci lattice. Both polynomials run on [-pi/4, pi/4].
fn circle(angle: f64) -> Circle {
    let quarter = floor(angle / 1.5707963267948966f64 + 0.5f64);
    let t = (angle - quarter * 1.570796326734125614166259765625f64) - quarter * 6.0771005065061926e-11f64;
    let q = t * t;
    let s = sine_polynomial(t, q);
    let c = cosine_polynomial(q);
    let phase = quarter - floor(quarter * 0.25f64) * 4.0f64;
    if phase == 1.0f64 { return Circle { cosine: -s, sine: c }; }
    if phase == 2.0f64 { return Circle { cosine: -c, sine: -s }; }
    if phase == 3.0f64 { return Circle { cosine: s, sine: -c }; }
    return Circle { cosine: c, sine: s };
}

fn sample_count(value: f64) -> u32 { return u32_from_f64(value).fold(fn(n) => n, fn(unit) => 0); }

fn indexed(n: u32) -> List<u32> {
    return buffer_fill(n, 0).freeze().map_indexed(fn(i) => fn(unused) => i);
}

fn fibonacci(index: u32, n: u32) -> math.Point {
    let k = f64_from_u32(index);
    let y = 1.0f64 - 2.0f64 * (k + 0.5f64) / f64_from_u32(n);
    let r = sqrt(math.max(0.0f64, 1.0f64 - y * y));
    let p = circle(k * 2.399963f64);
    return math.point(r * p.cosine, y, r * p.sine);
}

fn fifth_root(value: f64) -> f64 {
    if value <= 0.0f64 { return 0.0f64; }
    let exponent = f64_from_u64(wrapping_shr(f64_bits(value), 52) & 2047) - 1023.0f64;
    let start = u64_from_f64(floor(exponent * 0.2f64) + 1023.0f64).fold(fn(k) => f64_from_bits(wrapping_shl(k, 52)), fn(unit) => 1.0f64);
    return repeat(12, start, fn(i) => fn(x) => fifth_step(x, value));
}

fn fifth_step(value: f64, target: f64) -> f64 {
    let square = value * value;
    return (4.0f64 * value + target / (square * square)) * 0.2f64;
}

fn sample_power(value: f64) -> f64 {
    let root = fifth_root(value);
    let square = root * root;
    let quad = square * square;
    return quad * quad;
}

fn ellipsoid_area(r: math.Point) -> f64 {
    let mean = (sample_power(r.x * r.y) + sample_power(r.x * r.z) + sample_power(r.y * r.z)) / 3.0f64;
    let eighth = sqrt(sqrt(sqrt(mean)));
    let square = eighth * eighth;
    return 1.3f64 * 4.0f64 * math.pi() * (square * square * eighth);
}

fn ellipsoid_points(radii: math.Point, spacing: f64) -> List<math.Point> {
    let n = sample_count(ceil(ellipsoid_area(radii) / (spacing * spacing)));
    return indexed(n).map(fn(i) => radius_point(fibonacci(i, n), radii));
}

fn radius_point(unit: math.Point, radii: math.Point) -> math.Point {
    return math.point(unit.x * radii.x, unit.y * radii.y, unit.z * radii.z);
}

fn cyclical(axis: u32, a: f64, b: f64, c: f64) -> math.Point {
    if axis == 0 { return math.point(a, b, c); }
    if axis == 1 { return math.point(c, a, b); }
    return math.point(b, c, a);
}

fn face_dimensions(half: math.Point, axis: u32) -> math.Point {
    if axis == 0 { return half; }
    if axis == 1 { return math.point(half.y, half.z, half.x); }
    return math.point(half.z, half.x, half.y);
}

fn face_point(axis: u32, size: math.Point, width: u32, height: u32, index: u32) -> math.Point {
    let i = quot_or(index, height * 2, 0);
    let j = rem_or(quot_or(index, 2, 0), height, 0);
    let sign = if (index & 1) == 0 { -1.0f64 } else { 1.0f64 };
    let u = ((f64_from_u32(i) + 0.5f64) / f64_from_u32(width) * 2.0f64 - 1.0f64) * size.y;
    let v = ((f64_from_u32(j) + 0.5f64) / f64_from_u32(height) * 2.0f64 - 1.0f64) * size.z;
    return cyclical(axis, size.x * sign, u, v);
}

fn face_points(half: math.Point, spacing: f64, axis: u32) -> List<math.Point> {
    let size = face_dimensions(half, axis);
    let width = sample_count(math.max(1.0f64, floor(2.0f64 * size.y / spacing + 0.5f64)));
    let height = sample_count(math.max(1.0f64, floor(2.0f64 * size.z / spacing + 0.5f64)));
    return indexed(width * height * 2).map(fn(i) => face_point(axis, size, width, height, i));
}

fn boxed_points(box: sculpt.Box, spacing: f64) -> List<math.Point> {
    return face_points(box.half, spacing, 0).concat(face_points(box.half, spacing, 1)).concat(face_points(box.half, spacing, 2));
}

fn rotated(center: math.Point, frame: math.Matrix, p: math.Point) -> math.Point {
    return math.point(
        center.x + frame.x.x * p.x + frame.y.x * p.y + frame.z.x * p.z,
        center.y + frame.x.y * p.x + frame.y.y * p.y + frame.z.y * p.z,
        center.z + frame.x.z * p.x + frame.y.z * p.y + frame.z.z * p.z);
}

fn to_world(points: List<math.Point>, center: math.Point, frame: Option<math.Matrix>) -> List<math.Point> {
    return frame.fold(fn(frame) => points.map(fn(p) => rotated(center, frame, p)), fn(unit) => points.map(fn(p) => math.add(center, p)));
}

record Rim { radius: f64, y: f64, phase: f64, minimum: f64, }

fn rim_point(rim: Rim, index: u32, size: u32) -> math.Point {
    let angle = ((f64_from_u32(index) + rim.phase) / f64_from_u32(size)) * math.tau();
    let p = circle(angle);
    return math.point(p.cosine * rim.radius, rim.y, p.sine * rim.radius);
}

fn append_rim(points: Buffer<math.Point>, rim: Rim, spacing: f64) -> Buffer<math.Point> {
    let n = sample_count(math.max(rim.minimum, ceil(math.tau() * rim.radius / spacing)));
    return repeat_until(n, points, fn(work) => false, fn(i) => fn(work) => work.push(rim_point(rim, i, n)));
}

record Cap { radius: f64, points: Buffer<math.Point>, }

fn cap_points(points: Buffer<math.Point>, radius: f64, height: f64, spacing: f64) -> Buffer<math.Point> {
    let rings = sample_count(math.max(0.0f64, ceil(radius / spacing))) + 1;
    let start = Cap { radius: radius - spacing * 0.5f64, points: points };
    let result = repeat_until(rings, start, fn(cap) => cap.radius <= 0.0f64, fn(i) => fn(cap) =>
        Cap { radius: cap.radius - spacing,
            points: append_rim(cap.points, Rim { radius: cap.radius, y: height, phase: 0.0f64, minimum: 1.0f64 }, spacing) });
    return result.points;
}

pub fn lathe_rows(height: f64, spacing: f64) -> u32 {
    if !(spacing > 0.0f64 && is_finite(spacing)) { return 0; }
    return sample_count(ceil(height / spacing * 1.25f64));
}

fn lathe_ring(i: u32, size: u32, height: f64, radius: f64) -> Rim {
    let row = f64_from_u32(i);
    let t = (row + 0.5f64) / f64_from_u32(size);
    return Rim { radius: radius, y: (t - 0.5f64) * height, phase: row * 0.5f64, minimum: 3.0f64 };
}

fn lathe_points(height: f64, side: List<f64>, bottom: f64, top: f64, spacing: f64) -> List<math.Point> {
    let rows = length(side);
    let out: Buffer<math.Point> = Buffer.empty();
    let body = repeat_until(rows, out, fn(work) => false, fn(i) => fn(work) =>
        append_rim(work, lathe_ring(i, rows, height, side.at_or(i, 0.0f64)), spacing));
    let first = cap_points(body, bottom, (0.0f64 - 0.5f64) * height, spacing);
    return cap_points(first, top, (1.0f64 - 0.5f64) * height, spacing).freeze();
}

// An authored profile can supply ring and endpoint radii without moving the
// candidate topology, radial spacing or coordinate transforms into its host.
pub fn profile_candidates(center: math.Point, frame: Option<math.Matrix>, height: f64, side: List<f64>,
    bottom: f64, top: f64, spacing: f64) -> List<math.Point> {
    if !(spacing > 0.0f64 && is_finite(spacing)) { return []; }
    return to_world(lathe_points(height, side, bottom, top, spacing), center, frame);
}

fn turned_points(lathe: sculpt.Lathe, spacing: f64, from_tip: Bool) -> List<math.Point> {
    let rows = lathe_rows(lathe.height, spacing);
    let side = indexed(rows).map(fn(i) =>
        sculpt.lathe_radius(lathe, (f64_from_u32(i) + 0.5f64) / f64_from_u32(rows), from_tip));
    return lathe_points(lathe.height, side, sculpt.lathe_radius(lathe, 0.0f64, from_tip),
        sculpt.lathe_radius(lathe, 1.0f64, from_tip), spacing);
}

fn power_lathe_points(lathe: sculpt.PowerLathe, spacing: f64) -> List<math.Point> {
    let rows = lathe_rows(lathe.height, spacing);
    let side = indexed(rows).map(fn(i) =>
        sculpt.power_radius(lathe, (f64_from_u32(i) + 0.5f64) / f64_from_u32(rows)));
    return lathe_points(lathe.height, side, lathe.base, lathe.base + lathe.slope, spacing);
}

fn ripple_lathe_points(lathe: sculpt.RippleLathe, spacing: f64) -> List<math.Point> {
    let rows = lathe_rows(lathe.height, spacing);
    let side = indexed(rows).map(fn(i) =>
        sculpt.ripple_radius(lathe, (f64_from_u32(i) + 0.5f64) / f64_from_u32(rows)));
    return lathe_points(lathe.height, side, sculpt.ripple_radius(lathe, 0.0f64), sculpt.ripple_radius(lathe, 1.0f64), spacing);
}

fn power_ripple_lathe_points(lathe: sculpt.PowerRippleLathe, spacing: f64) -> List<math.Point> {
    let rows = lathe_rows(lathe.height, spacing);
    let side = indexed(rows).map(fn(i) =>
        sculpt.power_ripple_radius(lathe, (f64_from_u32(i) + 0.5f64) / f64_from_u32(rows)));
    return lathe_points(lathe.height, side, sculpt.power_ripple_radius(lathe, 0.0f64), lathe.tip, spacing);
}

fn ring_point(ring: sculpt.Torus, i: u32, j: u32, width: u32, height: u32) -> math.Point {
    let a = circle(f64_from_u32(i) / f64_from_u32(width) * math.tau());
    let b = circle(f64_from_u32(j) / f64_from_u32(height) * math.tau());
    let rad = ring.major + b.cosine * ring.minor;
    return math.point(a.cosine * rad, b.sine * ring.minor, a.sine * rad);
}

fn torus_points(ring: sculpt.Torus, spacing: f64) -> List<math.Point> {
    let width = sample_count(ceil(math.tau() * (ring.major + ring.minor) / spacing));
    let height = sample_count(math.max(4.0f64, ceil(math.tau() * ring.minor / spacing)));
    return indexed(width * height).map(fn(i) =>
        ring_point(ring, quot_or(i, height, 0), rem_or(i, height, 0), width, height));
}

record TubeFrame { left: math.Point, up: math.Point, }
record TubeRing { frame: TubeFrame, center: math.Point, radius: f64, phase: f64, }
record Endpoint { center: math.Point, radius: f64, }

fn tube_frame(delta: math.Point, length: f64) -> TubeFrame {
    let axis = math.point(delta.x / length, delta.y / length, delta.z / length);
    let span = sqrt(axis.x * axis.x + axis.z * axis.z);
    let left = if span < 0.0001f64 { math.point(1.0f64, 0.0f64, 0.0f64) }
        else { math.point(-axis.z / span, 0.0f64, axis.x / span) };
    let up = math.point(axis.y * left.z, axis.z * left.x - axis.x * left.z, -axis.y * left.x);
    return TubeFrame { left: left, up: up };
}

fn tube_point(ring: TubeRing, i: u32, n: u32) -> math.Point {
    let a = circle((f64_from_u32(i) + ring.phase) / f64_from_u32(n) * math.tau());
    let c = a.cosine * ring.radius;
    let s = a.sine * ring.radius;
    return math.point(
        ring.center.x + ring.frame.left.x * c + ring.frame.up.x * s,
        ring.center.y + ring.frame.up.y * s,
        ring.center.z + ring.frame.left.z * c + ring.frame.up.z * s);
}

fn append_tube_ring(points: Buffer<math.Point>, frame: TubeFrame, segment: sculpt.Segment, i: u32, rows: u32, spacing: f64) -> Buffer<math.Point> {
    let t = (f64_from_u32(i) + 0.5f64) / f64_from_u32(rows);
    let radius = math.mix(segment.base, segment.tip, t);
    let ring = TubeRing { frame: frame, center: math.add(segment.start, math.scale(segment.delta, t)),
        radius: radius, phase: f64_from_u32(i) * 0.5f64 };
    let n = sample_count(math.max(3.0f64, ceil(math.tau() * radius / spacing)));
    return repeat_until(n, points, fn(work) => false, fn(k) => fn(work) => work.push(tube_point(ring, k, n)));
}

fn append_sphere(points: Buffer<math.Point>, cap: Endpoint, spacing: f64) -> Buffer<math.Point> {
    let r = cap.radius;
    let n = sample_count(ceil(12.6f64 * r * r / (spacing * spacing)));
    return repeat_until(n, points, fn(work) => false, fn(i) => fn(work) =>
        work.push(math.add(cap.center, math.scale(fibonacci(i, n), r))));
}

fn append_segment(points: Buffer<math.Point>, segments: List<sculpt.Segment>, i: u32, spacing: f64) -> Buffer<math.Point> {
    let segment = segments.at_or(i, empty_segment());
    let length = sqrt(segment.length_squared);
    let frame = tube_frame(segment.delta, length);
    let rows = sample_count(math.max(1.0f64, ceil(length / spacing)));
    let sides = repeat_until(rows, points, fn(work) => false, fn(row) => fn(work) =>
        append_tube_ring(work, frame, segment, row, rows, spacing));
    if i == 0 { return sides; }
    let previous = segments.at_or(i - 1, empty_segment());
    let alignment = math.dot(previous.delta, segment.delta) / (sqrt(previous.length_squared) * length);
    return if alignment < 0.95f64 { append_sphere(sides, Endpoint { center: segment.start, radius: segment.base }, spacing) } else { sides };
}

fn empty_segment() -> sculpt.Segment {
    return sculpt.Segment { start: math.zero(), delta: math.zero(), length_squared: 0.0f64, base: 0.0f64, tip: 0.0f64 };
}

pub fn tube_candidates(segments: List<sculpt.Segment>, start: Endpoint, end: Endpoint, spacing: f64) -> List<math.Point> {
    if !(spacing > 0.0f64 && is_finite(spacing)) { return []; }
    let out: Buffer<math.Point> = Buffer.empty();
    let body = repeat_until(length(segments), out, fn(work) => false, fn(i) => fn(work) =>
        append_segment(work, segments, i, spacing));
    let first = append_sphere(body, start, spacing);
    return append_sphere(first, end, spacing).freeze();
}

fn tube_points(segments: List<sculpt.Segment>, spacing: f64) -> List<math.Point> {
    if length(segments) == 0 { return []; }
    let first = segments.at_or(0, empty_segment());
    let last = segments.at_or(length(segments) - 1, empty_segment());
    return tube_candidates(segments, Endpoint { center: first.start, radius: first.base },
        Endpoint { center: math.add(last.start, last.delta), radius: last.tip }, spacing);
}

pub fn model_candidates(model: sculpt.Model, spacing: f64) -> List<math.Point> {
    if !(spacing > 0.0f64 && is_finite(spacing)) { return []; }
    return match model.form {
        sculpt.Form.Boxed(box) => to_world(boxed_points(box, spacing), model.center, model.frame),
        sculpt.Form.Ellipsoid(radii) => to_world(ellipsoid_points(radii, spacing), model.center, model.frame),
        sculpt.Form.Turned(lathe) => to_world(turned_points(lathe, spacing, false), model.center, model.frame),
        sculpt.Form.TurnedFromTip(lathe) => to_world(turned_points(lathe, spacing, true), model.center, model.frame),
        sculpt.Form.TurnedPower(lathe) => to_world(power_lathe_points(lathe, spacing), model.center, model.frame),
        sculpt.Form.TurnedRipple(lathe) => to_world(ripple_lathe_points(lathe, spacing), model.center, model.frame),
        sculpt.Form.TurnedPowerRipple(lathe) => to_world(power_ripple_lathe_points(lathe, spacing), model.center, model.frame),
        sculpt.Form.Tube(segments) => tube_points(segments, spacing),
        sculpt.Form.Ring(ring) => to_world(torus_points(ring, spacing), model.center, model.frame),
    };
}
