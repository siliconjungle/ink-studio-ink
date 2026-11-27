module StudioPixelFault;

import "pixel_frame.ink" as frame;
import "pixel_mask.ink" as mask;

record Fault { code: String, message: String, layer: String, frame_id: String, detail: String, at: Option<Vec2<u32>>, }

fn invalid(message: String) -> Fault {
    return Fault { code: "invalid-edit", message: message, layer: "", frame_id: "", detail: "", at: None };
}

fn locked(layer: String) -> Fault {
    let message = string_concat("Layer ", string_concat(layer, " does not accept pixel edits"));
    return Fault { code: "locked-layer", message: message, layer: layer, frame_id: "", detail: "", at: None };
}

fn position(g: mask.Grid, p: u32) -> Vec2<u32> { return vec2(rem_or(p, g.width, 0), quot_or(p, g.width, 0)); }

fn blocked(g: mask.Grid, drawn: frame.PaintView, protected: List<u32>, layer: String, p: u32, message: String) -> Fault {
    let held = drawn.pixels.at_or(p, frame.blank()).locked || mask.selected(protected, p);
    return Fault { code: if held { "protected-pixel" } else { "clipped-pixel" },
        message: message, layer: layer, frame_id: "", detail: "", at: Some(position(g, p)) };
}

fn moved(g: mask.Grid, layer: String, detail: String, p: u32) -> Fault {
    return Fault { code: "protected-pixel", message: string_concat("Transform would change protected detail ", detail),
        layer: layer, frame_id: "", detail: detail, at: Some(position(g, p)) };
}


fn dependent(g: mask.Grid, frame_id: String, detail: String, p: u32) -> Fault {
    let at = position(g, p);
    let coords = string_concat(frame.decimal(at.x), string_concat(", ", frame.decimal(at.y)));
    let message = string_concat("Edit would change protected detail ", string_concat(detail, string_concat(" at ", coords)));
    return Fault { code: "protected-pixel", message: message, layer: "", frame_id: frame_id,
        detail: detail, at: Some(at) };
}
