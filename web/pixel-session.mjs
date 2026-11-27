const sessionFormat = 'ink-studio/pixel-edit-session';
const journalFormat = 'ink-studio/authoring-session';
const snapshotFormat = 'ink-studio/authoring';
const record = value => value && typeof value === 'object' && !Array.isArray(value);
const empty = value => record(value) && Object.keys(value).length === 0;
const integer = value => Number.isSafeInteger(value) && value >= 0;
const invalidJournal = 'Invalid authoring session or incompatible history limit';
const invalidState = 'Invalid retained pixel edit state';

export function parsePixelSession(source) {
  const raw = typeof source === 'string' ? JSON.parse(source) : source;
  if (!record(raw) || raw.format !== sessionFormat || raw.version !== 1 || !integer(raw.revision) || !raw.revision) {
    throw new Error('Invalid pixel edit session checkpoint');
  }
  if (!record(raw.baseline) || raw.baseline.design?.version !== 2 || !Object.hasOwn(raw.baseline, "legacyRevision")) throw new Error('Invalid pixel edit session identity');
  if (raw.scene !== null) throw new Error('This pixel checkpoint needs an attached scene');
  const { journal, slot } = raw;
  if (typeof slot !== 'string') throw new Error('Invalid pixel edit session identity');
  if (!record(journal) || journal.format !== journalFormat || journal.version !== 1 || !integer(journal.revision) ||
      !integer(journal.historyLimit) || journal.historyLimit > 0xffffffff || !Array.isArray(journal.undo) ||
      !Array.isArray(journal.redo) || journal.undo.length + journal.redo.length > journal.historyLimit) {
    throw new Error(invalidJournal);
  }
  for (const row of [...journal.undo, ...journal.redo, ...(Object.hasOwn(journal, 'draft') ? [journal.draft] : [])]) {
    if (!record(row) || typeof row.label !== 'string' || !row.label) throw new Error('Invalid authoring session entry');
  }
  return raw;
}

export function readPixelEdition(snapshot, slot, baseline) {
  if (!record(snapshot) || snapshot.format !== snapshotFormat || snapshot.version !== 1 || snapshot.id !== 'world' ||
      snapshot.seed !== 1 || snapshot.nextId !== 1 || !empty(snapshot.styles) || !empty(snapshot.environment) ||
      !record(snapshot.entities) || Object.keys(snapshot.entities).some(key => key !== slot)) {
    throw new Error('Session history does not belong to the retained document and scene');
  }
  const entity = snapshot.entities[slot];
  if (entity === undefined) return { ...baseline, receipts: [] };
  if (!record(entity) || entity.id !== slot || entity.type !== 'pixel-document' || typeof entity.content !== 'string') {
    throw new Error(invalidState);
  }
  const content = JSON.parse(entity.content);
  if (!record(content) || content.design?.version !== 2 || !Array.isArray(content.receipts) || content.receipts.length === 0 ||
      !Array.isArray(content.verifiedReplays) || content.verifiedReplays.length ||
      !empty(content.renderOutputs) || content.legacyRevision !== null) throw new Error(invalidState);
  return content;
}

export function pixelSessionCheckpoint({ baseline, slot, seed, revision, layout, snapshot }) {
  function edition(id) {
    const { cursor, document, receipts } = snapshot(id);
    const entities = cursor.receipt ? { [slot]: { id: slot, type: 'pixel-document', seed, parent: null,
      styleRef: null, anchor: null, parameters: {}, overrides: {}, content: JSON.stringify({
        design: document, legacyRevision: cursor.legacy || null, renderOutputs: {}, receipts, verifiedReplays: [],
      }) } } : {};
    return { format: snapshotFormat, version: 1, id: 'world', seed: 1, nextId: 1, entities, styles: {}, environment: {} };
  }
  const entry = row => ({ label: row.label, snapshot: edition(row.id) });
  const { draft } = layout;
  return { format: sessionFormat, version: 1, revision, slot, baseline, scene: null,
    journal: { format: journalFormat, version: 1, historyLimit: layout.limit, revision: Number(layout.revision),
      current: edition(draft.id), undo: layout.past.map(entry), redo: layout.future.map(entry),
      ...(draft.id && { draft: { label: draft.label, snapshot: edition(0) } }) } };
}
