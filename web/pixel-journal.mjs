import { callOwned } from '../build/pixel_document.mjs';
import { pixelPng, pngBase64 } from './pixel-png.mjs';
import { pixelSessionCheckpoint, readPixelEdition } from './pixel-session.mjs';

const receiptFormat = 'ink-studio/pixel-edit-receipt';
const isRevision = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);

function capture(value) {
  return JSON.parse(JSON.stringify(value ?? null));
}

function equal(a, b) {
  if (a === b) return true;
  if (!a || !b || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) !== Array.isArray(b)) {
    return false;
  }
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every(key => Object.hasOwn(b, key) && equal(a[key], b[key]));
}

function replayReceipt(receipt) {
  if (receipt?.format !== receiptFormat || receipt.version !== 1 || receipt.status !== 'applied' ||
      receipt.command?.runner !== 'sdk' || receipt.command.action !== 'edit' ||
      !isRecord(receipt.command.patch) || !isRecord(receipt.command.options) ||
      !isRevision(receipt.inputs?.documentRevision) || !isRevision(receipt.outputs?.artifactRevision)) {
    throw new TypeError('Replay needs an applied version 1 pixel edit receipt from the sdk');
  }
  return receipt;
}

function editError(code, message, details = {}) {
  return Object.assign(new Error(message), { conflict: { code, message, ...details } });
}

const batchFormat = 'ink-studio/pixel-edit-batch';

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (isRecord(value)) return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
}

function batchFailure(error) {
  return {
    ...(error.batchStep !== undefined && { failedStep: error.batchStep }),
    conflicts: error.receipt?.conflicts ?? error.conflicts ??
      [error.conflict ?? { code: 'invalid-edit', message: error.message }],
    ...(error.receipt && { editReceipt: error.receipt }),
  };
}

function rejectBatch(action, error, recordedRevision) {
  const failure = batchFailure(error);
  error.receipt = { format: 'ink-studio/pixel-batch-rejection', version: 1, action,
    ...(isRevision(recordedRevision) && { recordedRevision }), ...failure };
  throw error;
}

async function runBatchStep(index, run) {
  try {
    return await run();
  } catch (error) {
    throw Object.assign(error, { batchStep: index });
  }
}

function gateFields(patch) {
  if (!isRecord(patch)) return patch;
  const names = ['id', 'revision', 'frame', 'cel', 'destination', 'ownership', 'sourceRevision'];
  const fields = Object.fromEntries(names.filter(key => Object.hasOwn(patch, key)).map(key => [key, patch[key]]));
  if (Object.hasOwn(patch, 'edits')) fields.edits = true;
  if (Object.hasOwn(patch, 'operation')) fields.operation = { tool: patch.operation?.tool ?? null };
  return fields;
}

function commandMetadata(raw, nested = false) {
  if (!isRecord(raw)) return null;
  return Object.fromEntries(Object.entries(raw).map(([key, value]) => {
    if (['format', 'version', 'action', 'label', 'artifact'].includes(key)) return [key, value];
    if (key === 'edit' && !nested) return [key, commandMetadata(value, true)];
    if (key === 'options' && isRecord(value)) return [key, Object.fromEntries(Object.keys(value).map(name => [name, null]))];
    if (key === 'patch' && isRecord(value)) {
      const patch = {};
      if (Object.hasOwn(value, 'destination')) patch.destination = value.destination;
      if (Object.hasOwn(value, 'edits')) patch.edits = Array.isArray(value.edits) ? [] : null;
      if (Object.hasOwn(value, 'operation')) {
        const operation = value.operation;
        patch.operation = isRecord(operation) ? Object.fromEntries(
          Object.entries(operation).filter(([name]) => name === 'tool' || name === 'type')) : null;
      }
      return [key, patch];
    }
    return [key, null];
  }));
}

function normalizedPatch(patch, { destination, tool }) {
  if (destination.Some !== undefined) patch.destination = destination.Some;
  if (tool.Some !== undefined) patch.operation.tool = tool.Some;
  return patch;
}

function rasterAsset({ slots, alpha, knockouts }) {
  return { slots: slots.map(slot => slot < 0 ? null : slot),
    ...(alpha.length && { alpha }), ...(knockouts.length && { knockouts }) };
}

function stampAsset(codec, { info, raster, selections }) {
  return { ...codec.toJS(info), ...rasterAsset(raster), ...(selections.length && { selections }) };
}

function deckAsset(codec, { info, frames, shared, show_selections: showSelections }) {
  const baked = frames.map(frame => {
    const { durationMs, ...fields } = codec.toJS(frame.info);
    const cels = Object.fromEntries(frame.cels.map(cel =>
      [cel.layer, { ...codec.toJS(cel.info), ...rasterAsset(cel.raster) }]));
    return { ...fields, duration: durationMs / 1000, cels, ...(showSelections && { selections: frame.selections }) };
  });
  return { ...codec.toJS(info), frames: baked, ...(shared.length && { sharedSelections: shared }) };
}

function inspectionReport(codec, { document, layers }) {
  const branches = new Map();
  for (const { fields, id, parent, opacity } of layers) {
    const layer = codec.toJS(fields);
    layer.opacity = opacity;
    if (layer.kind === 'group') {
      layer.children = branches.get(id) ?? [];
      branches.delete(id);
    }
    if (!branches.has(parent)) branches.set(parent, []);
    branches.get(parent).push(layer);
  }
  return { ...codec.toJS(document), layers: branches.get('') ?? [] };
}

function previewOptions({ limit = 256, exact, shotHitFrame } = {}) {
  if (exact !== undefined && typeof exact !== 'boolean') throw new TypeError('Exact preview must be a boolean');
  if (shotHitFrame !== undefined && (!exact || !Number.isInteger(shotHitFrame) || shotHitFrame < 0 || shotHitFrame > 1e9)) {
    throw new TypeError('A preview shot hit sample needs exact mode and a nonnegative shot frame');
  }
  if (!Number.isSafeInteger(limit) || limit < 0) throw new RangeError('Pixel preview limit must be a nonnegative integer');
  return { limit: Math.min(limit, 0xffffffff), exact: exact ?? false };
}

function cellChanges(rows = [], exact = false) {
  const location = ({ layer, cel, swatch }) => ({ layer: layer || null, cel: cel || null, swatch: swatch || null });
  return rows.map(({ site, layer, before, after }) => {
    function describe({ Some: sample }) {
      if (!sample) return null;
      const { layer: owner, cel, swatch } = sample.location;
      const color = swatch ? '#' + sample.rgb.toString(16).padStart(6, '0') : null;
      const alpha = sample.alpha.Some;
      if (layer) return { cel: cel || null, swatch: swatch || null, color, alpha, knockout: sample.knockout, clip: sample.clip };
      const painted = { layer: owner || null, cel: cel || null, swatch: swatch || null, color, protected: sample.protected };
      if (alpha !== undefined) painted.alpha = alpha;
      if (!exact) painted.underneath = location(sample.underneath);
      return painted;
    }
    const { frame, at } = site;
    const left = describe(before), right = describe(after);
    return layer ? { frame, at, layer, before: left, after: right } : { frame, at, before: left, after: right };
  });
}

function previewReport(codec, changes, targets, conflicts, links, exact) {
  const guides = changes?.guides.map(row => codec.toJS(row)) ?? [];
  const report = { format: 'ink-studio/pixel-edit-preview', version: 1, valid: conflicts.length === 0,
    ...(links && { celLinks: links }), pixelCount: changes?.pixelCount ?? 0,
    pixels: cellChanges(changes?.pixels), sources: [], targets, conflicts, ...(guides.length && { guides }) };
  if (exact) {
    const cells = cellChanges(changes?.exact.cells, true);
    const protectedCells = changes?.exact.protectedCells ?? [];
    const details = changes?.exact.details.map(row => codec.toJS(row)) ?? [];
    const hits = conflicts.filter(issue => Object.hasOwn(issue, 'at'));
    const grids = changes?.exact.grids.map(row => codec.toJS(row)) ?? [];
    report.diff = { cells, grids, materials: [], geometry: [], other: [], rendered: [], renderErrors: [],
      skippedHits: hits, protection: { wouldChange: protectedCells.length !== 0 || details.length !== 0,
        details, geometry: [], cells: protectedCells, renderedCells: [],
        blocked: hits.filter(issue => issue.code.startsWith('protected-')) } };
  }
  return report;
}

export async function openPixelJournal({ editor, state, codec, revision, revisionText, restoreSnapshot, setGrid, documentInputLimits, workshopText }, input, historyLimit, checkpoint, storage) {
  const bind = (name, inputLimits) => state.bind(name, { resultOnly: true, inputLimits });
  const read = bind('pixel_journal'), begin = bind('begin_pixel_edit');
  const commit = bind('commit_pixel_edit'), cancel = bind('cancel_pixel_edit');
  const travel = bind('travel_pixel_history'), check = bind('resolve_pixel_edit');
  const grid = bind('pixel_editor_grid');
  const guarded = bind('replace_guarded_pixels');
  const paletteEdit = bind('edit_pixel_editor_palette');
  const guideEdit = bind('edit_pixel_editor_guides');
  const timelineEdit = bind('edit_pixel_editor_timeline', documentInputLimits);
  const canvasEdit = bind('edit_pixel_editor_canvas');
  const plan = bind('plan_pixel_command'), describe = bind('describe_pixel_command_document');
  const inspect = bind('inspect_pixel_command');
  const sample = bind('sample_pixel_editor'), snap = bind('snap_pixel_editor'), timeline = bind('timeline_pixel_editor');
  const slices = bind('slices_pixel_editor'), exportSlice = bind('export_pixel_slice');
  const inspectTilemap = bind('inspect_pixel_tilemap'), exportTilemap = bind('export_pixel_tilemap');
  const exportNeighbors = bind('export_pixel_tilemap_neighbors');
  const sliceFrame = frame => frame === undefined ? { None: null } : { Some: String(frame) };
  const stamp = bind('export_pixel_command_stamp'), deck = bind('export_pixel_command_layer_deck');
  const png = bind('export_pixel_command_png');
  const observe = bind('observe_pixel_edit'), links = bind('pixel_edit_links');
  const observePreview = bind('observe_pixel_preview'), editDiff = bind('pixel_preview_diff');
  const draftDiff = bind('pixel_draft_diff');
  const accept = bind('accept_pixel_edit');
  const batchStep = bind('plan_pixel_batch_step'), batchDraft = bind('pixel_batch_draft');
  const batchAnchor = bind('pixel_batch_anchor');
  const batchPure = (name, ...args) => callOwned('pixel_batch_' + name, args);
  const receipts = new Map();
  let nextReceipt = 0, previous = Promise.resolve();
  let attached = storage, savedToken, saveError = null;

  function unwrap(result) {
    if (Object.hasOwn(result, 'Err')) throw new Error(result.Err);
    return result.Ok;
  }

  function encodePng(options) {
    const image = unwrap(png(codec.fromJS(options)));
    return pixelPng(image, codec.toJS(image.metadata));
  }

  function rasterBytes({ width, height, pixels }) {
    const rgba = new Uint8Array(width * height * 4);
    const body = new DataView(rgba.buffer);
    for (let i = 0; i < pixels.length; i++) body.setUint32(i * 4, pixels[i]);
    return { w: width, h: height, rgba };
  }

  async function runWithSave(run) {
    try {
      return await run();
    } finally {
      await flushSession();
    }
  }

  function enqueue(run, mayWrite = false) {
    const result = previous.then(() => mayWrite && attached ? runWithSave(run) : run());
    previous = result.then(() => {}, () => {});
    return result;
  }

  function trim() {
    // The authored journal keeps lightweight cursors. The bridge owns the
    // detached JSON receipts and keeps only the chains those cursors reach.
    const reachable = new Set();
    for (let id of read().roots) {
      while (id && !reachable.has(id)) {
        reachable.add(id);
        id = receipts.get(id).parent;
      }
    }
    for (const id of receipts.keys()) if (!reachable.has(id)) receipts.delete(id);
  }

  function receiptChain(id = read().cursor.receipt, base = 0) {
    const rows = [];
    for (; id !== base;) {
      const row = receipts.get(id);
      rows.push(row.receipt);
      id = row.parent;
    }
    return rows.reverse();
  }

  function applyGuarded(patch, gate, reuseComposites) {
    const missing = { None: null };
    const nullValue = codec.fromJS(null);
    const edits = Array.isArray(patch.edits) && patch.edits.length <= 4096 ? patch.edits.map(raw => {
      const row = isRecord(raw) ? raw : {};
      const at = row.at ?? null;
      // Keep invalid coordinates in their authored form for the conflict reply.
      const packed = Array.isArray(at) && at.length === 2 &&
        at.every(word => Number.isInteger(word) && word >= 0 && word < 512);
      const field = key => Object.hasOwn(row, key)
        ? { Some: row[key] === null ? nullValue : codec.fromJS(row[key]) } : missing;
      return { point: packed ? { Some: at } : missing, at: packed || at === null ? nullValue : codec.fromJS(at),
        layer: field('layer'), from: field('from'), to: field('to') };
    }) : [];
    const result = guarded(patch.id, gate.frame, gate.cel, edits, reuseComposites);
    if (Object.hasOwn(result, 'Err')) {
      const conflicts = result.Err.map(issue => codec.toJS(issue));
      throw Object.assign(new Error(conflicts[0].message), { conflicts });
    }
    return { kind: 'raster', ...result.Ok };
  }

  function applyPalette(patch) {
    const scoped = ['frame', 'cel', 'edits'].some(key => Object.hasOwn(patch, key));
    return decodeEdit(paletteEdit(codec.fromJS(patch.operation ?? null), scoped));
  }

  function decodeEdit(result) {
    if (Object.hasOwn(result, 'Err')) {
      const conflict = codec.toJS(result.Err);
      throw Object.assign(new Error(conflict.message), { conflict });
    }
    return codec.toJS(result.Ok);
  }

  function applyCanvas(patch) {
    const scoped = ['frame', 'cel', 'edits'].some(key => Object.hasOwn(patch, key));
    return codec.toJS(unwrap(canvasEdit(codec.fromJS(patch.operation ?? null), scoped)));
  }

  async function attempt(patch, { dryRun = false, expected, preview, options: editOptions } = {}) {
    const { cursor, pending, redo } = read();
    const shot = (expected?.command.options ?? editOptions)?.shotHitFrame;
    const options = shot === undefined ? {} : { shotHitFrame: shot };
    const command = { runner: 'sdk', action: 'edit', options, patch };
    const common = { format: receiptFormat, version: 1, command, inputs: { documentRevision: cursor.revision } };
    let started = false;
    try {
      if (expected && !equal(options, expected.command.options)) {
        throw editError('receipt-arguments', 'Replay needs the same edit options recorded in the receipt');
      }
      if (expected && cursor.revision !== expected.inputs.documentRevision) {
        throw editError('stale-document', 'Receipt was recorded against a different pixel document',
          { expected: expected.inputs.documentRevision, actual: cursor.revision });
      }
      const gate = check(codec.fromJS(gateFields(patch)));
      if (gate.frame) command.frame = ['canvas', 'palette', 'timeline'].includes(gate.kind) ? null : gate.frame;
      const conflict = codec.toJS(gate.conflict);
      if (conflict) throw Object.assign(new Error(conflict.message), { conflict });
      if (shot !== undefined) {
        throw new Error('A shot hit sample needs a shot-correction edit and a nonnegative shot frame');
      }

      state.beginTransaction();
      started = true;
      if (!dryRun && !pending) unwrap(begin(patch.id));
      observe();
      if (preview) observePreview();
      const target = gate.direct ? applyGuarded(patch, gate, !!preview && !preview.exact)
        : gate.kind === 'canvas' ? applyCanvas(patch)
        : gate.kind === 'palette' ? applyPalette(patch)
        : gate.kind === 'guides' ? decodeEdit(guideEdit(codec.fromJS(patch.operation ?? null)))
        : gate.kind === 'timeline' ? decodeEdit(timelineEdit(codec.fromJS(patch.operation ?? null)))
        : gate.kind === 'selections' ? editor.saveSelection(patch.operation, { frame: gate.frame })
        : editor.paint(patch.operation, { frame: gate.frame, cel: gate.cel.Some });
      target.destination = gate.destination;
      if (preview) {
        const changes = gate.kind === 'selections' ? undefined : unwrap(editDiff(preview.limit, preview.exact));
        const report = previewReport(codec, changes, gate.direct || gate.kind === 'guides' ? [] : [target],
          [], links().Some, preview.exact);
        state.rollbackTransaction();
        return report;
      }
      const document = editor.snapshot();
      const after = await revision(document);
      const changes = links().Some;
      const receipt = { ...common, status: 'applied', affectedTargets: [target], skippedHits: [],
        ...(changes && { celLinks: changes }), outputs: { kind: gate.kind, documentRevision: after, artifactRevision: after } };
      if (expected) {
        const { celLinks, ...early } = receipt;
        if (!equal(Object.hasOwn(expected, 'celLinks') ? receipt : early, expected)) {
          throw editError('receipt-mismatch', 'Replay did not reproduce the recorded targets, hits, or output revisions');
        }
      }
      if (dryRun) {
        state.rollbackTransaction();
      } else {
        const id = nextReceipt + 1;
        if (id > 0xffffffff) throw new Error('Pixel edit history has reached its receipt limit');
        unwrap(accept(after, id));
        if (!pending) unwrap(commit());
        state.commitTransaction();
        if (gate.kind === 'canvas') setGrid(grid());
        nextReceipt = id;
        receipts.set(id, { parent: cursor.receipt, receipt });
        if (!pending && redo.length) trim();
      }
      started = false;
      return { document, receipt };
    } catch (error) {
      if (started) state.rollbackTransaction();
      if (pending && !dryRun) transition('cancel');
      const conflicts = error.conflicts ?? [error.conflict ?? { code: 'invalid-edit', message: error.message }];
      if (preview) return previewReport(codec, undefined, [], conflicts, undefined, preview.exact);
      const receipt = { ...common, status: 'rejected', affectedTargets: [],
        skippedHits: conflicts.filter(issue => Object.hasOwn(issue, 'at') || Object.hasOwn(issue, 'splat')), conflicts, outputs: null };
      if (dryRun) return { document: editor.snapshot(), receipt };
      throw Object.assign(error, { receipt });
    }
  }

  function history() {
    const { undo, redo } = read();
    return { undo, redo };
  }

  function transition(action) {
    if (action === 'undo' || action === 'redo') {
      const changed = unwrap(travel(action === 'redo'));
      if (changed) setGrid(grid());
      return changed;
    }
    const discard = action === 'cancel' || read().redo.length !== 0;
    const changed = unwrap(action === 'cancel' ? cancel() : commit());
    if (discard && changed) trim();
    if (action === 'cancel' && changed) setGrid(grid());
    return changed;
  }

  function previewDraft(options) {
    const { limit, exact } = previewOptions(options);
    const { cursor } = read();
    const result = unwrap(draftDiff(limit, exact));
    const targets = [];
    for (let id = cursor.receipt; id !== result.receipt;) {
      const row = receipts.get(id);
      const target = row.receipt.affectedTargets[0];
      if (!['guides', 'slice', 'tilemap'].includes(target.kind) && (target.kind !== 'raster' || target.tool)) targets.push(target);
      id = row.parent;
    }
    return previewReport(codec, result.changes, structuredClone(targets.reverse()), [], result.celLinks.Some, exact);
  }

  const anchor = () => codec.toJS(batchAnchor());

  function requireNoDraft() {
    if (read().pending) {
      throw editError('active-transaction', 'Finish the open pixel transaction before running a batch');
    }
  }

  async function sealBatch(label, inputs, outputs, steps, revalidatedFrom) {
    const body = { format: batchFormat, version: 1, label, inputs, outputs, steps,
      ...(revalidatedFrom !== undefined && { revalidatedFrom }) };
    return { ...body, revision: await revision(canonical(body)) };
  }

  async function readBatch(raw) {
    const metadata = isRecord(raw) ? Object.fromEntries(Object.entries(raw).map(([key, data]) =>
      [key, key === 'steps' ? null : data])) : null;
    unwrap(batchPure('receipt', codec.fromJS(metadata)));
    const { revision: recordedRevision, ...body } = raw;
    if (await revision(canonical(body)) !== recordedRevision) {
      throw editError('batch-integrity', 'The pixel batch receipt has changed', { revision: recordedRevision });
    }
    unwrap(batchPure('count', Array.isArray(body.steps) ? body.steps.length : 0));
    body.steps.forEach(replayReceipt);
    return raw;
  }

  async function settleBatch(label, run, save = true) {
    unwrap(begin(label));
    try {
      const result = await run();
      if (save) transition('commit');
      return result;
    } finally {
      if (read().pending) transition('cancel');
    }
  }

  async function applyBatch(raw) {
    try {
      requireNoDraft();
      const metadata = isRecord(raw) ? Object.fromEntries(Object.entries(raw).map(([key, data]) =>
        [key, key === 'revision' || key === 'label' ? data : null])) : null;
      const label = unwrap(batchPure('plan', codec.fromJS(metadata),
        Array.isArray(raw?.commands) ? raw.commands.length : 0));
      const inputs = anchor();
      if (raw.revision !== inputs.documentRevision) {
        throw editError('stale-document', 'Pixel batch needs its observed base revision',
          { expected: raw.revision, actual: inputs.documentRevision });
      }
      return await settleBatch(label, async () => {
        const steps = [];
        for (const [index, step] of raw.commands.entries()) {
          steps.push(await runBatchStep(index, async () => {
            const ready = unwrap(batchStep(codec.fromJS(commandMetadata(step))));
            const patch = normalizedPatch(step.patch, ready);
            if (!Object.hasOwn(patch, 'revision')) patch.revision = read().cursor.revision;
            return (await attempt(patch, { options: step.options })).receipt;
          }));
        }
        return sealBatch(label, inputs, anchor(), steps);
      });
    } catch (error) {
      rejectBatch('batch', error);
    }
  }

  async function recordBatch() {
    try {
      if (!read().pending) throw editError('missing-transaction', 'Open a pixel transaction before recording a batch');
      const base = unwrap(batchDraft());
      const steps = receiptChain(read().cursor.receipt, base.receipt);
      unwrap(batchPure('count', steps.length));
      return sealBatch(base.label, codec.toJS(base.anchor), anchor(), steps);
    } catch (error) {
      rejectBatch('record-batch', error);
    }
  }

  async function replayBatch(raw) {
    try {
      requireNoDraft();
      const recorded = await readBatch(raw);
      const conflicts = batchPure('input_changes', codec.fromJS(recorded.inputs), codec.fromJS(anchor()))
        .map(issue => codec.toJS(issue));
      if (conflicts.length) throw Object.assign(new Error(conflicts[0].message), { conflicts });
      return await settleBatch(recorded.label, async () => {
        for (const [index, expected] of recorded.steps.entries()) {
          await runBatchStep(index, () => attempt(expected.command.patch, { expected }));
        }
        const actual = anchor();
        if (!equal(actual, recorded.outputs)) {
          throw editError('batch-output-mismatch', 'Replay did not reproduce the recorded transaction outputs',
            { expected: recorded.outputs, actual });
        }
        return recorded;
      });
    } catch (error) {
      rejectBatch('replay-batch', error, raw?.revision);
    }
  }

  async function revalidateBatch(raw, options) {
    const report = { format: 'ink-studio/pixel-batch-revalidation', version: 1,
      ...(isRevision(raw?.revision) && { recordedRevision: raw.revision }) };
    try {
      requireNoDraft();
      const recorded = await readBatch(raw);
      const inputs = anchor();
      return await settleBatch(recorded.label, async () => {
        const changes = [], steps = [];
        for (const [index, previous] of recorded.steps.entries()) {
          await runBatchStep(index, async () => {
            const patch = structuredClone(previous.command.patch);
            patch.revision = read().cursor.revision;
            if (!Object.hasOwn(patch, 'frame') && !Object.hasOwn(patch, 'cel') && previous.command.frame) {
              patch.frame = previous.command.frame;
            }
            const { receipt } = await attempt(patch, { options: previous.command.options });
            const before = previous.affectedTargets?.[0], after = receipt.affectedTargets[0];
            if (!batchPure('same_target', codec.fromJS(before ?? null), codec.fromJS(after))) {
              throw editError('changed-target', 'The current edit resolves to a different destination or target',
                { ...(before && { before }), after });
            }
            const evidence = ({ affectedTargets: targets, skippedHits, shotHits }) => ({ targets, skippedHits, shotHits });
            const previousEvidence = evidence(previous), currentEvidence = evidence(receipt);
            if (!equal(previousEvidence, currentEvidence)) {
              changes.push({ step: index, before: previousEvidence, after: currentEvidence });
            }
            steps.push(receipt);
          });
        }
        const preview = previewDraft({ exact: options?.exact ?? false, limit: options?.limit });
        const batch = await sealBatch(recorded.label, inputs, anchor(), steps, recorded.revision);
        return { ...report, valid: true, batch, preview, changes, conflicts: [] };
      }, false);
    } catch (error) {
      return { ...report, valid: false, ...batchFailure(error) };
    }
  }

  async function execute(raw) {
    const ready = unwrap(plan(codec.fromJS(commandMetadata(raw))));
    switch (ready.action) {
      case 'apply':
        return structuredClone((await attempt(normalizedPatch(raw.patch, ready), { options: raw.options })).receipt);
      case 'replay': {
        const expected = replayReceipt(raw.receipt);
        return structuredClone((await attempt(expected.command.patch, { expected })).receipt);
      }
      case 'batch': {
        const { revision, label, commands } = raw;
        return structuredClone(await applyBatch({ revision, commands, ...(label !== undefined && { label }) }));
      }
      case 'record-batch': return structuredClone(await recordBatch());
      case 'replay-batch': return structuredClone(await replayBatch(raw.batch));
      case 'revalidate-batch': return revalidateBatch(raw.batch, raw.options);
      case 'begin':
        unwrap(begin(raw.label ?? ''));
        return { history: history() };
      case 'undo': case 'redo': case 'commit': case 'cancel':
        return { changed: transition(ready.action), history: history() };
      case 'preview-edit':
        return attempt(normalizedPatch(raw.edit.patch, ready), { dryRun: true, preview: previewOptions(raw.options) });
      case 'preview-draft':
        return previewDraft(raw.options);
      case 'select': {
        const result = editor.select(raw.query, raw.options);
        if (raw.options?.targetRevision !== undefined) throw new Error('A target revision needs an intent query');
        return { revision: read().cursor.revision, ...result, pixelCount: result.pixels.length };
      }
      case 'validate':
        return codec.toJS(unwrap(describe()));
      case 'inspect':
        return inspectionReport(codec, unwrap(inspect(codec.fromJS(raw.at), codec.fromJS(raw.options ?? {}))));
      case 'export-document':
        return { artifact: 'document', data: editor.snapshot() };
      case 'export-stamp':
        return { artifact: 'stamp', data: stampAsset(codec, unwrap(stamp(codec.fromJS(raw.options ?? {})))) };
      case 'export-png':
        return { artifact: 'png', encoding: 'base64', data: pngBase64(await encodePng(raw.options ?? {})) };
      case 'export-layer-deck':
        return { artifact: 'layer-deck', data: deckAsset(codec, unwrap(deck())) };
      case 'export-scene': case 'export-shot-corrections': case 'export-splat-fit': case 'export-scan-paint':
        throw new Error('No session artifact named ' + ready.action.slice(7));
      default:
        throw new Error('Pixel editor has not implemented command ' + raw.action +
          (raw.action === 'export' ? ' ' + raw.artifact : ''));
    }
  }

  const layout = bind('pixel_checkpoint_layout');
  const checkpointSnapshot = bind('snapshot_pixel_checkpoint');
  const baselineText = JSON.stringify(editor.snapshot());
  const [current, legacy] = await Promise.all([revisionText(baselineText), input.version === 1 ? revision(input) : '']);
  const legacyRevision = checkpoint ? checkpoint.baseline.legacyRevision : legacy || null;
  let slot = checkpoint?.slot;
  let generation = checkpoint?.revision ?? (storage ? 0 : 1);
  const identity = (name, revision) => unwrap(callOwned('pixel_checkpoint_identity',
    [name, codec.fromJS(legacyRevision), BigInt(revision)]));

  async function restoreCheckpoint(saved) {
    identity(slot, generation);
    const stage = bind('stage_pixel_checkpoint'), restore = bind('restore_pixel_checkpoint');
    const children = new Map();
    const { journal, baseline } = saved;
    const snapshots = [journal.current, ...journal.undo.map(row => row.snapshot), ...journal.redo.map(row => row.snapshot)];
    if (journal.draft) snapshots.push(journal.draft.snapshot);
    let activeRevision = current;
    for (const [index, snapshot] of snapshots.entries()) {
      const edition = readPixelEdition(snapshot, slot, baseline);
      let parent = 0, observed = current;
      for (const raw of edition.receipts) {
        const receipt = replayReceipt(raw);
        if (receipt.inputs.documentRevision !== observed || !isRevision(receipt.outputs.documentRevision))
          throw new Error('Invalid retained pixel edit receipt chain');
        observed = receipt.outputs.documentRevision;
        const branch = children.get(parent) ?? [];
        let next = branch.find(id => equal(receipt, receipts.get(id).receipt));
        if (!next) {
          next = ++nextReceipt;
          if (next > 0xffffffff) throw new Error('Pixel edit history has reached its receipt limit');
          branch.push(next);
          children.set(parent, branch);
          receipts.set(next, { parent, receipt });
        }
        parent = next;
      }
      const documentRevision = edition.receipts.length ? await revision(edition.design) : current;
      if (documentRevision !== observed) throw new Error('Invalid retained pixel document revision');
      if (documentRevision !== activeRevision) {
        editor.replaceDocument(edition.design);
        activeRevision = documentRevision;
      }
      unwrap(stage(index + 1, documentRevision, edition.legacyRevision ?? '', parent));
    }
    setGrid(unwrap(restore(BigInt(journal.revision), journal.historyLimit, journal.undo.map(row => row.label),
      journal.redo.map(row => row.label), journal.draft ? { Some: journal.draft.label } : { None: null })));
  }

  function exportSession(requested = generation, snapshotLayout = layout()) {
    if (!Number.isSafeInteger(requested) || requested < 1) throw new Error('Invalid pixel edit session checkpoint');
    slot ??= 'pixel-editor-' + crypto.randomUUID();
    const seed = identity(slot, requested);
    return pixelSessionCheckpoint({
      slot, seed, revision: requested, baseline: { design: JSON.parse(baselineText), legacyRevision }, layout: snapshotLayout,
      snapshot(id) {
        const edition = unwrap(checkpointSnapshot(id));
        const { cursor } = edition;
        return { cursor, document: cursor.receipt ? restoreSnapshot(edition.snapshot) : null,
          receipts: cursor.receipt ? receiptChain(cursor.receipt) : [] };
      },
    });
  }

  if (checkpoint) await restoreCheckpoint(checkpoint);
  else unwrap(bind('start_pixel_journal')(current, legacy, historyLimit));

  function sessionToken({ revision, cursor, draft }) {
    return [revision, cursor.receipt, draft.id].join(':');
  }

  async function flushSession() {
    if (!attached) return false;
    try {
      const snapshotLayout = layout();
      const nextToken = sessionToken(snapshotLayout);
      if (nextToken !== savedToken) {
        const next = exportSession(generation + 1, snapshotLayout);
        await attached.write(generation, next);
        generation = next.revision;
        savedToken = nextToken;
      }
      saveError = null;
    } catch (error) {
      saveError = error.message;
    }
    return saveError === null;
  }

  if (attached) {
    if (checkpoint) savedToken = sessionToken(layout());
    else if (!await flushSession()) throw new Error(saveError);
  }

  return Object.freeze({
    png(options = {}) {
      const saved = capture(options);
      return enqueue(() => encodePng(saved));
    },
    revision: () => enqueue(() => read().cursor.revision),
    history: () => enqueue(history),
    exportSession: generation => enqueue(() => exportSession(generation)),
    sessionStatus: () => enqueue(() => attached ? {
      name: attached.name, revision: generation, saved: saveError === null, error: saveError, pending: read().pending,
    } : null),
    flushSession: () => enqueue(flushSession),
    closeSession: () => enqueue(async () => {
      if (!await flushSession()) return false;
      attached.close();
      attached = undefined;
      return true;
    }),
    receipts: () => enqueue(() => structuredClone(receiptChain())),
    metadata: () => enqueue(editor.metadata),
    rasterize({ frame = '', layer = '', cel = '' } = {}) {
      return enqueue(() => editor.rasterize(frame, layer, cel));
    },
    ...(workshopText && { exportWorkshopStamp: () => enqueue(() => workshopText(read().cursor.revision === current)) }),
    snapshot: () => enqueue(editor.snapshot),
    select: (query, options) => enqueue(() => editor.select(query, options)),
    palette: () => enqueue(editor.palette),
    extractPalette(options = {}) {
      const saved = capture(options);
      return enqueue(() => editor.extractPalette(saved));
    },
    captureBrush: options => enqueue(() => editor.captureBrush(options)),
    copySelection: options => enqueue(() => editor.copySelection(options)),
    sample(at, options = {}) {
      const point = capture(at), settings = capture(options);
      return enqueue(() => codec.toJS(unwrap(sample(codec.fromJS(point), codec.fromJS(settings)))));
    },
    snap(at, options = {}) {
      const point = capture(at), settings = capture(options);
      return enqueue(() => codec.toJS(unwrap(snap(codec.fromJS(point), codec.fromJS(settings)))));
    },
    timeline: () => enqueue(() => codec.toJS(unwrap(timeline()))),
    slices({ frame } = {}) {
      return enqueue(() => codec.toJS(unwrap(slices(sliceFrame(frame)))));
    },
    slice(id, { frame } = {}) {
      return enqueue(() => {
        const { report, ...image } = unwrap(exportSlice(String(id), sliceFrame(frame)));
        return { ...codec.toJS(report), raster: rasterBytes(image) };
      });
    },
    tilemap(at) {
      const point = capture(at);
      return enqueue(() => codec.toJS(unwrap(inspectTilemap(codec.fromJS(point || null)))));
    },
    tilemapRaster({ time = 0 } = {}) {
      return enqueue(() => rasterBytes(unwrap(exportTilemap(typeof time === 'number' ? time : NaN))));
    },
    tilemapNeighborhood(at, { time = 0 } = {}) {
      const point = capture(at);
      return enqueue(() => {
        const { report, image } = unwrap(exportNeighbors(codec.fromJS(point ?? null), typeof time === 'number' ? time : NaN));
        return { ...codec.toJS(report), raster: rasterBytes(image) };
      });
    },
    begin: (label = '') => enqueue(() => unwrap(begin(label)), true),
    preview: () => enqueue(() => {
      if (!read().pending) throw new Error('No active transaction');
      return editor.snapshot();
    }),
    commit: () => enqueue(() => transition('commit'), true),
    cancel: () => enqueue(() => transition('cancel'), true),
    undo: () => enqueue(() => transition('undo'), true),
    redo: () => enqueue(() => transition('redo'), true),
    execute(raw) {
      const command = capture(raw);
      return enqueue(() => execute(command), true);
    },
    applyBatch(raw) {
      const plan = capture(raw);
      return enqueue(async () => structuredClone(await applyBatch(plan ?? {})), true);
    },
    recordBatch: () => enqueue(async () => structuredClone(await recordBatch())),
    replayBatch(raw) {
      const receipt = capture(raw);
      return enqueue(async () => structuredClone(await replayBatch(receipt)), true);
    },
    revalidateBatch(raw, options) {
      const receipt = capture(raw), settings = capture(options);
      return enqueue(() => revalidateBatch(receipt, settings));
    },
    previewPatch(raw) {
      const patch = capture(raw);
      return enqueue(() => attempt(patch, { dryRun: true }));
    },
    previewEdit(raw, options) {
      const patch = capture(raw);
      return enqueue(() => attempt(patch, { dryRun: true, preview: previewOptions(options) }));
    },
    previewChanges(options) {
      return enqueue(() => previewDraft(options));
    },
    apply(raw) {
      const patch = capture(raw);
      return enqueue(async () => (await attempt(patch)).document, true);
    },
    replay(raw) {
      const receipt = capture(raw);
      return enqueue(async () => (await attempt(replayReceipt(receipt).command.patch, { expected: receipt })).document, true);
    },
  });
}
