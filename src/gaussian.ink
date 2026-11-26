module Gaussian;

record Gaussian {
    center: Vec2<f32>,
    xx: f32,
    xy: f32,
    yy: f32,
    variance: f32,
    reach: f32,
    rgb: u32,
    alpha: f32,
}

record Ellipse {
    center: Vec2<f32>,
    axis_x: Vec2<f32>,
    axis_y: Vec2<f32>,
    rgb: u32,
    alpha: f32,
}

record WorldGaussian {
    position: Vec3<f32>,
    covariance0: Vec3<f32>,
    covariance1: Vec3<f32>,
    reach: f32,
    rgb: u32,
    alpha: f32,
}

record Camera {
    eye: Vec3<f32>,
    right: Vec3<f32>,
    up: Vec3<f32>,
    back: Vec3<f32>,
    half_viewport: Vec2<f32>,
    focal: f32,
    near_clip: f32,
    far_clip: f32,
    variance: f32,
    perspective: Bool,
}

fn absolute(x: f32) -> f32 {
    return if x < 0.0 { -x } else { x };
}

fn hidden() -> Ellipse {
    return Ellipse {
        center: vec2(0.0, 0.0),
        axis_x: vec2(0.0, 0.0),
        axis_y: vec2(0.0, 0.0),
        rgb: 0,
        alpha: 0.0,
    };
}

fn unit_direction(vector: Vec2<f32>) -> Vec2<f32> {
    let length = sqrt(vector.x * vector.x + vector.y * vector.y);
    return vec2(vector.x / length, vector.y / length);
}

// The screen-space covariance is symmetric. Its eigensystem supplies the
// principal axes of the quad, with a fixed orientation for circular splats.
fn project_one(splat: Gaussian, half_viewport: Vec2<f32>) -> Ellipse {
    let xx = splat.xx + splat.variance;
    let yy = splat.yy + splat.variance;
    let xy = splat.xy;
    if !(xx > 0.0 && yy > 0.0 && splat.alpha >= 0.004 && splat.reach > 0.0) {
        return hidden();
    }
    if absolute(splat.center.x) - splat.reach * sqrt(xx) >= half_viewport.x
        || absolute(splat.center.y) - splat.reach * sqrt(yy) >= half_viewport.y {
        return hidden();
    }
    let half_trace = (xx + yy) * 0.5;
    let half_difference = (xx - yy) * 0.5;
    let half_gap = sqrt(half_difference * half_difference + xy * xy);
    let major = half_trace + half_gap;
    let minor = (xx * yy - xy * xy) / major;
    if !(minor > 0.0 && major < 1e18) {
        return hidden();
    }
    let direction = if xx >= yy { vec2(major - yy, xy) } else { vec2(xy, major - xx) };
    let axis = if half_gap > 1e-12 { unit_direction(direction) } else { vec2(1.0, 0.0) };
    let long = splat.reach * sqrt(major);
    let short = splat.reach * sqrt(minor);
    return Ellipse {
        center: splat.center,
        axis_x: vec2(long * axis.x, long * axis.y),
        axis_y: vec2(short * -axis.y, short * axis.x),
        rgb: splat.rgb,
        alpha: splat.alpha,
    };
}

pub fn project(splats: List<Gaussian>, half_viewport: Vec2<f32>) -> List<Ellipse> {
    return splats.map(fn(splat) => project_one(splat, half_viewport));
}

fn dot3(a: Vec3<f32>, b: Vec3<f32>) -> f32 {
    return (a.x * b.x + a.y * b.y) + a.z * b.z;
}

fn clamped_slope(slope: f32, limit: f32) -> f32 {
    if slope > limit { return limit; }
    if slope < -limit { return -limit; }
    return slope;
}

fn projection_axis(basis: Vec3<f32>, back: Vec3<f32>, slope: f32, scale: f32) -> Vec3<f32> {
    return vec3(
        (basis.x + back.x * slope) * scale,
        (basis.y + back.y * slope) * scale,
        (basis.z + back.z * slope) * scale
    );
}

fn covariance_product(first: Vec3<f32>, rest: Vec3<f32>, v: Vec3<f32>) -> Vec3<f32> {
    return vec3(
        dot3(first, v),
        dot3(vec3(first.y, rest.x, rest.y), v),
        dot3(vec3(first.z, rest.y, rest.z), v)
    );
}

fn project_world_one(splat: WorldGaussian, camera: Camera) -> Ellipse {
    if !(splat.alpha >= 0.004 && splat.reach > 0.0) { return hidden(); }
    let position = vec3(splat.position.x - camera.eye.x,
        splat.position.y - camera.eye.y, splat.position.z - camera.eye.z);
    let depth = -dot3(camera.back, position);
    if !(depth >= camera.near_clip && depth <= camera.far_clip && camera.focal > 0.0) {
        return hidden();
    }
    if camera.perspective && !(depth > 0.0) { return hidden(); }
    let x = dot3(camera.right, position);
    let y = dot3(camera.up, position);
    let scale = if camera.perspective { camera.focal / depth } else { camera.focal };
    let slope_x = if camera.perspective {
        clamped_slope(x / depth, 1.3 * camera.half_viewport.x / camera.focal)
    } else { 0.0 };
    let slope_y = if camera.perspective {
        clamped_slope(y / depth, 1.3 * camera.half_viewport.y / camera.focal)
    } else { 0.0 };
    let jx = projection_axis(camera.right, camera.back, slope_x, scale);
    let jy = projection_axis(camera.up, camera.back, slope_y, scale);
    let cov_x = covariance_product(splat.covariance0, splat.covariance1, jx);
    let cov_y = covariance_product(splat.covariance0, splat.covariance1, jy);
    return project_one(Gaussian {
        center: vec2(x * scale, y * scale),
        xx: dot3(jx, cov_x),
        xy: dot3(jy, cov_x),
        yy: dot3(jy, cov_y),
        variance: if camera.variance >= 0.0 { camera.variance } else { 0.3 },
        reach: splat.reach,
        rgb: splat.rgb,
        alpha: splat.alpha,
    }, camera.half_viewport);
}

// Covariance words follow Studio's resident Point layout: xx, xy, xz,
// then yy, yz, zz. Camera axes are supplied by the host in world space.
pub fn project_world(splats: List<WorldGaussian>, camera: Camera) -> List<Ellipse> {
    return splats.map(fn(splat) => project_world_one(splat, camera));
}

fn depth_order(splat: WorldGaussian, camera: Camera, index: u32) -> u64 {
    let position = vec3(
        splat.position.x - camera.eye.x,
        splat.position.y - camera.eye.y,
        splat.position.z - camera.eye.z
    );
    let depth = -dot3(camera.back, position);
    let bits = f32_bits(if depth == 0.0 { 0.0 } else { depth });
    let ascending = if word_and(bits, 2147483648) != 0 {
        4294967295 - bits
    } else { bits + 2147483648 };
    let depth_key = if is_finite(depth) { 4294967295 - ascending } else { 4294967295 };
    return word_widen_u32_to_u64(depth_key) * 4294967296 + word_widen_u32_to_u64(index);
}

// Retain input order for equal depths by sorting the original index as the
// low half of the key. The renderer can consume the sorted list directly.
pub fn project_sorted_world(splats: List<WorldGaussian>, camera: Camera) -> List<Ellipse> {
    let keys = splats.map_indexed(fn(index) => fn(splat) => depth_order(splat, camera, index)).sort();
    let fallback = WorldGaussian {
        position: vec3(0.0, 0.0, 0.0),
        covariance0: vec3(0.0, 0.0, 0.0),
        covariance1: vec3(0.0, 0.0, 0.0),
        reach: 0.0,
        rgb: 0,
        alpha: 0.0,
    };
    return keys.map(fn(key) =>
        project_world_one(splats.at_or(word_narrow_u64_to_u32(key), fallback), camera));
}
