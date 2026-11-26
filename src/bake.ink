module StudioBake;

import "rig.ink" as math;
import "noise.ink" as noise;
import "terrain.ink" as terrain;
import "sculpt.ink" as sculpt;
import "sampling.ink" as sampling;
import "marks.ink" as marks;
import "gaussian.ink" as gaussian;

record Field {
    scene: sculpt.Scene,
    tables: noise.Noise,
    ground: Option<terrain.HeightGrid>,
}

record BakeSettings {
    spacing: f64,
    reach: f64,
    normal_step: f64,
    occlusion_step: f64,
    occlusion_strength: f64,
}

record Surface {
    position: math.Point,
    normal: math.Point,
    surface: u32,
    cut: u32,
    occlusion: f64,
    spacing: f64,
}

pub fn prepare_bake(models: List<sculpt.Model>, scene: sculpt.SceneSpec, seed: u32, ground: Option<terrain.HeightGrid>) -> Field {
    return Field { scene: sculpt.prepare_scene(models, scene), tables: noise.make_noise(seed ^ 2654435769), ground: ground };
}

pub fn surface_hit(field: Field, point: math.Point) -> sculpt.SurfaceHit {
    let distance = field.ground.fold(fn(grid) => terrain.terrain_sdf(grid, point.x, point.y, point.z), fn(unit) => 1e9f64);
    return sculpt.scene_hit(field.scene, field.tables, point, distance);
}

fn distance(field: Field, point: math.Point) -> f64 { return surface_hit(field, point).distance; }

fn axis_point(point: math.Point, dx: f64, dy: f64, dz: f64) -> math.Point {
    return math.point(point.x + dx, point.y + dy, point.z + dz);
}

fn absolute(x: f64) -> f64 { return math.max(x, -x); }

record Gradient { direction: math.Point, slope: f64, }

fn axial_gradient(dx: f64, dy: f64, dz: f64, step: f64) -> Gradient {
    let length = math.magnitude(math.point(dx, dy, dz));
    let safe_length = if length > 0.0f64 { length } else { 1.0f64 };
    return Gradient { direction: math.point(dx / safe_length, dy / safe_length, dz / safe_length),
        slope: math.max(0.6f64, safe_length / step) };
}

fn gradient(field: Field, point: math.Point, d: f64, step: f64) -> Gradient {
    return axial_gradient(
        distance(field, axis_point(point, step, 0.0f64, 0.0f64)) - d,
        distance(field, axis_point(point, 0.0f64, step, 0.0f64)) - d,
        distance(field, axis_point(point, 0.0f64, 0.0f64, step)) - d, step);
}

record Probe { point: math.Point, distance: f64, }

fn advance(field: Field, p: Probe, step: f64) -> Probe {
    let g = gradient(field, p.point, p.distance, step);
    let point = math.sub(p.point, math.scale(g.direction, p.distance / g.slope));
    return Probe { point: point, distance: distance(field, point) };
}

fn own_distance(model: sculpt.Model, member: sculpt.Member, tables: noise.Noise, point: math.Point) -> f64 {
    return sculpt.bumped_distance(model, member, tables, point);
}

fn own_advance(model: sculpt.Model, member: sculpt.Member, tables: noise.Noise, current: Probe) -> Probe {
    let p = current.point;
    let d = current.distance;
    let e = 0.006f64;
    let g = axial_gradient(
        own_distance(model, member, tables, axis_point(p, e, 0.0f64, 0.0f64)) - d,
        own_distance(model, member, tables, axis_point(p, 0.0f64, e, 0.0f64)) - d,
        own_distance(model, member, tables, axis_point(p, 0.0f64, 0.0f64, e)) - d, e);
    let point = math.sub(p, math.scale(g.direction, d / g.slope));
    return Probe { point: point, distance: own_distance(model, member, tables, point) };
}

fn seed_point(model: sculpt.Model, member: sculpt.Member, tables: noise.Noise, point: math.Point, reach: f64) -> math.Point {
    if reach <= 0.0f64 { return point; }
    let first = Probe { point: point, distance: own_distance(model, member, tables, point) };
    let done = repeat_until(8, first, fn(p) => absolute(p.distance) < 0.002f64,
        fn(i) => fn(p) => own_advance(model, member, tables, p));
    return done.point;
}

fn tap(field: Field, point: math.Point, n: math.Point, h: f64, weight: f64) -> f64 {
    let d = distance(field, math.add(point, math.scale(n, h)));
    return math.max(0.0f64, h - d) * weight / h;
}

fn ambient_occlusion(field: Field, point: math.Point, normal: math.Point, step: f64, strength: f64) -> f64 {
    if step <= 0.0f64 || strength <= 0.0f64 { return 1.0f64; }
    let first = tap(field, point, normal, step, 1.0f64);
    let second = tap(field, point, normal, step * 2.0f64, 0.6f64);
    let third = tap(field, point, normal, step * 3.0f64, 0.6f64 * 0.6f64);
    return math.sat(1.0f64 - strength * (first + second + third) / 1.96f64);
}

fn surface(field: Field, start: math.Point, member: sculpt.Member, settings: BakeSettings) -> Option<Surface> {
    let d = distance(field, start);
    let limit = settings.spacing * 0.7f64 + member.bump;
    if d > limit + settings.reach || d < -(limit + member.blend * 0.4f64 + settings.reach) { return None; }
    let projected = repeat_until(7, Probe { point: start, distance: d }, fn(p) => absolute(p.distance) <= 0.004f64,
        fn(i) => fn(p) => advance(field, p, settings.normal_step));
    if absolute(projected.distance) > settings.spacing * 0.5f64 { return None; }
    let point = projected.point;
    let hit = surface_hit(field, point);
    if hit.surface == 4294967295 { return None; }
    let normal = gradient(field, point, projected.distance, settings.normal_step).direction;
    let ao = ambient_occlusion(field, point, normal, settings.occlusion_step, settings.occlusion_strength);
    return Some(Surface { position: point, normal: normal, surface: hit.surface, cut: hit.cut,
        occlusion: ao, spacing: settings.spacing });
}

fn append_surface(out: Buffer<Surface>, field: Field, model: sculpt.Model, member: sculpt.Member,
    sample: math.Point, settings: BakeSettings) -> Buffer<Surface> {
    let start = seed_point(model, member, field.tables, sample, settings.reach);
    return surface(field, start, member, settings).fold(fn(surface) => out.push(surface), fn(unit) => out);
}

pub fn project_candidates(field: Field, model: sculpt.Model, member: sculpt.Member,
    candidates: List<math.Point>, settings: BakeSettings) -> List<Surface> {
    if !(settings.spacing > 0.0f64 && settings.normal_step > 0.0f64) { return []; }
    let out: Buffer<Surface> = Buffer.empty();
    return repeat_until(length(candidates), out, fn(out) => false,
        fn(i) => fn(out) => append_surface(out, field, model, member, candidates.at_or(i, math.zero()), settings)).freeze();
}

pub fn project_model(field: Field, model: sculpt.Model, member: sculpt.Member, settings: BakeSettings) -> List<Surface> {
    let spacing = settings.spacing * if member.bump > 0.0f64 { 0.8f64 } else { 1.0f64 };
    return project_candidates(field, model, member, sampling.model_candidates(model, spacing), settings);
}

record ProjectionJob {
    member: sculpt.Member,
    settings: BakeSettings,
    candidates: List<math.Point>,
    ghost: Bool,
}

record ShadowMarch {
    steps: u32,
    distance: f64,
    softness: f64,
    legacy_empty_space: Bool,
}
record DirectionalLight { direction: math.Point, march: ShadowMarch, }
record ShadowRay { distance: f64, visibility: f64, }
record Lamp {
    position: math.Point,
    radius: f64,
    strength: f64,
    casts_shadows: Bool,
}
record LampSample { power: f64, visibility: f64, }
record Lighting { sun: DirectionalLight, lamps: List<Lamp>, }
record LitSurface { surface: Surface, visibility: f64, lamps: List<LampSample>, }

fn shadow_step(field: Field, origin: math.Point, sun: DirectionalLight, ray: ShadowRay) -> ShadowRay {
    let h = distance(field, math.add(origin, math.scale(sun.direction, ray.distance)));
    if h < 0.004f64 { return ShadowRay { distance: ray.distance, visibility: 0.0f64 }; }
    let visibility = if h < 1.0f64 || sun.march.legacy_empty_space {
        math.min(ray.visibility, sun.march.softness * h / ray.distance)
    } else { ray.visibility };
    return ShadowRay { distance: ray.distance + math.min(0.9f64, math.max(0.05f64, h)), visibility: visibility };
}

fn sun_visibility(field: Field, surface: Surface, light: DirectionalLight) -> f64 {
    if math.dot(surface.normal, light.direction) <= 0.0f64 { return 1.0f64; }
    let start = ShadowRay { distance: 0.07f64, visibility: 1.0f64 };
    let origin = math.add(surface.position, math.scale(surface.normal, 0.05f64));
    let done = repeat_until(light.march.steps, start,
        fn(ray) => ray.visibility <= 0.0f64 || ray.distance >= light.march.distance,
        fn(i) => fn(ray) => shadow_step(field, origin, light, ray));
    return done.visibility;
}

fn lamp_step(field: Field, origin: math.Point, direction: math.Point, ray: ShadowRay) -> ShadowRay {
    let h = distance(field, math.add(origin, math.scale(direction, ray.distance)));
    if h < 0.004f64 { return ShadowRay { distance: ray.distance, visibility: 0.12f64 }; }
    return ShadowRay { distance: ray.distance + math.max(0.06f64, h), visibility: 1.0f64 };
}

fn sample_lamp(field: Field, surface: Surface, lamp: Lamp, steps: u32) -> LampSample {
    let offset = math.sub(lamp.position, surface.position);
    let dist = math.magnitude(offset);
    if dist > lamp.radius || lamp.radius <= 0.0f64 { return LampSample { power: 0.0f64, visibility: 1.0f64 }; }
    let normal = surface.normal;
    let nd = math.dot(normal, offset) / (if dist > 0.0f64 { dist } else { 1.0f64 });
    let fade = 1.0f64 - dist / lamp.radius;
    let power = fade * fade * lamp.strength * (0.2f64 + 0.8f64 * math.max(nd, 0.0f64));
    if !lamp.casts_shadows || power <= 0.03f64 || nd <= 0.0f64 {
        return LampSample { power: power, visibility: 1.0f64 };
    }
    let origin = math.add(surface.position, math.scale(normal, 0.05f64));
    let direction = math.point(offset.x / dist, offset.y / dist, offset.z / dist);
    let ray = repeat_until(steps, ShadowRay { distance: 0.08f64, visibility: 1.0f64 },
        fn(ray) => ray.visibility < 1.0f64 || ray.distance >= dist - 0.12f64,
        fn(i) => fn(ray) => lamp_step(field, origin, direction, ray));
    return LampSample { power: power * ray.visibility, visibility: ray.visibility };
}

record GhostProbe { point: math.Point, distance: f64, normal: math.Point, }

fn ghost_step(model: sculpt.Model, member: sculpt.Member, tables: noise.Noise, probe: GhostProbe, step: f64) -> GhostProbe {
    let p = probe.point;
    let d = probe.distance;
    let g = axial_gradient(
        own_distance(model, member, tables, axis_point(p, step, 0.0f64, 0.0f64)) - d,
        own_distance(model, member, tables, axis_point(p, 0.0f64, step, 0.0f64)) - d,
        own_distance(model, member, tables, axis_point(p, 0.0f64, 0.0f64, step)) - d, step);
    if member.bump <= 0.0f64 { return GhostProbe { point: p, distance: d, normal: g.direction }; }
    let shifted = math.sub(p, math.scale(g.direction, d / g.slope));
    return GhostProbe { point: shifted, distance: own_distance(model, member, tables, shifted), normal: g.direction };
}

fn ghost_surface(field: Field, model: sculpt.Model, job: ProjectionJob, p: math.Point) -> Surface {
    let probe = GhostProbe { point: p, distance: own_distance(model, job.member, field.tables, p), normal: math.zero() };
    let steps: u32 = if job.member.bump > 0.0f64 { 5 } else { 1 };
    let result = repeat_until(steps, probe, fn(probe) => false,
        fn(i) => fn(probe) => ghost_step(model, job.member, field.tables, probe, job.settings.normal_step));
    let ao = ambient_occlusion(field, result.point, result.normal, job.settings.occlusion_step, job.settings.occlusion_strength);
    return Surface { position: result.point, normal: result.normal, surface: 0, cut: 0, occlusion: ao, spacing: job.settings.spacing };
}

fn inside_projection_area(area: terrain.Rect, p: math.Point) -> Bool {
    return p.x > area.x0 && p.x < area.x1 && p.z > area.z0 && p.z < area.z1;
}

fn project_job(field: Field, models: List<sculpt.Model>, area: terrain.Rect, job: ProjectionJob) -> List<Surface> {
    let points = job.candidates.filter(fn(p) => inside_projection_area(area, p));
    let model = models.at_or(job.member.model, sculpt.no_model());
    if job.ghost { return points.map(fn(p) => ghost_surface(field, model, job, p)); }
    return project_candidates(field, model, job.member, points, job.settings);
}

pub fn project_cell(models: List<sculpt.Model>, scene: sculpt.SceneSpec, seed: u32, ground: terrain.HeightGrid,
    area: terrain.Rect, jobs: List<ProjectionJob>, lighting: Lighting) -> List<List<LitSurface>> {
    let field = Field { scene: sculpt.index_bake(sculpt.prepare_scene(models, scene)),
        tables: noise.make_noise(seed ^ 2654435769), ground: Some(ground) };
    return jobs.map(fn(job) => project_job(field, models, area, job).map(fn(surface) =>
        LitSurface { surface: surface, visibility: sun_visibility(field, surface, lighting.sun),
            lamps: lighting.lamps.map(fn(lamp) => sample_lamp(field, surface, lamp, lighting.sun.march.steps)) }));
}

record Material { colors: List<u32>, bias: f64, alpha: f32, }
record Palette { terrain: Material, surfaces: List<Material>, cuts: List<Material>, }
record Paint { direction: math.Point, ambient: f64, sky: f64, sun: f64, fat: f64, }

fn material_for(palette: Palette, s: Surface) -> Material {
    let base = if s.surface == 0 { palette.terrain } else { palette.surfaces.at_or(s.surface - 1, palette.terrain) };
    if s.cut == 0 { return base; }
    return palette.cuts.at_or(s.cut - 1, base);
}

fn color(material: Material, light: f64) -> u32 {
    let count = length(material.colors);
    if count == 0 { return 0; }
    let tone = math.sat(light + material.bias) * f64_from_u32(count);
    let channel = u32_from_f64(floor(tone)).fold(fn(i) => i, fn(unit) => 0);
    return material.colors.at_or(channel, material.colors.at_or(count - 1, 0));
}

fn to_splat(s: Surface, palette: Palette, paint: Paint, visibility: f64) -> gaussian.WorldGaussian {
    let material = material_for(palette, s);
    let direct = math.max(0.0f64, math.dot(s.normal, paint.direction)) * visibility;
    let light = s.occlusion * (paint.ambient + paint.sky * (0.5f64 + s.normal.y * 0.5f64)) + paint.sun * direct;
    let axial = marks.axial_mark(s.normal, s.spacing * 0.3f64, s.spacing * paint.fat);
    let cov = axial.fold(fn(mark) => mark.covariance, fn(error) => marks.round_mark(s.spacing * paint.fat));
    return gaussian.WorldGaussian { position: math.to_vec3(s.position), covariance0: math.to_vec3(cov.first),
        covariance1: math.to_vec3(cov.rest), reach: 3.0, rgb: color(material, light), alpha: material.alpha };
}

pub fn paint_surfaces(surfaces: List<Surface>, palette: Palette, light: Paint) -> List<gaussian.WorldGaussian> {
    return surfaces.map(fn(s) => to_splat(s, palette, light, 1.0f64));
}

record Blueprint {
    seed: u32,
    models: List<sculpt.Model>,
    scene: sculpt.SceneSpec,
    ground: Option<terrain.HeightGrid>,
    settings: List<BakeSettings>,
    palette: Palette,
    light: Paint,
}

fn no_job() -> BakeSettings {
    return BakeSettings { spacing: 0.0f64, reach: 0.0f64, normal_step: 0.012f64,
        occlusion_step: 0.0f64, occlusion_strength: 0.0f64 };
}

fn part(blueprint: Blueprint, field: Field, id: u32, member: sculpt.Member) -> List<Surface> {
    let settings = blueprint.settings.at_or(id, no_job());
    let model = blueprint.models.at_or(member.model, sculpt.no_model());
    return project_model(field, model, member, settings);
}

fn sample_blueprint(blueprint: Blueprint, field: Field) -> List<Surface> {
    let members = blueprint.scene.positive.concat(blueprint.scene.negative);
    let batches = members.map_indexed(fn(id) => fn(member) => part(blueprint, field, id, member));
    return foldl(batches, [], fn(batch) => fn(out) => out.concat(batch));
}

pub fn bake_surfaces(blueprint: Blueprint) -> List<Surface> {
    return sample_blueprint(blueprint, prepare_bake(blueprint.models, blueprint.scene, blueprint.seed, blueprint.ground));
}

pub fn bake_sculpt(blueprint: Blueprint) -> List<gaussian.WorldGaussian> {
    return paint_surfaces(bake_surfaces(blueprint), blueprint.palette, blueprint.light);
}

pub fn bake_sculpt_with_shadows(blueprint: Blueprint, march: ShadowMarch) -> List<gaussian.WorldGaussian> {
    let field = prepare_bake(blueprint.models, blueprint.scene, blueprint.seed, blueprint.ground);
    let sun = DirectionalLight { direction: blueprint.light.direction, march: march };
    return sample_blueprint(blueprint, field).map(fn(surface) =>
        to_splat(surface, blueprint.palette, blueprint.light, sun_visibility(field, surface, sun)));
}
