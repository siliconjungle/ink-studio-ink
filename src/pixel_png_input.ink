module StudioPixelPngInput;

record Bytes { start: u32, length: u32, }
record Pass { x: u32, y: u32, dx: u32, dy: u32, width: u32, height: u32, row_bytes: u32, }
record Layout { width: u32, height: u32, bits: u32, color: u32, bpp: u32, channels: u32,
    passes: List<Pass>, raw_size: u32, palette: List<u32>, transparency: List<u32>,
    data: List<Bytes>, annotation: Bytes, }
record Header { width: u32, height: u32, bits: u32, color: u32, interlace: Bool, }
record Chunks { at: u32, done: Bool, issue: String, header: Header, table: Bytes,
    transparency: Bytes, annotation: Bytes, data: Buffer<Bytes>, }
record Samples { pixels: List<u32>, indices: List<u32>, }
record Rows { previous: List<u32>, pixels: Buffer<u32>, indices: Buffer<u32>, cursor: u32, issue: String, }

fn empty_bytes() -> Bytes { return Bytes { start: 0, length: 0 }; }
fn words_for(size: u32) -> u32 { return wrapping_shr(size, 2) + (if word_and(size, 3) == 0 { 0 } else { 1 }); }

fn byte(words: List<u32>, i: u32) -> u32 {
    return word_and(wrapping_shr(words.at_or(wrapping_shr(i, 2), 0), word_and(i, 3) * 8), 255);
}

fn big_word(words: List<u32>, i: u32) -> u32 {
    return wrapping_shl(byte(words, i), 24) + wrapping_shl(byte(words, i + 1), 16)
        + wrapping_shl(byte(words, i + 2), 8) + byte(words, i + 3);
}

fn header(words: List<u32>, span: Bytes, chunks: Chunks) -> Chunks {
    let p = span.start;
    if span.length != 13 || byte(words, p + 10) != 0 || byte(words, p + 11) != 0 || byte(words, p + 12) > 1 {
        return Chunks { ..chunks, issue: "PNG must use standard filtering, compression and interlacing" };
    }
    return Chunks { ..chunks, header: Header { width: big_word(words, p), height: big_word(words, p + 4),
        bits: byte(words, p + 8), color: byte(words, p + 9), interlace: byte(words, p + 12) != 0 } };
}

fn chunk(words: List<u32>, size: u32, old: Chunks) -> Chunks {
    let p = old.at;
    if size - p < 12 { return Chunks { ..old, done: true }; }
    let n = big_word(words, p);
    if n > size - p - 12 { return Chunks { ..old, issue: "Truncated PNG chunk" }; }
    let span = Bytes { start: p + 8, length: n };
    let next = Chunks { ..old, at: p + n + 12 };
    let kind = big_word(words, p + 4);
    if kind == 1229472850 { return header(words, span, next); } // IHDR
    if kind == 1347179589 { return Chunks { ..next, table: span }; } // PLTE
    if kind == 1951551059 { return Chunks { ..next, transparency: span }; } // tRNS
    if kind == 1768835908 { // inKD
        if next.annotation.start != 0 { return Chunks { ..next, issue: "Duplicate Ink palette metadata" }; }
        return Chunks { ..next, annotation: span };
    }
    if kind == 1229209940 { return Chunks { ..next, data: next.data.push(span) }; } // IDAT
    if kind == 1229278788 { return Chunks { ..next, done: true }; } // IEND
    return next;
}

fn sample_channels(color: u32) -> u32 {
    return if color == 0 || color == 3 { 1 } else { if color == 2 { 3 } else {
        if color == 4 { 2 } else { if color == 6 { 4 } else { 0 } }
    } };
}

fn pass(header: Header, channels: u32, origin: Vec2<u32>, step: Vec2<u32>) -> Pass {
    let w = if header.width <= origin.x { 0 } else { quot_or(header.width - origin.x + step.x - 1, step.x, 0) };
    let h = if header.height <= origin.y { 0 } else { quot_or(header.height - origin.y + step.y - 1, step.y, 0) };
    return Pass { x: origin.x, y: origin.y, dx: step.x, dy: step.y, width: w, height: h,
        row_bytes: wrapping_shr(w * header.bits * channels + 7, 3) };
}

fn packed_rgb(words: List<u32>, p: u32) -> u32 {
    return byte(words, p) * 65536 + byte(words, p + 1) * 256 + byte(words, p + 2);
}

fn inspect(words: List<u32>, size: u32) -> Result<Layout, String> {
    if size < 33 || length(words) != words_for(size) ||
        big_word(words, 0) != 2303741511 || big_word(words, 4) != 218765834 { return Err("Not a PNG file"); }
    let empty = empty_bytes();
    let start = Chunks { at: 8, done: false, issue: "", table: empty, transparency: empty, annotation: empty,
        data: Buffer.empty(), header: Header { width: 0, height: 0, bits: 0, color: 0, interlace: false } };
    let result = repeat_until(quot_or(size, 12, 0), start, fn(out) => out.done || out.issue != "",
        fn(i) => fn(out) => chunk(words, size, out));
    if result.issue != "" { return Err(result.issue); }
    let h = result.header;
    let channels = sample_channels(h.color);
    let small = h.bits == 1 || h.bits == 2 || h.bits == 4;
    let bits_ok = h.bits == 8 || h.bits == 16 && h.color != 3 || small && (h.color == 0 || h.color == 3);
    if h.width == 0 || h.height == 0 || word_widen_u32_to_u64(h.width) * word_widen_u32_to_u64(h.height) > 16777216
        || channels == 0 || !bits_ok { return Err("Unsupported PNG dimensions or colour format"); }
    let table = result.table;
    let transparency = result.transparency;
    let entries = quot_or(table.length, 3, 0);
    if h.color == 3 && (rem_or(table.length, 3, 0) != 0 || entries == 0 || entries > wrapping_shl(1, h.bits)
        || transparency.length > entries) { return Err("Invalid indexed PNG palette"); }
    if h.width > 512 || h.height > 512 || h.bits > 8 {
        return Err("Pixel art import needs a PNG up to 512 × 512 with 8-bit or smaller channels");
    }
    let all = if h.interlace {
        [pass(h, channels, vec2(0, 0), vec2(8, 8)), pass(h, channels, vec2(4, 0), vec2(8, 8)),
            pass(h, channels, vec2(0, 4), vec2(4, 8)), pass(h, channels, vec2(2, 0), vec2(4, 4)),
            pass(h, channels, vec2(0, 2), vec2(2, 4)), pass(h, channels, vec2(1, 0), vec2(2, 2)),
            pass(h, channels, vec2(0, 1), vec2(1, 2))]
    } else { [pass(h, channels, vec2(0, 0), vec2(1, 1))] };
    let passes = all.filter(fn(row) => row.width != 0 && row.height != 0);
    let zero: u32 = 0;
    let raw_size = foldl(passes, zero, fn(row) => fn(n) => n + (row.row_bytes + 1) * row.height);
    let colors: Buffer<u32> = Buffer.empty();
    let palette: List<u32> = if h.color == 3 {
        repeat_until(entries, colors, fn(out) => false, fn(i) => fn(out) =>
            out.push(packed_rgb(words, table.start + i * 3))).freeze()
    } else { [] };
    let alpha_count = if h.color == 3 { transparency.length } else { if transparency.length > 6 { 6 } else { transparency.length } };
    let channels_alpha: Buffer<u32> = Buffer.empty();
    let alpha = repeat_until(alpha_count, channels_alpha, fn(out) => false,
        fn(i) => fn(out) => out.push(byte(words, transparency.start + i))).freeze();
    return Ok(Layout { width: h.width, height: h.height, color: h.color, bits: h.bits, channels: channels,
        bpp: wrapping_shr(channels * h.bits + 7, 3), passes: passes, raw_size: raw_size, palette: palette, transparency: alpha,
        data: result.data.freeze(), annotation: result.annotation });
}

fn distance(a: u32, b: u32) -> u32 { return if a >= b { a - b } else { b - a }; }

fn predict(filter: u32, left: u32, up: u32, corner: u32) -> u32 {
    if filter == 0 { return 0; }
    if filter == 1 { return left; }
    if filter == 2 { return up; }
    if filter == 3 { return wrapping_shr(left + up, 1); }
    let a = distance(up, corner);
    let b = distance(left, corner);
    let c = distance(left + up, corner * 2);
    return if a <= b && a <= c { left } else { if b <= c { up } else { corner } };
}

fn unfilter(words: List<u32>, cursor: u32, filter: u32, bpp: u32, previous: List<u32>, i: u32,
    row: Buffer<u32>) -> Buffer<u32> {
    let left = if i >= bpp { row.at_or(i - bpp, 0) } else { 0 };
    let corner = if i >= bpp { previous.at_or(i - bpp, 0) } else { 0 };
    let up = previous.at_or(i, 0);
    return row.push(word_and(byte(words, cursor + i) + predict(filter, left, up, corner), 255));
}

fn channel(row: List<u32>, bits: u32, i: u32) -> u32 {
    if bits == 8 { return row.at_or(i, 0); }
    let p = i * bits;
    return word_and(wrapping_shr(row.at_or(wrapping_shr(p, 3), 0), 8 - bits - word_and(p, 7)), wrapping_shl(1, bits) - 1);
}

fn transparent(values: List<u32>, i: u32) -> u32 {
    return if length(values) >= i * 2 + 2 { values.at_or(i * 2, 0) * 256 + values.at_or(i * 2 + 1, 0) } else { 65536 };
}

fn straight(h: Layout, row: List<u32>, i: u32, first: u32) -> u32 {
    if h.color == 0 || h.color == 4 {
        let gray = first * quot_or(255, wrapping_shl(1, h.bits) - 1, 0);
        let alpha = if h.color == 4 { channel(row, h.bits, i + 1) } else {
            if first == transparent(h.transparency, 0) { 0 } else { 255 }
        };
        return gray * 16843008 + alpha;
    }
    let g = channel(row, h.bits, i + 1);
    let b = channel(row, h.bits, i + 2);
    let alpha = if h.color == 6 { channel(row, h.bits, i + 3) } else {
        if first == transparent(h.transparency, 0) && g == transparent(h.transparency, 1)
            && b == transparent(h.transparency, 2) { 0 } else { 255 }
    };
    return wrapping_shl(first, 24) + g * 65536 + b * 256 + alpha;
}

fn pixel(h: Layout, row: List<u32>, pass: Pass, y: u32, x: u32, old: Rows) -> Rows {
    let p = (pass.y + y * pass.dy) * h.width + pass.x + x * pass.dx;
    let i = x * h.channels;
    let first = channel(row, h.bits, i);
    if h.color == 3 {
        if first >= length(h.palette) { return Rows { ..old, issue: "PNG references a colour outside its palette" }; }
        let word = h.palette.at_or(first, 0) * 256 + h.transparency.at_or(first, 255);
        return Rows { ..old, pixels: old.pixels.set(p, word), indices: old.indices.set(p, first) };
    }
    return Rows { ..old, pixels: old.pixels.set(p, straight(h, row, i, first)) };
}

fn scanline(h: Layout, words: List<u32>, pass: Pass, y: u32, old: Rows) -> Rows {
    let filter = byte(words, old.cursor);
    if filter > 4 { return Rows { ..old, issue: "Invalid PNG filter" }; }
    let empty: Buffer<u32> = Buffer.empty();
    let row = repeat_until(pass.row_bytes, empty, fn(out) => false, fn(i) => fn(out) =>
        unfilter(words, old.cursor + 1, filter, h.bpp, old.previous, i, out)).freeze();
    let next: Rows = Rows { ..old, cursor: old.cursor + pass.row_bytes + 1 };
    let decoded: Rows = repeat_until(pass.width, next, fn(out) => out.issue != "", fn(x) => fn(out) =>
        pixel(h, row, pass, y, x, out));
    return Rows { ..decoded, previous: row };
}

fn scan_pass(h: Layout, words: List<u32>, pass: Pass, out: Rows) -> Rows {
    let cleared = Rows { ..out, previous: [] };
    return repeat_until(pass.height, cleared, fn(row) => row.issue != "", fn(y) => fn(row) =>
        scanline(h, words, pass, y, row));
}

fn decode(h: Layout, words: List<u32>, size: u32) -> Result<Samples, String> {
    if size != h.raw_size || length(words) != words_for(size) { return Err("Invalid PNG scanline length"); }
    let n = h.width * h.height;
    let indices: Buffer<u32> = if h.color == 3 { buffer_fill(n, 0) } else { Buffer.empty() };
    let start = Rows { previous: [], pixels: buffer_fill(n, 0), indices: indices, cursor: 0, issue: "" };
    let finished = foldl(h.passes, start, fn(pass) => fn(out) =>
        if out.issue == "" { scan_pass(h, words, pass, out) } else { out });
    if finished.issue != "" { return Err(finished.issue); }
    return Ok(Samples { pixels: finished.pixels.freeze(), indices: finished.indices.freeze() });
}
