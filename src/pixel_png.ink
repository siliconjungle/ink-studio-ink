module StudioPixelPng;

import "std:json" as json;
import "pixel_asset_export.ink" as assets;
import "pixel_brush_paint.ink" as colors;
import "pixel_frame.ink" as frame;
import "pixel_values.ink" as value;

record Image { width: u32, height: u32, channels: u32, pixels: List<u32>, colors: List<u32>, coverage: List<u32>,
    palette: List<String>, ids: List<String>, slots: List<i32>, knockouts: List<u32>, metadata: json.Json, }
record Indexed { pixels: Buffer<u32>, colors: Buffer<u32>, coverage: Buffer<u32>, primary: Buffer<u32>,
    variants: Map<u32, u32>, hole: u32, has_alpha: Bool, full: Bool, }

fn index(raster: assets.Raster, palette: List<u32>) -> Indexed {
    let start = Indexed { pixels: Buffer.empty(), colors: buffer(palette), coverage: buffer_fill(length(palette), 255),
        primary: buffer_fill(length(palette), 256), variants: Map.empty(), hole: 256,
        has_alpha: false, full: length(palette) > 256 };
    return repeat_until(length(raster.slots), start, fn(out) => out.full, fn(p) => fn(out) =>
        add_pixel(raster.slots.at_or(p, -1), raster.alpha.at_or(p, 255), palette, out));
}

fn add_pixel(slot: i32, alpha: u32, palette: List<u32>, out: Indexed) -> Indexed {
    if slot < 0 {
        if out.hole != 256 { return Indexed { ..out, pixels: out.pixels.push(out.hole) }; }
        let entry = out.colors.len();
        if entry == 256 { return Indexed { ..out, full: true }; }
        return Indexed { ..out, hole: entry, pixels: out.pixels.push(entry), colors: out.colors.push(0),
            coverage: out.coverage.push(0), has_alpha: true };
    }
    let index = value.as_word(f64_from_i32(slot));
    let primary = out.primary.at_or(index, 256);
    if primary == alpha { return Indexed { ..out, pixels: out.pixels.push(index) }; }
    if primary == 256 {
        return Indexed { ..out, pixels: out.pixels.push(index), primary: out.primary.set(index, alpha),
            coverage: out.coverage.set(index, alpha), has_alpha: out.has_alpha || alpha != 255 };
    }
    let key = index * 256 + alpha;
    let known = out.variants.get_or(key, 256);
    if known != 256 { return Indexed { ..out, pixels: out.pixels.push(known) }; }
    let entry = out.colors.len();
    if entry == 256 { return Indexed { ..out, full: true }; }
    return Indexed { ..out, variants: out.variants.set(key, entry), pixels: out.pixels.push(entry),
        colors: out.colors.push(palette.at_or(index, 0)), coverage: out.coverage.push(alpha),
        has_alpha: out.has_alpha || alpha != 255 };
}

fn prepare(source: json.Json, art: frame.Artwork, options: json.Json) -> Result<Image, String> {
    let settings = value.fields(options);
    let scope = assets.export_scope(art, settings)?;
    let input = assets.scoped_raster(source, art, settings, scope, false)?;
    let mode = json.lookup(settings, "colorMode").fold(fn(raw) => value.text(raw), fn(unit) => "auto");
    if mode != "auto" && mode != "indexed" && mode != "rgba" { return Err("Choose auto, indexed, or rgba PNG color mode"); }
    let raster = input.raster;
    let palette = value.property(source, "palette").fold(fn(raw) => value.fields(raw), fn(unit) => []);
    let ramps = value.property(source, "ramps").fold(fn(raw) => value.items(raw), fn(unit) => []);
    let base = Image { width: art.grid.width, height: art.grid.height, channels: 4, pixels: [], colors: [], coverage: [],
        palette: input.colors.map(fn(rgb) => colors.color_text(rgb)), ids: input.ids, slots: raster.slots,
        knockouts: raster.knockouts, metadata: json.object(assets.palette_metadata(palette, ramps)) };
    if mode != "rgba" {
        let indexed = index(raster, input.colors);
        if !indexed.full {
            let alpha: List<u32> = if indexed.has_alpha { indexed.coverage.freeze() } else { [] };
            return Ok(Image { ..base, channels: 1, pixels: indexed.pixels.freeze(), colors: indexed.colors.freeze(), coverage: alpha });
        }
        if mode == "indexed" { return Err("An exact indexed PNG needs at most 256 color/alpha entries"); }
    }
    let pixels = raster.slots.map_indexed(fn(p) => fn(slot) =>
        if slot < 0 { 0 } else { frame.rgba(frame.color_at(input.colors, slot), raster.alpha.at_or(p, 255)) });
    return Ok(Image { ..base, pixels: pixels });
}
