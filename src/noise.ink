module StudioNoise;

record Noise {
    permutation: List<u32>,
    values: List<f32>,
}

fn fraction(word: u32) -> f64 { return f64_from_u32(word) / 4294967296.0f64; }

// Mulberry32's output after the indexed advance. The counter lets every call
// use the same stream independently of execution order.
fn random_word(seed: u32, index: u32) -> u32 {
    let a = seed + (index + 1) * 1831565813;
    let t = (a ^ wrapping_shr(a, 15)) * (1 | a);
    let v = (t + ((t ^ wrapping_shr(t, 7)) * (61 | t))) ^ t;
    return v ^ wrapping_shr(v, 14);
}

fn shuffle_index(word: u32, limit: u32) -> u32 {
    return word_narrow_u64_to_u32(wrapping_shr(
        word_widen_u32_to_u64(word) * word_widen_u32_to_u64(limit), 32));
}

pub fn make_noise(seed: u32) -> Noise {
    let ids = buffer_fill(256, 0).freeze().map_indexed(fn(i) => fn(unused) => i);
    let values = ids.map(fn(i) => f32_from_f64(fraction(random_word(seed, i))));
    let table = repeat(255, buffer(ids), fn(step) => fn(items) =>
        items.swap(255 - step, shuffle_index(random_word(seed, 256 + step), 256 - step))).freeze();
    return Noise { permutation: table.concat(table), values: values };
}

record Coordinate { whole: u32, fraction: f64, }

fn coordinate(value: f64) -> Coordinate {
    let cell = floor(value);
    let wrap = cell - floor(cell / 256.0f64) * 256.0f64;
    let index = u32_from_f64(wrap).fold(fn(word) => word, fn(unit) => 0);
    let f = value - cell;
    return Coordinate { whole: index, fraction: f * f * (3.0f64 - 2.0f64 * f) };
}

fn permute(noise: Noise, index: u32) -> u32 { return noise.permutation.at_or(index, 0); }

fn corner(noise: Noise, index: u32) -> f64 {
    return f64_from_f32(noise.values.at_or(permute(noise, index), 0.0));
}

fn interpolate(a: f64, b: f64, t: f64) -> f64 { return a + t * (b - a); }

fn plane(noise: Noise, low: u32, high: u32, z: u32, x: f64, y: f64) -> f64 {
    let a = interpolate(corner(noise, permute(noise, low) + z),
        corner(noise, permute(noise, high) + z), x);
    let b = interpolate(corner(noise, permute(noise, low + 1) + z),
        corner(noise, permute(noise, high + 1) + z), x);
    return interpolate(a, b, y);
}

pub fn noise3(noise: Noise, x: f64, y: f64, z: f64) -> f64 {
    let sx = coordinate(x);
    let sy = coordinate(y);
    let sz = coordinate(z);
    let low = permute(noise, sx.whole) + sy.whole;
    let high = permute(noise, sx.whole + 1) + sy.whole;
    let near = plane(noise, low, high, sz.whole, sx.fraction, sy.fraction);
    let far = plane(noise, low, high, sz.whole + 1, sx.fraction, sy.fraction);
    return interpolate(near, far, sz.fraction);
}

record Octave { x: f64, y: f64, z: f64, amplitude: f64, sum: f64, weight: f64, }

pub fn fbm(noise: Noise, x: f64, y: f64, z: f64, octaves: u32) -> f64 {
    let start = Octave { x: x, y: y, z: z, amplitude: 0.5f64, sum: 0.0f64, weight: 0.0f64 };
    let result = repeat_until(octaves, start, fn(o) => o.amplitude == 0.0f64,
        fn(index) => fn(o) => Octave { x: o.x * 2.03f64, y: o.y * 2.03f64, z: o.z * 2.03f64,
            amplitude: o.amplitude * 0.5f64, sum: o.sum + o.amplitude * noise3(noise, o.x, o.y, o.z),
            weight: o.weight + o.amplitude });
    return result.sum / result.weight;
}
