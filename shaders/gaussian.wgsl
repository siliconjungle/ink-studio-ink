// Ink's packed List<Ellipse> stores a length word followed by eight words per
// ellipse. The native and browser hosts validate this layout before drawing.
@group(0) @binding(0) var<storage, read> ellipses: array<u32>;
@group(0) @binding(1) var<uniform> half_viewport: vec2f;

struct Vertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) @interpolate(flat) color: vec4f,
}

fn pair(base: u32) -> vec2f {
    return vec2f(bitcast<f32>(ellipses[base]), bitcast<f32>(ellipses[base + 1u]));
}

@vertex
fn vertex(@builtin(vertex_index) corner: u32, @builtin(instance_index) index: u32) -> Vertex {
    if index >= ellipses[0] {
        return Vertex(vec4f(2.0, 2.0, 0.0, 1.0), vec2f(0.0), vec4f(0.0));
    }
    let base = 1u + index * 8u;
    let uv = vec2f(f32(corner & 1u), f32(corner >> 1u)) * 2.0 - 1.0;
    let point = pair(base) + uv.x * pair(base + 2u) + uv.y * pair(base + 4u);
    let color = unpack4x8unorm(ellipses[base + 6u]);
    return Vertex(vec4f(point / half_viewport, 0.0, 1.0), uv,
        vec4f(color.rgb, bitcast<f32>(ellipses[base + 7u])));
}

@fragment
fn fragment(input: Vertex) -> @location(0) vec4f {
    let power = -4.5 * dot(input.uv, input.uv);
    if power < -4.5 { discard; }
    let alpha = min(0.99, input.color.a * exp(power));
    if alpha < 0.004 { discard; }
    return vec4f(input.color.rgb * alpha, alpha);
}
