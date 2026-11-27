import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor, openPixelCommandSession } from '../web/pixel-document.mjs';
import { runCommands, verifyCommands } from './pixel-commands.mjs';

const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const design = {
  format: 'ink-studio/pixel-art', version: 2, width: 8, height: 6, pixelAspect: [1, 2],
  palette: { rust: '#cc381a', blue: '#204968' },
  layers: [{ id: 'base' }, { id: 'ink', clip: 'base' }],
  frames: [
    { id: 'front', durationMs: 120, cels: {
      base: { marks: [{ swatch: 'blue', shape: { type: 'rect', rect: [2, 1, 3, 2] } }] },
      ink: { id: 'glaze', marks: [{ swatch: 'rust', at: [2, 1] }, { alpha: 128, runs: [[1, 2, 1]] },
        { swatch: null, at: [3, 1] }, { swatch: 'rust', at: [5, 1] }] },
    } },
    { id: 'rear', durationMs: 240, cels: { base: { marks: [{ swatch: 'blue', at: [7, 5] }] } } },
  ],
  guides: [{ id: 'pivot', kind: 'pivot', at: [2.5, 1], frame: 'front' },
    { id: 'grid', kind: 'grid', at: [0, 0], step: [4, 2] }],
  selections: [{ id: 'line', frame: 'front', pixels: [[0, 0], [2, 1], [3, 1]] }],
  protectedDetails: [{ id: 'hold', pixels: [[7, 0], [2, 1]] }],
};
const crop = { type: 'crop', rect: [2, 1, 4, 3] };
const pad = { type: 'pad', margins: [1, 1, 0, 0] };

export function canvasCases(original) {
  const { createEditor } = createRequire(import.meta.url)(resolve(original, 'cli/pixel-art.js'));
  const cases = [];
  function scenario(label, document, schedule) {
    const editor = createEditor(document);
    const steps = [], replies = [];
    function run(raw) {
      const envelope = JSON.parse(JSON.stringify(raw));
      steps.push({ op: 'execute', command: envelope });
      try {
        const value = editor.execute(envelope);
        replies.push({ value: JSON.parse(JSON.stringify(value)) });
        return value;
      } catch (error) {
        replies.push({ error: error.message, ...(error.receipt && { receipt: structuredClone(error.receipt) }) });
      }
    }
    let serial = 0;
    const patch = (operation, extra = {}) => ({ id: 'canvas-' + ++serial, destination: 'canvas',
      revision: editor.describe().revision, operation, ...extra });
    const edit = (operation, extra) => run(command('apply', { patch: patch(operation, extra) }));
    const preview = (operation, options = { exact: true }, extra) =>
      run(command('preview', { edit: command('apply', { patch: patch(operation, extra) }), options }));
    schedule(run, edit, preview, patch);
    cases.push({ label, request: { document, steps }, replies });
  }

  scenario('crop and pad preview, paint, replay and history', design, (run, edit, preview, patch) => {
    assert.equal(preview(crop, {}).pixels.find(row => row.frame === 'rear' && row.at[0] === 7).after, null);
    assert.equal(preview(crop).diff.grids.length, 2);
    preview(pad, { exact: true, limit: 0 });
    assert.deepEqual(run(command('export')).data, design);
    const first = edit(crop);
    assert.equal(first.command.frame, null);
    assert.deepEqual(first.affectedTargets[0].droppedProtected, [{ id: 'hold', pixels: 1 }]);
    const cropped = run(command('export')).data;
    assert.deepEqual(cropped.guides.map(guide => guide.at), [[0.5, 0], [-2, -1]]);
    assert.deepEqual(cropped.selections[0].pixels, [[0, 0], [1, 0]]);
    run(command('export', { artifact: 'stamp', options: { frame: 'front', layer: 'ink' } }));
    run(command('undo'));
    assert.deepEqual(run(command('export')).data, design);
    run(command('redo'));
    assert.deepEqual(run(command('export')).data, cropped);
    run(command('undo'));
    assert.deepEqual(run(command('replay', { receipt: first })), first);
    run(command('begin', { label: 'Pad and paint' }));
    edit(pad);
    const pencil = patch({ tool: 'pencil', layer: 'base', swatch: 'rust', points: [[4, 3]] },
      { destination: 'raster', frame: 'front' });
    assert.equal(run(command('draw', { patch: pencil })).status, 'applied');
    run(command('preview', { options: { exact: true, limit: 4 } }));
    run(command('cancel'));
    assert.deepEqual(run(command('export')).data, cropped);
    run(command('draw', { patch: { ...pencil, revision: first.outputs.documentRevision } }));
    run(command('export'));
  });

  const trim = structuredClone(design);
  trim.protectedDetails[0].pixels = [[1, 4]];
  scenario('trim spans all frames and protected blank pixels', trim, (run, edit, preview) => {
    preview({ type: 'trim' });
    assert.ok(edit({ type: 'trim' }));
    const saved = run(command('export')).data;
    assert.deepEqual([saved.width, saved.height], [7, 5]);
    assert.deepEqual(saved.protectedDetails[0].pixels, [[0, 3]]);
  });

  const indexed = { ...design, width: 2, height: 2, layers: [{ id: 'base' }],
    frames: [{ id: 'front', durationMs: 120, cels: { base: { slots: ['rust', null, 'blue', null],
      marks: [{ alpha: 128, runs: [[1, 0, 1]] }, { swatch: null, at: [1, 1] }] } } }],
    guides: [], selections: [], protectedDetails: [] };
  scenario('nearest sampling, weighted alpha and anchored resize', indexed, (run, edit, preview, patch) => {
    const area = { type: 'resample', size: [1, 1], filter: 'area' };
    preview(area);
    assert.ok(edit(area));
    const faded = run(command('export')).data.frames[0].cels.base;
    assert.deepEqual(faded.slots, ['rust']);
    assert.deepEqual(faded.marks, [{ alpha: 96, runs: [[0, 0, 1]] }]);
    run(command('undo'));
    const nearest = { ...area, filter: 'nearest' };
    const { destination, ...inferred } = patch(nearest);
    assert.ok(run(command('transform', { patch: inferred })));
    assert.deepEqual(run(command('export')).data.frames[0].cels.base.marks, [{ swatch: null, runs: [[0, 0, 1]] }]);
    run(command('undo'));
    assert.ok(edit({ type: 'resize', size: [3, 3], anchor: 'bottom-right' }));
    run(command('export'));
  });

  const pinned = { ...indexed, protectedDetails: [{ id: 'preserve-rust', kind: 'accent', pixels: [[0, 0]] }] };
  scenario('hard protection chooses the original source during area resampling', pinned, (run, edit, preview) => {
    const narrow = { type: 'crop', rect: [1, 0, 1, 2] };
    assert.match(preview(narrow).conflicts[0].message, /discard protected detail/);
    edit(narrow);
    const area = { type: 'resample', size: [1, 1], filter: 'area' };
    assert.ok(edit(area));
    assert.deepEqual(run(command('export')).data.frames[0].cels.base.slots, ['rust']);
  });
  const competing = { ...pinned, protectedDetails: [
    ...pinned.protectedDetails, { id: 'preserve-blue', kind: 'pixel', pixels: [[0, 1]] },
  ] };
  scenario('hard protection rejects collapsing different pigments', competing, (run, edit, preview) => {
    const area = { type: 'resample', size: [1, 1], filter: 'area' };
    assert.match(preview(area).conflicts[0].message, /combine different protected pixels/);
    edit(area);
    assert.deepEqual(run(command('export')).data, competing);
  });

  const held = structuredClone(design);
  held.layers[0].offset = [1, 0];
  held.frames[1].cels.base = { id: 'held-base', label: 'Held pose', hold: 'front/base', offset: [0, 1] };
  held.slices = [{ id: 'badge', keys: [{ frame: 'front', bounds: [2, 1, 4, 3], pivot: [1.5, 1],
    nineSlice: [1, 1, 1, 1] }, { frame: 'rear', bounds: null }] }];
  scenario('offset held cels and slice guides across crop and pad', held, (run, edit, preview) => {
    assert.match(preview({ type: 'crop', rect: [0, 0, 1, 1] }).conflicts[0].message, /remove slice/);
    const review = preview(crop);
    assert.equal(review.celLinks.unlinked.length, 1);
    const receipt = edit(crop);
    assert.deepEqual(receipt.affectedTargets[0].slices.after[0].keys[0].bounds, [0, 0, 4, 3]);
    const saved = run(command('export')).data;
    assert.ok(saved.frames[1].cels.base.slots.includes('blue'));
    assert.equal(saved.frames[1].cels.base.hold, undefined);
    assert.equal(saved.layers[0].offset, undefined);
    assert.ok(edit(pad));
    run(command('export'));
    run(command('undo'));
    assert.deepEqual(run(command('export')).data, saved);
  });

  const bound = { ...design, sceneBindings: [{ id: 'source', scene: 'panel', object: 'wall', frame: 'front',
    stale: [[0, 7, 1], [1, 2, 2]] }] };
  scenario('binding policy composes translated registrations and rewrites stale runs', bound, (run, edit, preview) => {
    assert.match(preview(crop).conflicts[0].message, /bindingPolicy/);
    assert.ok(edit({ ...crop, bindingPolicy: 'preserve' }));
    assert.deepEqual(run(command('export')).data.sceneBindings[0].canvas, { size: [8, 6], offset: [2, 1], scale: [1, 1] });
    assert.ok(edit({ ...pad, bindingPolicy: 'preserve' }));
    const after = run(command('export')).data.sceneBindings[0];
    assert.deepEqual(after.canvas, { size: [8, 6], offset: [1, 0], scale: [1, 1] });
    assert.deepEqual(after.stale, [[1, 1, 2]]);
    assert.ok(edit({ type: 'resize', size: [5, 3], bindingPolicy: 'reframe' }));
    assert.equal(run(command('export')).data.sceneBindings[0].canvas, undefined);
  });

  scenario('empty trim and malformed geometry', { ...indexed, frames: [{ id: 'front', durationMs: 120, cels: {} }] },
    (run, edit, preview) => {
      assert.ok(edit({ type: 'trim' }));
      run(command('export'));
      for (const operation of [{ type: 'crop', rect: [1, 0, 2, 1] }, { type: 'pad', margins: [512, 0, 0, 0] },
        { type: 'resize', size: [3, 3], anchor: 'north' }, { type: 'resample', size: [3, 3], filter: 'other' }]) {
        assert.equal(preview(operation).valid, false);
        edit(operation);
      }
      for (const scope of [{ frame: 'front' }, { cel: 'front/base' }, { edits: [] }]) {
        assert.equal(preview(pad, {}, scope).valid, false);
      }
      run(command('export'));
    });
  const legacy = { format: 'ink-studio/pixel-art', version: 1, width: 2, height: 2,
    palette: { rust: '#cc381a' }, layers: [{ id: 'base', marks: [{ at: [1, 1], swatch: 'rust' }] }] };
  scenario('canvas edit and undo on migrated legacy input', legacy, (run, edit, preview) => {
    const single = { type: 'crop', rect: [1, 1, 1, 1] };
    assert.equal(preview(single).valid, true);
    assert.ok(edit(single));
    assert.equal(run(command('export')).data.width, 1);
    run(command('undo'));
    run(command('export'));
  });
  const named = { ...design, destinations: [{ id: 'canvas', kind: 'raster' }] };
  scenario('document canvas routing with a custom raster of the same name', named, (run, edit, preview) => {
    const scope = { destination: 'document:canvas' };
    assert.equal(preview(pad, { exact: true, limit: 2 }, scope).valid, true);
    assert.ok(edit(pad, scope));
    assert.deepEqual(run(command('export')).data.destinations, named.destinations);
  });
  return cases;
}

function latestCheckpoint(directory) {
  const revision = Math.max(...readdirSync(directory).map(name => Number(/^checkpoint-(\d+)\.json$/.exec(name)?.[1] ?? 0)));
  return JSON.parse(readFileSync(join(directory, 'checkpoint-' + revision + '.json'), 'utf8'));
}

async function verifySession(original, scratch, native) {
  const { createEditor, openEditorSession } = createRequire(import.meta.url)(resolve(original, 'cli/pixel-art.js'));
  const originalDirectory = join(scratch, 'original-session');
  const reference = createEditor(design, { sessionDirectory: originalDirectory });
  const transform = command('apply', { patch: { id: 'expand', destination: 'canvas',
    revision: reference.describe().revision, operation: pad } });
  reference.begin('Resize artwork');
  const first = reference.execute(transform);
  const draft = latestCheckpoint(originalDirectory);
  const browser = await openPixelCommandSession(draft);
  const review = reference.previewChanges({ exact: true });
  assert.deepEqual(await browser.previewChanges({ exact: true }), review);
  assert.deepEqual(await browser.snapshot(), reference.snapshot());
  const paint = command('draw', { patch: { id: 'new-edge', frame: 'front', revision: first.outputs.documentRevision,
    operation: { tool: 'pencil', layer: 'base', swatch: 'rust', points: [[8, 6]] } } });
  const second = reference.execute(paint);
  assert.deepEqual(await browser.execute(paint), second);
  assert.equal(await browser.commit(), reference.commit());
  const restored = await openPixelCommandSession(await browser.exportSession());
  const final = reference.snapshot();
  assert.deepEqual(await restored.snapshot(), final);
  assert.equal(await restored.undo(), true);
  assert.deepEqual(await restored.snapshot(), design);
  assert.equal(await restored.redo(), true);
  assert.deepEqual(await restored.snapshot(), final);

  if (!native) return;
  const directory = join(scratch, 'native-session');
  const input = join(scratch, 'canvas-session.json');
  function session(action, args = []) {
    const reply = spawnSync(resolve(native), ['session', action, directory, ...args], { encoding: 'utf8' });
    assert.equal(reply.status, 0, reply.stderr || reply.stdout);
    return JSON.parse(reply.stdout);
  }
  function run(action) {
    writeFileSync(input, JSON.stringify(action));
    return session('run', [input]);
  }
  writeFileSync(input, JSON.stringify(design));
  session('init', [input]);
  session('begin', ['--label', 'Resize artwork']);
  assert.deepEqual(run(transform), first);
  assert.deepEqual(run(command('preview', { options: { exact: true } })), review);
  assert.deepEqual(run(paint), second);
  assert.deepEqual(openEditorSession(directory).snapshot(), final);
  session('commit');
  session('undo');
  assert.deepEqual(run(command('export')).data, design);
  session('redo');
  assert.deepEqual(run(command('export')).data, final);
}

async function main(original, native) {
  const cases = canvasCases(original);
  const scratch = mkdtempSync(join(tmpdir(), 'ink-canvas-'));
  try {
    for (const { label, request, replies } of cases) {
      verifyCommands(await runCommands(await createPixelCommandEditor(request.document), request.steps), replies, 'JS ' + label);
      if (!native) continue;
      const input = join(scratch, 'request.json');
      writeFileSync(input, JSON.stringify(request));
      const result = spawnSync(resolve(native), ['journal-document', input], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
      assert.equal(result.status, 0, result.stderr);
      verifyCommands(result.stdout.trimEnd().split('\n').map(JSON.parse), replies, 'Rust ' + label);
    }
    await verifySession(original, scratch, native);
    console.log(JSON.stringify({ sessionRoundTrip: true, cases: cases.length, replies: cases.reduce((total, row) => total + row.replies.length, 0),
      native: Boolean(native) }));
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
