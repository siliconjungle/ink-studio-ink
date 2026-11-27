import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { document } from './pixel-timeline-edits.mjs';

const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const directional = {
  version: 1, approvedSwatches: ['red', 'gold'],
  partAnchors: [{ id: 'pin', part: 'arm', point: [0, 1.25, 2] }], viewBlend: 'depth-reprojected',
  views: [
    { frame: 'one', pose: 0, yaw: 0, pitch: 0, pivot: [1, 2], unitsPerPixel: 0.1 },
    { frame: 'two', pose: 0, yaw: 0.65, pitch: 0, pivot: [1.5, 2], unitsPerPixel: 0.1,
      anchors: { pin: [2, 1] }, handoff: 'exact' },
  ],
};
const slice = { id: 'panel', label: 'Panel', keys: [
  { frame: 'three', bounds: [2, 1, 2, 2], pivot: [0.5, 1] },
  { frame: 'one', bounds: [0, 0, 4, 3], pivot: [1.5, 2], nineSlice: [1, 1, 1, 1] },
] };
const initialMap = {
  version: 1, width: 4, height: 2,
  cells: [{ at: [2, 0], tile: 'two' }, { at: [0, 0], tile: 'two' }, { at: [3, 1], tile: 'three' }],
};

export function reference(original) {
  const { createEditor } = createRequire(import.meta.url)(join(original, 'cli/pixel-art.js'));
  const cases = [];
  function scenario(name, document, exercise) {
    const editor = createEditor(document), steps = [], replies = [];
    const run = (action, fields) => {
      const request = command(action, fields);
      steps.push({ op: 'execute', command: request });
      try {
        const value = editor.execute(request);
        replies.push({ value });
        return value;
      } catch (error) {
        replies.push({ error: error.message, ...(error.receipt && { receipt: error.receipt }) });
        return error.receipt;
      }
    };
    let id = 0;
    const patch = (operation, extra) => ({ id: 'asset-' + ++id, destination: 'timeline',
      revision: editor.timeline().revision, operation, ...extra });
    const edit = (operation, exact = true) => {
      const current = patch(operation);
      const report = run('preview', { edit: command('apply', { patch: current }), options: { exact } });
      assert.equal(report.valid, true, JSON.stringify(operation));
      return run('apply', { patch: current });
    };
    const reject = (operation, message) => {
      const current = patch(operation);
      assert.match(run('preview', { edit: command('apply', { patch: current }) }).conflicts[0].message, message);
      assert.equal(run('apply', { patch: current }).status, 'rejected');
    };
    exercise(editor, run, edit, reject, patch);
    cases.push({ name, request: { document, steps }, replies, timeline: editor.timeline() });
  }

  scenario('directional registration and held slice keys', { ...document, slices: [slice] },
    (editor, run, edit, reject) => {
      run('begin', { label: 'Register the poses' });
      edit({ type: 'set-directional', directional });
      assert.deepEqual(editor.timeline().directional, directional);
      edit({ type: 'set-slice-key', id: 'panel', label: null, key: {
        frame: 'two', bounds: [1, 1, 3, 3], pivot: [-0.5, 1], nineSlice: [1, 0, 1, 1],
      } });
      assert.deepEqual(editor.slices({ frame: 'two' }).active[0].registration, [0.5, 2]);
      run('preview', { options: { exact: true } });
      run('commit');
      const revised = run('export').data;
      run('undo');
      assert.equal(run('export').data.directional, undefined);
      run('redo');
      assert.deepEqual(run('export').data, revised);
      assert.deepEqual(run('export', { artifact: 'layer-deck' }).data.slices, revised.slices);
      edit({ type: 'set-slice-key', id: 'panel', key: { frame: 'two', bounds: null } });
      assert.deepEqual(editor.slices({ frame: 'two' }).active, []);
      edit({ type: 'remove-slice-key', id: 'panel', frame: 'two' });
      assert.equal(editor.slices({ frame: 'two' }).active[0].keyFrame, 'one');
      edit({ type: 'remove-slice', id: 'panel' });
      edit({ type: 'set-directional', directional: null });
      const duplicate = structuredClone(directional);
      duplicate.views[1].yaw = Math.PI * 2;
      reject({ type: 'set-directional', directional: duplicate }, /repeat a heading/);
      reject({ type: 'set-directional', directional: { ...directional, approvedSwatches: ['red', 'red'] } }, /unique document swatch/);
      reject({ type: 'set-directional', directional: { ...directional, partAnchors: [{ ...directional.partAnchors[0], point: [0, 1] }] } }, /finite asset-space/);
      reject({ type: 'set-slice-key', id: 'panel', key: { frame: 'unknown', bounds: null } }, /known frames/);
      reject({ type: 'set-slice-key', id: 'panel', key: { frame: 'two', bounds: [0, 1, 6, 2] } }, /inside the native canvas/);
      reject({ type: 'set-slice-key', id: 'panel', key: { frame: 'two', bounds: [0, 1, 2, 2], pivot: [0.25, 1] } }, /half-pixel/);
      reject({ type: 'set-slice-key', id: 'panel', key: { frame: 'two', bounds: [0, 1, 2, 2], nineSlice: [1, 1, 1, 1] } }, /nonempty stretch/);
      reject({ type: 'remove-slice', id: 'panel' }, /Unknown pixel slice panel/);
    });

  const tiles = structuredClone(document);
  tiles.frames[1].label = 'Held';
  tiles.frames[1].cels.ink = { hold: 'one/ink', offset: [1, 0] };
  tiles.guides = [{ id: 'edge', kind: 'axis', axis: 'x', at: 1, frame: 'two' },
    { id: 'edge-variant', kind: 'axis', axis: 'x', at: 3 }];
  tiles.selections = [{ id: 'top', frame: 'two', pixels: [[0, 0], [1, 0]] }];
  tiles.protectedDetails = [{ id: 'gap', kind: 'gap', frames: ['two', 'two'], pixels: [[0, 0]] }];
  scenario('tile strokes, local variants and guarded reuse', tiles, (editor, run, edit, reject, patch) => {
    reject({ type: 'place-tiles', points: [[0, 0]], tile: 'two' }, /Create a tilemap/);
    edit({ type: 'set-tilemap', tilemap: initialMap });
    const stroke = edit({ type: 'place-tiles', points: [[1, 0], [2, 0], [1, 0]], tile: 'one' });
    assert.deepEqual(stroke.affectedTargets[0].changes.map(row => row.at), [[1, 0], [2, 0]]);
    const erased = edit({ type: 'place-tiles', points: [[3, 1]], tile: null });
    assert.equal(erased.affectedTargets[0].cellCount, 1);
    run('begin', { label: 'Fork tile' });
    const fork = edit({ type: 'make-local-variant', at: [0, 0], tile: 'cracked' });
    const variant = run('export').data;
    assert.equal(variant.frames.at(-1).cels.ink.id, 'cracked/ink');
    assert.deepEqual(variant.frames.at(-1).cels.ink.slots, tiles.frames[0].cels.ink.slots);
    assert.equal(variant.guides.at(-1).id, 'edge-variant-2');
    assert.deepEqual(variant.selections.at(-1).pixels, tiles.selections[0].pixels);
    assert.equal(variant.protectedDetails.at(-1).frame, 'cracked');
    run('select', { query: { type: 'recall', id: 'top-variant' }, options: { frame: 'cracked' } });
    run('preview', { options: { exact: true } });
    run('commit');
    assert.deepEqual(editor.tilemap([0, 0]).exactMatches, ['two']);
    run('undo');
    const repeated = run('replay', { receipt: fork });
    assert.deepEqual(repeated, fork);
    edit({ type: 'reuse-exact-tile', at: [0, 0], tile: 'two' });
    run('undo');
    run('apply', { patch: patch({ tool: 'pencil', layer: 'ink', swatch: 'gold', points: [[4, 0]] },
      { frame: 'cracked', destination: 'raster' }) });
    reject({ type: 'reuse-exact-tile', at: [0, 0], tile: 'two' }, /artwork and protection must match exactly/);
    reject({ type: 'make-local-variant', at: [0, 1], tile: 'copy' }, /occupied tilemap cell/);
    reject({ type: 'place-tiles', points: [[4, 0]], tile: 'one' }, /inside the map/);
    reject({ type: 'set-tilemap', tilemap: { ...initialMap, cells: initialMap.cells.concat(initialMap.cells[0]) } }, /repeats cell/);
    reject({ type: 'set-tilemap', tilemap: { ...initialMap, variants: { two: { neighbors: { WE: 'one' } } } } }, /canonical NESW/);
    reject({ type: 'set-tilemap', tilemap: { ...initialMap, variants: { two: { animation: { frames: ['missing'] } } } } }, /known frames/);
    edit({ type: 'set-tilemap', tilemap: { ...initialMap, variants: { two: {
      neighbors: { E: 'one' }, connects: ['two'],
      animation: { frames: ['one', 'one', 'three'], direction: 'ping-pong', loop: false },
    } } } });
    reject({ type: 'duration', frame: 'one', durationMs: Number.MAX_SAFE_INTEGER - 1000 }, /safe time range/);
    reject({ type: 'reuse-exact-tile', at: [0, 0], tile: 'cracked' }, /matching tile animation and neighbor rules/);
    edit({ type: 'set-tilemap', tilemap: null });
    assert.equal(run('export').data.tilemap, undefined);
  });

  const comparisons = structuredClone(document);
  comparisons.palette.alias = comparisons.palette.red;
  comparisons.layers.push({ id: 'hidden', visible: false });
  const copy = id => ({ ...structuredClone(comparisons.frames[0]), id });
  const alias = copy('aliased');
  alias.cels.ink.slots[6] = 'alias';
  const alpha = copy('alpha');
  alpha.cels.ink.marks[0].alpha = 129;
  const shifted = copy('shifted');
  shifted.cels.ink.offset = [1, 0];
  const hidden = copy('extra-ink');
  hidden.cels.hidden = { marks: [{ swatch: 'gold', at: [0, 0] }] };
  const knockout = copy('knockout');
  knockout.cels.hidden = { marks: [{ swatch: null, at: [0, 0] }] };
  comparisons.frames.push(copy('match'), alias, alpha, shifted, hidden, knockout, copy('protected'));
  comparisons.protectedDetails = [{ id: 'accent', kind: 'accent', frame: 'protected', pixels: [[1, 1]] }];
  comparisons.tilemap = { ...initialMap, cells: [{ at: [0, 0], tile: 'one' }] };
  scenario('exact reuse considers indexed and hidden raw pixels', comparisons, (editor, run, edit, reject) => {
    for (const tile of ['aliased', 'alpha', 'shifted', 'extra-ink', 'knockout', 'protected']) {
      reject({ type: 'reuse-exact-tile', at: [0, 0], tile }, /artwork and protection must match exactly/);
    }
    edit({ type: 'reuse-exact-tile', at: [0, 0], tile: 'match' });
    assert.equal(run('export').data.tilemap.cells[0].tile, 'match');
  });
  return cases;
}

export function sliceReference(original) {
  const { createEditor } = createRequire(import.meta.url)(join(original, 'cli/pixel-art.js'));
  const source = { ...document, slices: [slice] };
  const editor = createEditor(source);
  const options = { frame: 'two' };
  return { source, options, report: editor.slices(options), picture: editor.slice('panel', { frame: 'one' }) };
}

function verify(actual, expected, steps, name) {
  assert.equal(actual.length, expected.length);
  for (let i = 0; i < expected.length; i++) {
    assert.deepEqual(actual[i], expected[i], name + ' step ' + (i + 1) + ' ' + JSON.stringify(steps[i]));
  }
}

async function run([original, native]) {
  const { createPixelCommandEditor } = await import('../web/pixel-document.mjs');
  const { runCommands } = await import('./pixel-commands.mjs');
  const cases = reference(original);
  const scratch = mkdtempSync(join(tmpdir(), 'ink-timeline-assets-'));
  const cli = (bin, args) => {
    const result = spawnSync(bin, args, { cwd: original, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      env: { ...process.env, INK_STUDIO_PORTABLE_SHOT: '1' } });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  try {
    for (const { name, request, replies, timeline } of cases) {
      const target = await createPixelCommandEditor(request.document);
      verify(await runCommands(target, request.steps), replies, request.steps, 'JavaScript ' + name);
      assert.deepEqual(await target.timeline(), timeline);
      if (native) {
        const file = join(scratch, 'journal.json');
        writeFileSync(file, JSON.stringify(request));
        const actual = cli(native, ['journal-document', file]).split('\n').map(JSON.parse);
        verify(actual, replies, request.steps, 'native ' + name);
      }
    }
    const checked = sliceReference(original);
    const editor = await createPixelCommandEditor(checked.source);
    assert.deepEqual(await editor.slices(checked.options), checked.report);
    assert.deepEqual(await editor.slice('panel', { frame: 'one' }), checked.picture);
    if (native) {
      const input = join(scratch, 'source.json');
      const out = join(scratch, 'slice.png'), metadata = join(scratch, 'metadata.json');
      const refOut = join(scratch, 'original.png');
      writeFileSync(input, JSON.stringify(checked.source));
      assert.deepEqual(JSON.parse(cli(native, ['slices', 'inspect', input, '--frame', 'two'])), checked.report);
      cli(native, ['slices', 'export', input, '--slice', 'panel', '--frame', 'one', '--out', out, '--metadata', metadata]);
      const { raster, ...report } = checked.picture;
      assert.deepEqual(JSON.parse(readFileSync(metadata)), report);
      cli(process.execPath, [join(original, 'cli/ink-studio.js'), 'pixel-art', 'slices', 'export', input,
        '--slice', 'panel', '--frame', 'one', '--out', refOut]);
      assert.deepEqual(readFileSync(out), readFileSync(refOut));
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ cases: cases.length, replies: cases.reduce((count, row) => count + row.replies.length, 0),
    sliceReport: true, native: Boolean(native), exactPng: Boolean(native) }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await run(process.argv.slice(2).map(path => resolve(path)));
}
