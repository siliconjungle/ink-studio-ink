use super::*;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::{
    collections::BTreeMap,
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

const SESSION_FORMAT: &str = "ink-studio/pixel-edit-session";
const JOURNAL_FORMAT: &str = "ink-studio/authoring-session";
const SNAPSHOT_FORMAT: &str = "ink-studio/authoring";
const INVALID_JOURNAL: &str = "Invalid authoring session or incompatible history limit";
const INVALID_STATE: &str = "Invalid retained pixel edit state";
const INVALID_CHAIN: &str = "Invalid retained pixel edit receipt chain";

pub(super) struct SessionIdentity {
    slot: Option<String>,
    baseline: String,
    legacy: Option<String>,
    generation: u64,
}

impl SessionIdentity {
    pub(super) fn fresh(baseline: String, legacy: String) -> Self {
        Self {
            slot: None,
            baseline,
            legacy: named(legacy),
            generation: 1,
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Baseline<'a> {
    #[serde(borrow)]
    design: &'a RawValue,
    legacy_revision: Option<&'a str>,
}

#[derive(Deserialize)]
struct Checkpoint<'a> {
    format: &'a str,
    version: u32,
    revision: u64,
    slot: &'a str,
    #[serde(borrow)]
    baseline: Baseline<'a>,
    scene: Value,
    #[serde(borrow)]
    journal: Journal<'a>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Journal<'a> {
    format: &'a str,
    version: u32,
    history_limit: u32,
    revision: u64,
    #[serde(borrow)]
    current: Snapshot<'a>,
    #[serde(borrow)]
    undo: Vec<Entry<'a>>,
    #[serde(borrow)]
    redo: Vec<Entry<'a>>,
    #[serde(borrow)]
    draft: Option<Entry<'a>>,
}

#[derive(Deserialize)]
struct Entry<'a> {
    label: String,
    #[serde(borrow)]
    snapshot: Snapshot<'a>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot<'a> {
    format: &'a str,
    version: u32,
    id: &'a str,
    seed: u32,
    next_id: u32,
    #[serde(borrow)]
    entities: BTreeMap<String, Entity<'a>>,
    styles: Value,
    environment: Value,
}

#[derive(Deserialize)]
struct Entity<'a> {
    id: &'a str,
    #[serde(rename = "type")]
    kind: &'a str,
    content: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Content<'a, R> {
    #[serde(borrow)]
    design: &'a RawValue,
    legacy_revision: Option<String>,
    render_outputs: Map<String, Value>,
    receipts: Vec<R>,
    verified_replays: Vec<u32>,
}

#[derive(Default)]
struct ReceiptIndex<'a> {
    children: HashMap<u32, Vec<u32>>,
    decoded: HashMap<&'a str, Arc<Value>>,
}

impl<'a> ReceiptIndex<'a> {
    fn decode(&mut self, source: &'a RawValue) -> Result<Arc<Value>, String> {
        if let Some(receipt) = self.decoded.get(source.get()) {
            return Ok(Arc::clone(receipt));
        }
        let receipt = Arc::new(serde_json::from_str(source.get()).map_err(|_| INVALID_CHAIN)?);
        check_replay_receipt(&receipt).map_err(|error| error.to_string())?;
        self.decoded.insert(source.get(), Arc::clone(&receipt));
        Ok(receipt)
    }
}

fn new_slot() -> String {
    static NEXT_SLOT: AtomicU64 = AtomicU64::new(0);
    let time = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let token = revision(&format!(
        "{time}-{}-{}",
        std::process::id(),
        NEXT_SLOT.fetch_add(1, Ordering::Relaxed)
    ));
    format!(
        "pixel-editor-{}-{}-{}-{}-{}",
        &token[..8],
        &token[8..12],
        &token[12..16],
        &token[16..20],
        &token[20..32]
    )
}

fn load_saved_document(editor: &mut PixelEditor, source: &str, error: &str) -> Result<(), String> {
    let (document, planes) = read_document(source)?;
    if is_legacy(&document) {
        return Err(error.into());
    }
    editor.replace_packed_document(document, planes)
}

fn empty_object(value: &Value) -> bool {
    value.as_object().is_some_and(Map::is_empty)
}

impl Snapshot<'_> {
    fn content(&self, slot: &str) -> Result<Option<Content<'_, &RawValue>>, String> {
        if self.format != SNAPSHOT_FORMAT
            || self.version != 1
            || self.id != "world"
            || self.seed != 1
            || self.next_id != 1
            || !empty_object(&self.styles)
            || !empty_object(&self.environment)
            || self.entities.keys().any(|key| key != slot)
        {
            return Err(
                "Session history does not belong to the retained document and scene".into(),
            );
        }
        let Some(entity) = self.entities.get(slot) else {
            return Ok(None);
        };
        if entity.id != slot || entity.kind != "pixel-document" {
            return Err(INVALID_STATE.into());
        }
        let content: Content<'_, &RawValue> =
            serde_json::from_str(&entity.content).map_err(|_| INVALID_STATE)?;
        if !content.verified_replays.is_empty()
            || !content.render_outputs.is_empty()
            || content.legacy_revision.is_some()
        {
            return Err(INVALID_STATE.into());
        }
        Ok(Some(content))
    }
}

impl PixelCommandEditor {
    pub fn open_session(source: &str) -> Result<Self, String> {
        let checkpoint: Checkpoint<'_> =
            serde_json::from_str(source).map_err(|_| "Invalid pixel edit session checkpoint")?;
        if checkpoint.format != SESSION_FORMAT || checkpoint.version != 1 {
            return Err("Invalid pixel edit session checkpoint".into());
        }
        if !checkpoint.scene.is_null() {
            return Err("This pixel checkpoint needs an attached scene".into());
        }
        let journal = checkpoint.journal;
        if journal.format != JOURNAL_FORMAT
            || journal.version != 1
            || journal.undo.len() + journal.redo.len() > journal.history_limit as usize
        {
            return Err(INVALID_JOURNAL.into());
        }
        let entries = journal
            .undo
            .iter()
            .chain(&journal.redo)
            .chain(&journal.draft);
        if entries.clone().any(|entry| entry.label.is_empty()) {
            return Err("Invalid authoring session entry".into());
        }
        let mut editor = PixelEditor::empty();
        load_saved_document(
            &mut editor,
            checkpoint.baseline.design.get(),
            "Invalid pixel edit session identity",
        )?;
        let mut result = Self {
            editor,
            receipts: HashMap::new(),
            next_receipt: 0,
            session: SessionIdentity {
                slot: Some(checkpoint.slot.into()),
                legacy: checkpoint.baseline.legacy_revision.map(str::to_owned),
                baseline: checkpoint.baseline.design.get().into(),
                generation: checkpoint.revision,
            },
        };
        result.session_seed(checkpoint.slot, checkpoint.revision)?;
        let base_revision = revision(&result.editor.snapshot()?);
        let mut active_revision = base_revision.clone();
        let mut receipt_index = ReceiptIndex::default();
        let snapshots =
            std::iter::once(&journal.current).chain(entries.map(|entry| &entry.snapshot));
        for (index, snapshot) in snapshots.enumerate() {
            let content = snapshot.content(checkpoint.slot)?;
            let (cursor_revision, legacy, receipt) = if let Some(content) = content {
                let (last, observed) = result.restore_receipts(
                    &base_revision,
                    content.receipts,
                    &mut receipt_index,
                )?;
                let design = content.design.get();
                // Published edition strings already use canonical document JSON. Reformat
                // only when a checkpoint producer wrote equivalent pretty-printed JSON.
                if last == 0
                    || revision(design) != observed
                        && revision(&parse_json(design)?.stringify(Limits::default())?) != observed
                {
                    return Err("Invalid retained pixel document revision".into());
                }
                if active_revision != observed {
                    load_saved_document(&mut result.editor, design, INVALID_STATE)?;
                    active_revision = observed.clone();
                }
                (observed, String::new(), last)
            } else {
                if active_revision != base_revision {
                    load_saved_document(
                        &mut result.editor,
                        &result.session.baseline,
                        INVALID_STATE,
                    )?;
                    active_revision = base_revision.clone();
                }
                (
                    base_revision.clone(),
                    result.session.legacy.clone().unwrap_or_default(),
                    0,
                )
            };
            let id = u32::try_from(index + 1).map_err(|_| INVALID_JOURNAL)?;
            result
                .editor
                .program
                .invoke_view_l_stage_pixel_checkpoint(id, cursor_revision, legacy, receipt)?
                .result?;
        }
        let grid = result
            .editor
            .program
            .invoke_view_l_restore_pixel_checkpoint(
                journal.revision,
                journal.history_limit,
                journal.undo.into_iter().map(|entry| entry.label).collect(),
                journal.redo.into_iter().map(|entry| entry.label).collect(),
                journal.draft.map(|entry| entry.label),
            )?
            .result?;
        result.editor.grid = [grid.l_width, grid.l_height];
        Ok(result)
    }

    fn restore_receipts<'a>(
        &mut self,
        base: &str,
        steps: Vec<&'a RawValue>,
        index: &mut ReceiptIndex<'a>,
    ) -> Result<(u32, String), String> {
        let mut parent = 0;
        let mut revision = base.to_owned();
        for step in steps {
            let receipt = index.decode(step)?;
            if receipt["inputs"]["documentRevision"] != revision
                || !valid_revision(&receipt["outputs"]["documentRevision"])
            {
                return Err(INVALID_CHAIN.into());
            }
            revision = receipt["outputs"]["documentRevision"]
                .as_str()
                .unwrap()
                .to_owned();
            let branch = index.children.entry(parent).or_default();
            if let Some(id) = branch
                .iter()
                .find(|id| self.receipts[id].receipt == receipt)
            {
                parent = *id;
                continue;
            }
            self.next_receipt = self
                .next_receipt
                .checked_add(1)
                .ok_or("Pixel edit history has reached its receipt limit")?;
            self.receipts
                .insert(self.next_receipt, RecordedEdit { parent, receipt });
            branch.push(self.next_receipt);
            parent = self.next_receipt;
        }
        Ok((parent, revision))
    }

    fn session_seed(&self, slot: &str, generation: u64) -> Result<u32, String> {
        let legacy = self
            .session
            .legacy
            .as_ref()
            .map_or(Json::Null, |text| Json::Text(text.clone()));
        let wire = compiled_json(legacy, &|kind, scalar, flag, values, keys| {
            self.editor
                .program
                .function_l_pixel_json_value(kind, scalar, flag, values, keys)
        });
        self.editor
            .program
            .function_l_pixel_checkpoint_identity(slot.into(), wire, generation)
    }

    pub fn session_generation(&self) -> u64 {
        self.session.generation
    }

    pub fn session_token(&mut self) -> Result<(u64, u32, bool), String> {
        let layout = self
            .editor
            .program
            .invoke_view_l_pixel_checkpoint_layout()?
            .result;
        Ok((
            layout.l_revision,
            layout.l_cursor.l_receipt,
            layout.l_draft.l_id != 0,
        ))
    }

    pub fn export_session(&mut self, generation: u64) -> Result<String, String> {
        if self.session.slot.is_none() {
            self.session.slot = Some(new_slot());
        }
        let slot = self.session.slot.as_ref().unwrap().clone();
        let seed = self.session_seed(&slot, generation)?;
        let layout = self
            .editor
            .program
            .invoke_view_l_pixel_checkpoint_layout()?
            .result;
        let current = self.session_snapshot(layout.l_draft.l_id, &slot, seed)?;
        let undo: Vec<_> = layout
            .l_past
            .into_iter()
            .map(|entry| {
                self.session_snapshot(entry.l_id, &slot, seed)
                    .map(|snapshot| json!({ "label": entry.l_label, "snapshot": snapshot }))
            })
            .collect::<Result<_, _>>()?;
        let redo: Vec<_> = layout
            .l_future
            .into_iter()
            .map(|entry| {
                self.session_snapshot(entry.l_id, &slot, seed)
                    .map(|snapshot| json!({ "label": entry.l_label, "snapshot": snapshot }))
            })
            .collect::<Result<_, _>>()?;
        let mut journal = json!({ "format": JOURNAL_FORMAT, "version": 1, "historyLimit": layout.l_limit,
            "revision": layout.l_revision, "current": current, "undo": undo, "redo": redo });
        if layout.l_draft.l_id != 0 {
            journal["draft"] = json!({ "label": layout.l_draft.l_label, "snapshot": self.session_snapshot(0, &slot, seed)? });
        }
        #[derive(Serialize)]
        struct Export<'a> {
            format: &'static str,
            version: u32,
            revision: u64,
            slot: String,
            #[serde(borrow)]
            baseline: Baseline<'a>,
            scene: (),
            journal: Value,
        }
        let design =
            serde_json::from_str(&self.session.baseline).map_err(|error| error.to_string())?;
        serde_json::to_string(&Export {
            format: SESSION_FORMAT,
            version: 1,
            revision: generation,
            slot,
            baseline: Baseline {
                design,
                legacy_revision: self.session.legacy.as_deref(),
            },
            scene: (),
            journal,
        })
        .map_err(|error| error.to_string())
    }

    fn session_snapshot(&mut self, edition: u32, slot: &str, seed: u32) -> Result<Value, String> {
        let (document, cursor) = self.editor.snapshot_version(Some(edition))?;
        let cursor = cursor.ok_or("Missing pixel session cursor")?;
        let mut entities = Map::new();
        if cursor.receipt != 0 {
            let mut receipts = Vec::new();
            let mut root = cursor.receipt;
            while root != 0 {
                let row = self
                    .receipts
                    .get(&root)
                    .ok_or("Missing pixel edit receipt")?;
                receipts.push(Arc::clone(&row.receipt));
                root = row.parent;
            }
            receipts.reverse();
            let design = serde_json::from_str(&document).map_err(|error| error.to_string())?;
            let content = serde_json::to_string(&Content {
                design,
                legacy_revision: named(cursor.legacy),
                render_outputs: Map::new(),
                receipts,
                verified_replays: Vec::new(),
            })
            .map_err(|error| error.to_string())?;
            entities.insert(slot.into(), json!({ "id": slot, "type": "pixel-document", "seed": seed,
                "parent": null, "styleRef": null, "anchor": null, "parameters": {}, "overrides": {}, "content": content }));
        }
        Ok(
            json!({ "format": SNAPSHOT_FORMAT, "version": 1, "id": "world", "seed": 1,
            "nextId": 1, "entities": entities, "styles": {}, "environment": {} }),
        )
    }
}
