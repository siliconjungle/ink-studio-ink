use super::{Json, Limits, PixelEditor, Wire, compiled_json};
use serde::{Serialize, Serializer, ser::SerializeMap};
use serde_json::{Map, Value};

#[derive(Serialize)]
struct Asset<T> {
    artifact: &'static str,
    data: T,
}

#[derive(Serialize)]
struct Raster {
    slots: Vec<Option<u32>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    alpha: Vec<u32>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    knockouts: Vec<u32>,
}

impl Raster {
    fn new(slots: Vec<i32>, alpha: Vec<u32>, knockouts: Vec<u32>) -> Self {
        Self {
            slots: slots
                .into_iter()
                .map(|slot| u32::try_from(slot).ok())
                .collect(),
            alpha,
            knockouts,
        }
    }
}

#[derive(Serialize)]
struct Selection {
    id: String,
    pixels: Vec<[u32; 2]>,
}

#[derive(Serialize)]
struct Stamp {
    #[serde(flatten)]
    info: Map<String, Value>,
    #[serde(flatten)]
    raster: Raster,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    selections: Vec<Selection>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Deck {
    #[serde(flatten)]
    info: Map<String, Value>,
    frames: Vec<Frame>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    shared_selections: Vec<Selection>,
}

#[derive(Serialize)]
struct Frame {
    #[serde(flatten)]
    info: Map<String, Value>,
    duration: f64,
    cels: Cels,
    #[serde(skip_serializing_if = "Option::is_none")]
    selections: Option<Vec<Selection>>,
}

#[derive(Serialize)]
struct Cel {
    #[serde(flatten)]
    info: Map<String, Value>,
    #[serde(flatten)]
    raster: Raster,
}

struct Cels(Vec<(String, Cel)>);

impl Serialize for Cels {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.0.len()))?;
        for (layer, cel) in &self.0 {
            map.serialize_entry(layer, cel)?;
        }
        map.end()
    }
}

fn metadata<T: Wire>(value: &T) -> Result<Map<String, Value>, String> {
    let limits = Limits::default();
    let json = Json::from_ink(&value.to_json(), limits)?.stringify(limits)?;
    serde_json::from_str(&json).map_err(|error| error.to_string())
}

fn encode<T: Serialize>(artifact: &'static str, data: T) -> Result<String, String> {
    serde_json::to_string(&Asset { artifact, data }).map_err(|error| error.to_string())
}

pub(super) fn stamp(editor: &mut PixelEditor, options: Json) -> Result<String, String> {
    let options = compiled_json(options, &|kind, scalar, flag, values, keys| {
        editor
            .program
            .function_l_pixel_json_value(kind, scalar, flag, values, keys)
    });
    let stamp = editor
        .program
        .invoke_view_l_export_pixel_command_stamp(options)?
        .result?;
    encode(
        "stamp",
        Stamp {
            info: metadata(&stamp.l_info)?,
            raster: Raster::new(
                stamp.l_raster.l_slots,
                stamp.l_raster.l_alpha,
                stamp.l_raster.l_knockouts,
            ),
            selections: stamp
                .l_selections
                .into_iter()
                .map(|row| Selection {
                    id: row.l_id,
                    pixels: row.l_pixels,
                })
                .collect(),
        },
    )
}

pub(super) fn deck(editor: &mut PixelEditor) -> Result<String, String> {
    let deck = editor
        .program
        .invoke_view_l_export_pixel_command_layer_deck()?
        .result?;
    let mut frames = Vec::with_capacity(deck.l_frames.len());
    for row in deck.l_frames {
        let mut info = metadata(&row.l_info)?;
        let ms = info
            .remove("durationMs")
            .and_then(|value| value.as_f64())
            .ok_or("Missing pixel frame duration")?;
        let mut cels = Vec::with_capacity(row.l_cels.len());
        for cel in row.l_cels {
            cels.push((
                cel.l_layer,
                Cel {
                    info: metadata(&cel.l_info)?,
                    raster: Raster::new(
                        cel.l_raster.l_slots,
                        cel.l_raster.l_alpha,
                        cel.l_raster.l_knockouts,
                    ),
                },
            ));
        }
        let selections = deck.l_show_selections.then(|| {
            row.l_selections
                .into_iter()
                .map(|selection| Selection {
                    id: selection.l_id,
                    pixels: selection.l_pixels,
                })
                .collect()
        });
        frames.push(Frame {
            info,
            duration: ms / 1000.0,
            cels: Cels(cels),
            selections,
        });
    }
    let shared_selections = deck
        .l_shared
        .into_iter()
        .map(|row| Selection {
            id: row.l_id,
            pixels: row.l_pixels,
        })
        .collect();
    encode(
        "layer-deck",
        Deck {
            info: metadata(&deck.l_info)?,
            frames,
            shared_selections,
        },
    )
}
