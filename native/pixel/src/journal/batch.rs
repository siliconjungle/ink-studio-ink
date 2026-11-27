use super::*;
use crate::{Digest, Sha256, array_index};

const BATCH_FORMAT: &str = "ink-studio/pixel-edit-batch";

#[derive(Default)]
struct BatchFailure {
    step: Option<usize>,
    conflicts: Vec<Value>,
    edit_receipt: Option<Box<Value>>,
}

type BatchResult<T> = Result<T, BatchFailure>;

impl From<String> for BatchFailure {
    fn from(message: String) -> Self {
        Self::single(conflict("invalid-edit", message))
    }
}

impl From<PixelEditError> for BatchFailure {
    fn from(error: PixelEditError) -> Self {
        let conflicts = error
            .receipt
            .as_ref()
            .and_then(|receipt| receipt["conflicts"].as_array())
            .cloned()
            .unwrap_or_else(|| vec![conflict("invalid-edit", error.message)]);
        Self {
            conflicts,
            edit_receipt: error.receipt,
            step: None,
        }
    }
}

impl BatchFailure {
    fn single(issue: Value) -> Self {
        Self {
            conflicts: vec![issue],
            ..Self::default()
        }
    }

    fn at(mut self, index: usize) -> Self {
        self.step = Some(index);
        self
    }

    fn report(self, mut value: Value) -> Value {
        if let Some(step) = self.step {
            value["failedStep"] = json!(step);
        }
        if let Some(receipt) = self.edit_receipt {
            value["editReceipt"] = *receipt;
        }
        value["conflicts"] = json!(self.conflicts);
        value
    }

    fn reject(self, action: &str, recorded: &Value) -> PixelEditError {
        let message = self.conflicts[0]["message"]
            .as_str()
            .unwrap_or("Pixel batch rejected")
            .to_owned();
        let mut receipt =
            json!({ "format": "ink-studio/pixel-batch-rejection", "version": 1, "action": action });
        set_recorded_revision(&mut receipt, recorded);
        PixelEditError {
            message,
            receipt: Some(Box::new(self.report(receipt))),
        }
    }
}

fn set_recorded_revision(report: &mut Value, recorded: &Value) {
    if valid_revision(recorded) {
        report["recordedRevision"] = recorded.clone();
    }
}

fn write_canonical(value: &Value, bytes: &mut Vec<u8>, omit_revision: bool) -> Result<(), String> {
    match value {
        Value::Array(items) => {
            bytes.push(b'[');
            for (index, item) in items.iter().enumerate() {
                if index != 0 {
                    bytes.push(b',');
                }
                write_canonical(item, bytes, false)?;
            }
            bytes.push(b']');
        }
        Value::Object(object) => {
            let mut fields = object
                .iter()
                .filter(|(key, _)| !omit_revision || *key != "revision")
                .collect::<Vec<_>>();
            fields.sort_unstable_by(|(a, _), (b, _)| {
                array_index(a)
                    .unwrap_or(u32::MAX)
                    .cmp(&array_index(b).unwrap_or(u32::MAX))
                    .then_with(|| a.encode_utf16().cmp(b.encode_utf16()))
            });
            bytes.push(b'{');
            for (index, (key, item)) in fields.into_iter().enumerate() {
                if index != 0 {
                    bytes.push(b',');
                }
                serde_json::to_writer(&mut *bytes, key).map_err(|error| error.to_string())?;
                bytes.push(b':');
                write_canonical(item, bytes, false)?;
            }
            bytes.push(b'}');
        }
        Value::Number(number) => {
            let number = number
                .as_f64()
                .ok_or("A pixel batch receipt needs finite JSON numbers")?;
            bytes.extend(ryu_js::Buffer::new().format_finite(number).as_bytes());
        }
        _ => serde_json::to_writer(bytes, value).map_err(|error| error.to_string())?,
    }
    Ok(())
}

fn canonical_revision(value: &Value) -> Result<String, String> {
    let mut bytes = Vec::new();
    write_canonical(value, &mut bytes, true)?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn seal(
    label: &str,
    inputs: Value,
    outputs: Value,
    steps: &[Arc<Value>],
    revalidated_from: Option<&Value>,
) -> BatchResult<Value> {
    let mut body = json!({ "format": BATCH_FORMAT, "version": 1, "label": label, "inputs": inputs,
        "outputs": outputs, "steps": steps.iter().map(Arc::as_ref).collect::<Vec<_>>() });
    if let Some(from) = revalidated_from {
        body["revalidatedFrom"] = from.clone();
    }
    body["revision"] = json!(canonical_revision(&body)?);
    Ok(body)
}

fn json_count(raw: &Json) -> u32 {
    match raw {
        Json::Array(rows) => u32::try_from(rows.len()).unwrap_or(u32::MAX),
        _ => 0,
    }
}

fn evidence(receipt: &Value) -> Value {
    let mut fields = Map::new();
    for (from, to) in [
        ("affectedTargets", "targets"),
        ("skippedHits", "skippedHits"),
        ("shotHits", "shotHits"),
    ] {
        if let Some(value) = receipt.get(from) {
            fields.insert(to.into(), value.clone());
        }
    }
    Value::Object(fields)
}

macro_rules! batch_wire {
    ($editor:expr, $value:expr) => {
        compiled_json($value, &|kind, scalar, flag, values, keys| {
            $editor
                .editor
                .program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        })
    };
}

impl PixelCommandEditor {
    pub(super) fn execute_batch_command(
        &mut self,
        action: &str,
        mut request: Json,
        options: Json,
    ) -> Result<String, PixelEditError> {
        let result = match action {
            "batch" => {
                let Json::Object(mut fields) = request else {
                    unreachable!()
                };
                fields
                    .retain(|(name, _)| matches!(name.as_str(), "revision" | "label" | "commands"));
                self.apply_batch_data(Json::Object(fields))
                    .map_err(|error| error.reject(action, &Value::Null))?
            }
            "record-batch" => self.record_batch()?,
            "replay-batch" => self.replay_batch_data(take_member(&mut request, "batch"))?,
            "revalidate-batch" => {
                self.revalidate_batch_data(take_member(&mut request, "batch"), &options)?
            }
            _ => unreachable!(),
        };
        encode_command(result)
    }

    pub fn apply_batch(&mut self, source: &str) -> Result<Value, PixelEditError> {
        self.apply_batch_data(parse_json(source)?)
            .map_err(|error| error.reject("batch", &Value::Null))
    }

    pub fn record_batch(&mut self) -> Result<Value, PixelEditError> {
        self.record_batch_data()
            .map_err(|error| error.reject("record-batch", &Value::Null))
    }

    pub fn replay_batch(&mut self, source: &str) -> Result<Value, PixelEditError> {
        self.replay_batch_data(parse_json(source)?)
    }

    pub fn revalidate_batch(
        &mut self,
        source: &str,
        options: &str,
    ) -> Result<Value, PixelEditError> {
        self.revalidate_batch_data(parse_json(source)?, &parse_json(options)?)
    }

    fn batch_anchor(&mut self) -> BatchResult<Value> {
        let value = self
            .editor
            .program
            .invoke_view_l_pixel_batch_anchor()?
            .result;
        Ok(json_value(&Json::from_ink(
            &value.to_json(),
            Limits::default(),
        )?)?)
    }

    fn require_no_draft(&mut self) -> BatchResult<()> {
        if self.view()?.pending {
            return Err(BatchFailure::single(conflict(
                "active-transaction",
                "Finish the open pixel transaction before running a batch",
            )));
        }
        Ok(())
    }

    fn settle_batch<T>(
        &mut self,
        label: &str,
        save: bool,
        run: impl FnOnce(&mut Self) -> BatchResult<T>,
    ) -> BatchResult<T> {
        self.begin(label)?;
        let result = run(self);
        if save && result.is_ok() {
            self.commit()?;
        } else {
            self.cancel()?;
        }
        result
    }

    fn apply_batch_data(&mut self, mut raw: Json) -> BatchResult<Value> {
        self.require_no_draft()?;
        let count = member(&raw, "commands").map_or(0, json_count);
        let metadata = match &raw {
            Json::Object(fields) => Json::Object(
                fields
                    .iter()
                    .map(|(key, item)| {
                        (
                            key.clone(),
                            if matches!(key.as_str(), "revision" | "label") {
                                item.clone()
                            } else {
                                Json::Null
                            },
                        )
                    })
                    .collect(),
            ),
            _ => Json::Null,
        };
        let wire = batch_wire! { self, metadata };
        let label = self
            .editor
            .program
            .function_l_pixel_batch_plan(wire, count)?;
        let inputs = self.batch_anchor()?;
        let expected = json_value(&take_member(&mut raw, "revision"))?;
        if expected != inputs["documentRevision"] {
            return Err(BatchFailure::single(json!({
                "code": "stale-document", "message": "Pixel batch needs its observed base revision",
                "expected": expected, "actual": inputs["documentRevision"],
            })));
        }
        let Json::Array(commands) = take_member(&mut raw, "commands") else {
            unreachable!()
        };
        self.settle_batch(&label, true, |editor| {
            let mut steps = Vec::with_capacity(commands.len());
            for (index, mut step) in commands.into_iter().enumerate() {
                let applied = (|| -> Result<StagedPixelEdit, PixelEditError> {
                    let wire = batch_wire! { editor, command_metadata(&step, false) };
                    let plan = editor
                        .editor
                        .program
                        .invoke_view_l_plan_pixel_batch_step(wire)?
                        .result?;
                    let mut patch = normalize_patch(
                        take_member(&mut step, "patch"),
                        plan.l_destination,
                        plan.l_tool,
                    );
                    if member(&patch, "revision").is_none() {
                        put_member(&mut patch, "revision", Json::Text(editor.revision()?));
                    }
                    let shot = member(&step, "options")
                        .and_then(|options| member(options, "shotHitFrame"))
                        .map(json_value)
                        .transpose()?;
                    Ok(editor.edit(patch, None, shot, EditMode::Apply)?.staged())
                })()
                .map_err(|error| BatchFailure::from(error).at(index))?;
                steps.push(applied.receipt);
            }
            seal(&label, inputs, editor.batch_anchor()?, &steps, None)
        })
    }

    fn record_batch_data(&mut self) -> BatchResult<Value> {
        if !self.view()?.pending {
            return Err(BatchFailure::single(conflict(
                "missing-transaction",
                "Open a pixel transaction before recording a batch",
            )));
        }
        let draft = self
            .editor
            .program
            .invoke_view_l_pixel_batch_draft()?
            .result?;
        let mut id = self.view()?.receipt;
        let mut steps = Vec::new();
        while id != draft.l_receipt {
            let row = self
                .receipts
                .get(&id)
                .ok_or("Missing pixel edit receipt".to_owned())?;
            steps.push(Arc::clone(&row.receipt));
            id = row.parent;
        }
        self.editor
            .program
            .function_l_pixel_batch_count(steps.len() as u32)?;
        steps.reverse();
        let inputs = json_value(&Json::from_ink(
            &draft.l_anchor.to_json(),
            Limits::default(),
        )?)?;
        seal(&draft.l_label, inputs, self.batch_anchor()?, &steps, None)
    }

    fn read_batch(&mut self, raw: &Value) -> BatchResult<()> {
        let metadata = raw
            .as_object()
            .map(|row| {
                Value::Object(
                    row.iter()
                        .map(|(key, item)| {
                            (
                                key.clone(),
                                if key == "steps" {
                                    Value::Null
                                } else {
                                    item.clone()
                                },
                            )
                        })
                        .collect(),
                )
            })
            .unwrap_or(Value::Null);
        let wire = batch_wire! { self, parse_json(&metadata.to_string())? };
        self.editor.program.function_l_pixel_batch_receipt(wire)?;
        let recorded = &raw["revision"];
        if canonical_revision(raw)? != recorded.as_str().unwrap() {
            return Err(BatchFailure::single(json!({
                "code": "batch-integrity", "message": "The pixel batch receipt has changed", "revision": recorded,
            })));
        }
        let steps = raw["steps"].as_array();
        self.editor
            .program
            .function_l_pixel_batch_count(steps.map_or(0, |rows| rows.len() as u32))?;
        for step in steps.unwrap() {
            check_replay_receipt(step)?;
        }
        Ok(())
    }

    fn replay_batch_data(&mut self, mut raw: Json) -> Result<Value, PixelEditError> {
        let recorded = json_value(&raw)?;
        self.run_recorded_batch(&recorded, take_member(&mut raw, "steps"))
            .map_err(|error| error.reject("replay-batch", &recorded["revision"]))?;
        Ok(recorded)
    }

    fn run_recorded_batch(&mut self, recorded: &Value, raw_steps: Json) -> BatchResult<()> {
        self.require_no_draft()?;
        self.read_batch(recorded)?;
        let Json::Array(raw_steps) = raw_steps else {
            unreachable!()
        };
        let actual = self.batch_anchor()?;
        let input = batch_wire! { self, parse_json(&recorded["inputs"].to_string())? };
        let current = batch_wire! { self, parse_json(&actual.to_string())? };
        let conflicts = self
            .editor
            .program
            .function_l_pixel_batch_input_changes(input, current);
        if !conflicts.is_empty() {
            return Err(BatchFailure {
                conflicts: preview_rows(&conflicts)?,
                ..BatchFailure::default()
            });
        }
        self.settle_batch(recorded["label"].as_str().unwrap(), true, |editor| {
            for (index, (mut raw, step)) in raw_steps.into_iter()
                .zip(recorded["steps"].as_array().unwrap()).enumerate()
            {
                let patch = take_member(&mut take_member(&mut raw, "command"), "patch");
                editor.edit(patch, Some(step), None, EditMode::Apply)
                    .map_err(|error| BatchFailure::from(error).at(index))?;
            }
            let actual = editor.batch_anchor()?;
            if actual != recorded["outputs"] {
                return Err(BatchFailure::single(json!({
                    "code": "batch-output-mismatch", "message": "Replay did not reproduce the recorded transaction outputs",
                    "expected": recorded["outputs"], "actual": actual,
                })));
            }
            Ok(())
        })
    }

    fn revalidate_batch_data(
        &mut self,
        mut raw: Json,
        options: &Json,
    ) -> Result<Value, PixelEditError> {
        let recorded = json_value(&raw)?;
        let mut report = json!({ "format": "ink-studio/pixel-batch-revalidation", "version": 1 });
        set_recorded_revision(&mut report, &recorded["revision"]);
        match self.review_batch(&recorded, take_member(&mut raw, "steps"), options) {
            Ok((batch, preview, changes)) => {
                report["valid"] = json!(true);
                report["batch"] = batch;
                report["preview"] = json!(preview);
                report["changes"] = json!(changes);
                report["conflicts"] = json!([]);
                Ok(report)
            }
            Err(error) => {
                report["valid"] = json!(false);
                Ok(error.report(report))
            }
        }
    }

    fn review_batch(
        &mut self,
        recorded: &Value,
        raw_steps: Json,
        options: &Json,
    ) -> BatchResult<(Value, PixelEditPreview, Vec<Value>)> {
        self.require_no_draft()?;
        self.read_batch(recorded)?;
        let Json::Array(raw_steps) = raw_steps else {
            unreachable!()
        };
        let label = recorded["label"].as_str().unwrap();
        let inputs = self.batch_anchor()?;
        self.settle_batch(label, false, |editor| {
            let mut steps = Vec::new();
            let mut changes = Vec::new();
            for (index, (mut raw, step)) in raw_steps
                .into_iter()
                .zip(recorded["steps"].as_array().unwrap())
                .enumerate()
            {
                let patch = take_member(&mut take_member(&mut raw, "command"), "patch");
                let result = editor
                    .review_batch_step(patch, step, index)
                    .map_err(|error| error.at(index))?;
                if let Some(change) = result.1 {
                    changes.push(change);
                }
                steps.push(result.0);
            }
            let mut settings = options.clone();
            if matches!(member(&settings, "exact"), Some(Json::Null)) {
                put_member(&mut settings, "exact", Json::Boolean(false));
            }
            let options = preview_options(&settings)?;
            let preview = editor.preview_changes(options)?;
            let batch = seal(
                label,
                inputs,
                editor.batch_anchor()?,
                &steps,
                Some(&recorded["revision"]),
            )?;
            Ok((batch, preview, changes))
        })
    }

    fn review_batch_step(
        &mut self,
        mut patch: Json,
        step: &Value,
        index: usize,
    ) -> BatchResult<(Arc<Value>, Option<Value>)> {
        put_member(&mut patch, "revision", Json::Text(self.revision()?));
        if member(&patch, "frame").is_none() && member(&patch, "cel").is_none() {
            if let Some(frame) = step["command"]["frame"]
                .as_str()
                .filter(|name| !name.is_empty())
            {
                put_member(&mut patch, "frame", Json::Text(frame.into()));
            }
        }
        let shot = step["command"]["options"].get("shotHitFrame").cloned();
        let receipt = self
            .edit(patch, None, shot, EditMode::Apply)?
            .staged()
            .receipt;
        let before = &step["affectedTargets"][0];
        let after = &receipt["affectedTargets"][0];
        let left = batch_wire! { self, parse_json(&before.to_string())? };
        let right = batch_wire! { self, parse_json(&after.to_string())? };
        if !self
            .editor
            .program
            .function_l_pixel_batch_same_target(left, right)
        {
            let mut issue = conflict(
                "changed-target",
                "The current edit resolves to a different destination or target",
            );
            if !before.is_null() {
                issue["before"] = before.clone();
            }
            issue["after"] = after.clone();
            return Err(BatchFailure::single(issue));
        }
        let previous = evidence(step);
        let current = evidence(&receipt);
        let change = (previous != current)
            .then(|| json!({ "step": index, "before": previous, "after": current }));
        Ok((receipt, change))
    }
}
