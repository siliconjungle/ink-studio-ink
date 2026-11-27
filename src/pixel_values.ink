module StudioPixelValues;

import "std:json" as json;

fn fields(value: json.Json) -> List<json.Member> {
    return json.members(value).fold(fn(items) => items, fn(error) => []);
}

fn items(value: json.Json) -> List<json.Json> {
    return json.elements(value).fold(fn(items) => items, fn(error) => []);
}

fn get(fields: List<json.Member>, key: String) -> json.Json {
    return json.lookup(fields, key).fold(fn(value) => value, fn(unit) => json.null());
}

fn property(value: json.Json, key: String) -> Option<json.Json> {
    return json.get(value, key).fold(fn(item) => item, fn(issue) => None);
}

fn has(fields: List<json.Member>, key: String) -> Bool {
    return fold_until(fields, false, fn(field) => fn(found) => found,
        fn(field) => fn(found) => found || field.key == key);
}

fn only(fields: List<json.Member>, keys: List<String>) -> Bool {
    return foldl(fields, true, fn(field) => fn(valid) =>
        valid && foldl(keys, false, fn(key) => fn(found) => found || key == field.key));
}

fn text(raw: json.Json) -> String {
    return json.as_text(raw).fold(fn(value) => value, fn(error) => "");
}

fn missing_number() -> f64 { return f64_from_bits(9221120237041090560); }
fn number(raw: json.Json) -> f64 {
    return json.as_number(raw).fold(fn(token) =>
        f64_from_decimal(token).fold(fn(value) => value, fn(unit) => missing_number()),
        fn(error) => missing_number());
}

fn integer(raw: json.Json, lo: i32, hi: i32) -> Option<i32> {
    let n = number(raw);
    if n < f64_from_i32(lo) || n > f64_from_i32(hi) || n != trunc(n) { return None; }
    return i32_from_f64(n);
}

fn word(raw: json.Json, hi: u32) -> u32 {
    let n = number(raw);
    if n < 0.0f64 || n > f64_from_u32(hi) || n != trunc(n) { return 4294967295; }
    return u32_from_f64(n).fold(fn(value) => value, fn(unit) => 4294967295);
}

fn flag(fields: List<json.Member>, key: String, fallback: Bool) -> Bool {
    return json.as_boolean(get(fields, key)).fold(fn(value) => value, fn(error) => fallback);
}

fn as_word(number: f64) -> u32 {
    return u32_from_f64(number).fold(fn(value) => value, fn(unit) => 0);
}

fn round_byte(number: f64) -> u32 {
    let base = floor(number);
    return as_word(if number - base >= 0.5f64 { base + 1.0f64 } else { base });
}

fn max(a: f64, b: f64) -> f64 { return if a >= b { a } else { b }; }
fn min(a: f64, b: f64) -> f64 { return if a <= b { a } else { b }; }
