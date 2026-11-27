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
