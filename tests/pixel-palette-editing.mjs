import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor } from '../web/pixel-document.mjs';
import { runCommands, verifyCommands } from './pixel-commands.mjs';

const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const design = {
  format: 'ink-studio/pixel-art', version: 2, width: 4, height: 2, pixelAspect: [1, 1],
  palette: { dark: { color: '#263442', label: 'Shadow', locked: true }, mid: '#49606F',
    glint: '#eeeecc', alias: '#49606f' },
  ramps: [{ id: 'steel', label: 'Brushed steel', swatches: ['dark', 'mid', 'glint'] }],
  layers: [{ id: 'ink' }],
  frames: [
    { id: 'front', durationMs: 100, cels: { ink: { slots: ['dark', 'mid', 'alias', null, null, 'alias', 'mid', 'glint'],
      marks: [{ alpha: 7, runs: [[0, 1, 1]] }, { at: [3, 0], swatch: null }] } } },
    { id: 'back', durationMs: 130, cels: { ink: { marks: [{ swatch: 'mid', steps: { from: [0, 1],
      axis: 'x', direction: [1, 1], lengths: [2] } }] } } },
    { id: 'held', durationMs: 100, cels: { ink: { hold: 'front/ink' } } },
  ],
};

const paint = (id, swatch = 'mid') => command('draw', { patch: {
  id, frame: 'front', operation: { tool: 'pencil', layer: 'ink', swatch, points: [[0, 1]] },
} });

export function paletteCases(original) {
  const { createEditor } = createRequire(import.meta.url)(resolve(original, 'cli/pixel-art.js'));
  const palette = (swatches, ramps = []) => ({ format: 'ink-studio/pixel-palette', version: 1, swatches, ramps });
  const cases = [];
  function scenario(label, document, schedule) {
    const originalEditor = createEditor(document);
    const steps = [], replies = [];
    const run = raw => {
      const saved = JSON.parse(JSON.stringify(raw));
      steps.push({ op: 'execute', command: saved });
      try {
        const value = originalEditor.execute(saved);
        replies.push({ value: JSON.parse(JSON.stringify(value)) });
        return value;
      } catch (error) {
        replies.push({ error: error.message, ...(error.receipt && { receipt: structuredClone(error.receipt) }) });
      }
    };
    const patch = (operation, extra = {}, destination = 'palette') => ({
      id: 'palette-edit', destination, revision: originalEditor.describe().revision, operation, ...extra,
    });
    const edit = (operation, extra, action = 'apply', destination) => run(command(action, { patch: patch(operation, extra, destination) }));
    const preview = (operation, options = { exact: true }, extra) =>
      run(command('preview', { edit: command('apply', { patch: patch(operation, extra) }), options }));
    schedule(run, edit, preview, patch, originalEditor);
    cases.push({ label, request: { document, steps }, replies });
  }

  scenario('ordered palette definitions, ramps and two-way import', design, (run, edit, preview, patch) => {
    const before = run(command('export')).data;
    preview({ type: 'swatch', swatch: { id: 'mid', color: '#335588' } });
    const recolor = edit({ type: 'swatch', swatch: { id: 'mid', color: '#335588' } }, {}, 'recolor');
    assert.equal(recolor.command.frame, null);
    assert.deepEqual(run(command('export')).data.frames, before.frames);
    edit({ type: 'swatch', swatch: { id: 'dark', label: 'New name' } });
    edit({ type: 'swatch', swatch: { id: 'dark', locked: false, label: null } });
    edit({ type: 'swatch', swatch: { id: 'dark', color: '#010203' } }, {}, 'apply', 'document:palette');
    edit({ type: 'swatch', swatch: { id: 'mint', color: '#00ffbb', label: 'Fresh' } });
    preview({ type: 'reorder', order: ['mint', 'glint', 'alias', 'mid', 'dark'] }, { exact: true, limit: 0 });
    edit({ type: 'reorder', order: ['mint', 'glint', 'alias', 'mid', 'dark'] });
    assert.deepEqual(run(command('export', { artifact: 'stamp', options: { frame: 'front', layer: 'ink' } })).data.slots,
      [4, 3, 2, null, null, 2, 3, 1]);
    edit({ type: 'ramp', ramp: { id: 'steel', swatches: ['glint', 'mid', 'dark'] } });
    edit({ type: 'import', palette: palette([{ id: 'mid', color: '#335588', locked: true },
      { id: 'sea', color: '#344d60' }], [{ id: 'coast', swatches: ['mid', 'sea'] }]) });
    edit({ type: 'remove-ramp', id: 'coast' });
    run(command('export'));
    run(command('validate'));
    run(command('undo'));
    run(command('redo'));
    run(command('export', { artifact: 'layer-deck' }));
    assert.equal(preview({ type: 'swatch', swatch: { id: 'mid', color: '#99aabb' } }).conflicts[0].code, 'locked-swatch');
  });

  scenario('simultaneous remaps cover literal planes, held cels and newly painted runs', design,
    (run, edit, preview, patch, originalEditor) => {
      const revision = run(command('validate')).revision;
      run({ ...paint('fresh-mark'), patch: { ...paint('fresh-mark').patch, revision } });
      const originalPaint = run(command('export')).data;
      const remap = { type: 'remap', map: { mid: 'alias' }, removeSources: true };
      const review = preview(remap);
      assert.equal(review.targets[0].remappedCels, 2);
      const first = edit(remap);
      assert.deepEqual(first.affectedTargets[0].removed, ['mid']);
      const revised = run(command('export')).data;
      assert.deepEqual(revised.ramps[0].swatches, ['dark', 'alias', 'glint']);
      assert.deepEqual(revised.frames[2], design.frames[2]);
      run(command('export', { artifact: 'stamp', options: { frame: 'held', layer: 'ink' } }));
      run(command('export', { artifact: 'png', options: { frame: 'held', layer: 'ink' } }));
      run(command('undo'));
      assert.deepEqual(run(command('export')).data, originalPaint);
      assert.deepEqual(run(command('replay', { receipt: first })), first);
      assert.deepEqual(run(command('export')).data, revised);
      run(command('undo'));
      const cycle = { type: 'remap-indices', map: { 1: 2, 2: 1 } };
      const indexed = edit(cycle, {}, 'recolor');
      assert.deepEqual(indexed.affectedTargets[0].indices, cycle.map);
      assert.deepEqual(run(command('export')).data.palette, design.palette);
      run(command('undo'));
      const batch = run(command('batch', { revision: originalEditor.describe().revision, label: 'Palette and paint', commands: [
        command('recolor', { patch: { id: 'blue', operation: { type: 'swatch', swatch: { id: 'blue', color: '#123456' } } } }),
        paint('use-new-color', 'blue'),
      ] }));
      assert.equal(batch.steps[0].command.frame, null);
      assert.equal(run(command('undo')).changed, true);
      run(command('replay-batch', { batch }));
      assert.equal(run(command('export')).data.palette.blue, '#123456');
    });

  scenario('palette validation rejects locks, malformed operations and incomplete remaps', design, (run, edit, preview) => {
    const cases = [
      { type: 'swatch', swatch: { id: 'dark', color: '#111111' } },
      { type: 'swatch', swatch: { id: 'dark', color: '#263442', label: '  ' } },
      { type: 'swatch', swatch: { id: 'new', locked: true } },
      { type: 'ramp', ramp: { id: 'bad', swatches: ['mid', 'mid'] } },
      { type: 'ramp', ramp: { id: 'bad', swatches: ['mid', 'missing'] } },
      { type: 'remove-ramp', id: 'missing' },
      { type: 'reorder', order: ['mid', 'dark', 'glint', 'alias', 'alias'] },
      { type: 'remap', map: { dark: 'alias' }, removeSources: true },
      { type: 'remap', map: { mid: 'mid' } },
      { type: 'remap', map: { mid: 'missing' } },
      { type: 'remap', map: { mid: 'glint', glint: 'mid' }, removeSources: true },
      { type: 'remap-indices', map: { '01': 2 } },
      { type: 'remap-indices', map: { 1: '2' } },
      { type: 'import', palette: palette([{ id: 'dark', color: '#aaaaaa' }]) },
      { type: 'import', palette: palette([{ id: 'mid', color: '#aaaaaa' }]) },
      { type: 'import', palette: palette([{ id: 'mid', color: '#49606f' }, { id: 'glint', color: '#eeeecc' }],
        [{ id: 'steel', swatches: ['mid', 'glint'] }]) },
    ];
    for (const op of cases) {
      assert.equal(preview(op).valid, false);
      edit(op);
    }
    edit({ type: 'swatch', swatch: { id: 'mid', label: 'Named' } }, { frame: 'front' });
    edit({ type: 'swatch', swatch: { id: 'mid', label: 'Named' } }, { cel: 'front/ink' });
    edit({ type: 'swatch', swatch: { id: 'mid', label: 'Named' } }, { edits: [] });
    assert.deepEqual(run(command('export')).data, design);
  });

  const protectedDesign = { ...design, protectedDetails: [{ id: 'highlight', kind: 'pixel', pixels: [[1, 0]], frame: 'held' }] };
  scenario('visible protection compares pigment identity across changed palette indices', protectedDesign, (run, edit, preview) => {
    assert.equal(preview({ type: 'swatch', swatch: { id: 'mid', color: '#335588' } }).conflicts[0].code, 'protected-pixel');
    assert.equal(preview({ type: 'remap', map: { mid: 'alias' } }).conflicts[0].code, 'protected-pixel');
    assert.ok(edit({ type: 'reorder', order: ['glint', 'alias', 'mid', 'dark'] }));
    run(command('export'));
  });

  const locked = { ...design, layers: [{ id: 'ink', locked: true }] };
  scenario('swatch color edits and locked raster remap guards have independent scopes', locked, (run, edit, preview) => {
    assert.ok(edit({ type: 'swatch', swatch: { id: 'mid', color: '#335588' } }));
    assert.equal(preview({ type: 'remap', map: { mid: 'alias' } }).conflicts[0].code, 'locked-layer');
    edit({ type: 'remap', map: { mid: 'alias' } });
    run(command('export'));
  });
  return cases;
}

async function main(original, native) {
  const cases = paletteCases(original);
  const scratch = mkdtempSync(join(tmpdir(), 'ink-palette-editing-'));
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
    console.log(JSON.stringify({ cases: cases.length, replies: cases.reduce((sum, row) => sum + row.replies.length, 0),
      native: Boolean(native) }));
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
