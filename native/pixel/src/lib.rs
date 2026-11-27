use compiled_state::{State, ValueWireLimits, Wire};
use indexmap::IndexMap;
use ink_abi::{
    json_value::{Json, JsonCodec},
    value_wire::{Limits, Schema},
};
use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use sha2::{Digest, Sha256};
use std::{fmt, sync::LazyLock};

pub struct OpenedDocument {
    pub document_json: String,
    pub revision: String,
    pub legacy_revision: Option<String>,
}

#[derive(serde::Deserialize, serde::Serialize)]
pub struct IndexedSelectionRaster {
    pub slots: Vec<i32>,
    #[serde(default)]
    pub alpha: Vec<u32>,
    #[serde(default)]
    pub clipping: Vec<u32>,
    #[serde(default)]
    pub ids: Vec<String>,
}

#[derive(serde::Serialize)]
pub struct PixelFrameRaster {
    pub width: u32,
    pub height: u32,
    pub frame: Option<String>,
    #[serde(flatten)]
    pub indexed: IndexedSelectionRaster,
    pub rgba: Vec<u32>,
}

pub fn rasterize_pixel_frame(
    source: &str,
    frame: Option<&str>,
    layer: Option<&str>,
    cel: Option<&str>,
) -> Result<PixelFrameRaster, String> {
    let OrderedJson(input) = serde_json::from_str(source).map_err(|error| error.to_string())?;
    let program = State::new();
    let build = |kind, scalar, flag, values, keys| {
        program.function_l_pixel_json_value(kind, scalar, flag, values, keys)
    };
    let raster = program.function_l_rasterize_pixel_frame(
        compiled_json(input, &build),
        frame.unwrap_or_default().into(),
        layer.unwrap_or_default().into(),
        cel.unwrap_or_default().into(),
    )?;
    Ok(PixelFrameRaster {
        width: raster.l_width,
        height: raster.l_height,
        frame: (!raster.l_frame.is_empty()).then_some(raster.l_frame),
        indexed: IndexedSelectionRaster {
            slots: raster.l_slots,
            alpha: raster.l_alpha,
            clipping: raster.l_clipping,
            ids: raster.l_ids,
        },
        rgba: raster.l_rgba,
    })
}

// Parse with ECMAScript's number rounding, last-value-wins object semantics,
// and property order so both hosts calculate the same document revision.
struct OrderedJson(Json);

impl<'de> Deserialize<'de> for OrderedJson {
    fn deserialize<D: Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        de.deserialize_any(OrderedJsonVisitor)
    }
}

struct OrderedJsonVisitor;

impl<'de> Visitor<'de> for OrderedJsonVisitor {
    type Value = OrderedJson;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON value")
    }

    fn visit_unit<E: de::Error>(self) -> Result<OrderedJson, E> {
        Ok(OrderedJson(Json::Null))
    }

    fn visit_bool<E: de::Error>(self, value: bool) -> Result<OrderedJson, E> {
        Ok(OrderedJson(Json::Boolean(value)))
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<OrderedJson, E> {
        let mut buffer = ryu_js::Buffer::new();
        Ok(OrderedJson(Json::Number(
            buffer.format_finite(value).into(),
        )))
    }

    fn visit_i64<E: de::Error>(self, value: i64) -> Result<OrderedJson, E> {
        self.visit_f64(value as f64)
    }

    fn visit_u64<E: de::Error>(self, value: u64) -> Result<OrderedJson, E> {
        self.visit_f64(value as f64)
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<OrderedJson, E> {
        Ok(OrderedJson(Json::Text(value.into())))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<OrderedJson, A::Error> {
        let mut items = Vec::new();
        while let Some(OrderedJson(item)) = seq.next_element()? {
            items.push(item);
        }
        Ok(OrderedJson(Json::Array(items)))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<OrderedJson, A::Error> {
        let mut items = IndexMap::new();
        while let Some((key, OrderedJson(value))) = map.next_entry::<String, OrderedJson>()? {
            items.insert(key, value);
        }
        let mut entries: Vec<_> = items.into_iter().collect();
        entries.sort_by_cached_key(|(key, _)| array_index(key).unwrap_or(u32::MAX));
        Ok(OrderedJson(Json::Object(entries)))
    }
}

fn array_index(key: &str) -> Option<u32> {
    if key == "0" {
        return Some(0);
    }
    if !key
        .as_bytes()
        .first()
        .is_some_and(|b| (b'1'..=b'9').contains(b))
        || !key.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    key.parse::<u32>().ok().filter(|&index| index < u32::MAX)
}

const OPEN: &str = "open_pixel_document";

static DOCUMENT_CODEC: LazyLock<Result<JsonCodec, String>> = LazyLock::new(|| {
    let (input, _) = State::binary_schemas(OPEN)?;
    let document = input.root()["fields"][0]["type"].clone();
    JsonCodec::new(Schema::new(document, input.named().clone())?)
});

fn revision(document: &str) -> String {
    format!("{:x}", Sha256::digest(document.as_bytes()))
}

fn coordinate(value: &Json, limit: u32) -> Option<u32> {
    let Json::Number(token) = value else {
        return None;
    };
    token.parse::<u32>().ok().filter(|&n| n < limit)
}

fn coordinate_slot([width, height]: [u32; 2], point: &Json) -> u32 {
    match point {
        Json::Array(pair) if pair.len() == 2 => coordinate(&pair[0], width)
            .zip(coordinate(&pair[1], height))
            .map_or(u32::MAX, |(x, y)| y * width + x),
        _ => u32::MAX,
    }
}

fn member_mut<'a>(value: &'a mut Json, name: &str) -> Option<&'a mut Json> {
    let Json::Object(fields) = value else {
        return None;
    };
    fields
        .iter_mut()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value)
}

fn take_array(value: &mut Json, name: &str) -> Option<Vec<Json>> {
    let Json::Array(rows) = member_mut(value, name)? else {
        return None;
    };
    Some(std::mem::take(rows))
}

fn pack_brush_slots(operation: &mut Json) -> Vec<i32> {
    let Some(rows) = member_mut(operation, "brush").and_then(|brush| take_array(brush, "slots"))
    else {
        return Vec::new();
    };
    if rows.len() > 512 * 512 {
        return Vec::new();
    }
    rows.into_iter()
        .map(|row| match row {
            Json::Null => -1,
            Json::Number(token) => token
                .parse::<i32>()
                .ok()
                .filter(|n| (0..255).contains(n))
                .unwrap_or(-2),
            _ => -2,
        })
        .collect()
}

fn clipboard_slot(slot: i32) -> i32 {
    if (-2..255).contains(&slot) { slot } else { -4 }
}

fn pack_clipboard(operation: &mut Json) -> (Vec<i32>, Vec<u32>) {
    let Some(clipboard) = member_mut(operation, "clipboard") else {
        return (Vec::new(), Vec::new());
    };
    let slots = take_array(clipboard, "slots")
        .filter(|rows| rows.len() <= 512 * 512)
        .map_or_else(Vec::new, |rows| {
            rows.into_iter()
                .map(|row| match row {
                    Json::Null => -3,
                    Json::Number(token) => token.parse::<i32>().map_or(-4, clipboard_slot),
                    _ => -4,
                })
                .collect()
        });
    let alpha = take_array(clipboard, "alpha")
        .filter(|rows| rows.len() <= 512 * 512)
        .map_or_else(Vec::new, |rows| {
            rows.iter()
                .map(|value| coordinate(value, 256).unwrap_or(u32::MAX))
                .collect()
        });
    (slots, alpha)
}

fn rgba_row(row: Json, canvas: [u32; 2], names: &mut IndexMap<String, u32>) -> [u32; 3] {
    let invalid = [u32::MAX, 0, u32::MAX];
    let Json::Object(fields) = row else {
        return invalid;
    };
    let mut p = u32::MAX;
    let mut rgba = None;
    let mut swatch = None;
    for (key, value) in fields {
        match key.as_str() {
            "at" => p = coordinate_slot(canvas, &value),
            "rgba" => rgba = Some(value),
            "swatch" => swatch = Some(value),
            _ => return invalid,
        }
    }
    if p == u32::MAX {
        return invalid;
    }
    if matches!(rgba, Some(Json::Null)) && swatch.is_none() {
        return [p + 262144, 0, u32::MAX];
    }
    let Some(Json::Array(bytes)) = rgba else {
        return invalid;
    };
    if bytes.len() != 4 {
        return invalid;
    }
    let mut encoded = 0;
    for byte in bytes {
        let Some(n) = coordinate(&byte, 256) else {
            return invalid;
        };
        encoded = (encoded << 8) | n;
    }
    let name = swatch.map_or(u32::MAX, |raw| {
        let key = if let Json::Text(name) = raw {
            name
        } else {
            String::new()
        };
        let ordinal = names.len() as u32;
        *names.entry(key).or_insert(ordinal)
    });
    [p, encoded, name]
}

fn pack_rgba(operation: &mut Json, [width, height]: [u32; 2]) -> (Vec<u32>, Vec<String>) {
    if !matches!(member_mut(operation, "tool"), Some(Json::Text(t)) if t == "rgba") {
        return (Vec::new(), Vec::new());
    }
    let Some(input) = take_array(operation, "pixels") else {
        return (Vec::new(), Vec::new());
    };
    if input.len() > (width * height) as usize {
        return (Vec::new(), Vec::new());
    }
    let mut names = IndexMap::new();
    let rows = input
        .into_iter()
        .flat_map(|row| rgba_row(row, [width, height], &mut names))
        .collect();
    (rows, names.into_keys().collect())
}

fn pack_named_pixels(input: &mut Json) -> Vec<Vec<u32>> {
    let Json::Object(fields) = input else {
        return Vec::new();
    };
    let Some(Json::Number(version)) = fields
        .iter()
        .find(|(key, _)| key == "version")
        .map(|(_, v)| v)
    else {
        return Vec::new();
    };
    if version != "2" {
        return Vec::new();
    }
    let dimension = |name: &str| {
        fields
            .iter()
            .find(|(key, _)| key == name)
            .and_then(|(_, value)| coordinate(value, 513))
            .filter(|&n| n != 0)
    };
    let Some(canvas) = dimension("width")
        .zip(dimension("height"))
        .map(|(w, h)| [w, h])
    else {
        return Vec::new();
    };
    let Some(Json::Array(rows)) = fields
        .iter_mut()
        .find(|(key, _)| key == "selections")
        .map(|(_, v)| v)
    else {
        return Vec::new();
    };
    rows.iter_mut()
        .map(|row| {
            let Json::Object(fields) = row else {
                return Vec::new();
            };
            let Some(Json::Array(pixels)) = fields
                .iter_mut()
                .find(|(key, _)| key == "pixels")
                .map(|(_, v)| v)
            else {
                return Vec::new();
            };
            std::mem::take(pixels)
                .iter()
                .map(|point| coordinate_slot(canvas, point))
                .collect()
        })
        .collect()
}

fn snapshot_cel_marks<'a>(
    document: &'a mut Json,
    frame_id: &str,
    layer: &str,
) -> Option<&'a mut Vec<Json>> {
    let Json::Array(frames) = member_mut(document, "frames")? else {
        return None;
    };
    let frame = frames.iter_mut().find(|frame| {
        matches!(frame, Json::Object(fields) if fields.iter().any(|(key, value)| {
            key == "id" && matches!(value, Json::Text(id) if id == frame_id)
        }))
    })?;
    let cel = member_mut(member_mut(frame, "cels")?, layer)?;
    let Json::Array(marks) = member_mut(cel, "marks")? else {
        return None;
    };
    Some(marks)
}

fn snapshot_mark(
    swatch: Option<String>,
    knockout: bool,
    alpha: Option<u32>,
    runs: Vec<[u32; 3]>,
) -> Json {
    let pigment = if let Some(alpha) = alpha {
        ("alpha", Json::Number(alpha.to_string()))
    } else if let Some(swatch) = swatch {
        ("swatch", Json::Text(swatch))
    } else if knockout {
        ("swatch", Json::Null)
    } else {
        ("clear", Json::Boolean(true))
    };
    let spans = runs
        .into_iter()
        .map(|run| {
            Json::Array(
                run.into_iter()
                    .map(|n| Json::Number(n.to_string()))
                    .collect(),
            )
        })
        .collect();
    Json::Object(vec![
        (pigment.0.into(), pigment.1),
        ("runs".into(), Json::Array(spans)),
    ])
}

fn append_json_members(
    out: &mut String,
    fields: &[(String, Json)],
    mut write_value: impl FnMut(&mut String, &str, &Json) -> Result<(), String>,
) -> Result<(), String> {
    out.push('{');
    for (i, (key, value)) in fields.iter().enumerate() {
        if i != 0 {
            out.push(',');
        }
        out.push_str(&serde_json::to_string(key).map_err(|error| error.to_string())?);
        out.push(':');
        write_value(out, key, value)?;
    }
    out.push('}');
    Ok(())
}

fn append_snapshot_selections(
    out: &mut String,
    rows: &[Json],
    width: u32,
    positions: &[Vec<u32>],
    limits: Limits,
) -> Result<(), String> {
    use std::fmt::Write;
    out.push('[');
    for (i, row) in rows.iter().enumerate() {
        if i != 0 {
            out.push(',');
        }
        if let (Json::Object(fields), Some(sites)) =
            (row, positions.get(i).filter(|row| !row.is_empty()))
        {
            append_json_members(out, fields, |out, key, value| {
                if key != "pixels" {
                    out.push_str(&value.stringify(limits)?);
                    return Ok(());
                }
                out.push('[');
                for (i, p) in sites.iter().enumerate() {
                    if i != 0 {
                        out.push(',');
                    }
                    write!(out, "[{},{}]", p % width, p / width)
                        .map_err(|error| error.to_string())?;
                }
                out.push(']');
                Ok(())
            })?;
        } else {
            out.push_str(&row.stringify(limits)?);
        }
    }
    out.push(']');
    Ok(())
}

fn snapshot_json(
    document: &Json,
    width: u32,
    positions: &[Vec<u32>],
    limits: Limits,
) -> Result<String, String> {
    let Json::Object(fields) = document else {
        return document.stringify(limits);
    };
    if positions.iter().all(Vec::is_empty) {
        return document.stringify(limits);
    }
    // The metadata is still bounded by the JSON codec. Saved coordinates
    // already crossed the typed boundary and serialize straight to the file.
    let mut output = String::new();
    append_json_members(&mut output, fields, |out, key, value| {
        if let ("selections", Json::Array(rows)) = (key, value) {
            append_snapshot_selections(out, rows, width, positions, limits)
        } else {
            out.push_str(&value.stringify(limits)?);
            Ok(())
        }
    })?;
    Ok(output)
}

fn coordinate_runs(canvas: [u32; 2], pixels: Json, limit: u32) -> Vec<u32> {
    let Json::Array(points) = pixels else {
        return Vec::new();
    };
    let count = points.len();
    if count > limit as usize {
        return Vec::new();
    }
    let mut runs = vec![count as u32];
    for point in points {
        let slot = coordinate_slot(canvas, &point);
        let end = runs.len() - 1;
        if end > 0 && runs[end - 1].checked_add(runs[end]) == Some(slot) {
            runs[end] += 1;
        } else {
            runs.extend([slot, 1]);
        }
    }
    runs
}

fn append_runs(canvas: [u32; 2], pixels: Json, limit: u32, runs: &mut Vec<Vec<u32>>) -> Json {
    runs.push(coordinate_runs(canvas, pixels, limit));
    Json::Number(runs.len().to_string())
}

// Flatten the recursive query references before crossing the compiled boundary.
fn append_selection_node(
    mut node: Json,
    canvas: [u32; 2],
    nodes: &mut Vec<Json>,
    runs: &mut Vec<Vec<u32>>,
) -> u32 {
    if nodes.len() == 33 {
        return 0;
    }
    let index = nodes.len();
    nodes.push(Json::Null);
    if let Json::Object(fields) = &mut node {
        let coordinates = fields.iter().find_map(|(key, value)| {
            if key != "type" {
                return None;
            }
            match value {
                Json::Text(kind) if kind == "pixels" => Some(("pixels", canvas[0] * canvas[1])),
                Json::Text(kind) if kind == "lasso" => Some(("points", 4096)),
                Json::Text(kind) if kind == "polygon" => Some(("points", 128)),
                _ => None,
            }
        });
        if let Some((field, limit)) = coordinates {
            if let Some((_, pixels)) = fields.iter_mut().find(|(name, _)| name == field) {
                *pixels = append_runs(canvas, std::mem::replace(pixels, Json::Null), limit, runs);
            }
        }
        for key in ["base", "with", "source"] {
            if let Some((_, value)) = fields.iter_mut().find(|(name, _)| name == key) {
                let child = append_selection_node(
                    std::mem::replace(value, Json::Null),
                    canvas,
                    nodes,
                    runs,
                );
                *value = Json::Number(child.to_string());
            }
        }
    }
    nodes[index] = node;
    index as u32 + 1
}

fn compiled_json<T>(value: Json, make: &impl Fn(u32, String, bool, Vec<T>, Vec<String>) -> T) -> T {
    match value {
        Json::Null => make(0, String::new(), false, Vec::new(), Vec::new()),
        Json::Boolean(flag) => make(1, String::new(), flag, Vec::new(), Vec::new()),
        Json::Number(token) => make(2, token, false, Vec::new(), Vec::new()),
        Json::Text(text) => make(3, text, false, Vec::new(), Vec::new()),
        Json::Array(items) => make(
            4,
            String::new(),
            false,
            items
                .into_iter()
                .map(|item| compiled_json(item, make))
                .collect(),
            Vec::new(),
        ),
        Json::Object(items) => {
            let (keys, values) = items
                .into_iter()
                .map(|(key, value)| (key, compiled_json(value, make)))
                .unzip();
            make(5, String::new(), false, values, keys)
        }
    }
}

pub fn select_pixels(
    width: u32,
    height: u32,
    query: &str,
    rgba: Vec<u32>,
    saved: &str,
) -> Result<Vec<[u32; 2]>, String> {
    let words = select_pixel_mask(width, height, query, rgba, saved, false)?;
    Ok(mask_pixels(width, &words))
}

pub fn mask_pixels(width: u32, words: &[u32]) -> Vec<[u32; 2]> {
    let mut pixels = Vec::new();
    for (i, &word) in words.iter().enumerate() {
        let mut bits = word;
        while bits != 0 {
            let slot = i as u32 * 32 + bits.trailing_zeros();
            pixels.push([slot % width, slot / width]);
            bits &= bits - 1;
        }
    }
    pixels
}

pub fn select_pixel_mask(
    width: u32,
    height: u32,
    query: &str,
    rgba: Vec<u32>,
    saved: &str,
    large: bool,
) -> Result<Vec<u32>, String> {
    select_pixel_mask_with_raster(width, height, query, rgba, saved, large, None)
}

pub fn select_pixel_mask_with_raster(
    width: u32,
    height: u32,
    query: &str,
    rgba: Vec<u32>,
    saved: &str,
    large: bool,
    indexed: Option<IndexedSelectionRaster>,
) -> Result<Vec<u32>, String> {
    let limit = if large { 8192 } else { 512 };
    if width == 0 || height == 0 || width > limit || height > limit || width * height > 16_777_216 {
        return Err(if large {
            "Selection exceeds the material canvas budget"
        } else {
            "Pixel selections need a canvas from 1 to 512 pixels on each axis"
        }
        .into());
    }
    let prepared = prepare_selection([width, height], query, saved)?;
    let program = State::new();
    let build = |kind, scalar, flag, values, keys| {
        program.function_l_pixel_json_value(kind, scalar, flag, values, keys)
    };
    let (nodes, saved, runs) = prepared.compile(&build);
    match indexed {
        Some(indexed) => program.function_l_select_pixel_words_from_raster(
            nodes,
            width,
            height,
            rgba,
            saved,
            runs,
            large,
            indexed.slots,
            indexed.alpha,
            indexed.clipping,
            indexed.ids,
        ),
        None => {
            program.function_l_select_pixel_words(nodes, width, height, rgba, saved, runs, large)
        }
    }
}

struct SelectionInput {
    nodes: Vec<Json>,
    saved: Json,
    runs: Vec<Vec<u32>>,
}

impl SelectionInput {
    fn compile<T>(
        self,
        build: &impl Fn(u32, String, bool, Vec<T>, Vec<String>) -> T,
    ) -> (Vec<T>, T, Vec<Vec<u32>>) {
        let nodes = self
            .nodes
            .into_iter()
            .map(|node| compiled_json(node, build))
            .collect();
        (nodes, compiled_json(self.saved, build), self.runs)
    }
}

fn prepare_selection(canvas: [u32; 2], query: &str, saved: &str) -> Result<SelectionInput, String> {
    let OrderedJson(query) = serde_json::from_str(query).map_err(|error| error.to_string())?;
    let OrderedJson(saved) = serde_json::from_str(saved).map_err(|error| error.to_string())?;
    Ok(prepare_selection_value(canvas, query, saved))
}

fn prepare_selection_value(canvas: [u32; 2], query: Json, saved: Json) -> SelectionInput {
    let [width, height] = canvas;
    let mut runs = Vec::new();
    let mut nodes = Vec::new();
    append_selection_node(query, canvas, &mut nodes, &mut runs);
    let mut packed_saved = Vec::new();
    if let Json::Object(entries) = saved {
        for (id, pixels) in entries {
            let used = nodes.iter().any(|node| match node {
                Json::Object(fields) => {
                    fields.iter().any(|(k, v)| {
                        k == "type" && matches!(v, Json::Text(kind) if kind == "recall")
                    }) && fields
                        .iter()
                        .any(|(k, v)| k == "id" && matches!(v, Json::Text(name) if *name == id))
                }
                _ => false,
            });
            if used {
                packed_saved.push((id, append_runs(canvas, pixels, width * height, &mut runs)));
            }
        }
    }
    SelectionInput {
        nodes,
        saved: Json::Object(packed_saved),
        runs,
    }
}

#[derive(Debug, PartialEq, serde::Serialize)]
pub struct PixelSelection {
    pub frame: String,
    pub grid: [u32; 2],
    pub pixels: Vec<[u32; 2]>,
}

#[derive(Debug, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RasterPaintReport {
    pub destination: &'static str,
    pub kind: &'static str,
    pub frame: String,
    pub layer: String,
    pub cel: String,
    pub tool: String,
    pub pixel_count: u32,
    pub runs: Vec<[u32; 3]>,
    #[serde(skip_serializing_if = "is_false")]
    pub pixel_perfect: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shape: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shading: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ramp: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub added_swatches: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drawing: Option<serde_json::Value>,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    pub transform: Option<SelectionTransformReport>,
}

#[derive(Debug, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectionTransformReport {
    pub bounds: [i32; 4],
    pub clipped_pixels: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_selection: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection_runs: Option<Vec<[u32; 3]>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub carried_protection: Vec<CarriedProtection>,
}

#[derive(Debug, PartialEq, serde::Serialize)]
pub struct CarriedProtection {
    pub id: String,
    pub kind: String,
    pub frame: String,
    pub pixels: Vec<[u32; 2]>,
}

fn is_false(value: &bool) -> bool {
    !value
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedSelectionReport {
    pub destination: &'static str,
    pub kind: &'static str,
    pub frame: String,
    pub selection: String,
    pub tool: String,
    pub pixel_count: u32,
    pub runs: Vec<[u32; 3]>,
}

#[derive(Debug, serde::Serialize)]
pub struct CapturedBrush {
    pub format: &'static str,
    pub version: u32,
    pub width: u32,
    pub height: u32,
    pub anchor: [u32; 2],
    pub palette: Vec<CapturedBrushSwatch>,
    pub slots: Vec<Option<u32>>,
    pub settings: Box<serde_json::value::RawValue>,
}

#[derive(Debug, serde::Serialize)]
pub struct CapturedBrushSwatch {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub color: String,
}

#[derive(Debug, serde::Serialize)]
pub struct CopiedSelection {
    pub format: &'static str,
    pub version: u32,
    pub width: u32,
    pub height: u32,
    pub origin: [u32; 2],
    pub palette: Vec<CapturedBrushSwatch>,
    pub slots: Vec<Option<i32>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub alpha: Vec<u32>,
}

#[derive(Debug, Default)]
pub struct PasteOptions<'a> {
    pub layer: Option<&'a str>,
    pub result_selection: Option<&'a str>,
    pub transform: PasteTransform<'a>,
}

#[derive(Debug, Default)]
pub struct PasteTransform<'a> {
    pub at: Option<[i32; 2]>,
    pub offset: Option<[i32; 2]>,
    pub size: Option<[u32; 2]>,
    pub angle: Option<f64>,
    pub flip_x: Option<bool>,
    pub flip_y: Option<bool>,
    pub rotation: Option<&'a str>,
}

impl PasteTransform<'_> {
    fn into_metadata(self) -> Json {
        let mut fields = Vec::new();
        let signed_pair = |pair: [i32; 2]| {
            Json::Array(
                pair.into_iter()
                    .map(|n| Json::Number(n.to_string()))
                    .collect(),
            )
        };
        if let Some(at) = self.at {
            fields.push(("at".into(), signed_pair(at)));
        }
        if let Some(offset) = self.offset {
            fields.push(("offset".into(), signed_pair(offset)));
        }
        if let Some(size) = self.size {
            fields.push((
                "size".into(),
                Json::Array(
                    size.into_iter()
                        .map(|n| Json::Number(n.to_string()))
                        .collect(),
                ),
            ));
        }
        if let Some(angle) = self.angle {
            let angle = if angle.is_finite() {
                Json::Number(ryu_js::Buffer::new().format_finite(angle).into())
            } else {
                Json::Null
            };
            fields.push(("angle".into(), angle));
        }
        if let Some(flip_x) = self.flip_x {
            fields.push(("flipX".into(), Json::Boolean(flip_x)));
        }
        if let Some(flip_y) = self.flip_y {
            fields.push(("flipY".into(), Json::Boolean(flip_y)));
        }
        if let Some(rotation) = self.rotation {
            fields.push(("rotation".into(), Json::Text(rotation.into())));
        }
        Json::Object(fields)
    }
}

#[derive(Default)]
struct PaintInputs {
    slots: Vec<i32>,
    alpha: Vec<u32>,
    pixels: Vec<u32>,
    names: Vec<String>,
}

fn clipboard_metadata(clipboard: &CopiedSelection) -> Json {
    let palette = clipboard.palette.iter().map(|swatch| {
        let mut fields = Vec::with_capacity(2);
        if let Some(id) = &swatch.id {
            fields.push(("id".into(), Json::Text(id.clone())));
        }
        fields.push(("color".into(), Json::Text(swatch.color.clone())));
        Json::Object(fields)
    });
    let mut fields = vec![
        ("format".into(), Json::Text(clipboard.format.into())),
        (
            "version".into(),
            Json::Number(clipboard.version.to_string()),
        ),
        ("width".into(), Json::Number(clipboard.width.to_string())),
        ("height".into(), Json::Number(clipboard.height.to_string())),
        (
            "origin".into(),
            Json::Array(
                clipboard
                    .origin
                    .iter()
                    .map(|n| Json::Number(n.to_string()))
                    .collect(),
            ),
        ),
        ("palette".into(), Json::Array(palette.collect())),
        ("slots".into(), Json::Array(Vec::new())),
    ];
    if !clipboard.alpha.is_empty() {
        fields.push(("alpha".into(), Json::Array(Vec::new())));
    }
    Json::Object(fields)
}

pub struct PixelEditor {
    program: State,
    grid: [u32; 2],
}

impl PixelEditor {
    pub fn new(source: &str) -> Result<Self, String> {
        let mut editor = Self {
            program: State::new(),
            grid: [0, 0],
        };
        editor.replace_document(source)?;
        Ok(editor)
    }

    pub fn replace_document(&mut self, source: &str) -> Result<(), String> {
        let OrderedJson(mut input) =
            serde_json::from_str(source).map_err(|error| error.to_string())?;
        let build = |kind, scalar, flag, values, keys| {
            self.program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        };
        let positions = pack_named_pixels(&mut input);
        let document = compiled_json(input, &build);
        let grid = self
            .program
            .invoke_view_l_load_pixel_editor(document, positions)?
            .result?;
        self.grid = [grid.l_width, grid.l_height];
        Ok(())
    }

    pub fn paint(
        &mut self,
        operation: &str,
        frame: Option<&str>,
        cel: Option<&str>,
    ) -> Result<RasterPaintReport, String> {
        let OrderedJson(mut operation) =
            serde_json::from_str(operation).map_err(|error| error.to_string())?;
        let (slots, alpha) = if matches!(member_mut(&mut operation, "tool"), Some(Json::Text(tool)) if tool == "paste")
        {
            pack_clipboard(&mut operation)
        } else {
            (pack_brush_slots(&mut operation), Vec::new())
        };
        let (pixels, names) = pack_rgba(&mut operation, self.grid);
        self.paint_inputs(
            operation,
            PaintInputs {
                slots,
                alpha,
                pixels,
                names,
            },
            frame,
            cel,
        )
    }

    /// Paste a typed clipboard, including its index and opacity planes.
    pub fn paste_clipboard(
        &mut self,
        clipboard: CopiedSelection,
        options: PasteOptions<'_>,
        frame: Option<&str>,
        cel: Option<&str>,
    ) -> Result<RasterPaintReport, String> {
        let mut fields = vec![
            ("tool".into(), Json::Text("paste".into())),
            ("clipboard".into(), clipboard_metadata(&clipboard)),
            ("transform".into(), options.transform.into_metadata()),
        ];
        if let Some(layer) = options.layer {
            fields.push(("layer".into(), Json::Text(layer.into())));
        }
        if let Some(selection) = options.result_selection {
            fields.push(("resultSelection".into(), Json::Text(selection.into())));
        }
        let inputs = PaintInputs {
            slots: clipboard
                .slots
                .into_iter()
                .map(|slot| slot.map_or(-3, clipboard_slot))
                .collect(),
            alpha: clipboard.alpha,
            ..PaintInputs::default()
        };
        self.paint_inputs(Json::Object(fields), inputs, frame, cel)
    }

    fn paint_inputs(
        &mut self,
        mut operation: Json,
        input: PaintInputs,
        frame: Option<&str>,
        cel: Option<&str>,
    ) -> Result<RasterPaintReport, String> {
        let drawing = member_mut(&mut operation, "drawing")
            .map(|value| {
                serde_json::from_str(&value.stringify(Limits::default())?)
                    .map_err(|err| err.to_string())
            })
            .transpose()?;
        let operation = compiled_json(operation, &|kind, scalar, flag, values, keys| {
            self.program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        });
        let report = self
            .program
            .invoke_view_l_paint_pixel_editor(
                operation,
                input.slots,
                input.alpha,
                input.pixels,
                input.names,
                frame.map(str::to_owned),
                cel.map(str::to_owned),
            )?
            .result?;
        Ok(RasterPaintReport {
            destination: "raster",
            kind: "raster",
            frame: report.l_frame,
            layer: report.l_layer,
            cel: report.l_cel,
            tool: report.l_tool,
            pixel_count: report.l_pixelCount,
            runs: report.l_runs,
            pixel_perfect: report.l_pixelPerfect,
            shape: report.l_shape,
            shading: report.l_shading,
            ramp: report.l_ramp,
            added_swatches: report.l_addedSwatches,
            from: report.l_from,
            to: report.l_to,
            selection: report.l_selection,
            drawing,
            transform: report.l_transform.map(|value| SelectionTransformReport {
                bounds: value.l_bounds,
                clipped_pixels: value.l_clippedPixels,
                mode: value.l_mode,
                selection_runs: value
                    .l_resultSelection
                    .as_ref()
                    .map(|_| value.l_selectionRuns),
                result_selection: value.l_resultSelection,
                carried_protection: value
                    .l_carriedProtection
                    .into_iter()
                    .map(|row| CarriedProtection {
                        id: row.l_id,
                        kind: row.l_kind,
                        frame: row.l_frame,
                        pixels: row.l_pixels,
                    })
                    .collect(),
            }),
        })
    }

    pub fn save_selection(
        &mut self,
        operation: &str,
        frame: Option<&str>,
    ) -> Result<SavedSelectionReport, String> {
        let OrderedJson(mut operation) =
            serde_json::from_str(operation).map_err(|error| error.to_string())?;
        let query = member_mut(&mut operation, "query")
            .map_or(Json::Null, |value| std::mem::replace(value, Json::Null));
        let build = |kind, scalar, flag, values, keys| {
            self.program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        };
        let (nodes, _, runs) =
            prepare_selection_value(self.grid, query, Json::Object(Vec::new())).compile(&build);
        let metadata = compiled_json(operation, &build);
        let report = self
            .program
            .invoke_view_l_save_pixel_editor_selection(
                metadata,
                nodes,
                runs,
                frame.map(str::to_owned),
            )?
            .result?;
        Ok(SavedSelectionReport {
            destination: "selections",
            kind: "selections",
            frame: report.l_frame,
            selection: report.l_selection,
            tool: report.l_tool,
            pixel_count: report.l_pixelCount,
            runs: report.l_runs,
        })
    }

    pub fn capture_brush(&mut self, options: &str) -> Result<CapturedBrush, String> {
        let OrderedJson(mut options) =
            serde_json::from_str(options).map_err(|error| error.to_string())?;
        let canvas = self.grid;
        let pixels = take_array(&mut options, "pixels")
            .filter(|rows| rows.len() <= (canvas[0] * canvas[1]) as usize)
            .map_or_else(Vec::new, |rows| {
                rows.iter()
                    .map(|row| coordinate_slot(canvas, row))
                    .collect()
            });
        let encoded = compiled_json(options, &|kind, scalar, flag, values, keys| {
            self.program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        });
        let result = self
            .program
            .invoke_view_l_capture_pixel_editor_brush(encoded, pixels)?
            .result?;
        let limits = Limits::default();
        let settings = Json::from_ink(&result.l_settings.to_json(), limits)?.stringify(limits)?;
        Ok(CapturedBrush {
            format: "ink-studio/pixel-brush",
            version: 1,
            width: result.l_width,
            height: result.l_height,
            anchor: result.l_anchor,
            palette: result
                .l_palette
                .into_iter()
                .map(|row| CapturedBrushSwatch {
                    id: (!row.l_id.is_empty()).then_some(row.l_id),
                    color: row.l_color,
                })
                .collect(),
            slots: result
                .l_slots
                .into_iter()
                .map(|slot| u32::try_from(slot).ok())
                .collect(),
            settings: serde_json::value::RawValue::from_string(settings)
                .map_err(|error| error.to_string())?,
        })
    }

    pub fn copy_selection(&mut self, options: &str) -> Result<CopiedSelection, String> {
        let OrderedJson(input) =
            serde_json::from_str(options).map_err(|error| error.to_string())?;
        let encoded = compiled_json(input, &|kind, scalar, flag, values, keys| {
            self.program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        });
        let result = self
            .program
            .invoke_view_l_copy_pixel_editor_selection(encoded)?
            .result?;
        Ok(CopiedSelection {
            format: "ink-studio/pixel-clipboard",
            version: 2,
            width: result.l_width,
            height: result.l_height,
            origin: result.l_origin,
            palette: result
                .l_palette
                .into_iter()
                .map(|row| CapturedBrushSwatch {
                    id: (!row.l_id.is_empty()).then_some(row.l_id),
                    color: row.l_color,
                })
                .collect(),
            slots: result
                .l_slots
                .into_iter()
                .map(|slot| (slot != -3).then_some(slot))
                .collect(),
            alpha: result.l_alpha,
        })
    }

    pub fn snapshot(&mut self) -> Result<String, String> {
        let snapshot = self.program.invoke_view_l_snapshot_pixel_editor()?.result;
        let limits = Limits::default();
        let mut document = Json::from_ink(&snapshot.l_document.to_json(), limits)?;
        for edit in snapshot.l_edits {
            let marks = snapshot_cel_marks(&mut document, &edit.l_frame, &edit.l_layer)
                .ok_or("Missing retained raster cel in the snapshot")?;
            marks.extend(edit.l_marks.into_iter().map(|mark| {
                snapshot_mark(mark.l_swatch, mark.l_knockout, mark.l_alpha, mark.l_runs)
            }));
        }
        snapshot_json(&document, self.grid[0], &snapshot.l_positions, limits)
    }

    pub fn select(
        &mut self,
        query: &str,
        frame: Option<&str>,
        layer: Option<&str>,
        cel: Option<&str>,
        saved: &str,
    ) -> Result<PixelSelection, String> {
        let build = |kind, scalar, flag, values, keys| {
            self.program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        };
        let (nodes, saved, runs) = prepare_selection(self.grid, query, saved)?.compile(&build);
        let selected = self
            .program
            .invoke_view_l_select_pixel_editor(
                nodes,
                saved,
                runs,
                frame.map(str::to_owned),
                layer.map(str::to_owned),
                cel.map(str::to_owned),
            )?
            .result?;
        Ok(PixelSelection {
            frame: selected.l_frame,
            grid: [selected.l_grid.l_width, selected.l_grid.l_height],
            pixels: mask_pixels(selected.l_grid.l_width, &selected.l_words),
        })
    }
}

pub fn open_pixel_document(source: &str) -> Result<OpenedDocument, String> {
    let OrderedJson(input) = serde_json::from_str(source).map_err(|error| error.to_string())?;
    let limits = Limits::default();
    let canonical = input.stringify(limits)?;
    let codec = DOCUMENT_CODEC.as_ref().map_err(Clone::clone)?;
    let (args, result) = State::binary_schemas(OPEN)?;
    let abi_limits = ValueWireLimits::default();

    let document = codec.parse_binary(&canonical, limits)?;
    let document = codec.schema().validate(&document, limits)?;
    let bytes = args.encode_with(abi_limits, |w| w.frame(|w| w.bytes(document.payload())))?;
    let reply = State::new().call_binary(OPEN, &bytes, abi_limits)?;
    let (failed, value) = result.validate(&reply, abi_limits)?.variant()?;
    let value = value.ok_or("Missing pixel document result")?;
    if failed {
        return Err(value.text()?.into());
    }
    let legacy = value
        .field("legacy")?
        .ok_or("Missing pixel legacy flag")?
        .body()?
        == [1];
    let document = value
        .field("document")?
        .ok_or("Missing opened pixel document")?;
    let bytes = codec
        .schema()
        .encode_with(limits, |w| w.bytes(document.payload()))?;
    let document_json = codec.stringify_binary(&bytes, limits)?;
    Ok(OpenedDocument {
        revision: revision(&document_json),
        legacy_revision: legacy.then(|| revision(&canonical)),
        document_json,
    })
}
