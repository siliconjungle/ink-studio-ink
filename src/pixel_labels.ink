module StudioPixelLabels;

record Scan { offset: u32, visible: Bool, }

fn byte(value: String, offset: u32) -> u32 {
    return string_byte_at(value, offset).fold(fn(n) => n, fn(unit) => 0);
}

fn digit(c: u32) -> Bool { return c >= 48 && c <= 57; }
fn letter(c: u32) -> Bool { return c >= 97 && c <= 122; }

fn id_tail(value: String, i: u32, ok: Bool) -> Bool {
    let c = byte(value, i + 1);
    return ok && (letter(c) || digit(c) || c == 45);
}

fn stable_id(value: String) -> Bool {
    let size = string_byte_len(value);
    if size == 0 || size > 64 || !letter(byte(value, 0)) { return false; }
    return repeat_until(size - 1, true, fn(ok) => !ok, fn(i) => fn(ok) => id_tail(value, i, ok));
}

fn hex_byte(c: u32) -> Bool { return digit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102); }

fn rgb(value: String) -> Bool {
    if string_byte_len(value) != 7 || byte(value, 0) != 35 { return false; }
    return repeat_until(6, true, fn(ok) => !ok, fn(i) => fn(ok) => ok && hex_byte(byte(value, i + 1)));
}

fn spaces(value: String, i: u32) -> u32 {
    let a = byte(value, i);
    if a == 32 || (a >= 9 && a <= 13) { return 1; }
    let b = byte(value, i + 1);
    if a == 194 && b == 160 { return 2; }
    let c = byte(value, i + 2);
    if (a == 225 && b == 154 && c == 128) || (a == 227 && b == 128 && c == 128) ||
        (a == 239 && b == 187 && c == 191) || (a == 226 &&
            ((b == 128 && ((c >= 128 && c <= 138) || c == 168 || c == 169 || c == 175)) || (b == 129 && c == 159))) {
        return 3;
    }
    return 0;
}

fn step(value: String, old: Scan) -> Scan {
    let span = spaces(value, old.offset);
    return Scan { offset: old.offset + span, visible: span == 0 };
}

fn present(value: String) -> Bool {
    let size = string_byte_len(value);
    return repeat_until(size, Scan { offset: 0, visible: false },
        fn(old) => old.visible || old.offset >= size, fn(i) => fn(old) => step(value, old)).visible;
}

// The hash selects a bucket. Exact names decide identity, including on collision.
fn id_hash(name: String) -> u64 {
    let size = string_byte_len(name);
    return repeat_until(size, 14695981039346656037, fn(hash) => false, fn(i) => fn(hash) =>
        (hash ^ word_widen_u32_to_u64(byte(name, i))) * 1099511628211);
}
