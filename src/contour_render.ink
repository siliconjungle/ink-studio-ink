module ContourRender;

import "std:render" as render;

fn grid(name: String) -> render.ViewportTexture {
    return render.ViewportTexture { name: name, scale: 2, height_scale: 3, format: render.TextureFormat.Rgba8Unorm };
}

fn bind_resource(slot: u32, source: String, resource: render.Resource, vertex: Bool, fragment: Bool) -> render.Binding {
    return render.Binding { slot: slot, source: source, resource: resource, vertex: vertex, fragment: fragment };
}

fn texture(slot: u32, source: String) -> render.Binding {
    return bind_resource(slot, source, render.Resource.FloatTexture, false, true);
}

fn splats(vertex: String, fragment: String, attachments: List<render.Attachment>) -> render.Pass {
    return render.Pass {
        vertex: vertex, fragment: fragment, topology: render.Topology.TriangleStrip, blend: true,
        attachments: attachments,
        bindings: [
            bind_resource(3, "palette", render.Resource.Uniform, true, true),
            bind_resource(5, "ellipses", render.Resource.ReadOnlyStorage, true, false),
            bind_resource(6, "viewport", render.Resource.Uniform, true, false),
        ],
        draw: render.packed(4, "ellipses"),
    };
}

fn finish(fragment: String, high_color: String, high_depth: String, native_color: String, native_depth: String) -> render.Pass {
    return render.Pass {
        vertex: "vertex", fragment: fragment, topology: render.Topology.Triangles, blend: false,
        attachments: [render.clear_with("surface", "background")],
        bindings: [
            texture(0, high_color), texture(1, high_depth), texture(2, native_color),
            bind_resource(3, "palette", render.Resource.Uniform, false, true), texture(4, native_depth),
        ],
        draw: render.direct(3, 1),
    };
}

fn atlas_frame() -> render.ViewportFrame {
    return render.ViewportFrame {
        textures: [grid("splat_color"), grid("splat_depth")],
        passes: [
            render.with_viewport(splats("high_vertex", "high_fragment",
                [render.clear_with("splat_color", "background"), render.clear("splat_depth", 0xff0000ff)]),
                Some(render.Viewport { x: 0, y: 1, width: 2, height: 2 })),
            render.with_viewport(splats("native_vertex", "native_fragment",
                [render.load("splat_color"), render.load("splat_depth")]),
                Some(render.Viewport { x: 0, y: 0, width: 1, height: 1 })),
            render.with_viewport(finish("fragment", "splat_color", "splat_depth", "splat_color", "splat_depth"), None),
        ],
    };
}

fn separate_grid(name: String, scale: u32) -> render.Texture {
    return render.Texture { name: name, scale: scale, format: render.TextureFormat.Rgba8Unorm };
}

fn separate_frame() -> render.Frame {
    return render.Frame {
        textures: [
            separate_grid("high_color", 2), separate_grid("high_depth", 2),
            separate_grid("native_color", 1), separate_grid("native_depth", 1),
        ],
        passes: [
            splats("high_vertex", "high_fragment",
                [render.clear_with("high_color", "background"), render.clear("high_depth", 0xff0000ff)]),
            splats("native_vertex", "native_fragment",
                [render.clear_with("native_color", "background"), render.clear("native_depth", 0xff0000ff)]),
            finish("separate_fragment", "high_color", "high_depth", "native_color", "native_depth"),
        ],
    };
}

pub fn frame() -> render.ViewportFrameWithFallback {
    return render.ViewportFrameWithFallback { primary: atlas_frame(), fallback: separate_frame() };
}
