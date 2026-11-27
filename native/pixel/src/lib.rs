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

fn restore_named_pixels(input: &mut Json, width: u32, positions: Vec<Vec<u32>>) {
    let Json::Object(fields) = input else {
        return;
    };
    let Some(Json::Array(rows)) = fields
        .iter_mut()
        .find(|(key, _)| key == "selections")
        .map(|(_, v)| v)
    else {
        return;
    };
    for (row, positions) in rows.iter_mut().zip(positions) {
        if positions.is_empty() {
            continue;
        }
        let Json::Object(fields) = row else {
            continue;
        };
        if let Some((_, pixels)) = fields.iter_mut().find(|(key, _)| key == "pixels") {
            *pixels = Json::Array(
                positions
                    .into_iter()
                    .map(|p| {
                        Json::Array(vec![
                            Json::Number((p % width).to_string()),
                            Json::Number((p / width).to_string()),
                        ])
                    })
                    .collect(),
            );
        }
    }
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
    Ok(SelectionInput {
        nodes,
        saved: Json::Object(packed_saved),
        runs,
    })
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
    pub selection: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drawing: Option<serde_json::Value>,
}

fn is_false(value: &bool) -> bool {
    !value
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
        let OrderedJson(operation) =
            serde_json::from_str(operation).map_err(|error| error.to_string())?;
        let drawing = match &operation {
            Json::Object(items) => items
                .iter()
                .find(|(key, _)| key == "drawing")
                .map(|(_, value)| value),
            _ => None,
        }
        .map(|value| {
            serde_json::from_str(&value.stringify(Limits::default())?)
                .map_err(|err| err.to_string())
        })
        .transpose()?;
        let build = |kind, scalar, flag, values, keys| {
            self.program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        };
        let operation = compiled_json(operation, &build);
        let report = self
            .program
            .invoke_view_l_paint_pixel_editor(
                operation,
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
            selection: report.l_selection,
            drawing,
        })
    }

    pub fn snapshot(&mut self) -> Result<String, String> {
        let snapshot = self.program.invoke_view_l_snapshot_pixel_editor()?.result;
        let limits = Limits::default();
        let mut document = Json::from_ink(&snapshot.l_document.to_json(), limits)?;
        restore_named_pixels(&mut document, self.grid[0], snapshot.l_positions);
        document.stringify(limits)
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
