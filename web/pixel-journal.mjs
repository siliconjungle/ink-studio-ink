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

export async function openPixelJournal({ editor, state, codec, revision }, input, historyLimit) {
  const bind = name => state.bind(name, { resultOnly: true });
  const read = bind('pixel_journal'), begin = bind('begin_pixel_edit');
  const commit = bind('commit_pixel_edit'), cancel = bind('cancel_pixel_edit');
  const travel = bind('travel_pixel_history'), check = bind('resolve_pixel_edit');
  const observe = bind('observe_pixel_edit'), links = bind('pixel_edit_links');
  const accept = bind('accept_pixel_edit');
  const receipts = new Map();
  let nextReceipt = 0, previous = Promise.resolve();

  function unwrap(result) {
    if (Object.hasOwn(result, 'Err')) throw new Error(result.Err);
    return result.Ok;
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

  async function attempt(patch, { dryRun = false, expected } = {}) {
    const { cursor, pending, redo } = read();
    const shot = expected?.command.options.shotHitFrame;
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
      const target = gate.kind === 'selections' ? editor.saveSelection(patch.operation, { frame: gate.frame })
        : editor.paint(patch.operation, { frame: gate.frame, cel: gate.cel.Some });
      target.destination = gate.destination;
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
      const issue = error.conflict ?? { code: 'invalid-edit', message: error.message };
      const receipt = { ...common, status: 'rejected', affectedTargets: [],
        skippedHits: Object.hasOwn(issue, 'at') ? [issue] : [], conflicts: [issue], outputs: null };
      if (dryRun) return { document: editor.snapshot(), receipt };
      throw Object.assign(error, { receipt });
    }
  }

  const [current, legacy] = await Promise.all([revision(editor.snapshot()), input.version === 1 ? revision(input) : '']);
  unwrap(bind('start_pixel_journal')(current, legacy, historyLimit));

  return Object.freeze({
    revision: () => enqueue(() => read().cursor.revision),
    history: () => enqueue(() => { const { undo, redo } = read(); return { undo, redo }; }),
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
    commit: () => enqueue(() => {
      const discard = read().redo.length !== 0;
      const changed = unwrap(commit());
      if (discard && changed) trim();
      return changed;
    }),
    cancel: () => enqueue(() => {
      const changed = unwrap(cancel());
      if (changed) trim();
      return changed;
    }),
    undo: () => enqueue(() => unwrap(travel(false))),
    redo: () => enqueue(() => unwrap(travel(true))),
    previewPatch(raw) {
      const patch = capture(raw);
      return enqueue(() => attempt(patch, { dryRun: true }));
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
