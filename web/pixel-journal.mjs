import { pixelPng, pngBase64 } from './pixel-png.mjs';

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
  const report = { format: 'ink-studio/pixel-edit-preview', version: 1, valid: conflicts.length === 0,
    ...(links && { celLinks: links }), pixelCount: changes?.pixelCount ?? 0,
    pixels: cellChanges(changes?.pixels), sources: [], targets, conflicts };
  if (exact) {
    const cells = cellChanges(changes?.exact.cells, true);
    const protectedCells = changes?.exact.protectedCells ?? [];
    const details = changes?.exact.details.map(row => codec.toJS(row)) ?? [];
    const hits = conflicts.filter(issue => Object.hasOwn(issue, 'at'));
    report.diff = { cells, grids: [], materials: [], geometry: [], other: [], rendered: [], renderErrors: [],
      skippedHits: hits, protection: { wouldChange: protectedCells.length !== 0 || details.length !== 0,
        details, geometry: [], cells: protectedCells, renderedCells: [],
        blocked: hits.filter(issue => issue.code.startsWith('protected-')) } };
  }
  return report;
}

export async function openPixelJournal({ editor, state, codec, revision }, input, historyLimit) {
  const bind = name => state.bind(name, { resultOnly: true });
  const read = bind('pixel_journal'), begin = bind('begin_pixel_edit');
  const commit = bind('commit_pixel_edit'), cancel = bind('cancel_pixel_edit');
  const travel = bind('travel_pixel_history'), check = bind('resolve_pixel_edit');
  const guarded = bind('replace_guarded_pixels');
  const plan = bind('plan_pixel_command'), describe = bind('describe_pixel_command_document');
  const inspect = bind('inspect_pixel_command');
  const stamp = bind('export_pixel_command_stamp'), deck = bind('export_pixel_command_layer_deck');
  const png = bind('export_pixel_command_png');
  const observe = bind('observe_pixel_edit'), links = bind('pixel_edit_links');
  const observePreview = bind('observe_pixel_preview'), editDiff = bind('pixel_preview_diff');
  const draftDiff = bind('pixel_draft_diff');
  const accept = bind('accept_pixel_edit');
  const receipts = new Map();
  let nextReceipt = 0, previous = Promise.resolve();

  function unwrap(result) {
    if (Object.hasOwn(result, 'Err')) throw new Error(result.Err);
    return result.Ok;
  }

  function encodePng(options) {
    const image = unwrap(png(codec.fromJS(options)));
    return pixelPng(image, codec.toJS(image.metadata));
  }

  function enqueue(run) {
    const result = previous.then(run);
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

  function allReceipts() {
    const rows = [];
    for (let id = read().cursor.receipt; id;) {
      const row = receipts.get(id);
      rows.push(structuredClone(row.receipt));
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
      if (gate.frame) command.frame = gate.frame;
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
        : gate.kind === 'selections' ? editor.saveSelection(patch.operation, { frame: gate.frame })
        : editor.paint(patch.operation, { frame: gate.frame, cel: gate.cel.Some });
      target.destination = gate.destination;
      if (preview) {
        const changes = gate.kind === 'selections' ? undefined : unwrap(editDiff(preview.limit, preview.exact));
        const report = previewReport(codec, changes, gate.direct ? [] : [target], [], links().Some, preview.exact);
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
        nextReceipt = id;
        receipts.set(id, { parent: cursor.receipt, receipt });
        if (!pending && redo.length) trim();
      }
      started = false;
      return { document, receipt };
    } catch (error) {
      if (started) state.rollbackTransaction();
      if (pending && !dryRun) {
        unwrap(cancel());
        trim();
      }
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
    if (action === 'undo' || action === 'redo') return unwrap(travel(action === 'redo'));
    const discard = action === 'cancel' || read().redo.length !== 0;
    const changed = unwrap(action === 'cancel' ? cancel() : commit());
    if (discard && changed) trim();
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
      if (target.kind !== 'raster' || target.tool) targets.push(target);
      id = row.parent;
    }
    return previewReport(codec, result.changes, structuredClone(targets.reverse()), [], result.celLinks.Some, exact);
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

  const [current, legacy] = await Promise.all([revision(editor.snapshot()), input.version === 1 ? revision(input) : '']);
  unwrap(bind('start_pixel_journal')(current, legacy, historyLimit));

  return Object.freeze({
    png(options = {}) {
      const saved = capture(options);
      return enqueue(() => encodePng(saved));
    },
    revision: () => enqueue(() => read().cursor.revision),
    history: () => enqueue(history),
    receipts: () => enqueue(allReceipts),
    snapshot: () => enqueue(editor.snapshot),
    select: (query, options) => enqueue(() => editor.select(query, options)),
    captureBrush: options => enqueue(() => editor.captureBrush(options)),
    copySelection: options => enqueue(() => editor.copySelection(options)),
    begin: (label = '') => enqueue(() => unwrap(begin(label))),
    preview: () => enqueue(() => {
      if (!read().pending) throw new Error('No active transaction');
      return editor.snapshot();
    }),
    commit: () => enqueue(() => transition('commit')),
    cancel: () => enqueue(() => transition('cancel')),
    undo: () => enqueue(() => transition('undo')),
    redo: () => enqueue(() => transition('redo')),
    execute(raw) {
      const command = capture(raw);
      return enqueue(() => execute(command));
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
      return enqueue(async () => (await attempt(patch)).document);
    },
    replay(raw) {
      const receipt = capture(raw);
      return enqueue(async () => (await attempt(replayReceipt(receipt).command.patch, { expected: receipt })).document);
    },
  });
}
