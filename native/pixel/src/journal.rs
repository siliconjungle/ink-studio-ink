use super::{Json, Limits, OrderedJson, PixelEditor, Wire, compiled_json, member_mut, revision};
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

fn member<'a>(value: &'a Json, name: &str) -> Option<&'a Json> {
    let Json::Object(rows) = value else {
        return None;
    };
    rows.iter()
        .find(|(key, _)| key == name)
        .map(|(_, item)| item)
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
        Ok(self.edit(parse_json(patch)?, None, false)?.document)
    }

    pub fn preview_patch(&mut self, patch: &str) -> Result<StagedPixelEdit, PixelEditError> {
        self.edit(parse_json(patch)?, None, true)
    }

    pub fn replay(&mut self, receipt: &str) -> Result<String, PixelEditError> {
        let mut recorded = parse_json(receipt)?;
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
        Ok(self.edit(patch, Some(expected), false)?.document)
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

    fn edit(
        &mut self,
        patch: Json,
        expected: Option<Value>,
        dry_run: bool,
    ) -> Result<StagedPixelEdit, PixelEditError> {
        let view = self.view()?;
        let raw_patch = json_value(&patch)?;
        let mut options = Map::new();
        if let Some(shot) = expected
            .as_ref()
            .and_then(|receipt| receipt["command"]["options"].get("shotHitFrame"))
        {
            options.insert("shotHitFrame".into(), shot.clone());
        }
        let mut common = json!({
            "format": RECEIPT_FORMAT, "version": 1,
            "command": { "runner": "sdk", "action": "edit", "options": options, "patch": raw_patch },
            "inputs": { "documentRevision": view.revision },
        });
        let mut started = false;
        let outcome = (|| -> Result<_, Value> {
            let invalid = |error: String| conflict("invalid-edit", error);
            if let Some(recorded) = &expected {
                if common["command"]["options"] != recorded["command"]["options"] {
                    return Err(conflict(
                        "receipt-arguments",
                        "Replay needs the same edit options recorded in the receipt",
                    ));
                }
                if recorded["inputs"]["documentRevision"] != view.revision {
                    return Err(json!({
                        "code": "stale-document", "message": "Receipt was recorded against a different pixel document",
                        "expected": recorded["inputs"]["documentRevision"], "actual": view.revision,
                    }));
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
                return Err(json_value(&issue).map_err(invalid)?);
            }
            if !common["command"]["options"].as_object().unwrap().is_empty() {
                return Err(conflict(
                    "invalid-edit",
                    "A shot hit sample needs a shot-correction edit and a nonnegative shot frame",
                ));
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
            let mut target =
                self.run_raster_edit(patch, &gate.l_kind, &gate.l_frame, gate.l_cel.as_deref())?;
            target["destination"] = json!(gate.l_destination);
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
                ));
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
            Ok(StagedPixelEdit { document, receipt })
        })();
        match outcome {
            Ok(staged) => {
                if !dry_run && !view.pending && !view.history.redo.is_empty() {
                    self.trim()?;
                }
                Ok(staged)
            }
            Err(issue) => {
                if started {
                    self.editor.program.rollback_transaction();
                }
                if view.pending && !dry_run {
                    self.cancel()?;
                }
                let message = issue["message"]
                    .as_str()
                    .unwrap_or("Pixel edit rejected")
                    .to_owned();
                let mut receipt = common;
                receipt.as_object_mut().unwrap().remove("celLinks");
                receipt["status"] = json!("rejected");
                receipt["affectedTargets"] = json!([]);
                receipt["skippedHits"] = if issue.get("at").is_some() {
                    json!([&issue])
                } else {
                    json!([])
                };
                receipt["conflicts"] = json!([issue]);
                receipt["outputs"] = Value::Null;
                if dry_run {
                    Ok(StagedPixelEdit {
                        document: self.editor.snapshot()?,
                        receipt: Arc::new(receipt),
                    })
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
