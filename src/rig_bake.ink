module StudioRigBake;

import "rig.ink" as math;
import "noise.ink" as noise;
import "sculpt.ink" as sculpt;
import "bake.ink" as bake;
import "marks.ink" as marks;
import "gaussian.ink" as gaussian;

record Band { bottom: f64, top: f64, }
record Binding {
    joints: Vec2<u32>,
    blend: Option<Band>,
    palette: Vec4<u32>,
    tones: u32,
    bias: f64,
    alpha: f32,
    eye: Bool,
}
record Part {
    geometry: sculpt.Model,
    group: u32,
    blend: f64,
    spacing: f64,
    binding: Option<Binding>,
}
record RigSculpt {
    solids: List<Part>,
    cuts: List<Part>,
    ghosts: List<Part>,
    occlusion_step: f64,
    occlusion_strength: f64,
}

fn member(part: Part, index: u32) -> sculpt.Member {
    return sculpt.Member { model: index, group: part.group, blend: part.blend, bump: 0.0f64, frequency: 0.0f64 };
}

fn bind_sample(surface: bake.Surface, binding: Binding, random: u32, index: u32) -> gaussian.SkinPoint {
    let p = surface.position;
    let n = surface.normal;
    let up = if sculpt.abs(n.y) > 0.95f64 { math.point(1.0f64, 0.0f64, 0.0f64) } else { math.point(0.0f64, 1.0f64, 0.0f64) };
    let tangent = math.unit(math.cross(up, n));
    let width = surface.spacing * 0.68f64;
    let cov = marks.surface_mark(n, tangent, width, width, surface.spacing * 0.22f64);
    let weight = binding.blend.fold(fn(band) => math.smooth((p.y - band.bottom) / (band.top - band.bottom)), fn(unit) => 0.0f64);
    let jitter = -0.06f64 + 0.12f64 * noise.fraction(noise.random_word(random, index));
    let shade = binding.bias + (surface.occlusion - 1.0f64) * 0.6f64 + jitter;
    return gaussian.SkinPoint { center: math.to_vec3(p), covariance0: math.to_vec3(cov.first), covariance1: math.to_vec3(cov.rest),
        normal: math.to_vec3(n), joints: binding.joints, weight: f32_from_f64(weight), shade: f32_from_f64(shade),
        palette: binding.palette, tones: binding.tones, eye: binding.eye, alpha: binding.alpha };
}

record Bindings { solid: List<Option<Binding>>, cut: List<Option<Binding>>, }

fn captured(surface: bake.Surface, tags: Bindings, ghost: Bool, source: Part) -> Option<Binding> {
    if ghost { return source.binding; }
    let solid = tags.solid.at_or(surface.surface - 1, None);
    if surface.cut == 0 { return solid; }
    return tags.cut.at_or(surface.cut - 1, None).fold(fn(tag) => Some(tag), fn(unit) => solid);
}

record Capture { rows: Buffer<gaussian.SkinPoint>, count: u32, }

fn capture_sample(out: Capture, surface: bake.Surface, tag: Binding, random: u32) -> Capture {
    return Capture { rows: out.rows.push(bind_sample(surface, tag, random, out.count)), count: out.count + 1 };
}

fn capture_part(field: bake.Field, authored: RigSculpt, tags: Bindings, out: Capture, part: Part, ghost: Bool, random: u32) -> Capture {
    let settings = bake.BakeSettings { spacing: part.spacing, reach: 0.0f64, normal_step: 0.012f64,
        occlusion_step: authored.occlusion_step, occlusion_strength: if ghost { 0.0f64 } else { authored.occlusion_strength } };
    let shape = member(part, 0);
    let surfaces = if ghost { bake.project_ghost(field, part.geometry, shape, settings) }
        else { bake.project_model(field, part.geometry, shape, settings) };
    return foldl(surfaces, out, fn(sample) => fn(out) => captured(sample, tags, ghost, part).fold(
        fn(tag) => capture_sample(out, sample, tag, random), fn(unit) => out));
}

// Resolving the owner after projection keeps a row bound to the visible
// material's joints, including where a cut exposes another part's surface.
pub fn bind_sculpt(authored: RigSculpt, seed: u32) -> List<gaussian.SkinPoint> {
    let parts = authored.solids.concat(authored.cuts);
    let models = parts.map(fn(part) => part.geometry);
    let solid_count = length(authored.solids);
    let scene = sculpt.SceneSpec { positive: authored.solids.map_indexed(fn(i) => fn(part) => member(part, i)),
        negative: authored.cuts.map_indexed(fn(i) => fn(part) => member(part, solid_count + i)) };
    let field = bake.prepare_indexed_bake(models, scene, seed, None);
    let tags = Bindings { solid: authored.solids.map(fn(part) => part.binding), cut: authored.cuts.map(fn(part) => part.binding) };
    let random = seed ^ 1540483477;
    let empty = Capture { rows: Buffer.empty(), count: 0 };
    let opaque = foldl(parts, empty, fn(part) => fn(out) => capture_part(field, authored, tags, out, part, false, random));
    return foldl(authored.ghosts, opaque, fn(part) => fn(out) => capture_part(field, authored, tags, out, part, true, random)).rows.freeze();
}
