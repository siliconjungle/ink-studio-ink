module StudioEdit;

import "bake.ink" as bake;
import "gaussian.ink" as gaussian;
import "rig.ink" as math;
import "sculpt.ink" as sculpt;

record Ray { origin: math.Point, direction: math.Point, near: f64, far: f64, }
record Brush { radius: f64, inset: f64, settings: bake.BakeSettings, material: bake.Material, }
record Cut { center: math.Point, brush: Brush, }
record Edit { base: bake.Blueprint, cuts: List<Cut>, undone: List<Cut>, }
record March { at: f64, distance: f64, }

fn double(v: Vec3<f32>) -> math.Point {
    return math.point(f64_from_f32(v.x), f64_from_f32(v.y), f64_from_f32(v.z));
}

fn screen_ray(camera: gaussian.Camera, x: f32, y: f32) -> Option<Ray> {
    let half = camera.half_viewport;
    if !(camera.focal > 0.0 && x >= 0.0 && y >= 0.0 && x < half.x * 2.0 && y < half.y * 2.0) { return None; }
    let u = f64_from_f32(x - half.x) / f64_from_f32(camera.focal);
    let v = f64_from_f32(half.y - y) / f64_from_f32(camera.focal);
    let offset = math.add(math.scale(double(camera.right), u), math.scale(double(camera.up), v));
    let eye = double(camera.eye);
    let forward = math.scale(double(camera.back), -1.0f64);
    let near = f64_from_f32(camera.near_clip);
    let far = f64_from_f32(camera.far_clip);
    if !camera.perspective { return Some(Ray { origin: math.add(eye, offset), direction: math.unit(forward), near: near, far: far }); }
    let direction = math.add(forward, offset);
    let stretch = math.magnitude(direction);
    return Some(Ray { origin: eye, direction: math.unit(direction), near: near * stretch, far: far * stretch });
}

fn point_on(ray: Ray, at: f64) -> math.Point {
    return math.add(ray.origin, math.scale(ray.direction, at));
}

fn probe(field: bake.Field, ray: Ray, at: f64) -> March {
    return March { at: at, distance: bake.distance(field, point_on(ray, at)) };
}

fn picked_point(field: bake.Field, ray: Ray) -> Option<math.Point> {
    if !(ray.far > ray.near && ray.near >= 0.0f64 && math.dot(ray.direction, ray.direction) > 0.0f64) { return None; }
    let result = repeat_until(512, probe(field, ray, ray.near),
        fn(march) => march.distance < 0.004f64 || march.at >= ray.far,
        fn(i) => fn(march) => probe(field, ray, march.at + math.max(march.distance * 0.8f64, 0.003f64)));
    if result.at > ray.far || result.distance >= 0.004f64 { return None; }
    let point = point_on(ray, result.at);
    let hit = bake.surface_hit(field, point);
    return if hit.surface > 0 && hit.surface < 4294967295 { Some(point) } else { None };
}

fn subtract(blueprint: bake.Blueprint, cut: Cut) -> bake.Blueprint {
    let radius = cut.brush.radius;
    let cutter = sculpt.ellipsoid(cut.center, None, radius, math.point(radius, radius, radius));
    let member = sculpt.Member { model: length(blueprint.models), group: 0, blend: 0.0f64, bump: 0.0f64, frequency: 0.0f64 };
    let scene = blueprint.scene;
    let palette = blueprint.palette;
    return bake.Blueprint { seed: blueprint.seed, models: blueprint.models.concat([cutter]), ground: blueprint.ground,
        scene: sculpt.SceneSpec { positive: scene.positive, negative: scene.negative.concat([member]) },
        settings: blueprint.settings.concat([cut.brush.settings]),
        palette: bake.Palette { terrain: palette.terrain, surfaces: palette.surfaces,
            cuts: palette.cuts.concat([cut.brush.material]) }, light: blueprint.light };
}

fn blueprint(edit: Edit) -> bake.Blueprint {
    return foldl(edit.cuts, edit.base, fn(cut) => fn(current) => subtract(current, cut));
}

pub fn start_edit(base: bake.Blueprint) -> Edit {
    return Edit { base: base, cuts: [], undone: [] };
}

fn stroke(edit: Edit, ray: Ray, brush: Brush) -> Option<Edit> {
    let current = blueprint(edit);
    let field = bake.prepare_bake(current.models, current.scene, current.seed, current.ground);
    return picked_point(field, ray).map(fn(point) =>
        Edit { base: edit.base, undone: [], cuts: edit.cuts.concat([
            Cut { center: math.add(point, math.scale(ray.direction, brush.inset)), brush: brush }]) });
}

pub fn carve(edit: Edit, camera: gaussian.Camera, x: f32, y: f32, brush: Brush) -> Option<Edit> {
    if !(is_finite(brush.radius) && brush.radius > 0.0f64 && is_finite(brush.inset)
        && brush.settings.spacing > 0.0f64 && brush.settings.normal_step > 0.0f64) { return None; }
    return screen_ray(camera, x, y).fold(fn(ray) => stroke(edit, ray, brush), fn(unit) => None);
}

pub fn undo_cut(edit: Edit) -> Edit {
    let size = length(edit.cuts);
    if size == 0 { return edit; }
    let last = edit.cuts.at_or(size - 1, none_cut());
    return Edit { base: edit.base, cuts: buffer(edit.cuts).pop().freeze(), undone: edit.undone.concat([last]) };
}

pub fn redo_cut(edit: Edit) -> Edit {
    let size = length(edit.undone);
    if size == 0 { return edit; }
    let last = edit.undone.at_or(size - 1, none_cut());
    return Edit { base: edit.base, cuts: edit.cuts.concat([last]), undone: buffer(edit.undone).pop().freeze() };
}

fn none_cut() -> Cut {
    return Cut { center: math.zero(), brush: Brush { radius: 0.0f64, inset: 0.0f64, settings: bake.no_job(),
        material: bake.Material { colors: [], bias: 0.0f64, alpha: 0.0 } } };
}

pub fn rebake(edit: Edit, march: bake.ShadowMarch) -> List<gaussian.WorldGaussian> {
    return bake.bake_sculpt_with_shadows(blueprint(edit), march);
}
