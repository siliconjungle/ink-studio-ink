import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fileAndSession, verify } from './pixel-timeline-edits.mjs';

const palette = { ink: '#142839', rust: '#c65126', sky: '#6899aa' };
const stair = ['.........', '.0.......', '..00000..', '.......0.', '.........'];
const fragment = ['.......', '.00122.', '.00.22.', '.......'];
const outline = ['.........', '.........', '.......0.', '......0..', '....00...', '....0....', '...0.....', '.........'];
const cluster = ['........', '.00..00.', '.000000.', '.00..00.', '........'];
const positions = (width, height) => Array.from({ length: width * height }, (_, i) => [i % width, Math.floor(i / width)]);

export function documentFor(rows, points, alpha = []) {
  const [width, height] = [rows[0].length, rows.length];
  const swatches = Object.keys(palette);
  const slots = rows.flatMap(row => [...row].map(value => swatches[value] ?? null));
  const marks = alpha.map(([x, y, opacity]) => ({ alpha: opacity, runs: [[y, x, 1]] }));
  return {
    format: 'ink-studio/pixel-art', version: 2, width, height, pixelAspect: [1, 1],
    palette, layers: [{ id: 'paint' }],
    frames: [
      { id: 'front', durationMs: 100, cels: { paint: { slots, marks } } },
      { id: 'side', durationMs: 100, cels: { paint: { hold: 'front/paint' } } },
    ],
    selections: [{ id: 'region', frame: 'front', pixels: points ?? positions(width, height) }],
  };
}

const scoped = { layer: 'paint', selection: 'region' };
const command = (action, fields) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const json = value => JSON.parse(JSON.stringify(value));

export function reference(original) {
  const { createEditor } = createRequire(import.meta.url)(join(original, 'cli/pixel-art.js'));
  const cases = [];
  function scenario(name, document, define) {
    const editor = createEditor(document);
    const steps = [], expected = [];
    let serial = 0;
    function execute(action, fields) {
      const operation = json(command(action, fields));
      steps.push({ op: 'execute', command: operation });
      try {
        const result = editor.execute(operation);
        expected.push({ value: json(result) });
        return result;
      } catch (error) {
        assert(error.receipt, error.message);
        expected.push({ error: error.message, receipt: json(error.receipt) });
        return error.receipt;
      }
    }
    function clean(operation, options, code) {
      const patch = { id: 'cleanup-' + ++serial, frame: 'front', revision: editor.describe().revision,
        operation: { tool: 'cleanup', ...operation }, ...options };
      const review = execute('preview', { edit: command('draw', { patch }), options: { exact: true, limit: 0 } });
      const receipt = execute('draw', { patch });
      if (code) {
        assert.equal(review.valid, false);
        assert.equal(receipt.conflicts[0].code, code);
        assert.deepEqual(review.conflicts, receipt.conflicts);
      } else {
        assert.equal(review.valid, true, JSON.stringify(review));
        assert.deepEqual(receipt.affectedTargets, review.targets);
      }
      return { review, receipt };
    }
    const snapshot = () => execute('export').data;
    define({ clean, execute, snapshot });
    cases.push({ name, request: { document, steps }, expected, timeline: editor.timeline() });
  }

  const covered = documentFor(stair, null, [[2, 2, 110], [6, 2, 82]]);
  covered.layers.push({ id: 'cover' });
  covered.frames[0].cels.cover = { marks: positions(9, 5).map(at => ({ at, swatch: 'sky' })) };
  scenario('exact repair under opaque paint with draft undo and redo', covered, ({ clean, execute, snapshot }) => {
    execute('begin', { label: 'Repair staircase' });
    const { review, receipt } = clean({ ...scoped, kind: 'stair', maxChanges: 4 });
    assert.equal(review.pixelCount, 4);
    assert(review.diff.cells.filter(row => !row.layer).every(row => row.frame === 'side'));
    const target = receipt.affectedTargets[0];
    assert.deepEqual(target.changes[0].after.rgba, [20, 40, 57, 110]);
    assert.equal(target.changes.length, 4);
    execute('preview', { options: { exact: true, limit: 0 } });
    execute('commit');
    const saved = snapshot();
    execute('undo');
    assert.deepEqual(snapshot(), covered);
    execute('redo');
    assert.deepEqual(snapshot(), saved);
  });

  scenario('explicit pixels and cel addressing preserve fragment coverage', documentFor(fragment, [[3, 1]], [[3, 1, 96]]),
    ({ clean, snapshot }) => {
      clean({ ...scoped, kind: 'fragment' }, undefined, 'cleanup-shape');
      const { receipt } = clean({ kind: 'fragment', pixels: [[3, 1]], swatch: 'sky' }, { cel: 'front/paint' });
      assert.deepEqual(receipt.affectedTargets[0].changes[0].after.rgba, [104, 153, 170, 96]);
      snapshot();
    });

  scenario('outline and cluster modes', documentFor(outline, [[4, 4], [5, 4]]), ({ clean, snapshot }) => {
    const { receipt } = clean({ ...scoped, kind: 'outline' });
    assert.deepEqual(receipt.affectedTargets[0].changes[0].at, [4, 4]);
    snapshot();
  });

  scenario('cluster growth and a held drawing edited by its cel ID', documentFor(cluster, [[2, 1], [2, 0], [3, 2]], [[2, 1, 64]]),
    ({ clean, snapshot }) => {
      clean({ kind: 'cluster', mode: 'grow', at: [2, 1], pixels: [[2, 1], [2, 0]] }, { frame: 'side', cel: 'side/paint' });
      const saved = snapshot();
      assert.equal(saved.frames[1].cels.paint.hold, undefined);
      clean({ ...scoped, kind: 'cluster', mode: 'shrink', at: [2, 1] });
      snapshot();
    });

  const protectedArt = documentFor(stair);
  protectedArt.protectedDetails = [{ id: 'gap', kind: 'gap', frame: 'front', pixels: [[6, 3]] }];
  scenario('protected pixels and cleanup budget carry structured details', protectedArt, ({ clean, snapshot }) => {
    const { receipt } = clean({ ...scoped, kind: 'stair' }, undefined, 'protected-pixel');
    assert.deepEqual(receipt.conflicts[0].at, [6, 3]);
    const limited = clean({ ...scoped, kind: 'stair', maxChanges: 1 }, undefined, 'cleanup-budget');
    assert.equal(limited.receipt.conflicts[0].maxChanges, 1);
    assert.deepEqual(snapshot(), protectedArt);
  });

  const clipped = documentFor(stair);
  clipped.layers = [{ id: 'hold', kind: 'mask' }, { id: 'paint', clip: 'hold' }];
  clipped.frames[0].cels.hold = { slots: [...clipped.frames[0].cels.paint.slots], marks: [] };
  scenario('target clipping rejects an outside repair', clipped, ({ clean, snapshot }) => {
    const { receipt } = clean({ ...scoped, kind: 'stair' }, undefined, 'clipped-pixel');
    assert.deepEqual(receipt.conflicts[0].at, [2, 1]);
    assert.deepEqual(snapshot(), clipped);
  });

  const shifted = documentFor(['....','0...','....'], [[0, 1], [1, 1]]);
  shifted.frames[0].cels.paint.offset = [1, 0];
  scenario('shifted grids and unchanged cluster repairs', shifted, ({ clean, snapshot }) => {
    const blocked = clean({ ...scoped, kind: 'cluster', mode: 'grow', at: [1, 1] }, undefined, 'outside-cel');
    assert.deepEqual(blocked.receipt.conflicts[0].at, [0, 1]);
    assert.equal(blocked.receipt.conflicts[0].layer, 'paint');
    const unchanged = clean({ layer: 'paint', kind: 'cluster', mode: 'grow', pixels: [[1, 1]] });
    assert.equal(unchanged.receipt.affectedTargets[0].pixelCount, 0);
    assert.deepEqual(snapshot(), shifted);
  });

  const large = documentFor(Array.from({ length: 46 }, () => '.'.repeat(46)), [[0, 0]]);
  scenario('selection budget on a larger native grid', large, ({ clean, snapshot }) => {
    clean({ layer: 'paint', kind: 'stair', pixels: positions(46, 46).slice(0, 2049) }, undefined, 'cleanup-selection');
    assert.deepEqual(snapshot(), large);
  });

  scenario('malformed pixel selections and out-of-frame named selections', documentFor(fragment, [[3, 1]]), ({ clean, snapshot }) => {
    clean({ ...scoped, kind: 'fragment', pixels: [[3, 1]] }, undefined, 'invalid-edit');
    clean({ layer: 'paint', kind: 'fragment' }, undefined, 'invalid-edit');
    clean({ layer: 'paint', kind: 'fragment', pixels: [[3, 1], [3, 1]] }, undefined, 'invalid-edit');
    clean({ layer: 'paint', kind: 'fragment', pixels: [[3, 100]] }, undefined, 'invalid-edit');
    clean({ layer: 'paint', kind: 'fragment', pixels: [] }, undefined, 'cleanup-selection');
    clean({ ...scoped, kind: 'fragment' }, { frame: 'side' }, 'invalid-edit');
    clean({ ...scoped, kind: 'fragment', selection: 7 }, undefined, 'invalid-edit');
    const bad = clean({ ...scoped, kind: 'fragment', at: ['bad', 1] }, undefined, 'cleanup-selection');
    assert.deepEqual(bad.receipt.conflicts[0].at, ['bad', 1]);
    clean({ ...scoped, kind: 'fragment', maxChanges: 0 }, undefined, 'invalid-edit');
    snapshot();
  });

  return cases;
}

async function run([original, native]) {
  const { createPixelCommandEditor } = await import('../web/pixel-document.mjs');
  const { runCommands } = await import('./pixel-commands.mjs');
  const cases = reference(original);
  const scratch = mkdtempSync(join(tmpdir(), 'ink-raster-cleanup-'));
  let sessionCommands = 0;
  try {
    for (const { name, request, expected, timeline } of cases) {
      const editor = await createPixelCommandEditor(request.document);
      verify(await runCommands(editor, request.steps), expected, request.steps, 'JavaScript ' + name);
      assert.deepEqual(await editor.timeline(), timeline, name);
      if (native) {
        const input = join(scratch, 'journal.json');
        writeFileSync(input, JSON.stringify(request));
        const result = execFileSync(native, ['journal-document', input], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
        verify(result.trim().split('\n').map(JSON.parse), expected, request.steps, 'Rust ' + name);
      }
    }
    if (native) {
      const clean = cases[0];
      const steps = clean.request.steps.map(step =>
        step.command.action === 'draw' ? { ...step, command: { ...step.command, action: 'apply' } } : step);
      sessionCommands = fileAndSession(original, native, scratch, { ...clean, request: { ...clean.request, steps } });
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ cases: cases.length, matchedReplies: cases.reduce((sum, row) => sum + row.expected.length, 0),
    native: Boolean(native), sessionCommands }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await run(process.argv.slice(2).map(path => resolve(path)));
}
