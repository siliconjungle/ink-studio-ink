module StudioPixelSession;

import "std:json" as json;
import "pixel_batch.ink" as batch;
import "pixel_history.ink" as history;
import "pixel_labels.ink" as labels;
import "pixel_values.ink" as value;

record Layout { revision: u64, limit: u32, cursor: history.Cursor, past: List<history.Entry>,
    future: List<history.Entry>, draft: history.Entry, }

fn valid_slot(slot: String) -> Bool {
    let size = string_byte_len(slot);
    let prefix = string_slice(slot, 0, 13).fold(fn(text) => text, fn(unit) => "");
    if size != 49 || prefix != "pixel-editor-" { return false; }
    return repeat_until(36, true, fn(valid) => !valid, fn(i) => fn(valid) =>
        slot_character(labels.byte(slot, i + 13)));
}

fn slot_character(byte: u32) -> Bool { return byte == 45 || batch.digest_digit(byte); }

fn slot_seed(slot: String) -> u32 {
    let initial: u32 = 1;
    return repeat_until(string_byte_len(slot), initial, fn(seed) => false, fn(i) => fn(seed) =>
        (seed ^ labels.byte(slot, i)) * 16777619);
}

fn identity(slot: String, legacy: json.Json, revision: u64) -> Result<u32, String> {
    if !valid_slot(slot) || !(legacy == json.null() || batch.revision(legacy)) {
        return Err("Invalid pixel edit session identity");
    }
    if revision == 0 || !safe_serial(revision) { return Err("Invalid pixel edit session checkpoint"); }
    return Ok(slot_seed(slot));
}

fn safe_serial(revision: u64) -> Bool { return revision <= 9007199254740991; }

fn next_serial(revision: u64) -> Result<u64, String> {
    if revision == 9007199254740991 { return Err("Pixel journal revision overflow"); }
    return Ok(revision + 1);
}

fn entries(receipts: List<u32>, first: u32, names: List<String>) -> List<history.Entry> {
    return names.map_indexed(fn(i) => fn(label) =>
        history.Entry { id: first + i, label: label, receipt: receipts.at_or(first + i, 0) });
}

fn receipt_count(receipts: List<u32>) -> u32 { return length(receipts); }

fn append_receipt(receipts: List<u32>, receipt: u32) -> List<u32> { return receipts.concat([receipt]); }

fn count(undo: List<String>, redo: List<String>) -> u64 {
    return word_widen_u32_to_u64(length(undo)) + word_widen_u32_to_u64(length(redo));
}

fn fits(retained: u64, limit: u32) -> Bool {
    return retained <= word_widen_u32_to_u64(limit) && retained < 4294967293;
}

fn saved_draft(label: Option<String>, receipts: List<u32>) -> history.Entry {
    return label.fold(fn(name) => history.Entry { id: 1, label: name, receipt: receipts.at_or(1, 0) },
        fn(unit) => history.empty_entry());
}

fn last_id(retained: u64) -> u32 { return word_narrow_u64_to_u32(retained) + 1; }

fn future_id(undo: List<String>) -> u32 { return length(undo) + 2; }
