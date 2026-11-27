use super::{
    Json, Limits, OpenedDocument, OrderedJson, SnapshotCel, SnapshotEdits, SnapshotMark,
    compiled_json, revision, snapshot_json,
};
use compiled_state::{State, Wire};
use cw_zlib::{Inflater, Progress};
use serde_json::{Value, value::RawValue};
use std::collections::HashMap;

fn words(bytes: &[u8]) -> Vec<u32> {
    bytes
        .chunks(4)
        .map(|chunk| {
            let mut word = [0; 4];
            word[..chunk.len()].copy_from_slice(chunk);
            u32::from_le_bytes(word)
        })
        .collect()
}

fn inflate<'a>(parts: impl IntoIterator<Item = &'a [u8]>, limit: usize) -> Result<Vec<u8>, String> {
    let mut decoder = Inflater::new(15).map_err(|error| error.message())?;
    let mut bytes = Vec::new();
    let too_large = || format!("Cannot create a Buffer larger than {limit} bytes");
    for part in parts {
        let remaining = limit + 1 - bytes.len();
        let progress = decoder
            .inflate(part, &mut bytes, remaining)
            .map_err(|error| error.message())?;
        if bytes.len() > limit {
            return Err(too_large());
        }
        match progress {
            Progress::End => return Ok(bytes),
            Progress::NeedInput => {}
            Progress::NeedDict(_) => return Err("Missing dictionary".into()),
            Progress::OutputFull => return Err(too_large()),
        }
    }
    Err("unexpected end of file".into())
}

fn annotation_word(value: &Value) -> Option<u32> {
    let n = value.as_f64()?;
    (n.fract() == 0.0 && (0.0..=f64::from(u32::MAX)).contains(&n)).then_some(n as u32)
}

struct Metadata {
    header: Json,
    slots: Vec<i32>,
    alpha: Vec<u32>,
    knockouts: Vec<u32>,
}

impl Default for Metadata {
    fn default() -> Self {
        Self {
            header: Json::Null,
            slots: Vec::new(),
            alpha: Vec::new(),
            knockouts: Vec::new(),
        }
    }
}

fn parse_metadata(bytes: &[u8]) -> Result<Metadata, String> {
    let utf8 = std::str::from_utf8(bytes)
        .map_err(|_| "The encoded data was not valid for encoding utf-8")?;
    let text = utf8.strip_prefix('\u{feff}').unwrap_or(utf8);
    let json_issue = |error: serde_json::Error| error.to_string();
    if !text
        .trim_start_matches([' ', '\t', '\n', '\r'])
        .starts_with('{')
    {
        serde_json::from_str::<&RawValue>(text).map_err(json_issue)?;
        return Ok(Metadata::default());
    }
    // Only the three dense planes bypass the ordered JSON representation.
    let fields: HashMap<String, &RawValue> = serde_json::from_str(text).map_err(json_issue)?;
    let mut header = Vec::new();
    for key in [
        "version",
        "palette",
        "swatchIds",
        "swatchLabels",
        "lockedSwatches",
        "ramps",
    ] {
        if let Some(raw) = fields.get(key) {
            let OrderedJson(value) = serde_json::from_str(raw.get()).map_err(json_issue)?;
            header.push((key.into(), value));
        }
    }
    let mut plane = |key: &str| -> Result<Vec<Value>, String> {
        let Some(raw) = fields.get(key) else {
            return Ok(Vec::new());
        };
        if raw.get().starts_with('[') {
            header.push((key.into(), Json::Array(Vec::new())));
            return serde_json::from_str(raw.get()).map_err(json_issue);
        }
        header.push((key.into(), Json::Null));
        Ok(Vec::new())
    };
    let slots = plane("slots")?
        .iter()
        .map(|row| {
            if row.is_null() {
                -1
            } else {
                annotation_word(row)
                    .and_then(|n| i32::try_from(n).ok())
                    .unwrap_or(-3)
            }
        })
        .collect();
    let word = |row: &Value| annotation_word(row).unwrap_or(u32::MAX);
    let alpha = plane("alpha")?.iter().map(word).collect();
    let knockouts = plane("knockouts")?.iter().map(word).collect();
    Ok(Metadata {
        header: Json::Object(header),
        slots,
        alpha,
        knockouts,
    })
}

pub fn open_pixel_png(bytes: &[u8]) -> Result<OpenedDocument, String> {
    let size = u32::try_from(bytes.len()).map_err(|_| "PNG file exceeds the import byte limit")?;
    let program = State::new();
    let layout = program.function_l_inspect_pixel_png(words(bytes), size)?;
    let slices = layout.l_data.iter().map(|range| {
        let start = range.l_start as usize;
        &bytes[start..start + range.l_length as usize]
    });
    let scanlines = inflate(slices, layout.l_raw_size as usize)?;
    let samples = program.function_l_decode_pixel_png(
        layout.clone(),
        words(&scanlines),
        scanlines.len() as u32,
    )?;
    let annotation = &layout.l_annotation;
    let metadata = if annotation.l_start == 0 {
        Metadata::default()
    } else {
        let start = annotation.l_start as usize;
        let bytes = inflate(
            [&bytes[start..start + annotation.l_length as usize]],
            layout.l_width as usize * layout.l_height as usize * 14 + 8_388_608,
        )?;
        parse_metadata(&bytes)?
    };
    let header = compiled_json(metadata.header, &|kind, scalar, flag, values, keys| {
        program.function_l_pixel_json_value(kind, scalar, flag, values, keys)
    });
    let imported = program.function_l_restore_pixel_png(
        layout,
        samples,
        header,
        metadata.slots,
        metadata.alpha,
        metadata.knockouts,
    )?;
    let limits = Limits::default();
    let template = Json::from_ink(&imported.l_template.to_json(), limits)?;
    let marks = imported
        .l_marks
        .into_iter()
        .map(|mark| {
            let start = mark.l_first as usize;
            let words = &imported.l_spans[start..start + mark.l_length as usize];
            SnapshotMark {
                swatch: None,
                knockout: mark.l_alpha == 255,
                alpha: (mark.l_alpha != 255).then_some(mark.l_alpha),
                runs: words
                    .iter()
                    .map(|&word| [word >> 18, (word >> 9) & 511, (word & 511) + 1])
                    .collect(),
                point: false,
            }
        })
        .collect();
    let mut edits = SnapshotEdits::new();
    edits.entry("artwork".into()).or_default().insert(
        "image".into(),
        SnapshotCel {
            marks,
            plane: Some(0),
        },
    );
    let document_json = snapshot_json(&template, 0, &[], &edits, &[imported.l_slots], limits)?;
    Ok(OpenedDocument {
        revision: revision(&document_json),
        document_json,
        legacy_revision: None,
    })
}
