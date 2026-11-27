use compiled_state::{State, ValueWireLimits};
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

fn coordinate_runs([width, height]: [u32; 2], pixels: Json, limit: u32) -> Vec<u32> {
    let Json::Array(points) = pixels else {
        return Vec::new();
    };
    let count = points.len();
    if count > limit as usize {
        return Vec::new();
    }
    let mut runs = vec![count as u32];
    for point in points {
        let slot = match point {
            Json::Array(pair) if pair.len() == 2 => coordinate(&pair[0], width)
                .zip(coordinate(&pair[1], height))
                .map_or(u32::MAX, |(x, y)| y * width + x),
            _ => u32::MAX,
        };
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
    let limit = if large { 8192 } else { 512 };
    if width == 0 || height == 0 || width > limit || height > limit || width * height > 16_777_216 {
        return Err(if large {
            "Selection exceeds the material canvas budget"
        } else {
            "Pixel selections need a canvas from 1 to 512 pixels on each axis"
        }
        .into());
    }
    let OrderedJson(query) = serde_json::from_str(query).map_err(|error| error.to_string())?;
    let OrderedJson(saved) = serde_json::from_str(saved).map_err(|error| error.to_string())?;
    let canvas = [width, height];
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
    let program = State::new();
    let build = |kind, scalar, flag, values, keys| {
        program.function_l_pixel_json_value(kind, scalar, flag, values, keys)
    };
    let nodes = nodes
        .into_iter()
        .map(|node| compiled_json(node, &build))
        .collect();
    let saved = compiled_json(Json::Object(packed_saved), &build);
    program.function_l_select_pixel_words(nodes, width, height, rgba, saved, runs, large)
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
