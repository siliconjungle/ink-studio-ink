module StudioPixelLabels;

record Scan { offset: u32, visible: Bool, }

fn byte(value: String, offset: u32) -> u32 {
    return string_byte_at(value, offset).fold(fn(n) => n, fn(unit) => 0);
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
