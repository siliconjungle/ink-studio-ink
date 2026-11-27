import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor } from '../web/pixel-document.mjs';
import { fixture } from './pixel-color-edits.mjs';

const command = (action, fields) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const design = {
  format: 'ink-studio/pixel-art', version: 2, width: 6, height: 5, pixelAspect: [1, 1],
  palette: { brick: '#a04829', copper: { color: '#AD7738', label: 'Copper', locked: true }, glass: '#47ae96' },
  layers: [{ id: 'ink' }, { id: 'wash', label: 'Wash', opacity: 0.5 }],
  frames: [{ id: 'front', label: 'Front pose', durationMs: 90, cels: { ink: { marks: [] } } }],
  protectedDetails: [{ id: 'quiet-corner', kind: 'gap', pixels: [[5, 4]] }],
};

export function commandCases(root) {
  const { createEditor } = createRequire(import.meta.url)(resolve(root, 'cli/pixel-art.js'));
  const cases = [];
  function scenario(label, document, schedule) {
    const original = createEditor(document);
    const steps = [], replies = [];
    function run(raw) {
      const envelope = JSON.parse(JSON.stringify(raw));
      steps.push({ op: 'execute', command: envelope });
      try {
        const value = original.execute(envelope);
        replies.push({ value: structuredClone(value) });
        return value;
      } catch (error) {
        replies.push({ error: error.message, ...(error.receipt && { receipt: structuredClone(error.receipt) }) });
      }
    }
    let serial = 0;
    const withPatch = (action, operation, scope = {}) => command(action, {
      patch: { id: 'op-' + ++serial, revision: original.describe().revision, frame: 'front', operation, ...scope },
    });
    schedule(run, withPatch);
    cases.push({ label, request: { document, steps }, replies });
  }

  scenario('local command workflow retains the original envelope, receipts and history', design, (run, edit) => {
    const start = run(command('validate'));
    assert.equal(start.identities.swatches[1].color, '#AD7738');
    assert.deepEqual(run(command('export')).data, design);
    assert.deepEqual(run(command('export', { artifact: null })).data, design);
    const query = { type: 'rectangle', rect: [1, 1, 2, 1] };
    assert.deepEqual(run(command('select', { query, options: { frame: 'front' } })).pixels, [[1, 1], [2, 1]]);
    run(command('begin', { label: '\u2003Paint and move a badge 🖋\u2003' }));
    const draft = edit('draw', { tool: 'pencil', layer: 'ink', swatch: 'brick', points: [[1, 1], [2, 1]] });
    assert.equal(run(command('preview', { edit: draft, options: { exact: true, limit: 1 } })).pixelCount, 2);
    assert.equal(run(command('validate')).revision, start.revision);
    const first = run(draft);
    assert.equal(first.command.patch.destination, 'raster');
    run(edit('mask', { id: 'badge', query }));
    const alias = run(edit('recolor', { layer: 'ink', selection: 'badge', from: 'brick', to: 'glass' }));
    assert.equal(alias.command.patch.operation.tool, 'replace-swatch');
    const moved = run(edit('transform', { layer: 'ink', selection: 'badge',
      transform: { offset: [2, 1] }, resultSelection: 'moved' }));
    assert.equal(moved.command.patch.operation.tool, 'transform');
    const next = run(command('preview', { options: { exact: true, limit: 1 } }));
    assert.deepEqual(next.targets.map(row => row.tool), ['pencil', 'rectangle', 'replace-swatch', 'transform']);
    assert.equal(next.pixelCount, 2);
    assert.equal(run(command('commit')).changed, true);
    const exported = run(command('export', { artifact: 'document' })).data;
    assert.deepEqual(exported.selections.find(row => row.id === 'moved').pixels, [[3, 2], [4, 2]]);
    run(command('export', { artifact: 'stamp', options: { layer: 'ink' } }));
    run(command('export', { artifact: 'layer-deck' }));
    run(command('select', { query: { type: 'recall', id: 'moved' } }));
    run(command('validate'));
    assert.equal(run(command('undo')).changed, true);
    run(command('export'));
    assert.equal(run(command('redo')).changed, true);
    run(command('export'));
    run(command('undo'));
    assert.deepEqual(run(command('replay', { receipt: first })), first);
    run(command('apply', { patch: edit('draw', { tool: 'pencil', layer: 'wash', points: [[1, 0]], swatch: 'glass' }).patch }));
    const identities = run(command('validate')).identities;
    assert.equal(identities.cels.at(-1).id, 'front/wash');
    run(command('export', { artifact: 'stamp' }));
    run(command('export', { artifact: 'layer-deck' }));
    run(command('export'));
  });

  scenario('envelope errors and rejected edits are distinguishable', design, (run, edit) => {
    const draft = edit('draw', { tool: 'pencil', layer: 'ink', swatch: 'brick', points: [[1, 1]] });
    const stale = { ...draft, patch: { ...draft.patch, revision: '0'.repeat(64) } };
    for (const malformed of [null, [], {}, { ...draft, version: '1' }, { ...draft, version: 2 },
      { ...draft, unknown: true }, command('validate', { options: {} }), command('draw'), command('replay'),
      command('select'), command('apply', { patch: null }), command('draw', { patch: [] }),
      command('preview', { edit: command('undo') }), command('preview', { edit: null }),
      command('begin', { label: '\ufeff\u00a0\n\u2028' }), command('begin', { label: null }),
      command('select', { query: { type: 'rectangle', rect: [0, 0, 1, 1] }, options: null }),
      command('select', { query: { type: 'rectangle', rect: [0, 0, 1, 1] }, options: { targetRevision: 'x' } }),
      command('preview', { options: { extra: false } }), command('export', { artifact: 'missing' }),
      command('export', { artifact: 'document', options: { layer: 'ink' } }),
      command('export', { artifact: 'scene' }), command('export', { artifact: 'scan-paint' }),
      { ...draft, patch: { ...draft.patch, destination: 'unknown' } },
      { ...draft, patch: { ...draft.patch, destination: null } },
      { ...draft, patch: { ...draft.patch, destination: 'selections' }, options: null },
      { ...draft, options: { extra: false } }, { ...draft, options: [] },
      { ...draft, patch: { ...draft.patch, operation: { tool: 'transform' } } },
      { ...draft, action: 'transform', patch: { ...draft.patch, operation: { tool: null } } },
      command('replay', { receipt: {} })]) run(malformed);
    run(command('cancel'));
    run(command('preview'));
    run(command('begin'));
    run(command('begin', { label: 'Nested' }));
    run(command('preview', { options: { exact: true } }));
    assert.equal(run(command('preview', { edit: stale })).conflicts[0].code, 'stale-document');
    run({ ...draft, options: { forbidden: true } });
    assert.equal(run(command('preview')).pixelCount, 0);
    run(draft);
    run(stale);
    run(command('preview'));
    run(command('undo'));
    run(command('validate'));
    run({ ...draft, options: { shotHitFrame: 1 } });
    run(command('replay', { receipt: {} }));
    run(command('export'));
  });

  scenario('explicit destination, frame holds, preview and replay use the same normalized patch', fixture({
    destinations: [{ id: 'custom-raster', kind: 'raster' }],
  }), (run, edit) => {
    const revision = run(command('validate')).revision;
    const graphic = edit('draw', { tool: 'pencil', layer: 'ink', points: [[3, 3]], swatch: 'brass' },
      { destination: 'custom-raster' });
    const preview = run(command('preview', { edit: graphic, options: { limit: 0, exact: true } }));
    assert.equal(preview.celLinks.sharedDrawings[0].holds[0].cel, 'held');
    assert.equal(preview.targets[0].destination, 'custom-raster');
    const applied = run(graphic);
    run(command('validate'));
    const local = edit('draw', { tool: 'rgba', pixels: [{ at: [3, 2], rgba: [30, 20, 70, 150] }] },
      { frame: 'back', cel: 'held' });
    run(command('preview', { edit: local, options: { exact: true } }));
    run(local);
    run(command('validate'));
    run(command('undo'));
    run(command('undo'));
    assert.equal(run(command('validate')).revision, revision);
    assert.deepEqual(run(command('replay', { receipt: applied })), applied);
    run(command('export'));
  });

  const art = fixture();
  art.layers.unshift({ id: 'ground' }, { id: 'reference', kind: 'reference', opacity: 0.5 });
  art.layers[2].opacity = 0.75;
  art.frames[0].label = 'Pose';
  art.frames[0].cels.ground = { id: 'front-ground', label: 'Paper', marks: [{ swatch: 'shadow', runs: [[0, 0, 9]] }] };
  art.frames[0].cels.reference = { marks: [{ swatch: 'brass', at: [9, 0] }] };
  art.frames.push({ id: 'off-grid', durationMs: 70, cels: { ink: { id: 'off-grid-cel', hold: 'source', offset: [-24, -2] } } });
  art.ramps = [{ id: 'metals', swatches: ['shadow', 'brass'] }];
  art.guides = [{ id: 'pin', kind: 'pivot', at: [1, 2] }, { id: 'local-pin', kind: 'pivot', at: [2, 2], frame: 'back' }];
  scenario('artifacts retain blends, references, offsets, masks, ramps and cel metadata', art, (run, edit) => {
    const composite = run(command('export', { artifact: 'stamp' })).data;
    assert.ok(composite.swatchIds.some(id => id.startsWith('blend-')));
    assert.equal(composite.slots[9], null);
    const references = run(command('export', { artifact: 'stamp', options: { references: true } })).data;
    assert.notEqual(references.slots[9], null);
    const indexed = run(command('export', { artifact: 'stamp', options: { layer: 'ink', cel: 'held' } })).data;
    assert.deepEqual(indexed.knockouts, [15]);
    assert.deepEqual(indexed.guides.map(guide => guide.id), ['pin', 'local-pin']);
    assert.ok(indexed.selections.some(row => row.id === 'rear'));
    const outside = run(command('export', { artifact: 'stamp', options: { layer: 'ink', cel: 'off-grid-cel' } })).data;
    assert.ok(outside.slots.every(slot => slot === null));
    assert.ok(outside.alpha.every(byte => byte === 255));
    const layerDeck = run(command('export', { artifact: 'layer-deck' })).data;
    assert.equal(layerDeck.frames[0].cels.ground.label, 'Paper');
    assert.equal(layerDeck.frames[1].cels.ink.id, 'held');
    assert.deepEqual(layerDeck.frames[1].cels.ink.knockouts, [15]);
    assert.deepEqual(layerDeck.ramps, art.ramps);
    for (const options of [{ frame: 'unknown' }, { frame: 'front', cel: 'held' },
      { layer: 'unknown' }, { layer: null }, { colorMode: 'indexed' }]) {
      run(command('export', { artifact: 'stamp', options }));
    }
    run(edit('draw', { tool: 'pencil', layer: 'ground', swatch: 'brass', points: [[2, 0]] }, { frame: 'back' }));
    run(command('export', { artifact: 'layer-deck' }));
  });
  const { seal } = createRequire(import.meta.url)(resolve(root, 'cli/pixel-edit-batch.js'));
  const reseal = batch => seal(batch.label, batch.inputs, batch.outputs, batch.steps, batch.revalidatedFrom);
  const wrongRevision = '0'.repeat(64);
  const pencil = (id, at, swatch = 'brick') => command('draw', { patch: {
    id, frame: 'front', operation: { tool: 'pencil', layer: 'ink', swatch, points: [at] },
  } });
  scenario('ordered batches roll back on rejection and support atomic history and receipt replay', design, run => {
    const revision = run(command('validate')).revision;
    const steps = [pencil('batch-mark', [2, 1]), command('mask', { patch: {
      id: 'batch-mask', frame: 'front', operation: { id: 'selected', query: { type: 'swatch', id: 'brick' } },
    } }), command('recolor', { patch: {
      id: 'batch-recolor', frame: 'front', operation: { layer: 'ink', selection: 'selected', from: 'brick', to: 'glass' },
    } }), command('transform', { patch: {
      id: 'batch-move', frame: 'front', operation: { layer: 'ink', selection: 'selected', transform: { offset: [1, 0] } },
    } })];
    const batch = commands => command('batch', { revision, label: 'Paint and move 🖋', commands });
    run(command('batch', { revision, commands: [] }));
    run(command('batch', { revision, commands: Array(257).fill(steps[0]) }));
    run(command('batch', { revision, label: '\u2003\n', commands: steps }));
    run(command('batch', { revision: wrongRevision, commands: steps }));
    run(batch([steps[0], command('undo')]));
    run(batch([steps[0], command('draw', { patch: null })]));
    run(batch([steps[0], { ...steps[1], options: { unknown: true } }]));
    run(batch([steps[0], { ...steps[1], patch: { ...steps[1].patch, revision: wrongRevision } }]));
    assert.deepEqual(run(command('export')).data, design);
    assert.equal(run(command('undo')).changed, false);

    const applied = run(batch(steps));
    assert.equal(applied.steps.length, 4);
    assert.equal(applied.steps[1].command.patch.revision, applied.steps[0].outputs.documentRevision);
    assert.equal(run(command('inspect', { at: [3, 1] })).swatch, 'glass');
    const edited = run(command('export')).data;
    assert.deepEqual(run(command('undo')).history, { undo: [], redo: [applied.label] });
    assert.deepEqual(run(command('export')).data, design);

    const badStep = structuredClone(applied);
    badStep.steps[2].outputs.artifactRevision = wrongRevision;
    run(command('replay-batch', { batch: badStep }));
    run(command('replay-batch', { batch: reseal(badStep) }));
    const badOutput = structuredClone(applied);
    badOutput.outputs.documentRevision = wrongRevision;
    run(command('replay-batch', { batch: reseal(badOutput) }));
    const badSource = structuredClone(applied);
    badSource.inputs.renderRevision = wrongRevision;
    badSource.inputs.scene = { ref: 'original-source', revision: wrongRevision };
    run(command('replay-batch', { batch: reseal(badSource) }));
    assert.deepEqual(run(command('export')).data, design);
    assert.deepEqual(run(command('redo')).history, { undo: [applied.label], redo: [] });
    assert.deepEqual(run(command('export')).data, edited);
    run(command('undo'));

    const reorder = (_key, value) => value && Object.getPrototypeOf(value) === Object.prototype
      ? Object.fromEntries(Object.entries(value).reverse()) : value;
    assert.deepEqual(run(command('replay-batch', { batch: JSON.parse(JSON.stringify(applied, reorder)) })), applied);
    assert.deepEqual(run(command('export')).data, edited);
    assert.deepEqual(run(command('undo')).history, { undo: [], redo: [applied.label] });
    assert.deepEqual(run(command('export')).data, design);
  });

  scenario('recording and revalidating batches leaves the open draft or committed document intact', design, run => {
    const revision = run(command('validate')).revision;
    run(command('record-batch'));
    run(command('begin', { label: 'My draft' }));
    run(command('record-batch'));
    run({ ...pencil('first', [2, 1]), patch: { ...pencil('first', [2, 1]).patch, revision } });
    const recorded = run(command('record-batch'));
    assert.equal(recorded.label, 'My draft');
    assert.equal(recorded.steps.length, 1);
    run(command('batch', { revision, commands: [pencil('second', [3, 1])] }));
    run(command('replay-batch', { batch: recorded }));
    run(command('revalidate-batch', { batch: recorded }));
    assert.equal(run(command('preview')).pixelCount, 1);
    assert.deepEqual(run(command('cancel')).history, { undo: [], redo: [] });

    const pick = command('mask', { patch: { id: 'sample', frame: 'front',
      operation: { id: 'sampled', query: { type: 'swatch', id: 'brick' } } } });
    const batch = run(command('batch', { revision, commands: [pencil('sample-mark', [2, 1]), pick] }));
    run(command('undo'));
    run({ ...pencil('new-brick', [1, 2]), patch: { ...pencil('new-brick', [1, 2]).patch, revision } });
    const before = run(command('export')).data;
    run(command('replay-batch', { batch }));
    const review = run(command('revalidate-batch', { batch, options: { exact: true, limit: 0 } }));
    assert.equal(review.valid, true);
    assert.equal(review.batch.revalidatedFrom, batch.revision);
    assert.equal(review.changes[0].after.targets[0].pixelCount, 2);
    assert.deepEqual(run(command('export')).data, before);
    run(command('replay-batch', { batch: review.batch }));
    assert.deepEqual(run(command('select', { query: { type: 'recall', id: 'sampled' } })).pixels, [[2, 1], [1, 2]]);
    assert.deepEqual(run(command('undo')).history, { undo: ['new-brick'], redo: [batch.label] });
    assert.deepEqual(run(command('export')).data, before);
  });

  scenario('local revalidation retains explicit pixel guards', design, run => {
    const revision = run(command('validate')).revision;
    const patch = { id: 'guarded', frame: 'front', edits: [{ at: [2, 1], layer: null, from: null, to: 'glass' }] };
    const result = run(command('batch', { revision, commands: [command('apply', { patch })] }));
    run(command('undo'));
    run({ ...pencil('fill-guard', [2, 1]), patch: { ...pencil('fill-guard', [2, 1]).patch, revision } });
    const before = run(command('export')).data;
    const review = run(command('revalidate-batch', { batch: result }));
    assert.equal(review.valid, false);
    assert.equal(review.failedStep, 0);
    assert.equal(review.conflicts[0].code, 'pixel-changed');
    assert.deepEqual(run(command('export')).data, before);
    assert.deepEqual(run(command('undo')).history, { undo: [], redo: ['fill-guard'] });
  });

  const schema = createRequire(import.meta.url)(resolve(root, 'docs/reference/pixel-command-schema.json'));
  const examples = schema['x-ink'];
  for (const action of ['batch', 'record-batch', 'replay-batch', 'revalidate-batch']) {
    for (const { command: example, setup, result } of examples.commands[action].examples) {
      scenario('published ' + action + ' example', examples.exampleDocument, run => {
        setup.forEach(run);
        assert.deepEqual(JSON.parse(JSON.stringify(run(example))), result);
      });
    }
  }

  scenario('the full 256-step batch keeps the legacy anchor through undo and replay', {
    format: 'ink-studio/pixel-art', version: 1, width: 3, height: 2, palette: { brick: design.palette.brick, glass: design.palette.glass },
    layers: [{ id: 'ink', marks: [] }],
  }, run => {
    const revision = run(command('validate')).revision;
    const commands = Array.from({ length: 256 }, (_, index) => {
      const { patch } = pencil('legacy-' + index, [1, 0], index % 2 ? 'glass' : 'brick');
      return command('draw', { patch: { ...patch, frame: 'artwork' } });
    });
    const applied = run(command('batch', { revision, commands }));
    assert.equal(applied.steps.length, 256);
    assert.ok(applied.inputs.legacyRevision);
    assert.equal(applied.outputs.legacyRevision, null);
    run(command('undo'));
    assert.deepEqual(run(command('replay-batch', { batch: applied })), applied);
    assert.deepEqual(run(command('undo')).history, { undo: [], redo: ['Pixel edit batch'] });
  });

  return cases;
}

export async function runCommands(editor, steps) {
  const replies = [];
  for (const step of steps) {
    try {
      replies.push({ value: await editor.execute(step.command) });
    } catch (error) {
      replies.push({ error: error.message, ...(error.receipt && { receipt: error.receipt }) });
    }
  }
  return replies;
}

export function verifyCommands(actual, expected, label) {
  assert.equal(actual.length, expected.length, label);
  for (const [i, reply] of actual.entries()) {
    assert.deepEqual(reply, expected[i], label + ' at command ' + i);
    if (reply.value?.artifact === 'document') {
      assert.equal(JSON.stringify(reply.value.data), JSON.stringify(expected[i].value.data), label + ' ordered document at command ' + i);
    }
    if (reply.value?.artifact === 'layer-deck') {
      assert.deepEqual(reply.value.data.frames.map(frame => Object.keys(frame.cels)),
        expected[i].value.data.frames.map(frame => Object.keys(frame.cels)), label + ' ordered cels at command ' + i);
    }
  }
}

async function main(root, native) {
  const cases = commandCases(root);
  const temp = mkdtempSync(join(tmpdir(), 'ink-studio-pixel-commands-'));
  try {
    for (const { label, request, replies } of cases) {
      verifyCommands(await runCommands(await createPixelCommandEditor(request.document), request.steps), replies, 'JavaScript ' + label);
      if (!native) continue;
      const file = join(temp, 'request.json');
      writeFileSync(file, JSON.stringify(request));
      const result = spawnSync(resolve(native), ['journal-document', file], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
      assert.equal(result.status, 0, result.stderr);
      verifyCommands(result.stdout.trim().split('\n').map(line => JSON.parse(line)), JSON.parse(JSON.stringify(replies)), 'Rust ' + label);
    }
    if (native) {
      const { request, replies } = cases[1];
      for (const index of [0, request.steps.findIndex((s, i) => s.command?.action === 'validate' && replies[i].value),
        request.steps.findIndex(s => s.command?.action === 'preview' && s.command.edit?.patch?.revision === '0'.repeat(64)),
        request.steps.findIndex(s => s.command?.options?.shotHitFrame === 1)]) {
        assert.notEqual(index, -1);
        const file = join(temp, 'command.json');
        writeFileSync(file, JSON.stringify({ document: request.document, command: request.steps[index].command }));
        const result = spawnSync(resolve(native), ['command-document', file], { encoding: 'utf8' });
        const expected = replies[index];
        const status = expected.receipt || expected.value?.valid === false ? 2 : expected.error ? 1 : 0;
        assert.equal(result.status, status, result.stderr || result.stdout);
        if (status === 1) assert.equal(result.stderr.trim(), expected.error);
        else assert.deepEqual(JSON.parse(result.stdout), expected.receipt ?? expected.value);
      }
    }
    console.log(JSON.stringify({ cases: cases.length, replies: cases.reduce((count, row) => count + row.replies.length, 0),
      pairedWithNative: Boolean(native) }));
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
