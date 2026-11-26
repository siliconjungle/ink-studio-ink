module StudioMaterial;

import "bake.ink" as bake;
import "brush.ink" as brush;
import "gaussian.ink" as gaussian;
import "marks.ink" as marks;
import "noise.ink" as noise;
import "rig.ink" as math;

record Lighting { direction: math.Point, ambient: f64, sky: f64, sun: f64, wobble: f64, }
record Exposure { sky_sun: f64, lamps: f64, direct: f64, shadow: f64, strongest: Option<u32>, }
record LampTotal { sum: f64, power: f64, strongest: Option<u32>, index: u32, }

fn add_lamp(old: LampTotal, lamp: bake.LampSample, occlusion: f64) -> LampTotal {
    let stronger = lamp.power > old.power;
    return LampTotal { sum: old.sum + lamp.power * (0.4f64 + 0.6f64 * occlusion),
        power: if stronger { lamp.power } else { old.power }, index: old.index + 1,
        strongest: if stronger { Some(old.index) } else { old.strongest } };
}

pub fn expose(sample: bake.LitSurface, light: Lighting, leaf: Bool) -> Exposure {
    let n = sample.surface.normal;
    let ao = sample.surface.occlusion;
    let sun = math.max(0.0f64, math.dot(n, light.direction));
    let visibility = if sun <= 0.0f64 || light.sun <= 0.0f64 || leaf { 1.0f64 } else { sample.visibility };
    let direct = light.sun * (sun * if leaf && light.sun > 0.0f64 { 0.8f64 } else { visibility });
    let base = ao * (light.ambient + light.sky * (0.5f64 + 0.5f64 * n.y)) + direct;
    let lamps = foldl(sample.lamps, LampTotal { sum: 0.0f64, power: 0.0f64, strongest: None, index: 0 },
        fn(lamp) => fn(total) => add_lamp(total, lamp, ao));
    return Exposure { sky_sun: base, lamps: lamps.sum, direct: direct, shadow: 1.0f64 - visibility,
        strongest: lamps.strongest };
}

pub fn diffuse(tables: noise.Noise, position: math.Point, light: Lighting, exposure: Exposure, bias: f64) -> f64 {
    let grain = noise.noise3(tables, position.x * 3.1f64 + 7.0f64, position.y * 3.1f64, position.z * 3.1f64);
    return exposure.sky_sun + exposure.lamps + bias + light.wobble * (grain - 0.5f64);
}

pub fn top_facing(tables: noise.Noise, position: math.Point, up: f64, minimum: f64) -> Bool {
    let edge = noise.noise3(tables, position.x * 1.9f64, position.y * 1.9f64, position.z * 1.9f64);
    return up > minimum + 0.35f64 * (edge - 0.5f64);
}

record Shade { tone: f64, ramp: List<u32>, }

pub fn shade(exposure: Exposure, tone: f64, base: List<u32>, sunlit: List<u32>, glow: List<u32>,
    lamp_pigments: Option<Vec2<u32>>) -> Shade {
    let switches = length(sunlit) > 0;
    let sun = switches && exposure.direct > 0.2f64;
    let warm = length(glow) > 0 && exposure.lamps > exposure.sky_sun * 0.8f64;
    let ramp = if warm { lamp_pigments.fold(fn(colors) => [glow.at_or(0, 0), colors.x, colors.y], fn(unit) => glow) }
        else { if sun { sunlit } else { base } };
    return Shade { tone: if !switches { tone } else { if sun { (tone - 0.3f64) / 0.75f64 } else { tone / 0.5f64 } },
        ramp: ramp };
}

pub fn pigment(shade: Shade) -> u32 {
    let n = length(shade.ramp);
    return if n > 0 { shade.ramp.at_or(brush.tone_index(shade.tone * f64_from_u32(n), n - 1), 0) } else { 0 };
}

pub fn dab(surface: bake.Surface, radius: f64, thickness: f64, rgb: u32, alpha: f32) -> gaussian.WorldGaussian {
    let axial = marks.axial_mark(surface.normal, thickness, radius);
    let shape = axial.fold(fn(mark) => mark.covariance, fn(error) => marks.round_mark(radius));
    return gaussian.WorldGaussian { position: math.to_vec3(surface.position), covariance0: math.to_vec3(shape.first),
        covariance1: math.to_vec3(shape.rest), reach: 3.0, rgb: rgb, alpha: alpha };
}

pub fn course_tone(tables: noise.Noise, position: math.Point, width: f64, height: f64, variation: f64) -> f64 {
    let row = floor(position.y / height);
    let parity = row - (if row < 0.0f64 { ceil(row / 2.0f64) } else { floor(row / 2.0f64) }) * 2.0f64;
    let u = (position.x + position.z * 0.7f64) / width + parity * 0.5f64;
    let column = floor(u);
    if position.y / height - row < 0.16f64 || u - column < 0.07f64 { return -0.3f64; }
    return variation * (noise.noise3(tables, column * 7.31f64, row * 3.17f64, 1.7f64) - 0.5f64) * 2.0f64;
}
