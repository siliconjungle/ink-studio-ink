module Rail;

import "rig.ink" as math;

record Segment { start: math.Point, delta: math.Point, length: f64, offset: f64, }
record Path { segments: List<Segment>, length: f64, }
record Point { position: math.Point, direction: math.Point, }
record Projection { distance: f64, arc: f64, point: Point, }

fn clamp01(x: f64) -> f64 { return math.max(0.0f64, math.min(1.0f64, x)); }

fn extend(path: Path, a: math.Point, b: math.Point) -> Path {
    let delta = math.sub(b, a);
    let span = sqrt(math.dot(delta, delta));
    if span <= 0.0f64 { return path; }
    let next = Segment { start: a, delta: delta, length: span, offset: path.length };
    return Path { segments: path.segments.concat([next]), length: path.length + span };
}

pub fn prepare_rail(knots: List<math.Point>) -> Path {
    let empty = Path { segments: [], length: 0.0f64 };
    if length(knots) < 2 { return empty; }
    let indices = buffer_fill(length(knots) - 1, 0).freeze().map_indexed(fn(i) => fn(unused) => i);
    return foldl(indices, empty, fn(i) => fn(path) =>
        extend(path, knots.at_or(i, math.zero()), knots.at_or(i + 1, math.zero())));
}

fn point(segment: Segment, fraction: f64) -> Point {
    return Point { position: math.add(segment.start, math.scale(segment.delta, fraction)),
        direction: math.scale(segment.delta, 1.0f64 / segment.length) };
}

pub fn rail_at(path: Path, arc: f64) -> Option<Point> {
    let empty: Option<Segment> = None;
    let target = math.max(0.0f64, math.min(path.length, arc));
    let selected = foldl(path.segments, empty, fn(segment) => fn(best) =>
        best.fold(fn(found) => Some(found), fn(unit) =>
            if target <= segment.offset + segment.length { Some(segment) } else { None }));
    return selected.fold(fn(segment) => Some(point(segment, clamp01((target - segment.offset) / segment.length))), fn(unit) => None);
}

fn project(segment: Segment, x: f64, z: f64) -> Projection {
    let dx = segment.delta.x;
    let dz = segment.delta.z;
    let norm = dx * dx + dz * dz;
    let fraction = if norm > 0.0f64 {
        clamp01(((x - segment.start.x) * dx + (z - segment.start.z) * dz) / norm)
    } else { 0.0f64 };
    let at = point(segment, fraction);
    let ex = x - at.position.x;
    let ez = z - at.position.z;
    return Projection { distance: sqrt(ex * ex + ez * ez), arc: segment.offset + fraction * segment.length, point: at };
}

fn nearer(a: Projection, b: Projection) -> Projection { return if a.distance < b.distance { a } else { b }; }

fn include_projection(best: Option<Projection>, segment: Segment, x: f64, z: f64) -> Option<Projection> {
    let candidate = project(segment, x, z);
    return Some(best.fold(fn(known) => nearer(candidate, known), fn(unit) => candidate));
}

pub fn rail_nearest(path: Path, x: f64, z: f64) -> Option<Projection> {
    let empty: Option<Projection> = None;
    return foldl(path.segments, empty, fn(segment) => fn(best) =>
        include_projection(best, segment, x, z));
}
