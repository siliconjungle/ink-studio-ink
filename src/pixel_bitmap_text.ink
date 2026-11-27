module StudioPixelBitmapText;

import "std:json" as json;
import "pixel_bitmap_font.ink" as font;
import "pixel_drawing_grid.ink" as grid;
import "pixel_labels.ink" as labels;
import "pixel_values.ink" as value;

record Options { scale: u32, tracking: u32, leading: u32, align: String, columns: u32, }
record Scan { codes: Buffer<u32>, rows: Buffer<u32>, current: u32, longest: u32, offset: u32, units: u32, }
record Text { origin: grid.Point, options: Options, codes: List<u32>, rows: List<u32>, width: u32, }
record Scalar { code: u32, bytes: u32, units: u32, }

fn number(spec: List<json.Member>, field: String, min: u32, max: u32, absent: u32) -> u32 {
    return json.lookup(spec, field).fold(fn(raw) =>
        if value.word(raw, max) < min { 4294967295 } else { value.word(raw, max) }, fn(unit) => absent);
}

fn options(spec: List<json.Member>) -> Options {
    let raw = value.get(spec, "columns");
    let count = value.number(raw);
    let valid = count >= 1.0f64 && count <= 9007199254740991.0f64 && count == trunc(count);
    let columns: u32 = if !value.has(spec, "columns") { 4096 }
        else { if valid { value.as_word(value.min(4096.0f64, count)) } else { 0 } };
    return Options { scale: number(spec, "scale", 1, 32, 1), tracking: number(spec, "tracking", 0, 256, 0),
        leading: number(spec, "leading", 0, 256, 0), columns: columns,
        align: json.lookup(spec, "align").fold(fn(raw) => value.text(raw), fn(unit) => "left") };
}

fn scalar(text: String, i: u32) -> Scalar {
    let lead = labels.byte(text, i);
    if lead < 128 { return Scalar { code: lead, bytes: 1, units: 1 }; }
    let b = word_and(labels.byte(text, i + 1), 63);
    if lead < 224 { return Scalar { code: word_and(lead, 31) * 64 + b, bytes: 2, units: 1 }; }
    let c = word_and(labels.byte(text, i + 2), 63);
    if lead < 240 { return Scalar { code: (word_and(lead, 15) * 64 + b) * 64 + c, bytes: 3, units: 1 }; }
    let d = word_and(labels.byte(text, i + 3), 63);
    return Scalar { code: ((word_and(lead, 7) * 64 + b) * 64 + c) * 64 + d, bytes: 4, units: 2 };
}

fn break_line(old: Scan) -> Scan {
    let max = if old.current > old.longest { old.current } else { old.longest };
    return Scan { ..old, rows: old.rows.push(old.current), current: 0, longest: max };
}

fn scan(text: String, columns: u32, old: Scan) -> Scan {
    let c = scalar(text, old.offset);
    let after = old.offset + c.bytes;
    if c.code == 13 || c.code == 10 {
        let crlf = c.code == 13 && labels.byte(text, after) == 10;
        let step: u32 = if crlf { 1 } else { 0 };
        return break_line(Scan { ..old, offset: after + step, units: old.units + c.units + step });
    }
    let row = if old.current == columns { break_line(old) } else { old };
    return Scan { ..row, codes: row.codes.push(c.code), current: row.current + 1,
        offset: after, units: row.units + c.units };
}

fn advance(o: Options) -> u32 { return 6 * o.scale + o.tracking; }

fn row_width(o: Options, n: u32) -> u32 {
    return if n == 0 { 0 } else { n * advance(o) - o.tracking };
}

fn line_step(o: Options) -> u32 { return 8 * o.scale + o.leading; }

fn layout(d: grid.Drawing, spec: List<json.Member>) -> Result<Text, String> {
    let at = grid.point(value.get(spec, "at"), d);
    if !grid.inside(at, d) { return Err("Bitmap text needs an in-bounds native anchor"); }
    let o = options(spec);
    let issue = "Invalid bitmap text or layout options";
    if o.scale > 32 || o.tracking > 256 || o.leading > 256 || o.columns == 0 ||
        (o.align != "left" && o.align != "center" && o.align != "right") { return Err(issue); }
    let source: Result<String, String> = json.as_text(value.get(spec, "text")).fold(fn(s) => Ok(s), fn(e) => Err(issue));
    let text = source?;
    let size = string_byte_len(text);
    if size > 12288 { return Err(issue); }
    let init = Scan { codes: Buffer.empty(), rows: Buffer.empty(), current: 0, longest: 0, offset: 0, units: 0 };
    let found = repeat_until(size, init, fn(out) => out.offset >= size || out.units > 4096,
        fn(i) => fn(out) => scan(text, o.columns, out));
    if found.units > 4096 { return Err(issue); }
    let final = break_line(found);
    let rows = final.rows.freeze();
    let w = row_width(o, final.longest);
    let width: u32 = if w == 0 { 1 } else { w };
    let height = length(rows) * line_step(o) - o.leading;
    if width > quot_or(4000000, height, 0) { return Err("Bitmap text exceeds its pixel budget"); }
    if width > 8192 || height > 8192 { return Err("Raster dimensions exceed the canvas budget"); }
    return Ok(Text { origin: at, options: o, codes: final.codes.freeze(), rows: rows, width: width });
}

fn alignment(t: Text, n: u32) -> u32 {
    let rest = t.width - row_width(t.options, n);
    return if t.options.align == "left" { 0 }
        else { if t.options.align == "center" { quot_or(rest, 2, 0) } else { rest } };
}

fn search(codes: List<u32>, code: u32, range: Vec2<u32>) -> Vec2<u32> {
    let mid = quot_or(range.x + range.y, 2, 0);
    return if codes.at_or(mid, 4294967295) < code { vec2(mid + 1, range.y) } else { vec2(range.x, mid) };
}

fn glyph(f: font.Font, code: u32) -> Vec2<u32> {
    let range: Vec2<u32> = vec2(0, length(f.codes));
    let i = repeat_until(10, range, fn(bounds) => bounds.x >= bounds.y,
        fn(round) => fn(bounds) => search(f.codes, code, bounds)).x;
    // The printable range starts at U+0020, and U+003F is the default glyph.
    let index: u32 = if f.codes.at_or(i, 4294967295) == code { i } else { 31 };
    return vec2(f.pixels.at_or(index * 2, 0), f.pixels.at_or(index * 2 + 1, 0));
}

