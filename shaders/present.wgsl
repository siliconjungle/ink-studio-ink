@group(0) @binding(0) var art: texture_2d<f32>;

struct Vertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

@vertex
fn vertex(@builtin(vertex_index) index: u32) -> Vertex {
    let point = vec2f(f32((index << 1u) & 2u), f32(index & 2u));
    return Vertex(vec4f(point * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0), point);
}

fn sample_art(uv: vec2f) -> vec4f {
    let size = vec2i(textureDimensions(art));
    return textureLoad(art, clamp(vec2i(uv * vec2f(size)), vec2i(0), size - 1), 0);
}

@fragment
fn fragment(input: Vertex) -> @location(0) vec4f {
    return sample_art(input.uv);
}

@fragment
fn fragment_srgb(input: Vertex) -> @location(0) vec4f {
    let display = sample_art(input.uv);
    let linear = select(pow((display.rgb + 0.055) / 1.055, vec3f(2.4)),
        display.rgb / 12.92, display.rgb <= vec3f(0.04045));
    return vec4f(linear, display.a);
}
