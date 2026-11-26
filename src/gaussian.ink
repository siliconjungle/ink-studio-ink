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
