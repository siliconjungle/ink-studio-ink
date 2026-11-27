use super::edit_preview::{CellChange, Color, Location, PixelEditPreview, Preview, Sample, Site};
use super::{
    Json, Limits, OrderedJson, PixelEditor, Wire, compiled_json, coordinate, member_mut, revision,
};
use serde_json::{Map, Value, json};
use std::{
    collections::{HashMap, HashSet},
    fmt,
    sync::Arc,
};

const RECEIPT_FORMAT: &str = "ink-studio/pixel-edit-receipt";

#[derive(Debug)]
pub struct PixelEditError {
    message: String,
    pub receipt: Option<Box<Value>>,
}

impl fmt::Display for PixelEditError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for PixelEditError {}

impl From<String> for PixelEditError {
    fn from(message: String) -> Self {
        Self {
            message,
            receipt: None,
        }
    }
}

#[derive(Debug, PartialEq, serde::Serialize)]
pub struct EditHistory {
    pub undo: Vec<String>,
    pub redo: Vec<String>,
}

pub struct StagedPixelEdit {
    pub document: String,
    pub receipt: Arc<Value>,
}

#[derive(Clone, Copy)]
pub struct PixelPreviewOptions {
    pub limit: u64,
    pub exact: bool,
}

impl Default for PixelPreviewOptions {
    fn default() -> Self {
        Self {
            limit: 256,
            exact: false,
        }
    }
}

impl PixelPreviewOptions {
    pub fn from_json(source: &str) -> Result<Self, PixelEditError> {
        let options = parse_json(source)?;
        preview_options(&options)
    }

    fn checked_limit(self) -> Result<u32, String> {
        if self.limit > 9_007_199_254_740_991 {
            return Err("Pixel preview limit must be a nonnegative integer".into());
        }
        Ok(self.limit.min(u64::from(u32::MAX)) as u32)
    }
}

enum EditMode {
    Apply,
    Stage,
    Preview(PixelPreviewOptions),
}

enum EditOutcome {
    Staged(StagedPixelEdit),
    Preview(PixelEditPreview),
}

struct EditConflicts(Vec<Value>);

impl From<Value> for EditConflicts {
    fn from(issue: Value) -> Self {
        Self(vec![issue])
    }
}

impl EditOutcome {
    fn staged(self) -> StagedPixelEdit {
        match self {
            Self::Staged(staged) => staged,
            Self::Preview(_) => unreachable!(),
        }
    }
}

struct JournalView {
    revision: String,
    receipt: u32,
    pending: bool,
    history: EditHistory,
    roots: Vec<u32>,
}

struct RecordedEdit {
    parent: u32,
    receipt: Arc<Value>,
}

pub struct PixelCommandEditor {
    editor: PixelEditor,
    receipts: HashMap<u32, RecordedEdit>,
    next_receipt: u32,
}

fn conflict(code: &str, message: impl Into<String>) -> Value {
    json!({ "code": code, "message": message.into() })
}

fn valid_revision(value: &Value) -> bool {
    value.as_str().is_some_and(|text| {
        text.len() == 64
            && text
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

fn receipt_matches(receipt: &Value, expected: &Value) -> bool {
    if expected.get("celLinks").is_some() {
        return receipt == expected;
    }
    let Some(object) = receipt.as_object() else {
        return false;
    };
    let Some(old) = expected.as_object() else {
        return false;
    };
    old.len() == object.len() - usize::from(object.contains_key("celLinks"))
        && old
            .iter()
            .all(|(key, value)| object.get(key) == Some(value))
}

fn parse_json(source: &str) -> Result<Json, String> {
    let OrderedJson(value) = serde_json::from_str(source).map_err(|error| error.to_string())?;
    Ok(value)
}

fn json_value(value: &Json) -> Result<Value, String> {
    serde_json::from_str(&value.stringify(Limits::default())?).map_err(|error| error.to_string())
}

fn preview_rows<T: Wire>(rows: &[T]) -> Result<Vec<Value>, String> {
    rows.iter()
        .map(|row| json_value(&Json::from_ink(&row.to_json(), Limits::default())?))
        .collect()
}

fn named(text: String) -> Option<String> {
    (!text.is_empty()).then_some(text)
}

fn member<'a>(value: &'a Json, name: &str) -> Option<&'a Json> {
    let Json::Object(rows) = value else {
        return None;
    };
    rows.iter()
        .find(|(key, _)| key == name)
        .map(|(_, item)| item)
}

fn take_member(value: &mut Json, name: &str) -> Json {
    member_mut(value, name).map_or(Json::Null, |item| std::mem::replace(item, Json::Null))
}

fn put_member(value: &mut Json, name: &str, item: Json) {
    if let Some(field) = member_mut(value, name) {
        *field = item;
    } else if let Json::Object(fields) = value {
        fields.push((name.into(), item));
    }
}

fn normalize_patch(mut patch: Json, destination: Option<String>, tool: Option<String>) -> Json {
    if let Some(destination) = destination {
        put_member(&mut patch, "destination", Json::Text(destination));
    }
    if let Some(tool) = tool {
        if let Some(operation) = member_mut(&mut patch, "operation") {
            put_member(operation, "tool", Json::Text(tool));
        }
    }
    patch
}

fn command_metadata(value: &Json, nested: bool) -> Json {
    let Json::Object(rows) = value else {
        return Json::Null;
    };
    Json::Object(
        rows.iter()
            .map(|(key, item)| {
                let projected = match (key.as_str(), item) {
                    ("format" | "version" | "action" | "artifact" | "label", _) => item.clone(),
                    ("edit", _) if !nested => command_metadata(item, true),
                    ("options", Json::Object(fields)) => Json::Object(
                        fields
                            .iter()
                            .map(|(name, _)| (name.clone(), Json::Null))
                            .collect(),
                    ),
                    ("patch", Json::Object(fields)) => Json::Object(
                        fields
                            .iter()
                            .filter_map(|(name, data)| {
                                let value = match (name.as_str(), data) {
                                    ("destination", _) => data.clone(),
                                    ("edits", Json::Array(_)) => Json::Array(Vec::new()),
                                    ("operation", Json::Object(fields)) => Json::Object(
                                        fields
                                            .iter()
                                            .filter(|(name, _)| name == "tool" || name == "type")
                                            .cloned()
                                            .collect(),
                                    ),
                                    ("operation" | "edits", _) => Json::Null,
                                    _ => return None,
                                };
                                Some((name.clone(), value))
                            })
                            .collect(),
                    ),
                    _ => Json::Null,
                };
                (key.clone(), projected)
            })
            .collect(),
    )
}

fn number(value: &Json) -> Option<f64> {
    if let Json::Number(token) = value {
        token.parse().ok()
    } else {
        None
    }
}

fn preview_options(value: &Json) -> Result<PixelPreviewOptions, PixelEditError> {
    let exact = match member(value, "exact") {
        Some(Json::Boolean(exact)) => *exact,
        None => false,
        Some(_) => return Err("Exact preview must be a boolean".to_owned().into()),
    };
    if let Some(shot) = member(value, "shotHitFrame") {
        if !exact || !number(shot).is_some_and(|n| n.fract() == 0.0 && (0.0..=1e9).contains(&n)) {
            return Err(
                "A preview shot hit sample needs exact mode and a nonnegative shot frame"
                    .to_owned()
                    .into(),
            );
        }
    }
    let limit = match member(value, "limit") {
        Some(limit) => number(limit)
            .filter(|n| n.fract() == 0.0 && (0.0..=9_007_199_254_740_991.0).contains(n))
            .ok_or_else(|| "Pixel preview limit must be a nonnegative integer".to_owned())?
            as u64,
        None => 256,
    };
    Ok(PixelPreviewOptions { limit, exact })
}

fn encode_command(reply: impl serde::Serialize) -> Result<String, PixelEditError> {
    serde_json::to_string(&reply).map_err(|error| error.to_string().into())
}

fn gate_metadata(patch: &Json) -> Json {
    let Json::Object(rows) = patch else {
        return Json::Null;
    };
    let metadata = rows
        .iter()
        .filter_map(|(key, data)| {
            let item = match key.as_str() {
                "id" | "revision" | "frame" | "cel" | "destination" | "ownership"
                | "sourceRevision" => data.clone(),
                "edits" => Json::Boolean(true),
                "operation" => Json::Object(vec![(
                    "tool".into(),
                    member(data, "tool").cloned().unwrap_or(Json::Null),
                )]),
                _ => return None,
            };
            Some((key.clone(), item))
        })
        .collect();
    Json::Object(metadata)
}

impl PixelCommandEditor {
    pub fn new(source: &str, history_limit: u32) -> Result<Self, String> {
        let input = parse_json(source)?;
        let legacy = match member(&input, "version") {
            Some(Json::Number(token)) if token == "1" => {
                revision(&input.stringify(Limits::default())?)
            }
            _ => String::new(),
        };
        let mut editor = PixelEditor::empty();
        editor.replace_document_data(input)?;
        let current = revision(&editor.snapshot()?);
        editor
            .program
            .invoke_view_l_start_pixel_journal(current, legacy, history_limit)?
            .result?;
        Ok(Self {
            editor,
            receipts: HashMap::new(),
            next_receipt: 0,
        })
    }

    fn view(&mut self) -> Result<JournalView, String> {
        let view = self.editor.program.invoke_view_l_pixel_journal()?.result;
        Ok(JournalView {
            revision: view.l_cursor.l_revision,
            receipt: view.l_cursor.l_receipt,
            pending: view.l_pending,
            history: EditHistory {
                undo: view.l_undo,
                redo: view.l_redo,
            },
            roots: view.l_roots,
        })
    }

    pub fn revision(&mut self) -> Result<String, String> {
        Ok(self.view()?.revision)
    }

    pub fn history(&mut self) -> Result<EditHistory, String> {
        Ok(self.view()?.history)
    }

    pub fn receipts(&mut self) -> Result<Vec<Value>, String> {
        let mut result = Vec::new();
        let mut id = self.view()?.receipt;
        while id != 0 {
            let row = self.receipts.get(&id).ok_or("Missing pixel edit receipt")?;
            result.push(row.receipt.as_ref().clone());
            id = row.parent;
        }
        result.reverse();
        Ok(result)
    }

    fn trim(&mut self) -> Result<(), String> {
        let mut reachable = HashSet::new();
        for mut id in self.view()?.roots {
            while id != 0 && reachable.insert(id) {
                id = self
                    .receipts
                    .get(&id)
                    .ok_or("Missing pixel edit receipt")?
                    .parent;
            }
        }
        self.receipts.retain(|id, _| reachable.contains(id));
        Ok(())
    }

    pub fn begin(&mut self, label: &str) -> Result<(), String> {
        self.editor
            .program
            .invoke_view_l_begin_pixel_edit(label.into())?
            .result
    }

    pub fn preview(&mut self) -> Result<String, String> {
        if !self.view()?.pending {
            return Err("No active transaction".into());
        }
        self.editor.snapshot()
    }

    pub fn snapshot(&mut self) -> Result<String, String> {
        self.editor.snapshot()
    }

    pub fn commit(&mut self) -> Result<bool, String> {
        let discard = !self.view()?.history.redo.is_empty();
        let changed = self
            .editor
            .program
            .invoke_view_l_commit_pixel_edit()?
            .result?;
        if changed && discard {
            self.trim()?;
        }
        Ok(changed)
    }

    pub fn cancel(&mut self) -> Result<bool, String> {
        let changed = self
            .editor
            .program
            .invoke_view_l_cancel_pixel_edit()?
            .result?;
        if changed {
            self.trim()?;
        }
        Ok(changed)
    }

    pub fn undo(&mut self) -> Result<bool, String> {
        self.editor
            .program
            .invoke_view_l_travel_pixel_history(false)?
            .result
    }

    pub fn redo(&mut self) -> Result<bool, String> {
        self.editor
            .program
            .invoke_view_l_travel_pixel_history(true)?
            .result
    }

    pub fn copy_selection(&mut self, options: &str) -> Result<super::CopiedSelection, String> {
        self.editor.copy_selection(options)
    }

    pub fn select(
        &mut self,
        query: &str,
        frame: Option<&str>,
        layer: Option<&str>,
        cel: Option<&str>,
        saved: &str,
    ) -> Result<super::PixelSelection, String> {
        self.editor.select(query, frame, layer, cel, saved)
    }

    pub fn apply(&mut self, patch: &str) -> Result<String, PixelEditError> {
        Ok(self
            .edit(parse_json(patch)?, None, None, EditMode::Apply)?
            .staged()
            .document)
    }

    pub fn preview_patch(&mut self, patch: &str) -> Result<StagedPixelEdit, PixelEditError> {
        Ok(self
            .edit(parse_json(patch)?, None, None, EditMode::Stage)?
            .staged())
    }

    pub fn preview_edit(
        &mut self,
        patch: &str,
        options: PixelPreviewOptions,
    ) -> Result<PixelEditPreview, PixelEditError> {
        self.preview_edit_data(parse_json(patch)?, options)
    }

    fn preview_edit_data(
        &mut self,
        patch: Json,
        options: PixelPreviewOptions,
    ) -> Result<PixelEditPreview, PixelEditError> {
        options.checked_limit()?;
        match self.edit(patch, None, None, EditMode::Preview(options))? {
            EditOutcome::Preview(report) => Ok(report),
            EditOutcome::Staged(_) => unreachable!(),
        }
    }

    pub fn preview_changes(
        &mut self,
        options: PixelPreviewOptions,
    ) -> Result<PixelEditPreview, String> {
        let mut id = self.view()?.receipt;
        let report = self.read_preview(options, true)?;
        let mut targets = Vec::new();
        while id != report.receipt {
            let row = self.receipts.get(&id).ok_or("Missing pixel edit receipt")?;
            let target = &row.receipt["affectedTargets"][0];
            if target["kind"] != "raster" || target.get("tool").is_some() {
                targets.push(target.clone());
            }
            id = row.parent;
        }
        targets.reverse();
        Ok(report.report(targets, Vec::new(), options.exact))
    }

    fn read_preview(
        &mut self,
        options: PixelPreviewOptions,
        grouped: bool,
    ) -> Result<Preview, String> {
        let limit = options.checked_limit()?;
        let (changes, links, receipt) = if grouped {
            let draft = self
                .editor
                .program
                .invoke_view_l_pixel_draft_diff(limit, options.exact)?
                .result?;
            (draft.l_changes, draft.l_celLinks, draft.l_receipt)
        } else {
            let edit = self
                .editor
                .program
                .invoke_view_l_pixel_preview_diff(limit, options.exact)?
                .result?;
            let links = self.editor.program.invoke_view_l_pixel_edit_links()?.result;
            (edit, links, 0)
        };
        let mut report = Preview {
            count: changes.l_pixelCount,
            pixels: Vec::with_capacity(changes.l_pixels.len()),
            cells: Vec::with_capacity(changes.l_exact.l_cells.len()),
            protected_cells: changes
                .l_exact
                .l_protectedCells
                .into_iter()
                .map(|site| Site {
                    frame: site.l_frame,
                    at: site.l_at,
                })
                .collect(),
            details: preview_rows(&changes.l_exact.l_details)?,
            links: links.map(|links| links.to_json()),
            receipt,
        };
        for (rows, output, exact) in [
            (changes.l_pixels, &mut report.pixels, false),
            (changes.l_exact.l_cells, &mut report.cells, true),
        ] {
            for row in rows {
                let layer = named(row.l_layer);
                let [before, after] = [row.l_before, row.l_after].map(|sample| {
                    sample.map(|sample| {
                        let location = sample.l_location;
                        let cel = named(location.l_cel);
                        let swatch = named(location.l_swatch);
                        let color = swatch.as_ref().map(|_| Color(sample.l_rgb));
                        if layer.is_some() {
                            Sample::Raw {
                                cel,
                                swatch,
                                color,
                                alpha: sample.l_alpha.unwrap_or(0),
                                knockout: sample.l_knockout,
                                clip: sample.l_clip,
                            }
                        } else {
                            let beneath = sample.l_underneath;
                            Sample::Composite {
                                layer: named(location.l_layer),
                                cel,
                                swatch,
                                color,
                                protected: sample.l_protected,
                                alpha: sample.l_alpha,
                                underneath: (!exact).then(|| Location {
                                    layer: named(beneath.l_layer),
                                    cel: named(beneath.l_cel),
                                    swatch: named(beneath.l_swatch),
                                }),
                            }
                        }
                    })
                });
                output.push(CellChange {
                    frame: row.l_site.l_frame,
                    at: row.l_site.l_at,
                    layer,
                    before,
                    after,
                });
            }
        }
        Ok(report)
    }

    pub fn replay(&mut self, receipt: &str) -> Result<String, PixelEditError> {
        Ok(self.replay_edit(parse_json(receipt)?)?.document)
    }

    fn replay_edit(&mut self, mut recorded: Json) -> Result<StagedPixelEdit, PixelEditError> {
        let expected = json_value(&recorded)?;
        let command = &expected["command"];
        if expected["format"] != RECEIPT_FORMAT
            || expected["version"] != 1
            || expected["status"] != "applied"
            || command["runner"] != "sdk"
            || command["action"] != "edit"
            || !command["patch"].is_object()
            || !command["options"].is_object()
            || !valid_revision(&expected["inputs"]["documentRevision"])
            || !valid_revision(&expected["outputs"]["artifactRevision"])
        {
            return Err(
                "Replay needs an applied version 1 pixel edit receipt from the sdk"
                    .to_owned()
                    .into(),
            );
        }
        let patch = member_mut(&mut recorded, "command")
            .and_then(|value| member_mut(value, "patch"))
            .map(|value| std::mem::replace(value, Json::Null))
            .unwrap_or(Json::Null);
        Ok(self
            .edit(patch, Some(expected), None, EditMode::Apply)?
            .staged())
    }

    pub fn png(&mut self, options: &str) -> Result<Vec<u8>, PixelEditError> {
        super::export_assets::png(&mut self.editor, parse_json(options)?).map_err(Into::into)
    }

    pub fn execute(&mut self, source: &str) -> Result<String, PixelEditError> {
        let mut request = parse_json(source)?;
        let make = |kind, scalar, flag, values, keys| {
            self.editor
                .program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        };
        let wire = compiled_json(command_metadata(&request, false), &make);
        let plan = self
            .editor
            .program
            .invoke_view_l_plan_pixel_command(wire)?
            .result?;
        let options = take_member(&mut request, "options");
        match plan.l_action.as_str() {
            "apply" => {
                let patch = normalize_patch(
                    take_member(&mut request, "patch"),
                    plan.l_destination,
                    plan.l_tool,
                );
                let shot = member(&options, "shotHitFrame")
                    .map(json_value)
                    .transpose()?;
                let stage = self.edit(patch, None, shot, EditMode::Apply)?.staged();
                encode_command(stage.receipt.as_ref())
            }
            "replay" => {
                let stage = self.replay_edit(take_member(&mut request, "receipt"))?;
                encode_command(stage.receipt.as_ref())
            }
            "begin" => {
                let label = take_member(&mut request, "label");
                self.begin(if let Json::Text(ref label) = label {
                    label
                } else {
                    ""
                })?;
                encode_command(json!({ "history": self.history()? }))
            }
            "undo" | "redo" | "commit" | "cancel" => {
                let changed = match plan.l_action.as_str() {
                    "undo" => self.undo()?,
                    "redo" => self.redo()?,
                    "commit" => self.commit()?,
                    _ => self.cancel()?,
                };
                encode_command(json!({ "changed": changed, "history": self.history()? }))
            }
            "preview-edit" => {
                let mut nested = take_member(&mut request, "edit");
                let patch = normalize_patch(
                    take_member(&mut nested, "patch"),
                    plan.l_destination,
                    plan.l_tool,
                );
                encode_command(self.preview_edit_data(patch, preview_options(&options)?)?)
            }
            "preview-draft" => encode_command(self.preview_changes(preview_options(&options)?)?),
            "select" => self.command_selection(take_member(&mut request, "query"), &options),
            "inspect" => self.command_inspection(take_member(&mut request, "at"), options),
            "validate" => {
                let value = self
                    .editor
                    .program
                    .invoke_view_l_describe_pixel_command_document()?
                    .result?;
                Json::from_ink(&value.to_json(), Limits::default())?
                    .stringify(Limits::default())
                    .map_err(Into::into)
            }
            "export-document" => Ok(format!(
                r#"{{"artifact":"document","data":{}}}"#,
                self.snapshot()?
            )),
            "export-stamp" => {
                super::export_assets::stamp(&mut self.editor, options).map_err(Into::into)
            }
            "export-png" => {
                super::export_assets::png_command(&mut self.editor, options).map_err(Into::into)
            }
            "export-layer-deck" => super::export_assets::deck(&mut self.editor).map_err(Into::into),
            "export-scene"
            | "export-shot-corrections"
            | "export-splat-fit"
            | "export-scan-paint" => {
                Err(format!("No session artifact named {}", &plan.l_action[7..]).into())
            }
            _ => {
                let command = if let Some(artifact) = plan.l_action.strip_prefix("export-") {
                    format!("export {artifact}")
                } else {
                    plan.l_action
                };
                Err(format!("Pixel editor has not implemented command {command}").into())
            }
        }
    }

    fn command_selection(&mut self, query: Json, options: &Json) -> Result<String, PixelEditError> {
        let scoped = |field: &str| -> Result<Option<&str>, PixelEditError> {
            match member(options, field) {
                None => Ok(None),
                Some(Json::Text(name)) => Ok(Some(name)),
                Some(value) => Err(format!("Unknown pixel {field} {}", json_value(value)?).into()),
            }
        };
        let selection = self.select(
            &query.stringify(Limits::default())?,
            scoped("frame")?,
            scoped("layer")?,
            scoped("cel")?,
            "{}",
        )?;
        if member(options, "targetRevision").is_some() {
            return Err("A target revision needs an intent query".to_owned().into());
        }
        encode_command(
            json!({ "revision": self.revision()?, "frame": selection.frame, "grid": selection.grid,
            "pixelCount": selection.pixels.len(), "pixels": selection.pixels }),
        )
    }

    fn command_inspection(
        &mut self,
        coordinate: Json,
        options: Json,
    ) -> Result<String, PixelEditError> {
        let make = |kind, scalar, flag, values, keys| {
            self.editor
                .program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        };
        let at = compiled_json(coordinate, &make);
        let settings = compiled_json(options, &make);
        let report = self
            .editor
            .program
            .invoke_view_l_inspect_pixel_command(at, settings)?
            .result?;
        let limits = Limits::default();
        let mut branches: HashMap<String, Vec<Value>> = HashMap::new();
        for row in report.l_layers {
            let mut layer = json_value(&Json::from_ink(&row.l_fields.to_json(), limits)?)?;
            layer["opacity"] = json!(row.l_opacity);
            if layer["kind"] == "group" {
                layer["children"] = Value::Array(branches.remove(&row.l_id).unwrap_or_default());
            }
            branches.entry(row.l_parent).or_default().push(layer);
        }
        let mut document = json_value(&Json::from_ink(&report.l_document.to_json(), limits)?)?;
        document["layers"] = Value::Array(branches.remove("").unwrap_or_default());
        encode_command(document)
    }

    fn run_raster_edit(
        &mut self,
        mut patch: Json,
        kind: &str,
        frame: &str,
        cel: Option<&str>,
    ) -> Result<Value, Value> {
        let operation = member_mut(&mut patch, "operation")
            .map_or(Json::Null, |value| std::mem::replace(value, Json::Null));
        let invalid = |message: String| conflict("invalid-edit", message);
        let report = if kind == "selections" {
            serde_json::to_value(
                self.editor
                    .save_selection_data(operation, Some(frame))
                    .map_err(invalid)?,
            )
        } else {
            match self.editor.paint_data(operation, Some(frame), cel) {
                Ok(report) => serde_json::to_value(report),
                Err(issue) => return Err(json!(issue)),
            }
        };
        report.map_err(|error| invalid(error.to_string()))
    }

    fn run_guarded_edit(
        &mut self,
        mut patch: Json,
        frame: String,
        cel: Option<String>,
        reuse_composites: bool,
    ) -> Result<Value, EditConflicts> {
        let id = match take_member(&mut patch, "id") {
            Json::Text(id) => id,
            _ => String::new(),
        };
        let encode = |raw| {
            compiled_json(raw, &|kind, scalar, flag, values, keys| {
                self.editor
                    .program
                    .function_l_pixel_json_value(kind, scalar, flag, values, keys)
            })
        };
        let edits = match take_member(&mut patch, "edits") {
            Json::Array(rows) if rows.len() <= 4096 => rows
                .into_iter()
                .map(|row| {
                    let mut at = Json::Null;
                    let (mut layer, mut from, mut to) = (None, None, None);
                    if let Json::Object(fields) = row {
                        for (key, raw) in fields {
                            match key.as_str() {
                                "at" => at = raw,
                                "layer" => layer = Some(raw),
                                "from" => from = Some(raw),
                                "to" => to = Some(raw),
                                _ => (),
                            }
                        }
                    }
                    let point = match &at {
                        Json::Array(xy) if xy.len() == 2 => coordinate(&xy[0], 512)
                            .zip(coordinate(&xy[1], 512))
                            .map(|(x, y)| [x, y]),
                        _ => None,
                    };
                    self.editor.program.function_l_pixel_guarded_input(
                        point,
                        encode(if point.is_some() { Json::Null } else { at }),
                        layer.map(encode),
                        from.map(encode),
                        to.map(encode),
                    )
                })
                .collect(),
            _ => Vec::new(),
        };
        let invalid = |message| EditConflicts::from(conflict("invalid-edit", message));
        let output = self
            .editor
            .program
            .invoke_view_l_replace_guarded_pixels(id, frame, cel, edits, reuse_composites)
            .map_err(invalid)?
            .result;
        match output {
            Ok(target) => Ok(
                json!({ "kind": "raster", "frame": target.l_frame, "layer": target.l_layer,
                "cel": target.l_cel, "pixels": target.l_pixels }),
            ),
            Err(issues) => Err(EditConflicts(preview_rows(&issues).map_err(invalid)?)),
        }
    }

    fn edit(
        &mut self,
        patch: Json,
        expected: Option<Value>,
        shot: Option<Value>,
        mode: EditMode,
    ) -> Result<EditOutcome, PixelEditError> {
        let dry_run = !matches!(mode, EditMode::Apply);
        let view = self.view()?;
        let raw_patch = if matches!(mode, EditMode::Preview(_)) {
            Value::Null
        } else {
            json_value(&patch)?
        };
        let mut options = Map::new();
        if let Some(shot) = expected
            .as_ref()
            .and_then(|receipt| receipt["command"]["options"].get("shotHitFrame"))
            .cloned()
            .or(shot)
        {
            options.insert("shotHitFrame".into(), shot);
        }
        let mut common = json!({
            "format": RECEIPT_FORMAT, "version": 1,
            "command": { "runner": "sdk", "action": "edit", "options": options, "patch": raw_patch },
            "inputs": { "documentRevision": view.revision },
        });
        let mut started = false;
        let outcome = (|| -> Result<_, EditConflicts> {
            let invalid = |error: String| EditConflicts::from(conflict("invalid-edit", error));
            if let Some(recorded) = &expected {
                if common["command"]["options"] != recorded["command"]["options"] {
                    return Err(conflict(
                        "receipt-arguments",
                        "Replay needs the same edit options recorded in the receipt",
                    )
                    .into());
                }
                if recorded["inputs"]["documentRevision"] != view.revision {
                    return Err(json!({
                        "code": "stale-document", "message": "Receipt was recorded against a different pixel document",
                        "expected": recorded["inputs"]["documentRevision"], "actual": view.revision,
                    }).into());
                }
            }
            let meta = compiled_json(
                gate_metadata(&patch),
                &|kind, scalar, flag, values, keys| {
                    self.editor
                        .program
                        .function_l_pixel_json_value(kind, scalar, flag, values, keys)
                },
            );
            let gate = self
                .editor
                .program
                .invoke_view_l_resolve_pixel_edit(meta)
                .map_err(invalid)?
                .result;
            if !gate.l_frame.is_empty() {
                common["command"]["frame"] = json!(&gate.l_frame);
            }
            let issue =
                Json::from_ink(&gate.l_conflict.to_json(), Limits::default()).map_err(invalid)?;
            if !matches!(issue, Json::Null) {
                return Err(json_value(&issue).map_err(invalid)?.into());
            }
            if !common["command"]["options"].as_object().unwrap().is_empty() {
                return Err(conflict(
                    "invalid-edit",
                    "A shot hit sample needs a shot-correction edit and a nonnegative shot frame",
                )
                .into());
            }
            self.editor.program.begin_transaction().map_err(invalid)?;
            started = true;
            if !dry_run && !view.pending {
                self.begin(common["command"]["patch"]["id"].as_str().unwrap_or(""))
                    .map_err(invalid)?;
            }
            self.editor
                .program
                .invoke_view_l_observe_pixel_edit()
                .map_err(invalid)?;
            if matches!(mode, EditMode::Preview(_)) {
                self.editor
                    .program
                    .invoke_view_l_observe_pixel_preview()
                    .map_err(invalid)?;
            }
            let mut target = if gate.l_direct {
                let reuse = matches!(mode, EditMode::Preview(options) if !options.exact);
                self.run_guarded_edit(patch, gate.l_frame, gate.l_cel, reuse)?
            } else {
                self.run_raster_edit(patch, &gate.l_kind, &gate.l_frame, gate.l_cel.as_deref())?
            };
            target["destination"] = json!(gate.l_destination);
            if let EditMode::Preview(options) = mode {
                let preview = if gate.l_kind == "selections" {
                    Preview::default()
                } else {
                    self.read_preview(options, false).map_err(invalid)?
                };
                self.editor.program.rollback_transaction();
                return Ok(EditOutcome::Preview(preview.report(
                    if gate.l_direct {
                        Vec::new()
                    } else {
                        vec![target]
                    },
                    Vec::new(),
                    options.exact,
                )));
            }
            let document = self.editor.snapshot().map_err(invalid)?;
            let after = revision(&document);
            let links = self
                .editor
                .program
                .invoke_view_l_pixel_edit_links()
                .map_err(invalid)?
                .result;
            common["status"] = json!("applied");
            common["affectedTargets"] = Value::Array(vec![target]);
            common["skippedHits"] = json!([]);
            if let Some(links) = links {
                common["celLinks"] = links.to_json();
            }
            common["outputs"] = json!({ "kind": gate.l_kind, "documentRevision": after, "artifactRevision": after });
            if expected
                .as_ref()
                .is_some_and(|old| !receipt_matches(&common, old))
            {
                return Err(conflict(
                    "receipt-mismatch",
                    "Replay did not reproduce the recorded targets, hits, or output revisions",
                )
                .into());
            }
            if dry_run {
                self.editor.program.rollback_transaction();
            } else {
                let id = self.next_receipt.checked_add(1).ok_or_else(|| {
                    invalid("Pixel edit history has reached its receipt limit".into())
                })?;
                self.editor
                    .program
                    .invoke_view_l_accept_pixel_edit(after, id)
                    .map_err(invalid)?
                    .result
                    .map_err(invalid)?;
                if !view.pending {
                    self.editor
                        .program
                        .invoke_view_l_commit_pixel_edit()
                        .map_err(invalid)?
                        .result
                        .map_err(invalid)?;
                }
                self.editor.program.commit_transaction();
                self.next_receipt = id;
            }
            started = false;
            let receipt = Arc::new(std::mem::take(&mut common));
            if !dry_run {
                self.receipts.insert(
                    self.next_receipt,
                    RecordedEdit {
                        parent: view.receipt,
                        receipt: Arc::clone(&receipt),
                    },
                );
            }
            Ok(EditOutcome::Staged(StagedPixelEdit { document, receipt }))
        })();
        match outcome {
            Ok(staged) => {
                if !dry_run && !view.pending && !view.history.redo.is_empty() {
                    self.trim()?;
                }
                Ok(staged)
            }
            Err(EditConflicts(issues)) => {
                if started {
                    self.editor.program.rollback_transaction();
                }
                if view.pending && !dry_run {
                    self.cancel()?;
                }
                if let EditMode::Preview(options) = mode {
                    return Ok(EditOutcome::Preview(Preview::default().report(
                        Vec::new(),
                        issues,
                        options.exact,
                    )));
                }
                let message = issues
                    .first()
                    .and_then(|issue| issue["message"].as_str())
                    .unwrap_or("Pixel edit rejected")
                    .to_owned();
                let mut receipt = common;
                receipt.as_object_mut().unwrap().remove("celLinks");
                receipt["status"] = json!("rejected");
                receipt["affectedTargets"] = json!([]);
                receipt["skippedHits"] = Value::Array(
                    issues
                        .iter()
                        .filter(|issue| issue.get("at").is_some() || issue.get("splat").is_some())
                        .cloned()
                        .collect(),
                );
                receipt["conflicts"] = Value::Array(issues);
                receipt["outputs"] = Value::Null;
                if dry_run {
                    Ok(EditOutcome::Staged(StagedPixelEdit {
                        document: self.editor.snapshot()?,
                        receipt: Arc::new(receipt),
                    }))
                } else {
                    Err(PixelEditError {
                        message,
                        receipt: Some(Box::new(receipt)),
                    })
                }
            }
        }
    }
}
