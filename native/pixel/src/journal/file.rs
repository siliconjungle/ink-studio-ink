use super::*;

/// A one-shot editor for the original file-based edit commands.
/// It leaves the in-memory journal untouched and preserves the file's format version.
pub struct PixelFileEditor {
    editor: PixelCommandEditor,
    legacy: Option<LegacyFile>,
}

pub(super) struct LegacyFile {
    document: Json,
    revision: String,
}

impl LegacyFile {
    pub(super) fn revision(&self) -> &str {
        &self.revision
    }

    fn read(document: &Json, planes: &CelPlanes) -> Result<Self, String> {
        let text = restore_cel_planes(document, planes, Limits::default())?;
        Ok(Self {
            document: parse_json(&text)?,
            revision: revision(&text),
        })
    }

    pub(super) fn restore(&self, edited: &str) -> Result<String, String> {
        let mut document = self.document.clone();
        let mut current = parse_json(edited)?;
        for key in ["width", "height", "palette"] {
            put_member(&mut document, key, take_member(&mut current, key));
        }
        let Some(Json::Array(frames)) = member_mut(&mut current, "frames") else {
            return Err("Missing version 1 raster frame".into());
        };
        let Some(frame) = frames.first_mut() else {
            return Err("Missing version 1 raster frame".into());
        };
        let mut cels = take_member(frame, "cels");
        let Json::Array(current_layers) = take_member(&mut current, "layers") else {
            return Err("Missing version 1 raster layers".into());
        };
        let Json::Array(original_layers) = take_member(&mut document, "layers") else {
            return Err("Missing original version 1 raster layers".into());
        };
        let original: HashMap<_, _> = original_layers
            .iter()
            .filter_map(|row| {
                let Json::Text(id) = member(row, "id")? else {
                    return None;
                };
                Some((id.as_str(), row))
            })
            .collect();
        let mut layers = Vec::with_capacity(current_layers.len());
        for current in current_layers {
            let Some(Json::Text(id)) = member(&current, "id") else {
                return Err("Missing version 1 layer ID".into());
            };
            let mut cel = take_member(&mut cels, id);
            let mut layer = match original.get(id.as_str()) {
                Some(row) => (*row).clone(),
                None => current,
            };
            if member(&cel, "slots").is_some() {
                put_member(&mut layer, "slots", take_member(&mut cel, "slots"));
            }
            put_member(&mut layer, "marks", take_member(&mut cel, "marks"));
            layers.push(layer);
        }
        put_member(&mut document, "layers", Json::Array(layers));
        document.stringify(Limits::default())
    }
}

impl PixelFileEditor {
    pub fn new(source: &str) -> Result<Self, String> {
        let (document, planes) = read_document(source)?;
        let legacy = is_legacy(&document)
            .then(|| LegacyFile::read(&document, &planes))
            .transpose()?;
        let legacy_revision = legacy
            .as_ref()
            .map_or_else(String::new, |file| file.revision.clone());
        let editor = PixelCommandEditor::from_document(document, planes, legacy_revision, 0)?;
        Ok(Self { editor, legacy })
    }

    pub fn revision(&mut self) -> Result<String, String> {
        match &self.legacy {
            Some(file) => Ok(file.revision.clone()),
            None => self.editor.revision(),
        }
    }

    pub fn timeline(&mut self) -> Result<String, PixelEditError> {
        if self.legacy.is_some() {
            return Err("Upgrade to a version 2 document to inspect the cel timeline".to_owned().into());
        }
        self.editor.timeline()
    }

    pub fn edit(
        &mut self,
        patch: &str,
        options: &Map<String, Value>,
    ) -> Result<StagedPixelEdit, PixelEditError> {
        self.apply(parse_json(patch)?, options, None)
    }

    pub fn replay(
        &mut self,
        receipt: &str,
        options: &Map<String, Value>,
    ) -> Result<StagedPixelEdit, PixelEditError> {
        let mut recorded = parse_json(receipt)?;
        let expected = json_value(&recorded)?;
        check_replay_receipt_as(&expected, "cli")?;
        self.apply(receipt_patch(&mut recorded), options, Some(&expected))
    }

    pub fn preview(
        &mut self,
        patch: &str,
        options: PixelPreviewOptions,
        frame: Option<&Value>,
    ) -> Result<Value, PixelEditError> {
        options.checked_limit()?;
        let origin = EditOrigin::File {
            options: Map::new(),
            frame: file_frame(frame)?,
            legacy: self.legacy.as_ref(),
        };
        let preview =
            self.editor
                .edit_using(parse_json(patch)?, None, origin, EditMode::Preview(options))?;
        match preview {
            EditOutcome::Preview(report) => {
                let mut report = serde_json::to_value(report).map_err(|error| error.to_string())?;
                if self.legacy.is_some() {
                    legacy_preview(&mut report);
                }
                Ok(report)
            }
            EditOutcome::Staged(_) => unreachable!(),
        }
    }

    fn apply(
        &mut self,
        patch: Json,
        options: &Map<String, Value>,
        expected: Option<&Value>,
    ) -> Result<StagedPixelEdit, PixelEditError> {
        let origin = EditOrigin::File {
            options: options.clone(),
            frame: file_frame(options.get("frame"))?,
            legacy: self.legacy.as_ref(),
        };
        let staged = self
            .editor
            .edit_using(patch, expected, origin, EditMode::Stage)?
            .staged();
        if staged.receipt["status"] == "rejected" {
            let message = staged.receipt["conflicts"][0]["message"]
                .as_str()
                .unwrap_or("Pixel edit rejected")
                .to_owned();
            return Err(PixelEditError {
                message,
                receipt: Some(Box::new(Arc::unwrap_or_clone(staged.receipt))),
            });
        }
        Ok(staged)
    }
}

fn legacy_preview(report: &mut Value) {
    fn cells(rows: &mut Value, exact: bool) {
        for row in rows.as_array_mut().into_iter().flatten() {
            row["frame"] = Value::Null;
            for key in ["before", "after"] {
                let Some(sample) = row[key].as_object_mut() else {
                    continue;
                };
                if exact {
                    sample.insert("cel".into(), Value::Null);
                } else {
                    sample.remove("cel");
                }
                if let Some(underneath) =
                    sample.get_mut("underneath").and_then(Value::as_object_mut)
                {
                    underneath.remove("cel");
                }
            }
        }
    }
    cells(&mut report["pixels"], false);
    if let Some(diff) = report.get_mut("diff") {
        cells(&mut diff["cells"], true);
        for row in diff["grids"].as_array_mut().into_iter().flatten() {
            row["frame"] = Value::Null;
        }
        for row in diff["protection"]["cells"]
            .as_array_mut()
            .into_iter()
            .flatten()
        {
            row["frame"] = Value::Null;
        }
    }
}

fn file_frame(option: Option<&Value>) -> Result<Option<Json>, String> {
    option
        .map(|value| parse_json(&value.to_string()))
        .transpose()
}
