use super::{Json, OrderedJson, array_index, coordinate};
use indexmap::IndexMap;
use serde::de::{Deserialize, Deserializer, MapAccess, Visitor};
use serde_json::value::RawValue;
use std::{borrow::Cow, fmt};

pub(super) struct SlotPlane {
    pub frame: String,
    pub layer: String,
    pub slots: Vec<i32>,
}

pub(super) struct RunPlane {
    pub frame: String,
    pub layer: String,
    pub marks: Vec<Vec<u32>>,
}

#[derive(Default)]
pub(super) struct CelPlanes {
    pub slots: Vec<SlotPlane>,
    pub runs: Vec<RunPlane>,
}

struct Fields<'a>(Vec<(String, &'a RawValue)>);

impl<'de> Deserialize<'de> for Fields<'de> {
    fn deserialize<D: Deserializer<'de>>(input: D) -> Result<Self, D::Error> {
        struct ReadFields;
        impl<'de> Visitor<'de> for ReadFields {
            type Value = Fields<'de>;

            fn expecting(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
                out.write_str("an ordered pixel document object")
            }

            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
                let mut fields = IndexMap::new();
                while let Some((key, raw)) = map.next_entry::<String, &'de RawValue>()? {
                    fields.insert(key, raw);
                }
                let mut fields: Vec<_> = fields.into_iter().collect();
                fields.sort_by_cached_key(|(key, _)| array_index(key).unwrap_or(u32::MAX));
                Ok(Fields(fields))
            }
        }
        input.deserialize_map(ReadFields)
    }
}

fn parse<'a, T: Deserialize<'a>>(source: &'a str) -> Result<T, String> {
    serde_json::from_str(source).map_err(|error| error.to_string())
}

fn json(raw: &RawValue) -> Result<Json, String> {
    parse(raw.get()).map(|OrderedJson(value)| value)
}

impl<'a> Fields<'a> {
    fn read(raw: &'a RawValue) -> Result<Option<Self>, String> {
        if raw.get().starts_with('{') {
            parse(raw.get()).map(Some)
        } else {
            Ok(None)
        }
    }

    fn get(&self, name: &str) -> Option<&'a RawValue> {
        self.0
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, raw)| *raw)
    }

    fn id(&self) -> Option<String> {
        self.get("id")
            .and_then(|raw| serde_json::from_str(raw.get()).ok())
    }

    fn read_object(
        self,
        mut value: impl FnMut(&str, &'a RawValue) -> Result<Json, String>,
    ) -> Result<Json, String> {
        self.0
            .into_iter()
            .map(|(key, raw)| {
                let part = value(&key, raw)?;
                Ok((key, part))
            })
            .collect::<Result<Vec<_>, _>>()
            .map(Json::Object)
    }
}

fn array(
    raw: &RawValue,
    mut item: impl FnMut(&RawValue) -> Result<Json, String>,
) -> Result<Json, String> {
    if !raw.get().starts_with('[') {
        return json(raw);
    }
    let items: Vec<&RawValue> = parse(raw.get())?;
    items
        .into_iter()
        .map(&mut item)
        .collect::<Result<Vec<_>, _>>()
        .map(Json::Array)
}

fn span_words(raw: &RawValue, [width, height]: [u32; 2]) -> Option<Vec<u32>> {
    let rows: Vec<[f64; 3]> = serde_json::from_str(raw.get()).ok()?;
    if rows.is_empty() || rows.len() > (width * height) as usize {
        return None;
    }
    let mut end = 0;
    rows.into_iter()
        .map(|[y, x, n]| {
            let word = |n: f64, limit: u32| {
                (n >= 0.0 && n < f64::from(limit) && n.fract() == 0.0).then_some(n as u32)
            };
            let y = word(y, height)?;
            let x = word(x, width)?;
            let n = word(n, width - x + 1)?;
            let start = y * width + x;
            if n == 0 || start < end {
                return None;
            }
            end = start + n;
            Some((y << 18) + (x << 9) + n - 1)
        })
        .collect()
}

struct DocumentInput {
    grid: [u32; 2],
    ids: IndexMap<String, i32>,
    planes: CelPlanes,
}

#[derive(serde::Deserialize)]
#[serde(transparent)]
struct SlotName<'a>(#[serde(borrow)] Cow<'a, str>);

impl DocumentInput {
    fn read_slots(&mut self, raw: &RawValue, frame: &str, layer: &str) -> Result<Json, String> {
        if let Ok(values) = serde_json::from_str::<Vec<Option<SlotName<'_>>>>(raw.get())
            && values.len() == (self.grid[0] * self.grid[1]) as usize
            && let Some(slots) = values
                .iter()
                .map(|value| match value {
                    None => Some(-1),
                    Some(SlotName(name)) => self.ids.get(name.as_ref()).copied(),
                })
                .collect::<Option<Vec<_>>>()
        {
            self.planes.slots.push(SlotPlane {
                frame: frame.into(),
                layer: layer.into(),
                slots,
            });
            return Ok(Json::Array(Vec::new()));
        }
        json(raw)
    }

    fn read_marks(&mut self, raw: &RawValue, frame: &str, layer: &str) -> Result<Json, String> {
        let mut marks = Vec::new();
        let metadata = array(raw, |mark| {
            let Some(fields) = Fields::read(mark)? else {
                marks.push(Vec::new());
                return json(mark);
            };
            let words = fields
                .get("runs")
                .and_then(|rows| span_words(rows, self.grid))
                .unwrap_or_default();
            let packed = !words.is_empty();
            marks.push(words);
            fields.read_object(|key, raw| {
                if key == "runs" && packed {
                    Ok(Json::Array(Vec::new()))
                } else {
                    json(raw)
                }
            })
        })?;
        if marks.iter().any(|rows| !rows.is_empty()) {
            self.planes.runs.push(RunPlane {
                frame: frame.into(),
                layer: layer.into(),
                marks,
            });
        }
        Ok(metadata)
    }

    fn read_cel(
        &mut self,
        raw: &RawValue,
        frame: &str,
        layer: Option<&str>,
    ) -> Result<Json, String> {
        let Some(fields) = Fields::read(raw)? else {
            return json(raw);
        };
        let layer = match layer.map(str::to_owned).or_else(|| fields.id()) {
            Some(id) => id,
            None => return json(raw),
        };
        fields.read_object(|key, raw| match key {
            "slots" => self.read_slots(raw, frame, &layer),
            "marks" => self.read_marks(raw, frame, &layer),
            _ => json(raw),
        })
    }

    fn read_frame(&mut self, raw: &RawValue) -> Result<Json, String> {
        let Some(fields) = Fields::read(raw)? else {
            return json(raw);
        };
        let Some(id) = fields.id() else {
            return json(raw);
        };
        fields.read_object(|key, raw| {
            if key == "cels"
                && let Some(cels) = Fields::read(raw)?
            {
                return cels.read_object(|layer, cel| self.read_cel(cel, &id, Some(layer)));
            }
            json(raw)
        })
    }
}

pub(super) fn read_document(source: &str) -> Result<(Json, CelPlanes), String> {
    let raw: &RawValue = parse(source)?;
    let Some(fields) = Fields::read(raw)? else {
        return Ok((json(raw)?, CelPlanes::default()));
    };
    let field = |key| fields.get(key).map(json).transpose();
    let dimension = |key| -> Result<Option<u32>, String> {
        Ok(field(key)?
            .and_then(|n| coordinate(&n, 513))
            .filter(|&n| n > 0))
    };
    let legacy = match field("version")? {
        Some(Json::Number(version)) if version == "1" => true,
        Some(Json::Number(version)) if version == "2" => false,
        _ => return Ok((json(raw)?, CelPlanes::default())),
    };
    let (Some(width), Some(height), Some(Json::Object(palette))) =
        (dimension("width")?, dimension("height")?, field("palette")?)
    else {
        return Ok((json(raw)?, CelPlanes::default()));
    };
    let ids = palette
        .into_iter()
        .enumerate()
        .map(|(i, (name, _))| (name, i as i32))
        .collect();
    let mut input = DocumentInput {
        grid: [width, height],
        ids,
        planes: CelPlanes::default(),
    };
    let document = fields.read_object(|key, raw| match (legacy, key) {
        (true, "layers") => array(raw, |layer| input.read_cel(layer, "artwork", None)),
        (false, "frames") => array(raw, |frame| input.read_frame(frame)),
        _ => json(raw),
    })?;
    Ok((document, input.planes))
}
