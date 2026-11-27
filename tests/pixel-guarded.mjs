import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor } from '../web/pixel-document.mjs';
import { fixture } from './pixel-color-edits.mjs';
import { verifyCommands } from './pixel-commands.mjs';

const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const copy = value => JSON.parse(JSON.stringify(value));
const exact = { limit: 1, exact: true };
const plain = {
  format: 'ink-studio/pixel-art', version: 2, width: 8, height: 6, pixelAspect: [1, 1],
  palette: { brass: '#cb4519', alias: '#cb4519', soot: '#212131' },
  layers: [{ id: 'paper' }, { id: 'ink', opacity: 0.75 }, { id: 'fixed', protect: true }],
  frames: [{ id: 'front', durationMs: 100, cels: {
    paper: { id: 'front-paper', marks: [{ swatch: 'soot', runs: [[0, 0, 5], [1, 0, 5]] }] },
    ink: { id: 'front-ink', marks: [{ swatch: 'brass', runs: [[0, 0, 3], [1, 1, 1]] }] },
    fixed: { id: 'front-fixed', marks: [{ swatch: 'brass', at: [3, 0] }] },
  } }],
};

export function guardedCases(root) {
  const { createEditor, validate } = createRequire(import.meta.url)(resolve(root, 'cli/pixel-art.js'));
  const cases = [];
  function scenario(label, document, schedule) {
    const original = createEditor(document);
    const steps = [], replies = [];
    function step(op, data = {}) {
      const req = copy({ op, ...data });
      steps.push(req);
      try {
        let value;
        if (op === 'execute') value = original.execute(req.command);
        else if (op === 'preview-patch') {
          const candidate = createEditor(original.snapshot());
          try {
            const document = candidate.apply(req.patch);
            value = { document, receipt: candidate.receipts().at(-1) };
          } catch (issue) {
            if (!issue.receipt) throw issue;
            value = { document: original.snapshot(), receipt: issue.receipt };
          }
        } else if (op === 'revision') value = original.describe().revision;
        else value = original[op]();
        replies.push({ value: copy(value ?? null) });
        return value;
      } catch (error) {
        replies.push({ error: error.message, ...(error.receipt && { receipt: copy(error.receipt) }) });
        return error.receipt;
      }
    }
    const run = (action, fields) => step('execute', { command: command(action, fields) });
    const guard = (at, to, options) => {
      const { layer, swatch: from } = original.inspect(at, options);
      return { at, layer, from, to };
    };
    let serial = 0;
    const patch = (edits, fields = {}) => ({ id: 'edit-' + ++serial, revision: original.describe().revision,
      frame: original.snapshot().frames[0].id, edits, ...fields });
    schedule({ original, run, guard, patch, step, validate });
    cases.push({ label, request: { document, steps }, replies });
  }

  scenario('new overlay preserves authored point marks, render diffs and ordered receipt coordinates', plain,
    ({ run, guard, patch, step }) => {
      const overlay = patch([guard([4, 1], 'brass'), guard([1, 0], null), guard([7, 4], 'alias')], { id: 'repair' });
      const envelope = command('draw', { patch: overlay });
      run('begin', { label: 'Apply a guarded correction' });
      const prospect = run('preview', { edit: envelope, options: exact });
      assert.equal(prospect.pixelCount, 3);
      assert.deepEqual(prospect.targets, []);
      assert.equal(prospect.diff.cells.length, 6);
      const shaded = prospect.pixels[0];
      assert.equal(shaded.after.layer, 'repair');
      assert.equal(shaded.after.swatch, null);
      assert.equal(shaded.after.underneath.layer, 'ink');
      for (const options of [{ limit: 0 }, { limit: 1 }, undefined]) {
        const preview = run('preview', { edit: envelope, options });
        assert.equal(preview.pixelCount, 3);
        assert.equal(preview.pixels.length, Math.min(3, options?.limit ?? 3));
      }
      const staged = step('preview-patch', { patch: overlay });
      assert.equal(staged.receipt.status, 'applied');
      assert.deepEqual(staged.document.frames[0].cels.repair.marks.map(mark => mark.at), overlay.edits.map(edit => edit.at));
      step('snapshot');
      step('receipts');
      const first = step('execute', { command: envelope });
      assert.deepEqual(first.affectedTargets[0].pixels, [[4, 1], [1, 0], [7, 4]]);
      const inspected = run('inspect', { at: [1, 0] });
      assert.equal(inspected.layer, 'repair');
      assert.equal(inspected.cel, 'front/repair');
      assert.equal(inspected.swatch, null);
      run('draw', { patch: patch(undefined, { operation: { tool: 'pencil', layer: 'repair', points: [[2, 2]], swatch: 'soot' } }) });
      const second = patch([guard([4, 1], 'alias'), guard([6, 2], 'brass')], { cel: 'front/repair' });
      run('apply', { patch: second });
      const aggregate = run('preview', { options: { limit: 0, exact: true } });
      assert.deepEqual(aggregate.targets.map(target => target.tool), ['pencil']);
      const snapshot = step('snapshot');
      assert.deepEqual(snapshot.frames[0].cels.repair.marks.map(mark => Object.keys(mark).at(-1)), ['at', 'at', 'at', 'runs', 'at', 'at']);
      run('validate');
      run('commit');
      step('receipts');
      run('undo');
      step('snapshot');
      run('redo');
      step('snapshot');
      run('undo');
      assert.deepEqual(run('replay', { receipt: first }), first);
      run('export');
    });

  scenario('guard collisions return every conflict in the original order and preserve the staged baseline', plain,
    ({ run, guard, patch, step }) => {
      run('begin', { label: 'Draft' });
      const proposal = patch([
        { at: [20, 0], layer: null, from: null, to: null },
        guard([3, 0], 'soot'),
        null,
        { ...guard([0, 0], 'alias'), from: 'alias' },
        guard([0, 0], null),
        guard([4, 1], 'brass'),
        { ...guard([2, 0], null), to: '#cb4519' },
        { ...guard([1, 0], 'alias'), to: '' },
        { ...guard([7, 5], 'brass'), layer: [] },
        { at: [1001, 0], layer: null, from: null, to: 'brass' },
        { at: [7, 5], layer: null, to: null },
      ], { cel: 'front-ink' });
      const expected = ['invalid-pixel', 'protected-pixel', 'invalid-pixel', 'pixel-changed',
        'duplicate-pixel', 'wrong-cel', 'invalid-pixel', 'invalid-pixel', 'pixel-changed', 'invalid-pixel', 'invalid-pixel'];
      const dryRun = run('preview', { edit: command('apply', { patch: proposal }), options: exact });
      assert.deepEqual(dryRun.conflicts.map(issue => issue.code), expected);
      assert.equal(dryRun.conflicts[3].actual.underneath.layer, 'paper');
      assert.equal(dryRun.conflicts[3].actual.alpha, 255);
      assert.equal(dryRun.diff.skippedHits.length, 10);
      const staged = step('preview-patch', { patch: proposal });
      assert.deepEqual(staged.receipt.conflicts, dryRun.conflicts);
      assert.equal(run('preview').pixelCount, 0);
      const rejected = run('apply', { patch: proposal });
      assert.deepEqual(rejected.conflicts, dryRun.conflicts);
      run('preview');
      step('history');
      step('snapshot');
      step('receipts');
      run('apply', { patch: patch([guard([7, 5], 'brass')], { id: 'ink' }) });
      for (const edits of [null, {}, [], undefined, Array(4097).fill(null)]) {
        run('apply', { patch: patch(edits) });
      }
      for (const tool of ['pencil', 'replace-swatch', 'paste', 'rgba', 'cleanup']) {
        run('apply', { patch: patch([guard([7, 5], 'brass')], { operation: { tool } }) });
      }
      run('apply', { patch: patch([guard([7, 5], 'brass')], { revision: '0'.repeat(64) }) });
      step('snapshot');
    });

  scenario('explicit cel edits follow holds, detach, shift correctly and preserve authored slots', fixture(),
    ({ run, guard, patch, step }) => {
      const linked = patch([guard([0, 0], 'shadow', { frame: 'front' })], { cel: 'source', frame: undefined });
      const propagated = run('preview', { edit: command('apply', { patch: linked }), options: exact });
      assert.equal(propagated.celLinks.sharedDrawings[0].holds[0].cel, 'held');
      run('apply', { patch: linked });
      const detached = patch([guard([3, 1], 'accent', { frame: 'back' })], { cel: 'held', frame: 'back' });
      const probe = run('preview', { edit: command('draw', { patch: detached }), options: exact });
      assert.equal(probe.celLinks.unlinked[0].instance.cel, 'held');
      const receipt = run('apply', { patch: detached });
      const held = step('snapshot').frames[1].cels.ink;
      assert.equal(held.hold, undefined);
      assert.deepEqual(held.marks.at(-1).at, [2, 0]);
      run('undo');
      run('replay', { receipt });
      run('export', { artifact: 'stamp', options: { layer: 'ink', cel: 'held' } });
      const outside = patch([guard([0, 0], 'brass', { frame: 'back' }), guard([3, 1], 'shadow', { frame: 'back' })],
        { cel: 'held', frame: 'back' });
      const rejected = run('apply', { patch: outside });
      assert.equal(rejected.conflicts[0].code, 'outside-cel');
      assert.deepEqual(rejected.conflicts[0].at, [0, 0]);
      step('snapshot');
    });

  const protectedHold = fixture({
    protectedDetails: [{ id: 'dependent', kind: 'accent', frame: 'back', pixels: [[1, 1]] }],
  });
  scenario('protected dependent cels fail atomically', protectedHold, ({ run, patch, guard, step }) => {
    const raw = patch([guard([0, 0], null, { frame: 'front' })], { cel: 'source' });
    const preview = run('preview', { edit: command('apply', { patch: raw }), options: exact });
    assert.equal(preview.conflicts[0].code, 'protected-pixel');
    assert.equal(preview.conflicts[0].detail, 'dependent');
    run('apply', { patch: raw });
    step('snapshot');
    step('receipts');
  });

  const clip = copy(plain);
  clip.layers = [{ id: 'matte', kind: 'mask' }, { id: 'ink', clip: 'matte' }];
  clip.frames[0].cels = {
    matte: { marks: [{ swatch: 'soot', at: [0, 0] }] },
    ink: { id: 'clipped', marks: [{ swatch: 'brass', at: [0, 0] }] },
  };
  scenario('post-raster clipping reports all rejected coordinates', clip, ({ run, patch, guard, step }) => {
    const blocked = patch([guard([3, 1], 'brass'), guard([0, 3], null)], { cel: 'clipped' });
    const receipt = run('apply', { patch: blocked });
    assert.deepEqual(receipt.conflicts.map(issue => issue.at), [[3, 1], [0, 3]]);
    assert.ok(receipt.conflicts.every(issue => issue.code === 'clipped-pixel'));
    run('preview', { edit: command('apply', { patch: blocked }), options: exact });
    step('snapshot');
    step('receipts');
  });

  const collision = copy(plain);
  collision.frames[0].cels.ink.id = 'front/overlay';
  scenario('new layer avoids an occupied fallback cel ID', collision, ({ run, guard, patch, step }) => {
    const paint = patch([guard([0, 1], 'brass')], { id: 'overlay' });
    assert.equal(run('apply', { patch: paint }).affectedTargets[0].cel, 'front/overlay-2');
    assert.equal(step('snapshot').frames[0].cels.overlay.id, 'front/overlay-2');
  });

  const dense = { ...copy(plain), width: 64, height: 64, layers: [{ id: 'paper' }],
    frames: [{ id: 'front', durationMs: 100, cels: {} }] };
  scenario('guarded previews accept the full point budget and keep row order', dense, ({ run, patch }) => {
    const edits = Array.from({ length: 4096 }, (_, i) => ({
      at: [63 - i % 64, 63 - Math.floor(i / 64)], from: null, layer: null, to: i % 2 === 0 ? 'brass' : null,
    }));
    const edit = command('draw', { patch: patch(edits) });
    const preview = run('preview', { edit, options: { limit: 3 } });
    assert.equal(preview.pixelCount, 4096);
    assert.deepEqual(preview.pixels.map(pixel => pixel.at), [[0, 0], [1, 0], [2, 0]]);
    assert.equal(run('apply', { patch: edit.patch }).affectedTargets[0].pixels.length, 4096);
    assert.equal(run('inspect', { at: [0, 0] }).layer, edit.patch.id);
  });

  const legacy = { format: 'ink-studio/pixel-art', version: 1, width: 5, height: 5,
    palette: { brass: '#cb4519' }, layers: [{ id: 'ink', marks: [{ swatch: 'brass', at: [1, 0] }] }] };
  scenario('legacy revision aliases survive rollback and history travel', legacy, ({ run, guard, patch, step, validate }) => {
    const paint = patch([guard([1, 0], null)], { frame: undefined, revision: validate(legacy).revision });
    run('preview', { edit: command('draw', { patch: paint }), options: exact });
    run('apply', { patch: paint });
    step('snapshot');
    run('undo');
    run('apply', { patch: paint });
    step('snapshot');
  });

  const layered = copy(plain);
  layered.layers = [
    { id: 'paper' }, { id: 'stack', kind: 'group', blend: 'multiply', opacity: 0.66 },
    { id: 'matte', kind: 'mask', parent: 'stack' }, { id: 'ink', parent: 'stack', clip: 'matte', opacity: 0.75 },
    { id: 'detail', kind: 'group', parent: 'stack', locked: true, opacity: 0.35 },
    { id: 'edge', parent: 'detail', offset: [1, -1], label: 'Shifted Edge' },
    { id: 'invisible', kind: 'group', visible: false }, { id: 'hidden-child', parent: 'invisible' },
    { id: 'zero', opacity: 0 }, { id: 'reference', kind: 'reference' },
    { id: 'fixed', protect: true }, { id: 'overlay' },
  ];
  layered.frames[0].cels = {
    paper: { marks: [{ swatch: 'soot', runs: [[0, 0, 7], [1, 0, 7], [2, 0, 7]] }] },
    matte: { marks: [{ swatch: 'brass', runs: [[0, 0, 4], [1, 0, 4]] }, { alpha: 111, runs: [[0, 1, 1]] }] },
    ink: { id: 'front-root', opacity: 173, marks: [{ swatch: 'brass', runs: [[0, 0, 5], [1, 1, 4]] },
      { swatch: null, at: [2, 0] }] },
    edge: { marks: [{ swatch: 'alias', runs: [[1, 0, 4], [2, 0, 4]] }] },
    'hidden-child': { marks: [{ swatch: 'soot', at: [3, 1] }] },
    zero: { marks: [{ swatch: 'soot', at: [5, 2] }] },
    reference: { marks: [{ swatch: 'alias', at: [7, 5] }, { swatch: 'alias', at: [3, 0] }] },
    fixed: { marks: [{ swatch: 'brass', at: [3, 0] }] },
    overlay: { marks: [{ swatch: 'brass', at: [3, 0] }] },
  };
  layered.frames.push({ id: 'echo', durationMs: 75, cels: { ink: { id: 'echo-hold', hold: 'front-root', offset: [1, 1] } } });
  layered.protectedDetails = [{ id: 'negative', kind: 'gap', frame: 'front', pixels: [[7, 5]] },
    { id: 'accent', kind: 'accent', frames: ['front', 'echo'], pixels: [[1, 2]] }];
  layered.sceneBindings = [{ id: 'binding', scene: 'scenery', object: 'plate', frame: 'front' }];
  scenario('local inspection traces nested compositing, clips, locks and contributor order', layered, ({ run }) => {
    const scope = { frame: 'front' };
    const where = at => run('inspect', { at, options: scope });
    const mask = where([1, 0]);
    assert.equal(mask.layers[1].children[0].status, 'mask');
    assert.equal(mask.layers[1].children[1].clip.alpha, 111);
    assert.equal(mask.layers[1].children[1].opacity, 0.75 * (173 / 255));
    const protect = where([3, 0]);
    assert.equal(protect.layers.at(-1).status, 'protected');
    assert.equal(protect.layer, 'fixed');
    const knockout = where([2, 0]);
    assert.equal(knockout.layers[1].children[1].status, 'knockout');
    const reference = run('inspect', { at: [7, 5], options: { references: true } });
    assert.equal(reference.layer, 'reference');
    assert.equal(reference.protected, true);
    for (let y = 0; y < layered.height; y++) for (let x = 0; x < layered.width; x++) where([x, y]);
    run('inspect', { at: [2, 1], options: { cel: 'echo-hold' } });
    run('inspect', { at: [4, 4], options: { destinations: [] } });
    for (const [at, options] of [
      [[-1, 0], {}], [[1.5, 0], {}], [[1], {}], [null, {}], [[0, 0], { frame: 'missing' }],
      [[0, 0], { cel: 'echo-hold', frame: 'front' }], [[0, 0], { binding: 'missing' }],
      [[0, 0], { binding: 'binding' }], [[0, 0], { destinations: ['raster', 'raster'] }],
      [[0, 0], { destinations: ['missing'] }], [[0, 0], { destinations: ['raster'] }],
    ]) run('inspect', { at, options });
  });

  const cropped = copy(layered);
  cropped.layers.find(layer => layer.id === 'fixed').protect = false;
  cropped.layers.find(layer => layer.id === 'zero').offset = [-50, 80];
  cropped.protectedDetails = cropped.protectedDetails.filter(detail => detail.kind !== 'gap');
  scenario('single-pixel compositing preserves shifted sources and clips without frame-wide guards', cropped, ({ run }) => {
    for (const references of [false, true]) {
      for (const at of [[0, 0], [1, 0], [2, 0], [3, 0], [0, 1], [7, 5]]) {
        run('inspect', { at, options: { references } });
      }
    }
    run('inspect', { at: [2, 1], options: { cel: 'echo-hold' } });
  });

  const deep = copy(legacy);
  deep.version = 2;
  deep.pixelAspect = [1, 1];
  const group = n => 'group-' + n;
  deep.layers = Array.from({ length: 63 }, (_, i) => ({ id: group(i), kind: 'group',
    ...(i && { parent: group(i - 1) }) }));
  deep.layers.push({ id: 'ink', parent: group(62) });
  deep.frames = [{ id: 'front', durationMs: 15, cels: { ink: { marks: [{ swatch: 'brass', at: [1, 0] }] } } }];
  scenario('inspection and overlays respect the documented stack limit', deep, ({ run, patch, guard, step }) => {
    const inspected = run('inspect', { at: [1, 0] });
    assert.equal(inspected.layer, 'ink');
    let row = inspected.layers[0], depth = 1;
    while (row.children?.length) { row = row.children[0]; depth++; }
    assert.equal(depth, 64);
    const edit = patch([guard([0, 0], 'brass')], { id: 'overflow' });
    const rejected = run('draw', { patch: edit });
    assert.equal(rejected.conflicts[0].message, 'Pixel art needs a native grid, a palette and up to 64 bounded layers');
    step('snapshot');
  });
  return cases;
}

export async function runGuarded(editor, steps) {
  const replies = [];
  for (const step of steps) {
    try {
      const value = step.op === 'execute' ? await editor.execute(step.command)
        : step.op === 'preview-patch' ? await editor.previewPatch(step.patch) : await editor[step.op]();
      replies.push({ value: value ?? null });
    } catch (error) {
      replies.push({ error: error.message, ...(error.receipt && { receipt: error.receipt }) });
    }
  }
  return replies;
}

export function verifyGuarded(actual, expected, name) {
  verifyCommands(actual, expected, name);
  for (const [i, reply] of actual.entries()) {
    const doc = reply.value?.document ?? reply.value;
    if (doc?.format === 'ink-studio/pixel-art')
      assert.equal(JSON.stringify(doc), JSON.stringify(expected[i].value.document ?? expected[i].value), name + ' authored order ' + i);
  }
}

async function main(root, native) {
  const cases = guardedCases(root);
  const temp = mkdtempSync(join(tmpdir(), 'ink-guarded-pixels-'));
  try {
    for (const { label, request, replies } of cases) {
      verifyGuarded(await runGuarded(await createPixelCommandEditor(request.document), request.steps), replies, 'JavaScript ' + label);
      if (!native) continue;
      const file = join(temp, 'request.json');
      writeFileSync(file, JSON.stringify(request));
      const result = spawnSync(resolve(native), ['journal-document', file], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
      assert.equal(result.status, 0, result.stderr);
      verifyGuarded(result.stdout.trim().split('\n').map(line => JSON.parse(line)), replies, 'Rust ' + label);
    }
    console.log(JSON.stringify({ cases: cases.length, replies: cases.reduce((n, row) => n + row.replies.length, 0),
      pairedWithNative: Boolean(native) }));
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
