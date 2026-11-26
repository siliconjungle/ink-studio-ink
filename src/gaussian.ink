module Gaussian;

import "rig.ink" as rig;

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

fn depth_rank(center: Vec3<f32>, camera: Camera) -> u32 {
    let position = vec3(
        center.x - camera.eye.x,
        center.y - camera.eye.y,
        center.z - camera.eye.z
    );
    let depth = -dot3(camera.back, position);
    let bits = f32_bits(if depth == 0.0 { 0.0 } else { depth });
    let ascending = if word_and(bits, 2147483648) != 0 {
        4294967295 - bits
    } else { bits + 2147483648 };
    return if is_finite(depth) { 4294967295 - ascending } else { 4294967295 };
}

fn indexed_depth(depth: u32, index: u32) -> u64 {
    return word_widen_u32_to_u64(depth) * 4294967296 + word_widen_u32_to_u64(index);
}

fn depth_order(center: Vec3<f32>, camera: Camera, index: u32) -> u64 {
    return indexed_depth(depth_rank(center, camera), index);
}

fn absent_world() -> WorldGaussian {
    return WorldGaussian {
        position: vec3(0.0, 0.0, 0.0),
        covariance0: vec3(0.0, 0.0, 0.0),
        covariance1: vec3(0.0, 0.0, 0.0),
        reach: 0.0,
        rgb: 0,
        alpha: 0.0,
    };
}

// Retain input order for equal depths by sorting the original index as the
// low half of the key. The renderer can consume the sorted list directly.
pub fn project_sorted_world(splats: List<WorldGaussian>, camera: Camera) -> List<Ellipse> {
    let keys = splats.map_indexed(fn(index) => fn(splat) => depth_order(splat.position, camera, index)).sort();
    return keys.map(fn(key) =>
        project_world_one(splats.at_or(word_narrow_u64_to_u32(key), absent_world()), camera));
}

fn legacy_color(value: f32) -> u32 {
    return u32_from_f32(value).fold(fn(rgb) => word_and(rgb, 16777215), fn(unit) => 0);
}

fn legacy_row(data: List<f32>, offset: u32) -> WorldGaussian {
    return WorldGaussian {
        position: vec3(data.at_or(offset, 0.0), data.at_or(offset + 1, 0.0), data.at_or(offset + 2, 0.0)),
        covariance0: vec3(data.at_or(offset + 4, 0.0), data.at_or(offset + 5, 0.0), data.at_or(offset + 6, 0.0)),
        covariance1: vec3(data.at_or(offset + 8, 0.0), data.at_or(offset + 9, 0.0), data.at_or(offset + 10, 0.0)),
        reach: 3.0,
        rgb: legacy_color(data.at_or(offset + 7, 0.0)),
        alpha: data.at_or(offset + 3, 0.0),
    };
}

// Import the static attributes of complete sixteen-float Studio builder rows.
pub fn import_builder_splats(data: List<f32>) -> List<WorldGaussian> {
    let rows = buffer_fill(quot_or(length(data), 16, 0), 0).freeze();
    return rows.map_indexed(fn(index) => fn(unused) => legacy_row(data, index * 16));
}

record ActorPlacement {
    first: u32,
    origin: Vec3<f32>,
    forward: Vec2<f32>,
}

// A yaw turns the local +X axis toward the unit XZ facing vector.
fn yaw_center(center: Vec3<f32>, actor: ActorPlacement) -> Vec3<f32> {
    return vec3(actor.forward.x * center.x - actor.forward.y * center.z + actor.origin.x,
        center.y + actor.origin.y, actor.forward.y * center.x + actor.forward.x * center.z + actor.origin.z);
}

fn yaw_one(splat: WorldGaussian, actor: ActorPlacement) -> WorldGaussian {
    let x_axis = vec3(actor.forward.x, 0.0, -actor.forward.y);
    let y_axis = vec3(0.0, 1.0, 0.0);
    let z_axis = vec3(actor.forward.y, 0.0, actor.forward.x);
    let cx = covariance_product(splat.covariance0, splat.covariance1, x_axis);
    let cy = covariance_product(splat.covariance0, splat.covariance1, y_axis);
    let cz = covariance_product(splat.covariance0, splat.covariance1, z_axis);
    return WorldGaussian {
        position: yaw_center(splat.position, actor),
        covariance0: vec3(dot3(x_axis, cx), dot3(x_axis, cy), dot3(x_axis, cz)),
        covariance1: vec3(dot3(y_axis, cy), dot3(y_axis, cz), dot3(z_axis, cz)),
        reach: splat.reach,
        rgb: splat.rgb,
        alpha: splat.alpha,
    };
}

// The actor occupies the final rows of the buffer. Sort on world-space
// centers so terrain and actor occlude each other in the same raster pass.
pub fn project_sorted_actor(splats: List<WorldGaussian>, camera: Camera, actor: ActorPlacement) -> List<Ellipse> {
    let keys = splats.map_indexed(fn(index) => fn(splat) =>
        depth_order(if index >= actor.first { yaw_center(splat.position, actor) } else { splat.position },
            camera, index)).sort();
    return keys.map(fn(key) => project_actor_key(splats, camera, actor, key));
}

fn project_actor_key(splats: List<WorldGaussian>, camera: Camera, actor: ActorPlacement, key: u64) -> Ellipse {
    let index = word_narrow_u64_to_u32(key);
    let splat = splats.at_or(index, absent_world());
    return project_world_one(if index >= actor.first { yaw_one(splat, actor) } else { splat }, camera);
}

record SkinPoint {
    center: Vec3<f32>,
    covariance0: Vec3<f32>,
    covariance1: Vec3<f32>,
    normal: Vec3<f32>,
    joints: Vec2<u32>,
    weight: f32,
    shade: f32,
    palette: Vec4<u32>,
    tones: u32,
    eye: Bool,
    alpha: f32,
}

fn identity_bone() -> rig.Bone {
    return rig.Bone { axis_x: vec3(1.0, 0.0, 0.0), axis_y: vec3(0.0, 1.0, 0.0),
        axis_z: vec3(0.0, 0.0, 1.0), offset: vec3(0.0, 0.0, 0.0) };
}

fn blend_vector(a: Vec3<f32>, b: Vec3<f32>, w: f32) -> Vec3<f32> {
    let u = 1.0 - w;
    return vec3(a.x * u + b.x * w, a.y * u + b.y * w, a.z * u + b.z * w);
}

fn blend_bones(a: rig.Bone, b: rig.Bone, w: f32) -> rig.Bone {
    return rig.Bone { axis_x: blend_vector(a.axis_x, b.axis_x, w), axis_y: blend_vector(a.axis_y, b.axis_y, w),
        axis_z: blend_vector(a.axis_z, b.axis_z, w), offset: blend_vector(a.offset, b.offset, w) };
}

fn skin_color(splat: SkinPoint, bone: rig.Bone, light: rig.RigLight) -> u32 {
    if splat.tones <= 1 { return splat.palette.x; }
    let n = vec3(dot3(bone.axis_x, splat.normal), dot3(bone.axis_y, splat.normal), dot3(bone.axis_z, splat.normal));
    let length = sqrt(dot3(n, n));
    let lit = light.ambient + light.diffuse * (0.5 + 0.5 * if length > 0.0 { dot3(n, light.sun) / length } else { 0.0 }) + splat.shade;
    let tone = lit * f32_from_u32(splat.tones);
    if tone < 1.0 { return splat.palette.x; }
    if tone < 2.0 { return splat.palette.y; }
    return if tone < 3.0 { splat.palette.z } else { splat.palette.w };
}

fn skin_one(splat: SkinPoint, bones: List<rig.Bone>, light: rig.RigLight) -> WorldGaussian {
    let a = bones.at_or(splat.joints.x, identity_bone());
    let bone = if splat.weight > 0.0 { blend_bones(a, bones.at_or(splat.joints.y, a), splat.weight) } else { a };
    let x = bone.axis_x;
    let y = bone.axis_y;
    let z = bone.axis_z;
    let cx = covariance_product(splat.covariance0, splat.covariance1, x);
    let cy = covariance_product(splat.covariance0, splat.covariance1, y);
    let cz = covariance_product(splat.covariance0, splat.covariance1, z);
    let eye = if splat.eye { light.blink } else { 1.0 };
    return WorldGaussian {
        position: vec3(dot3(x, splat.center) + bone.offset.x, dot3(y, splat.center) + bone.offset.y,
            dot3(z, splat.center) + bone.offset.z),
        covariance0: vec3(dot3(x, cx), dot3(x, cy) * eye, dot3(x, cz)),
        covariance1: vec3(dot3(y, cy) * eye * eye, dot3(y, cz) * eye, dot3(z, cz)),
        reach: 3.0, rgb: skin_color(splat, bone, light), alpha: splat.alpha,
    };
}

pub fn skin_world(rest: List<SkinPoint>, bones: List<rig.Bone>, light: rig.RigLight) -> List<WorldGaussian> {
    return rest.map(fn(splat) => skin_one(splat, bones, light));
}

record DepthEllipse {
    depth: u32,
    ellipse: Ellipse,
}

fn project_tagged(splat: WorldGaussian, camera: Camera) -> DepthEllipse {
    let ellipse = project_world_one(splat, camera);
    return DepthEllipse { depth: if ellipse.alpha > 0.0 { depth_rank(splat.position, camera) } else { 0 },
        ellipse: ellipse };
}

fn visible_world(splats: List<WorldGaussian>, camera: Camera) -> List<DepthEllipse> {
    return splats.map(fn(splat) => project_tagged(splat, camera)).filter(fn(entry) => entry.ellipse.alpha > 0.0);
}

// Project and compact each resident input ahead of the shared depth sort.
// Stable compaction preserves the scene's original order for tied depths.
pub fn project_sorted_scene(terrain: List<WorldGaussian>, actors: List<WorldGaussian>, camera: Camera) -> List<Ellipse> {
    let visible = visible_world(terrain, camera).concat(visible_world(actors, camera));
    let keys = visible.map_indexed(fn(index) => fn(row) => indexed_depth(row.depth, index)).sort();
    let fallback = DepthEllipse { depth: 0, ellipse: hidden() };
    return keys.map(fn(key) => visible.at_or(word_narrow_u64_to_u32(key), fallback).ellipse);
}
