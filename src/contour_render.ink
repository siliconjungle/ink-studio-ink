module ContourRender;

import "std:render" as render;

fn grid(name: String, scale: u32) -> render.Texture {
    return render.Texture { name: name, scale: scale, format: render.TextureFormat.Rgba8Unorm };
}

fn bind_resource(slot: u32, source: String, resource: render.Resource, vertex: Bool, fragment: Bool) -> render.Binding {
    return render.Binding { slot: slot, source: source, resource: resource, vertex: vertex, fragment: fragment };
}

fn texture(slot: u32, source: String) -> render.Binding {
    return bind_resource(slot, source, render.Resource.FloatTexture, false, true);
}

fn splats(vertex: String, fragment: String, color: String, depth: String) -> render.Pass {
    return render.Pass {
        vertex: vertex, fragment: fragment, topology: render.Topology.TriangleStrip, blend: true,
        attachments: [render.clear_with(color, "background"), render.clear(depth, 0xff0000ff)],
        bindings: [
            bind_resource(3, "palette", render.Resource.Uniform, true, true),
            bind_resource(5, "ellipses", render.Resource.ReadOnlyStorage, true, false),
            bind_resource(6, "viewport", render.Resource.Uniform, true, false),
        ],
        draw: render.packed(4, "ellipses"),
    };
}

pub fn frame() -> render.Frame {
    return render.Frame {
        textures: [
            grid("high_color", 2), grid("high_depth", 2),
            grid("native_color", 1), grid("native_depth", 1),
        ],
        passes: [
            splats("high_vertex", "high_fragment", "high_color", "high_depth"),
            splats("native_vertex", "native_fragment", "native_color", "native_depth"),
            render.Pass {
                vertex: "vertex", fragment: "fragment", topology: render.Topology.Triangles, blend: false,
                attachments: [render.clear_with("surface", "background")],
                bindings: [
                    texture(0, "high_color"), texture(1, "high_depth"), texture(2, "native_color"),
                    bind_resource(3, "palette", render.Resource.Uniform, false, true), texture(4, "native_depth"),
                ],
                draw: render.direct(3, 1),
            },
        ],
    };
}
