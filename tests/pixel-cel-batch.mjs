import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fileAndSession, verify } from './pixel-timeline-edits.mjs';

const mark = (swatch, x, y) => ({ swatch, at: [x, y] });
const drawing = () => ({ marks: [mark('red', 1, 1), { alpha: 96, runs: [[1, 1, 1]] },
  mark('green', 3, 1), mark(null, 0, 0)] });
const fixture = () => ({
  format: 'ink-studio/pixel-art', version: 2, width: 5, height: 3, pixelAspect: [1, 1],
  palette: { red: '#b03020', green: '#20b050' }, layers: [{ id: 'shadow', visible: false }, { id: 'ink' }],
  frames: [
    { id: 'first', durationMs: 90, cels: { shadow: drawing(), ink: drawing() } },
    { id: 'second', durationMs: 120, cels: { ink: { hold: 'first/ink' } } },
    { id: 'third', durationMs: 65, cels: { ink: { hold: 'second/ink' } } },
    { id: 'fourth', durationMs: 80, cels: { ink: { hold: 'third/ink' } } },
  ],
  tags: [{ id: 'twobeat', start: 'first', end: 'second', direction: 'reverse', loop: false }],
  selections: [
    { id: 'middle', pixels: [[1, 1], [2, 1]] },
    { id: 'first-tip', frame: 'first', pixels: [[0, 0], [1, 1]] },
    { id: 'second-tip', frame: 'second', pixels: [[1, 1]] },
  ],
});
const editCels = (scope, edit) => ({ type: 'edit-cels', scope, edit });
const swap = { type: 'palette-swap', map: { red: 'green', green: 'red' } };
const pixels = (cel, ...points) => ({ cel, pixels: points.map(([x, y, swatch]) => ({ at: [x, y], swatch })) });
const writeCels = (...cels) => ({ type: 'write-cels', cels });
const json = value => JSON.parse(JSON.stringify(value));
const command = (action, options) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...options });

function repairFixture(rows, points, alpha = []) {
  const colors = { ink: '#142839', rust: '#c65126', sky: '#6899aa' };
  const [width, height] = [rows[0].length, rows.length];
  const swatches = Object.keys(colors);
  const slots = rows.flatMap(row => [...row].map(value => swatches[value] ?? null));
  const marks = alpha.map(([x, y, opacity]) => ({ alpha: opacity, runs: [[y, x, 1]] }));
  return {
    format: 'ink-studio/pixel-art', version: 2, width, height, pixelAspect: [1, 1],
    palette: colors, layers: [{ id: 'paint' }],
    frames: [
      { id: 'front', durationMs: 100, cels: { paint: { slots, marks } } },
      { id: 'side', durationMs: 100, cels: { paint: { hold: 'front/paint' } } },
    ],
    selections: [{ id: 'region', pixels: points ?? Array.from({ length: width * height }, (_, i) => [i % width, Math.floor(i / width)]) }],
  };
}

export function reference(original) {
  const { createEditor } = createRequire(import.meta.url)(join(original, 'cli/pixel-art.js'));
  const cases = [];
  function scenario(name, document, define) {
    const editor = createEditor(document);
    const steps = [], expected = [];
    let serial = 0;
    function execute(action, options) {
      const request = json(command(action, options));
      steps.push({ op: 'execute', command: request });
      try {
        const value = editor.execute(request);
        expected.push({ value: json(value) });
        return value;
      } catch (error) {
        expected.push({ error: error.message, ...(error.receipt && { receipt: json(error.receipt) }) });
        if (!error.receipt) throw error;
        return error.receipt;
      }
    }
    function patch(operation, options) {
      return { id: 'batch-' + ++serial, destination: 'timeline', revision: editor.describe().revision, operation, ...options };
    }
    const preview = (patch, exact = true) => execute('preview', { edit: command('apply', { patch }), options: { exact, limit: 0 } });
    function edit(operation, error) {
      const next = patch(operation);
      const review = preview(next);
      const receipt = execute('apply', { patch: next });
      if (error) {
        assert.equal(review.valid, false);
        assert.equal(review.conflicts[0].code, error);
        assert.equal(receipt.conflicts[0].code, error);
      } else {
        assert.equal(review.valid, true, JSON.stringify(review));
        assert.deepEqual(receipt.affectedTargets, review.targets);
      }
      return receipt;
    }
    const snapshot = () => execute('export').data;
    define({ execute, patch, preview, edit, snapshot });
    cases.push({ name, request: { document, steps }, expected, timeline: editor.timeline() });
  }

  scenario('simultaneous palette swaps in document order through held cels', fixture(), ({ execute, edit, snapshot }) => {
    execute('begin', { label: 'Batch swatches' });
    const receipt = edit(editCels({ tag: 'twobeat', layers: ['ink', 'shadow'] }, swap));
    const target = receipt.affectedTargets[0];
    assert.deepEqual(target.frames.map(row => [row.frame, row.pixelCount, row.missingLayers]),
      [['first', 4, []], ['second', 2, ['shadow']]]);
    assert.equal(target.frames[0].cels[0].changes[0].after.alpha, 96);
    assert.deepEqual(target.links, [{ cel: 'third/ink', frame: 'third', layer: 'ink', before: 'second/ink', after: null }]);
    execute('preview', { options: { exact: true, limit: 0 } });
    execute('commit');
    const saved = snapshot();
    assert.equal(saved.frames[1].cels.ink.hold, 'first/ink');
    assert.equal(saved.frames[3].cels.ink.hold, 'third/ink');
    execute('undo');
    assert.deepEqual(snapshot(), fixture());
    execute('redo');
    assert.deepEqual(snapshot(), saved);
    edit(editCels({ frames: ['first', 'fourth'], layers: ['shadow', 'ink'], selection: 'middle' }, swap));
    snapshot();
  });

  scenario('explicit pixels, custom IDs, clearing coverage and repartition', (() => {
    const art = fixture();
    art.frames[0].cels.ink.id = 'anchor';
    art.frames[1].cels.ink.hold = 'anchor';
    art.frames[0].cels.ink.slots = Array(15).fill(null);
    art.frames[0].cels.ink.slots[8] = 'green';
    return art;
  })(), ({ edit, snapshot }) => {
    const written = edit(writeCels(pixels('third/ink', [3, 1, null], [1, 1, 'red']), pixels('anchor', [1, 1, 'red']),
      pixels('second/ink', [1, 1, 'red'])));
    assert.deepEqual(written.affectedTargets[0].scope.cels, ['third/ink', 'anchor', 'second/ink']);
    assert.equal(written.affectedTargets[0].frames[0].cels[0].changes[0].after.alpha, 255);
    assert.equal(snapshot().frames[1].cels.ink.hold, 'anchor');
    edit(writeCels(pixels('third/ink', [3, 1, null])));
    edit(writeCels(pixels('third/ink', [0, 1, null], [0, 1, 'red'])), 'invalid-edit');
    edit(writeCels(pixels('third/ink', [5, 1, 'red'])), 'invalid-edit');
    edit(writeCels(pixels('unknown', [0, 0, 'red'])), 'missing-cel');
    edit(writeCels(pixels('third/ink', [0, 1, 'absent'])), 'invalid-edit');
    snapshot();
  });

  scenario('selected nudges and both mask modes', fixture(), ({ edit, snapshot }) => {
    const scope = { cels: ['second/ink', 'first/shadow'], selections: { first: 'first-tip', second: 'second-tip' } };
    const nudged = edit(editCels(scope, { type: 'nudge', offset: [1, 0] }));
    assert.equal(nudged.affectedTargets[0].pixelCount, 6);
    assert.equal(snapshot().frames[2].cels.ink.hold, 'first/ink');
    edit(editCels({ ...scope, selections: { ...scope.selections, third: 'middle' } }, swap), 'invalid-edit');
    edit(editCels({ cels: ['second/ink'], selection: 'first-tip' }, swap), 'missing-selection');
    edit(editCels({ cels: ['first/ink'] }, { type: 'nudge', offset: [-1, -1] }), 'outside-canvas');
    edit(editCels({ cels: ['second/ink'] }, { type: 'nudge', offset: [0, 0] }));
    edit(editCels({ frames: ['first', 'second'], layers: ['shadow', 'ink'], selection: 'middle' }, { type: 'mask' }));
    edit(editCels({ cels: ['second/ink'], selection: 'middle' }, { type: 'mask', mode: 'erase' }));
    edit(editCels({ cels: ['second/ink'] }, { type: 'mask' }), 'invalid-edit');
    snapshot();
  });

  const guarded = fixture();
  guarded.protectedDetails = [{ id: 'stay', kind: 'pixel', frame: 'second', pixels: [[1, 1]] }];
  scenario('batch rollback on protected pixels and validation order', guarded, ({ edit, snapshot }) => {
    const blocked = edit(editCels({ frames: ['first', 'second'], layers: ['ink'] }, swap), 'protected-pixel');
    assert.deepEqual(blocked.conflicts[0].at, [1, 1]);
    assert.equal(blocked.conflicts[0].cel, 'second/ink');
    edit(writeCels(pixels('first/ink', [1, 0, 'green']), pixels('second/ink', [1, 1, null])), 'protected-pixel');
    edit(editCels({ frames: ['second', 'first'], layers: ['ink'] }, swap), 'invalid-edit');
    edit(editCels({ tag: 'absent', layers: ['ink'] }, swap), 'missing-tag');
    edit(editCels({ tag: 42, layers: ['ink'] }, swap), 'missing-tag');
    edit(editCels({ tag: 'twobeat', layers: ['absent'] }, swap), 'missing-layer');
    assert.deepEqual(snapshot(), guarded);
  });

  const guardedLayers = fixture();
  guardedLayers.layers[0].parent = 'parent';
  guardedLayers.layers.unshift({ id: 'parent', kind: 'group', locked: true });
  scenario('inherited locks', guardedLayers, ({ edit, snapshot }) => {
    edit(editCels({ cels: ['first/shadow'] }, swap), 'locked-layer');
    assert.deepEqual(snapshot(), guardedLayers);
  });

  const clipped = fixture();
  clipped.layers[1].clip = 'shadow';
  clipped.frames[3].cels.ink.offset = [1, 0];
  scenario('clipped layers', clipped, ({ edit, snapshot }) => {
    edit(editCels({ cels: ['first/ink'] }, swap), 'clipped-pixel');
    edit(writeCels(pixels('fourth/ink', [0, 1, 'red'])), 'clipped-pixel');
    assert.deepEqual(snapshot(), clipped);
  });

  const shifted = fixture();
  shifted.frames[1].cels.ink.offset = [1, 0];
  scenario('native coordinates and shifted cel bounds', shifted, ({ edit, snapshot }) => {
    edit(writeCels(pixels('second/ink', [0, 2, 'red'])), 'outside-cel');
    edit(writeCels(pixels('second/ink', [4, 1, 'red'])));
    assert.equal(snapshot().frames[1].cels.ink.marks.at(-1).runs[0][1], 3);
  });

  const cleaning = (kind, spec) => editCels({ frames: ['front', 'side'], layers: ['paint'], selection: 'region' },
    { type: 'cleanup', kind, ...spec });
  scenario('stair coverage and the cleanup budget', repairFixture(
    ['.........', '.0.......', '..00000..', '.......0.', '.........'], null, [[2, 2, 110], [6, 2, 82]]),
  ({ edit, snapshot }) => {
    edit(cleaning('stair', { maxChanges: 3 }), 'cleanup-budget');
    assert.equal(edit(cleaning('stair', { maxChanges: 4 })).affectedTargets[0].pixelCount, 8);
    assert.equal(snapshot().frames[1].cels.paint.hold, 'front/paint');
  });
  scenario('fragment donor ambiguity and borrowed coverage', repairFixture(
    ['.......', '.00122.', '.00.22.', '.......'], [[3, 1]], [[3, 1, 96]]),
  ({ edit, snapshot }) => {
    edit(cleaning('fragment'), 'cleanup-shape');
    edit(cleaning('fragment', { at: [4, 1] }), 'cleanup-selection');
    assert.equal(edit(cleaning('fragment', { swatch: 'sky' })).affectedTargets[0].frames[0].cels[0].changes[0].after.alpha, 96);
    snapshot();
  });
  scenario('outline stepping corner', repairFixture(
    ['.........', '.........', '.......0.', '......0..', '....00...', '....0....', '...0.....', '.........'], [[4, 4], [5, 4]]),
  ({ edit, snapshot }) => {
    assert.equal(edit(cleaning('outline')).affectedTargets[0].pixelCount, 2);
    snapshot();
  });
  scenario('cluster growth and preserving the bridge', repairFixture(
    ['........', '.00..00.', '.000000.', '.00..00.', '........'], [[1, 1], [2, 1], [2, 0], [3, 2]], [[2, 1, 64]]),
  ({ edit, snapshot }) => {
    const receipt = edit(cleaning('cluster', { mode: 'grow', maxChanges: 1 }));
    assert.equal(receipt.affectedTargets[0].frames[0].cels[0].changes[0].after.alpha, 64);
    edit(cleaning('cluster', { mode: 'shrink', at: [2, 1] }));
    snapshot();
  });
  const dense = repairFixture(Array.from({ length: 32 }, () => '0'.repeat(40)), [[0, 0]]);
  scenario('native grid writes above the three-digit count boundary', dense, ({ edit, snapshot }) => {
    const coordinates = Array.from({ length: 1280 }, (_, p) => [p % 40, Math.floor(p / 40), 'rust']);
    const receipt = edit(writeCels(pixels('side/paint', ...coordinates), pixels('front/paint', ...coordinates)));
    assert.equal(receipt.affectedTargets[0].pixelCount, 2560);
    assert.equal(receipt.affectedTargets[0].frames[0].cels[0].pixelCount, 1280);
    assert.equal(snapshot().frames[1].cels.paint.hold, 'front/paint');
  });
  return cases;
}

async function run([original, native]) {
  const { createPixelCommandEditor } = await import('../web/pixel-document.mjs');
  const { runCommands } = await import('./pixel-commands.mjs');
  const cases = reference(original);
  const scratch = mkdtempSync(join(tmpdir(), 'ink-cel-batch-'));
  let sessionCommands = 0;
  try {
    for (const { name, request, expected, timeline } of cases) {
      const editor = await createPixelCommandEditor(request.document);
      const actual = await runCommands(editor, request.steps);
      verify(actual, expected, request.steps, 'JavaScript ' + name);
      assert.deepEqual(await editor.timeline(), timeline, 'timeline ' + name);
      if (native) {
        const input = join(scratch, 'journal.json');
        writeFileSync(input, JSON.stringify(request));
        const result = execFileSync(native, ['journal-document', input], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
        verify(result.trim().split('\n').map(JSON.parse), expected, request.steps, 'Rust ' + name);
      }
    }
    if (native) sessionCommands = fileAndSession(original, native, scratch, cases[1]);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ cases: cases.length, matchedReplies: cases.reduce((sum, row) => sum + row.expected.length, 0),
    native: Boolean(native), sessionCommands }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await run(process.argv.slice(2).map(path => resolve(path)));
}
