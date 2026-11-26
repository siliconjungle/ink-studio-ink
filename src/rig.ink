module StudioRig;

// The renderer consumes affine rows in packed binary32. Animation state is
// evaluated in binary64 at the simulation's fixed tick.
record Bone {
    axis_x: Vec3<f32>,
    axis_y: Vec3<f32>,
    axis_z: Vec3<f32>,
    offset: Vec3<f32>,
}

record RigLight {
    sun: Vec3<f32>,
    ambient: f32,
    diffuse: f32,
    blink: f32,
}

record Point { x: f64, y: f64, z: f64, }
record Matrix { x: Point, y: Point, z: Point, }
record Transform { axes: Matrix, offset: Point, }

fn point(x: f64, y: f64, z: f64) -> Point {
    return Point { x: x, y: y, z: z };
}

fn zero() -> Point { return point(0.0f64, 0.0f64, 0.0f64); }

fn add(a: Point, b: Point) -> Point { return point(a.x + b.x, a.y + b.y, a.z + b.z); }
fn sub(a: Point, b: Point) -> Point { return point(a.x - b.x, a.y - b.y, a.z - b.z); }
fn scale(a: Point, k: f64) -> Point { return point(a.x * k, a.y * k, a.z * k); }
fn dot(a: Point, b: Point) -> f64 { return a.x * b.x + a.y * b.y + a.z * b.z; }
fn magnitude(a: Point) -> f64 { return sqrt(dot(a, a)); }
fn unit(a: Point) -> Point {
    let length = magnitude(a);
    return if length > 0.0f64 { scale(a, 1.0f64 / length) } else { zero() };
}
fn cross(a: Point, b: Point) -> Point {
    return point(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

fn axes(x: Point, y: Point, z: Point) -> Matrix {
    return Matrix { x: x, y: y, z: z };
}
fn apply(m: Matrix, v: Point) -> Point { return point(dot(m.x, v), dot(m.y, v), dot(m.z, v)); }
fn transpose(m: Matrix) -> Matrix {
    return axes(point(m.x.x, m.y.x, m.z.x), point(m.x.y, m.y.y, m.z.y), point(m.x.z, m.y.z, m.z.z));
}
fn multiply(a: Matrix, b: Matrix) -> Matrix {
    let t = transpose(b);
    return axes(apply(t, a.x), apply(t, a.y), apply(t, a.z));
}
fn diagonal(x: f64, y: f64, z: f64) -> Matrix {
    return axes(point(x, 0.0f64, 0.0f64), point(0.0f64, y, 0.0f64), point(0.0f64, 0.0f64, z));
}
fn identity() -> Matrix { return diagonal(1.0f64, 1.0f64, 1.0f64); }

fn pivot(m: Matrix, at: Point, position: Point) -> Transform {
    return Transform { axes: m, offset: sub(position, apply(m, at)) };
}
fn place(t: Transform, p: Point) -> Point { return add(apply(t.axes, p), t.offset); }

fn to_vec3(p: Point) -> Vec3<f32> { return vec3(f32_from_f64(p.x), f32_from_f64(p.y), f32_from_f64(p.z)); }
fn pack(t: Transform) -> Bone {
    return Bone { axis_x: to_vec3(t.axes.x), axis_y: to_vec3(t.axes.y), axis_z: to_vec3(t.axes.z), offset: to_vec3(t.offset) };
}

fn pi() -> f64 { return 3.141592653589793f64; }
fn tau() -> f64 { return 6.283185307179586f64; }
fn min(a: f64, b: f64) -> f64 { return if a < b { a } else { b }; }
fn max(a: f64, b: f64) -> f64 { return if a > b { a } else { b }; }
fn sat(x: f64) -> f64 { return min(1.0f64, max(0.0f64, x)); }
fn mix(a: f64, b: f64, t: f64) -> f64 { return a + (b - a) * t; }
fn smooth(x: f64) -> f64 { let t = sat(x); return t * t * (3.0f64 - 2.0f64 * t); }
fn wrap_angle(x: f64) -> f64 { return x - tau() * floor((x + pi()) / tau()); }

fn sin(x: f64) -> f64 {
    let phase = wrap_angle(x);
    let y = if phase > pi() * 0.5f64 { pi() - phase }
        else { if phase < -pi() * 0.5f64 { -pi() - phase } else { phase } };
    let q = y * y;
    // Taylor series on [-pi/2, pi/2], through the x^15 term.
    let hi = 1.0f64 / 6227020800.0f64 - q / 1307674368000.0f64;
    let mid = 1.0f64 / 362880.0f64 + q * (-1.0f64 / 39916800.0f64 + q * hi);
    return y * (1.0f64 + q * (-1.0f64 / 6.0f64 + q *
        (1.0f64 / 120.0f64 + q * (-1.0f64 / 5040.0f64 + q * mid))));
}
fn cos(x: f64) -> f64 { return sin(x + pi() * 0.5f64); }

fn atan_series(x: f64) -> f64 {
    // Alternating series after reducing to [-tan(pi/8), tan(pi/8)].
    let q = x * x;
    let tail = 1.0f64 / 17.0f64 + q * (-1.0f64 / 19.0f64 + q / 21.0f64);
    let mid = 1.0f64 / 9.0f64 + q * (-1.0f64 / 11.0f64 + q *
        (1.0f64 / 13.0f64 + q * (-1.0f64 / 15.0f64 + q * tail)));
    return x * (1.0f64 + q * (-1.0f64 / 3.0f64 + q *
        (1.0f64 / 5.0f64 + q * (-1.0f64 / 7.0f64 + q * mid))));
}
fn atan_unit(x: f64) -> f64 {
    return if x <= 0.414213562373095f64 { atan_series(x) }
        else { pi() * 0.25f64 + atan_series((x - 1.0f64) / (x + 1.0f64)) };
}
fn bearing(x: f64, z: f64) -> f64 {
    if x == 0.0f64 && z == 0.0f64 { return 0.0f64; }
    let ax = max(x, -x);
    let az = max(z, -z);
    let octant = if ax >= az { atan_unit(az / ax) } else { pi() * 0.5f64 - atan_unit(ax / az) };
    let angle = if x < 0.0f64 { pi() - octant } else { octant };
    return if z < 0.0f64 { -angle } else { angle };
}

fn exp_negative(x: f64) -> f64 {
    if x < -36.0f64 { return 0.0f64; }
    let r = x / 64.0f64;
    let series = repeat(10, 1.0f64, fn(i) => fn(result) => 1.0f64 + r * result / f64_from_u32(10 - i));
    return repeat(6, series, fn(i) => fn(result) => result * result);
}

fn wave(age: f64, duration: f64, speed: f64, damping: f64) -> f64 {
    let u = age / duration;
    return if age < 0.0f64 || u >= 1.0f64 { 0.0f64 }
        else { cos(age * speed * tau()) * exp_negative(-u * damping) * (1.0f64 - u) };
}

fn rotate_z(angle: f64) -> Matrix {
    let c = cos(angle);
    let s = sin(angle);
    return axes(point(c, -s, 0.0f64), point(s, c, 0.0f64), point(0.0f64, 0.0f64, 1.0f64));
}
fn rotate_y(angle: f64) -> Matrix {
    let c = cos(angle);
    let s = sin(angle);
    return axes(point(c, 0.0f64, s), point(0.0f64, 1.0f64, 0.0f64), point(-s, 0.0f64, c));
}

fn turn(a: Point, b: Point) -> Matrix {
    let c = dot(a, b);
    if c < -0.9999f64 { return diagonal(-1.0f64, -1.0f64, 1.0f64); }
    let v = cross(a, b);
    let k = 1.0f64 / (1.0f64 + c);
    return axes(
        point(1.0f64 - k * (v.y * v.y + v.z * v.z), k * v.x * v.y - v.z, k * v.x * v.z + v.y),
        point(k * v.x * v.y + v.z, 1.0f64 - k * (v.x * v.x + v.z * v.z), k * v.y * v.z - v.x),
        point(k * v.x * v.z - v.y, k * v.y * v.z + v.x, 1.0f64 - k * (v.x * v.x + v.y * v.y)));
}

fn stretch(start: Point, end: Point, base: Point, tip: Point) -> Transform {
    let rest = sub(end, start);
    let delta = sub(tip, base);
    let distance = max(0.03f64, magnitude(delta));
    let direction = unit(rest);
    let ratio = distance / magnitude(rest);
    let width = 1.0f64 / sqrt(ratio);
    let e = ratio - width;
    let x = direction.x;
    let y = direction.y;
    let z = direction.z;
    let resize = axes(point(width + e * x * x, e * x * y, e * x * z),
        point(e * y * x, width + e * y * y, e * y * z), point(e * z * x, e * z * y, width + e * z * z));
    return pivot(multiply(turn(direction, scale(delta, 1.0f64 / distance)), resize), start, base);
}

fn world(t: Transform, yaw: Matrix, origin: Point) -> Transform {
    return Transform { axes: multiply(yaw, t.axes), offset: add(apply(yaw, t.offset), origin) };
}
