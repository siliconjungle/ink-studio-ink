import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const format = 'ink-studio/pixel-art';
const mark = (swatch, x, y) => ({ swatch, at: [x, y] });
const edit = (settings = {}) => ({ mode: 'layer', ...settings });
const tag = (id, direction, options = {}) => ({ id, start: 'front', end: 'back', direction, ...options });

export const document = {
  format, version: 2, width: 16, height: 16, pixelAspect: [2, 1],
  palette: { blue: '#234591', red: '#ef2020', white: '#ffffff' },
  layers: [
    { id: 'base', label: 'Base', offset: [1, 0] },
    { id: 'group', kind: 'group', locked: true, opacity: 0.5 },
    { id: 'mask', parent: 'group', kind: 'mask' },
    { id: 'paint', parent: 'group', clip: 'mask' },
    { id: 'hidden', visible: false },
    { id: 'ref', kind: 'reference' },
    { id: 'erase' },
  ],
  frames: [
    { id: 'front', label: 'Opening', durationMs: 100, cels: {
      base: { id: 'root', marks: [mark('blue', 0, 0), mark('blue', 1, 0), mark('blue', 2, 0)] },
      mask: { marks: [mark('white', 1, 0)] },
      paint: { id: 'ink', marks: [mark('red', 1, 0), mark('red', 2, 0), { alpha: 149, runs: [[0, 1, 1]] }] },
      hidden: { marks: [mark('blue', 1, 1)] },
      ref: { marks: [mark('red', 1, 0)] },
      erase: { marks: [{ clear: true, runs: [[0, 3, 1]] }] },
    } },
    { id: 'side', durationMs: 275, cels: {
      base: { id: 'left', label: 'Lean', hold: 'root', offset: [2, 1], opacity: 87 },
      paint: { marks: [] },
    } },
    { id: 'back', durationMs: 41, cels: { base: { hold: 'left', offset: [-1, 2] } } },
  ],
  guides: [
    { id: 'tile', kind: 'grid', at: [-3, -2], step: [4, 4] },
    { id: 'z-axis', kind: 'axis', axis: 'x', at: 5 },
    { id: 'a-axis', kind: 'axis', axis: 'x', at: 5 },
    { id: 'front-pin', kind: 'registration', at: [6.5, 7], frame: 'front' },
    { id: 'side-pin', kind: 'pivot', at: [11, 11], frame: 'side' },
  ],
  tags: [
    { id: 'play', start: 'front', end: 'back' }, tag('rewind', 'reverse', { label: 'Rewind', loop: false }),
    tag('loop', 'ping-pong'), tag('settle', 'ping-pong-reverse', { repeat: 3 }),
    tag('one', 'ping-pong', { start: 'back' }), tag('two', 'ping-pong', { start: 'side' }),
  ],
};

export const requests = [
  ['sample', [1, 0], {}],
  ['sample', [2, 0], {}],
  ['sample', [3, 0], {}],
  ['sample', [15, 15], {}],
  ['sample', [1, 0], edit({ cel: 'ink' })],
  ['sample', [2, 0], edit({ layer: 'paint' })],
  ['sample', [4, 0], edit({ layer: 'paint' })],
  ['sample', [1, 0], edit({ layer: 'ref' })],
  ['sample', [1, 1], edit({ layer: 'hidden' })],
  ['sample', [3, 0], edit({ layer: 'erase' })],
  ['sample', [3, 1], { frame: 'side' }],
  ['sample', [3, 1], edit({ cel: 'left' })],
  ['sample', [1, 2], edit({ frame: 'back', layer: 'base' })],
  ['sample', [1, 1], edit({ frame: 'side', layer: 'paint' })],
  ['sample', [1, 1], edit({ frame: 'back', layer: 'paint' })],
  ['sample', [1, 0], edit({ layer: 'group' })],
  ['sample', [1, 0], edit({ layer: 'unknown' })],
  ['sample', [1, 0], edit({ frame: 'side', cel: 'ink' })],
  ['sample', [1.25, 0], {}],
  ['sample', [1, 0], { layer: 'base' }],
  ['snap', [5.4, 6.2], {}],
  ['snap', [7.1, 7.2], {}],
  ['snap', [7.1, 7.2], { frame: 'side' }],
  ['snap', [10.7, 10.5], { frame: 'side' }],
  ['snap', [7.1, 7.2], { radius: 0.25 }],
  ['snap', [3, 4], { radius: 2 }],
  ['snap', [6.5, 7], { radius: 0 }],
  ['snap', [0.49999999999999994, 14.5], { radius: 0 }],
  ['snap', [-1e100, 1e100], { radius: 32 }],
  ['snap', [1, 2], { radius: -1 }],
  ['snap', [1, 2], { frame: 'missing' }],
  ['timeline'],
];

export async function results(editor) {
  const output = [];
  for (const [name, ...args] of requests) {
    try { output.push({ value: await editor[name](...args) }); }
    catch (error) { output.push({ error: error.message }); }
  }
  return output;
}

export async function reference(original) {
  const { createEditor } = createRequire(import.meta.url)(join(original, 'cli/pixel-art.js'));
  return results(createEditor(document));
}

function flags(point, options = {}) {
  const at = point ? ['--at', point.join(',')] : [];
  return [...at, ...Object.entries(options).flatMap(([key, value]) => ['--' + key, String(value)])];
}

async function run([original, binary]) {
  const { createPixelCommandEditor } = await import('../web/pixel-document.mjs');
  const expected = await reference(original);
  const editor = await createPixelCommandEditor(document);
  const actual = await results(editor);
  assert.equal(expected.filter(row => row.error).length, 7, 'reference error coverage');
  for (let i = 0; i < requests.length; i++) assert.deepEqual(actual[i], expected[i], JSON.stringify(requests[i]));

  const scratch = mkdtempSync(join(tmpdir(), 'ink-session-tools-'));
  try {
    const source = join(scratch, 'source.json'), dir = join(scratch, 'draft');
    writeFileSync(source, JSON.stringify(document));
    const call = (action, ...args) => {
      const result = spawnSync(binary, ['session', action, dir, ...args], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
      assert.equal(result.error, undefined);
      if (result.status !== 0) return { error: result.stderr.trim() };
      return { value: JSON.parse(result.stdout) };
    };
    const initial = call('init', source).value;
    assert.equal(initial.revision, 1);
    for (let i = 0; i < requests.length; i++) {
      const [action, point, options] = requests[i];
      assert.deepEqual(call(action, ...flags(point, options)), expected[i], JSON.stringify(requests[i]));
    }
    assert.equal(call('status').value.revision, initial.revision);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ browserSdkQueries: requests.length, nativeSessionQueries: requests.length }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await run(process.argv.slice(2).map(path => resolve(path)));
}
