import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const dot = (swatch, x, y) => ({ swatch, at: [x, y] });
const span = (swatch, y, x, length) => ({ swatch, runs: [[y, x, length]] });
const tile = (id, durationMs, marks, extra = {}) => ({ id, durationMs, cels: { ink: { marks, ...extra } } });
const road = [span('red', 1, 0, 4), { alpha: 100, runs: [[1, 3, 1]] }, dot('gold', 1, 0)];
export const document = {
  format: 'ink-studio/pixel-art', version: 2, width: 4, height: 3, pixelAspect: [1, 1],
  palette: { red: '#b12721', blue: '#273678', gold: '#efac50' },
  layers: [{ id: 'ink' }, { id: 'hidden', visible: false }],
  frames: [
    tile('road', 100, road),
    tile('junction', 100, road),
    tile('bank', 100, [span('gold', 1, 0, 4)]),
    tile('glow-a', 50, [span('blue', 1, 0, 4), dot('blue', 0, 0)]),
    tile('glow-b', 80, [span('gold', 1, 0, 4), dot('blue', 0, 0)]),
    tile('glow-c', 30, [span('red', 1, 0, 4), dot('red', 3, 2)]),
    { id: 'plain', label: 'Darker road', durationMs: 37, cels: { ink: { marks: [{ swatch: 'red',
      shape: { type: 'rect', rect: [0, 0, 4, 3] } }] } } },
    { id: 'plain-held', durationMs: 37, cels: { ink: { hold: 'plain/ink' } } },
    tile('clear', 41, []),
  ],
  tilemap: {
    version: 1, width: 5, height: 4,
    cells: [
      { at: [4, 3], tile: 'plain' }, { at: [1, 1], tile: 'road' }, { at: [0, 1], tile: 'road' },
      { at: [0, 0], tile: 'bank' }, { at: [2, 1], tile: 'road' }, { at: [2, 0], tile: 'bank' },
      { at: [3, 2], tile: 'clear' },
    ],
    variants: {
      road: { neighbors: { EW: 'junction', E: 'glow-a', none: 'clear' }, connects: ['road'] },
      junction: { animation: { frames: ['glow-a', 'glow-b', 'glow-c'], direction: 'ping-pong' } },
      bank: { animation: { frames: ['glow-a', 'glow-b'], direction: 'reverse', loop: false } },
    },
  },
};

export const requests = [
  ['tilemap', []],
  ['tilemap', [[4, 3]]],
  ['tilemap', [[0, 3]]],
  ['tilemap', [[1, 1]]],
  ['tilemap', [[5, 0]]],
  ...[0, 0.0499999, 0.05, 0.1299999, 0.13, 0.16, 0.24, 9007199254740].map(time =>
    ['tilemapNeighborhood', [[1, 1], { time }]]),
  ['tilemapNeighborhood', [[0, 0], { time: 0.04 }]],
  ['tilemapNeighborhood', [[0, 0], { time: 0.08 }]],
  ['tilemapNeighborhood', [[0, 0], { time: 2 }]],
  ['tilemapNeighborhood', [[4, 3], { time: 0.1 }]],
  ['tilemapNeighborhood', [[0, 3]]],
  ['tilemapNeighborhood', [[-1, 0]]],
  ['tilemapNeighborhood', [[1, 1], { time: -1 }]],
  ['tilemapRaster', []],
  ['tilemapRaster', [{ time: 0.13 }]],
  ['tilemapRaster', [{ time: -1 }]],
  ['tilemapRaster', [{ time: '0.1' }]],
];

function printable(reply) {
  if (reply.raster) return { ...reply, raster: { ...reply.raster, rgba: Array.from(reply.raster.rgba) } };
  if (reply.rgba) return { ...reply, rgba: Array.from(reply.rgba) };
  return reply;
}

export async function replies(editor, calls = requests) {
  const rows = [];
  for (const [name, args] of calls) {
    try { rows.push({ value: printable(await editor[name](...args)) }); }
    catch (error) { rows.push({ error: error.message }); }
  }
  return rows;
}

export function originalEditor(original, source = document) {
  const { createEditor } = createRequire(import.meta.url)(join(original, 'cli/pixel-art.js'));
  return createEditor(source);
}

export function revisions(revision) {
  return [
    { id: 'map-stroke', revision, destination: 'timeline',
      operation: { type: 'place-tiles', points: [[0, 0], [3, 3]], tile: 'plain' } },
    { id: 'map-paint', destination: 'raster', frame: 'plain',
      operation: { tool: 'pencil', layer: 'ink', swatch: 'blue', points: [[1, 1]] } },
  ];
}

export const editedRequests = [['tilemap', [[0, 0]]], ['tilemapRaster', [{ time: 0.13 }]],
  ['tilemapNeighborhood', [[4, 3], { time: 0.13 }]]];
export const largeMap = { ...document, width: 16, height: 16, tilemap: { version: 1, width: 125, height: 125,
  cells: [{ at: [124, 124], tile: 'glow-a' }] } };

const directions = [['N', 0, -1], ['E', 1, 0], ['S', 0, 1], ['W', -1, 0]];
export const maskCases = Array.from({ length: 16 }, (_, bits) => {
  const at = [1 + (bits % 4) * 3, 1 + Math.floor(bits / 4) * 3];
  const linked = directions.filter((side, i) => bits & 1 << i);
  const mask = linked.map(([side]) => side).join('') || 'none';
  const cells = [{ at, tile: 'road' }, ...linked.map(([, dx, dy]) => ({ at: [at[0] + dx, at[1] + dy], tile: 'bank' }))];
  return { at, mask, cells };
});
export const masksMap = { ...document, tilemap: { ...document.tilemap, width: 12, height: 12,
  cells: maskCases.flatMap(row => row.cells),
  variants: { road: { neighbors: Object.fromEntries(maskCases.map(({ mask }) => [mask, 'junction'])), connects: ['bank'] } },
} };

async function run([original, native]) {
  const { createPixelCommandEditor } = await import('../web/pixel-document.mjs');
  const reference = originalEditor(original);
  const editor = await createPixelCommandEditor(document);
  const expected = await replies(reference);
  const actual = await replies(editor);
  for (let i = 0; i < expected.length; i++) assert.deepEqual(actual[i], expected[i], JSON.stringify(requests[i]));
  assert.deepEqual(expected[1].value.exactMatches, ['plain-held']);
  assert.equal(expected[2].value.picked.tile, null);
  assert.deepEqual(expected.slice(5, 13).map(row => row.value.cells[4].frame),
    ['glow-a', 'glow-a', 'glow-b', 'glow-b', 'glow-c', 'glow-b', 'glow-a', 'glow-a']);
  assert.equal(expected[13].value.cells[0].outside, true);
  assert.deepEqual(expected.slice(13, 16).map(row => row.value.cells[4].frame), ['glow-b', 'glow-a', 'glow-a']);
  assert(expected[5].value.seams.some(row => row.color > 0 || row.coverage > 0));

  const [stroke, paint] = revisions(reference.timeline().revision);
  await editor.begin('Tile draft');
  reference.begin('Tile draft');
  for (const patch of [stroke, paint]) {
    const request = { ...patch, revision: reference.timeline().revision };
    assert.deepEqual(await editor.apply(request), reference.apply(request));
  }
  assert.deepEqual(await replies(editor, editedRequests), await replies(reference, editedRequests));
  await editor.commit();
  reference.commit();
  const saved = await editor.snapshot();
  assert.equal(await editor.undo(), true);
  assert.deepEqual(await replies(editor, editedRequests), await replies(originalEditor(original), editedRequests));
  assert.equal(await editor.redo(), true);
  assert.deepEqual(await editor.snapshot(), saved);

  const [largeReference, largePort] = await Promise.all([
    originalEditor(original, largeMap).tilemapRaster(),
    (await createPixelCommandEditor(largeMap)).tilemapRaster(),
  ]);
  assert.deepEqual(largePort, largeReference);
  const maskReference = originalEditor(original, masksMap);
  const maskPort = await createPixelCommandEditor(masksMap);
  for (const { at, mask } of maskCases) {
    const expected = maskReference.tilemapNeighborhood(at);
    assert.equal(expected.cells[4].mask, mask);
    assert.deepEqual(await maskPort.tilemapNeighborhood(at), expected);
  }

  let cliCases = 0;
  if (native) cliCases = compareCli(original, native, saved);
  console.log(JSON.stringify({ sdkQueries: requests.length + editedRequests.length * 2, masks: maskCases.length, maximumRasterPixels: 4000000,
    cliCases, native: Boolean(native) }));
}

function compareCli(original, native, edited) {
  const scratch = mkdtempSync(join(tmpdir(), 'ink-tilemap-render-'));
  const first = join(scratch, 'map.json'), changed = join(scratch, 'edited.json');
  const cli = [process.execPath, join(original, 'cli/ink-studio.js'), 'pixel-art'];
  function run([bin, ...prefix], args) {
    const result = spawnSync(bin, [...prefix, 'tilemap', ...args], { cwd: original, encoding: 'utf8',
      env: { ...process.env, INK_STUDIO_PORTABLE_SHOT: '1' } });
    assert.equal(result.error, undefined);
    return { status: result.status, out: result.stdout ? JSON.parse(result.stdout) : null, error: result.stderr.trim() };
  }
  let counted = 0;
  try {
    writeFileSync(first, JSON.stringify(document));
    writeFileSync(changed, JSON.stringify(edited));
    for (const input of [first, changed]) {
      for (const args of [
        ['inspect', input], ['inspect', input, '--at', '4,3'], ['inspect', input, '--at', '0,3'],
        ['inspect', input, '--at', '5,0'], ['neighbors', input, '--at', '0,0', '--t', '-1'],
        ['neighbors', input, '--at', '0,0', '--t', '0.08'],
      ]) {
        assert.deepEqual(run([native], args), run(cli, args), JSON.stringify(args));
        counted++;
      }
      for (const time of ['0', '0.13', '0.24']) {
        const a = join(scratch, 'original.png'), b = join(scratch, 'ink.png');
        const draw = ['draw', input, '--t', time, '--out'];
        for (const [cmd, path] of [[cli, a], [[native], b]]) assert.equal(run(cmd, [...draw, path]).status, 0);
        assert.deepEqual(readFileSync(b), readFileSync(a), 'PNG at ' + time);
        counted++;
        const neighbor = ['neighbors', input, '--at', '1,1', '--t', time, '--image'];
        assert.deepEqual(run([native], [...neighbor, b]), run(cli, [...neighbor, a]));
        assert.deepEqual(readFileSync(b), readFileSync(a), 'neighbor PNG at ' + time);
        counted++;
      }
    }
    const large = join(scratch, 'large.json'), originalPng = join(scratch, 'large-original.png');
    const nativePng = join(scratch, 'large-ink.png');
    writeFileSync(large, JSON.stringify(largeMap));
    assert.equal(run(cli, ['draw', large, '--out', originalPng]).status, 0);
    assert.equal(run([native], ['draw', large, '--out', nativePng]).status, 0);
    assert.deepEqual(readFileSync(nativePng), readFileSync(originalPng), 'PNG at the full raster budget');
    const masks = join(scratch, 'masks.json');
    writeFileSync(masks, JSON.stringify(masksMap));
    for (const { at } of maskCases) {
      const args = ['neighbors', masks, '--at', at.join(',')];
      assert.deepEqual(run([native], args), run(cli, args), 'mask at ' + at.join(','));
    }
    return counted + 1 + maskCases.length;
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await run(process.argv.slice(2).map(path => resolve(path)));
}
