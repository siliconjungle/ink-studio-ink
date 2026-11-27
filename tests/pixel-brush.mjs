import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelEditor } from '../web/pixel-document.mjs';

export function artwork(extra = {}) {
  return { format: 'ink-studio/pixel-art', version: 2, width: 14, height: 11, pixelAspect: [1, 1],
    palette: { red: '#668888', base: '#273034', blue: '#1d6294', cool: '#1D6294', warm: '#dd9900',
      'brush-cc382d': '#ffffff', 'brush-cc382d-2': '#999999' },
    layers: [{ id: 'ink' }],
    frames: [{ id: 'front', durationMs: 100, cels: { ink: { id: 'ink-cel', marks: [
      { swatch: 'base', runs: [[0, 0, 14], [2, 2, 7], [4, 2, 7], [9, 0, 10]] },
      { swatch: 'blue', runs: [[3, 1, 3], [6, 1, 5]] },
      { swatch: 'red', runs: [[3, 5, 4], [5, 3, 8]] },
      { alpha: 111, runs: [[2, 2, 3], [3, 1, 3], [4, 2, 3]] },
      { alpha: 0, runs: [[5, 6, 2]] },
    ] } } }],
    ramps: [{ id: 'light', swatches: ['red', 'base', 'blue', 'warm'] }], ...extra };
}

export function brushTip(settings = {}, extra = {}) {
  return { format: 'ink-studio/pixel-brush', version: 1, width: 3, height: 2, anchor: [0, 0],
    palette: [{ id: 'red', color: '#CC382D' }, { id: 'cool', color: '#1d6294' }, { color: '#dd710b' }],
    slots: [0, null, 1, 0, 2, null],
    settings: { angle: 0, size: [3, 2], swatch: { mode: 'original' }, ...settings }, ...extra };
}

const single = (settings = {}) => brushTip(settings, { width: 1, height: 1, anchor: [0, 0],
  palette: [{ id: 'red', color: '#CC382D' }], slots: [0],
  settings: { angle: 0, size: [1, 1], swatch: { mode: 'original' }, ...settings } });

const original = root => createRequire(import.meta.url)(resolve(root, 'cli/pixel-art.js')).createEditor;
const operation = (brush, placement, extra) => ({ tool: 'brush', layer: 'ink', brush, ...placement, ...extra });

export function brushCases(originalRoot) {
  const create = original(originalRoot);
  const fixtures = [];
  const base = artwork();
  function add(label, tip, placement, extra = {}, document = base, scope = { frame: 'front' }) {
    const op = operation(tip, placement, extra);
    if (scope.cel && !Object.hasOwn(extra, 'layer')) delete op.layer;
    const request = { document, operation: op, ...scope };
    const editor = create(document);
    const patch = { id: 'brush-test', revision: editor.describe().revision, operation: op, ...scope };
    const preview = editor.previewEdit(patch);
    fixtures.push(preview.valid ? { label, request, expected: { target: preview.targets[0], document: editor.apply(patch) } }
      : { label, request, error: preview.conflicts[0].message });
  }
  const angles = [-360000, -720, -180, -90, -32.5, -30, 0, 10, 15, 30, 32, 45, 59.75, 60, 75, 89.5, 90,
    120, 135, 150, 179, 180, 210, 225, 240, 270, 300, 315, 330, 360, 359999];
  for (const angle of angles) for (const size of [[1, 1], [2, 2], [4, 3], [6, 4], [8, 8]]) {
    add('rotated tip', brushTip({ angle, size }), { at: [6, 6] });
    add('wrapped reflected tip', brushTip({ angle, size }, { anchor: [2, 1] }),
      { points: [[-3, 5], [0, 9], [16, 13], [-4, 5]] },
      { drawing: { wrapX: true, wrapY: true, mirrorX: 3.5, mirrorY: 0 } });
  }
  add('existing exact ID beats duplicate RGB', brushTip(), { at: [7, 7] });
  add('explicit override', brushTip({ angle: 90 }), { at: [7, 7] }, { swatch: 'warm' });
  add('named tint and lowercase serialization', brushTip({ swatch: { mode: 'tint', id: 'teal', color: '#00FBAC' } }),
    { points: [[0, 0], [13, 10], [0, 10]] });
  add('untouched palette slots', brushTip({}, { slots: [0, 0, 0, null, null, null] }), { at: [7, 7] });
  add('tip only hits outside the canvas', brushTip({ angle: 180 }, { anchor: [0, 0], slots: [null, null, 0, null, 1, null] }),
    { at: [0, 0] });
  add('empty selection', brushTip(), { points: [[0, 3], [13, 3]] }, { selection: 'none' },
    { ...base, selections: [{ id: 'none', pixels: [] }] });
  add('selection and protected point', brushTip(), { points: [[0, 2], [13, 2]] }, { selection: 'part' },
    { ...base, selections: [{ id: 'part', pixels: [[4, 2], [6, 3], [9, 4]] }],
      protectedDetails: [{ id: 'safe', pixels: [[1, 2]] }] });
  add('blocked protection', brushTip(), { points: [[0, 2], [13, 2]] }, {},
    { ...base, protectedDetails: [{ id: 'safe', pixels: [[1, 2]] }] });

  const limited = artwork({ layers: [{ id: 'mask', kind: 'mask' }, { id: 'ink', clip: 'mask' }],
    frames: [{ id: 'front', durationMs: 100, cels: { mask: { marks: [{ swatch: 'red', runs: [[1, 1, 9], [2, 1, 4]] }] },
      ink: { id: 'ink-cel', marks: [] } } }] });
  add('successful clipped-layer edit', single(), { at: [4, 2] }, {}, limited, { cel: 'ink-cel' });
  add('blocked clipping', brushTip(), { at: [5, 2] }, {}, limited, { cel: 'ink-cel' });

  const hold = artwork({ frames: [...base.frames, { id: 'back', durationMs: 100, cels: {
    ink: { id: 'held', hold: 'ink-cel', offset: [1, 1] },
  } }] });
  add('detached held brush mark', brushTip({ angle: 90 }), { at: [6, 6] }, {}, hold, { cel: 'held' });
  add('detached held alpha mark', single(), { at: [5, 4] }, { shading: { mode: 'alpha', value: 0 } },
    hold, { cel: 'held' });
  add('dependent held protection', brushTip(), { at: [0, 3] }, {}, {
    ...hold, protectedDetails: [{ id: 'pin', frame: 'back', pixels: [[1, 4]] }],
  });

  for (const shading of [{ mode: 'recolor' }, { mode: 'alpha', value: 0 }, { mode: 'alpha', value: 111 },
    { mode: 'alpha', value: 255 }, { mode: 'ramp', ramp: ['red', 'base', 'blue'], step: -1 },
    { mode: 'ramp', ramp: 'light', step: 1 }, { mode: 'ramp', ramp: 'light', step: 254 }]) {
    const path = { points: [[0, 2], [13, 5], [0, 2], [13, 5], [9, 7]] };
    add('overlapping shading', brushTip({ angle: 20, size: [9, 5] }), path, { shading });
    if (shading.mode === 'recolor') add('override recolor', brushTip(), path, { shading, swatch: 'warm' });
  }
  add('shade ignores protected transparent cells', single(), { points: [[0, 2], [8, 2]] },
    { shading: { mode: 'recolor' }, swatch: 'warm' }, {
      ...base, protectedDetails: [{ id: 'air', kind: 'gap', pixels: [[0, 2]] }],
    });

  const samples = [{ at: [1.5, 3.49], pressure: 0, time: 0 }, { at: [4.49, 9], pressure: .33, time: 10 },
    { at: [9.5, 3.5], pressure: 1, time: 20 }, { at: [2.5, 8.5], pressure: .2, time: 60 },
    { at: [2.5, 8.5], pressure: .31, time: 60 }, { at: [13.5, 10.5], pressure: .7, time: 61.01 }];
  for (const stabilize of [0, .1, 20, 100, 500]) for (const [pres, velocity] of
    [[[1, 1], undefined], [[.2, 1], { speed: 100, size: [1, .2] }],
      [[3, 0], { speed: 250, size: [0, 2] }], [[.9, 4], { speed: 10000, size: [4, .01] }]]) {
    const b = brushTip({ size: [5, 4], angle: 32, dynamics: { stabilization: stabilize, pressure: pres, ...(velocity && { velocity }) } });
    add('sampled size and release', b, { samples });
    add('sampled wrapping', b, { samples: samples.map(row => ({ ...row, at: [row.at[0] - 9, row.at[1] + 3] })) },
      { drawing: { wrapX: true, wrapY: true, mirrorY: 5.5 } });
    add('same-time velocity', b, { samples: samples.slice(0, 2).map(row => ({ ...row, time: 100 })) });
  }
  add('4096 overlapping samples', single({ dynamics: { stabilization: 50 } }),
    { samples: Array.from({ length: 4096 }, (_, time) => ({ at: [3.5, 4.5], time, pressure: 1 })) });

  for (const [tag, tip] of [['null brush', null], ['unknown brush field', brushTip({}, { opaque: true })],
    ['invalid anchor', brushTip({}, { anchor: [3, 2] })], ['bad color', brushTip({}, { palette: [{ color: '#badhex' }] })],
    ['empty tip', brushTip({}, { slots: Array(6).fill(null) })], ['bad slot', brushTip({}, { slots: [0, 8, 1, 0, null, 2] })],
    ['bad ID', brushTip({}, { palette: [{ id: 'BRIGHT', color: '#00ffaa' }] })], ['bad size', brushTip({ size: [0, 1] })],
    ['bad angle', brushTip({ angle: 360001 })], ['bad tint', brushTip({ swatch: { mode: 'original', color: '#00ffaa' } })],
    ['bad velocity', brushTip({ dynamics: { velocity: { speed: 0, size: [1, 1] } } })],
    ['bad stabilization', brushTip({ dynamics: { stabilization: -1 } })], ['bad pressure scales', brushTip({ dynamics: { pressure: [-1, 1] } })],
  ]) add(tag, tip, { at: [0, 0] });
  for (const [tag, placement] of [['no points', {}], ['out of bounds', { at: [-1, 0] }],
    ['at and path', { at: [1, 1], points: [[1, 1]] }], ['invalid samples', { samples: null }],
    ['missing samples', { samples: [] }], ['out of order', { samples: [samples[1], samples[0]] }],
    ['pressure above bounds', { samples: [{ ...samples[0], pressure: 1.01 }] }],
    ['fractional neighbor out of bounds', { samples: [{ ...samples[0], at: [13.500001, 0] }] }],
    ['samples and path', { samples, points: [[1, 1]] }], ['samples and at', { samples, at: [1, 1] }],
  ]) add(tag, brushTip(), placement);
  for (const shading of [null, {}, { mode: 'ramp', step: 0, ramp: 'light' }, { mode: 'ramp', step: 1, ramp: 'missing' },
    { mode: 'ramp', step: 1, ramp: ['red', 'red'] }, { mode: 'ramp', step: 1, ramp: ['ghost', 'red'] },
    { mode: 'alpha', value: -1 }, { mode: 'recolor', alpha: 123 }]) {
    add('invalid shading', single(), { at: [1, 2] }, { shading });
  }
  add('invalid shading with override', single(), { at: [1, 1] }, { shading: { mode: 'alpha', value: 2 }, swatch: 'red' });
  add('invalid swatch override', single(), { at: [1, 1] }, { swatch: 'ghost' });
  const fullPalette = Object.fromEntries(Array.from({ length: 255 }, (_, i) => ['color-' + i, '#121212']));
  const fullSource = artwork({ palette: fullPalette, ramps: [], frames: [{ id: 'front', durationMs: 100, cels: {} }] });
  add('palette full', brushTip(), { at: [1, 1] }, {}, fullSource);
  add('palette full with override', brushTip(), { at: [1, 1] }, { swatch: 'color-0' }, fullSource);
  const blank = artwork({ width: 64, height: 64, frames: [{ id: 'front', durationMs: 100, cels: {} }] });
  add('large tip', single({ size: [512, 512] }), { at: [0, 0] }, {}, blank);
  const dense = { ...single({ size: [40, 38] }), width: 512, height: 512, anchor: [255, 255],
    slots: Array.from({ length: 512 * 512 }, (_, i) => i % 9 === 0 ? null : 0) };
  add('512 × 512 saved tip', dense, { at: [31, 31] }, {}, blank);
  add('static stroke pixel budget', single({ size: [512, 512] }), { points: [[0, 1], [40, 1]] }, {}, blank);

  let seed = 191227;
  const random = max => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) >>> 6) % max;
  for (let i = 0; i < 100; i++) {
    const dynamic = i % 2 === 0;
    const d = { wrapX: i % 2 === 1, wrapY: i % 3 === 1, mirrorX: random(27) / 2, mirrorY: random(21) / 2 };
    const point = () => [random(d.wrapX ? 42 : 14) - (d.wrapX ? 14 : 0),
      random(d.wrapY ? 33 : 11) - (d.wrapY ? 11 : 0)];
    const path = Array.from({ length: 2 + random(5) }, point);
    const placement = dynamic ? { samples: path.map((pos, j) => ({ at: pos.map(n => n - random(5) / 10),
      time: j * (i + 1), pressure: random(101) / 100 })) } : { points: path };
    add(dynamic ? 'sampled seeded path' : 'static seeded path',
      brushTip({ angle: (random(14401) - 7200) / 10, size: [1 + random(20), 1 + random(20)],
        dynamics: { stabilization: random(501), pressure: [.1, 2], velocity: { speed: 251, size: [1, .4] } } }),
      placement, { drawing: d });
  }
  return fixtures;
}

export function captureCases(originalRoot) {
  const create = original(originalRoot);
  const fixtures = [];
  const base = artwork();
  const add = (label, options, document = base) => {
    const editor = create(document);
    try {
      fixtures.push({ label, document, options, expected: editor.captureBrush(options) });
    } catch (error) {
      fixtures.push({ label, document, options, error: error.message });
    }
  };
  const selection = [{ id: 'pick', frame: 'front', pixels: [[5, 4], [2, 2], [0, 0], [7, 1], [6, 5]] },
    { id: 'empty', pixels: [] }, { id: 'masked', frame: 'back', pixels: [[5, 4], [2, 2], [1, 0]] }];
  const stack = {
    ...base,
    layers: [{ id: 'under' }, { id: 'ink', opacity: .7, blend: 'screen' }, { id: 'hidden', visible: false }],
    frames: [{ ...base.frames[0], cels: { ...base.frames[0].cels,
      under: { id: 'under-cel', marks: [{ swatch: 'warm', shape: { type: 'rect', rect: [0, 0, 9, 8] } }] },
      hidden: { marks: [{ swatch: 'base', runs: [[0, 2, 4], [4, 1, 2]] }] },
    } }, { id: 'back', durationMs: 100, cels: {
      ink: { id: 'held', hold: 'ink-cel', offset: [2, 1] },
      under: { marks: [{ swatch: 'red', shape: { type: 'rect', rect: [0, 0, 8, 9] } }] },
    } }],
    selections: selection,
  };
  for (const options of [
    { rect: [0, 0, 14, 11] }, { rect: [0, 0, 5, 6], layer: 'ink' }, { rect: [3, 1, 5, 5], cel: 'ink-cel' },
    { rect: [3, 1, 5, 5], cel: 'held', settings: { angle: 32, size: [14, 11] } },
    { rect: [2, 0, 2, 3], layer: 'hidden' }, { rect: [3, 1, 5, 5], frame: 'back' },
    { pixels: [[2, 3], [9, 2], [3, 1], [3, 0], [2, 2]] },
    { pixels: [[7, 3], [2, 3], [4, 2], [0, 0]], anchor: [1, 1], layer: 'ink' },
    { pixels: [[7, 3], [2, 3], [4, 2], [0, 0]], anchor: null, layer: 'ink' },
    { selection: 'pick' }, { selection: 'pick', layer: 'ink' }, { selection: 'pick', cel: 'ink-cel' },
    { selection: 'masked' }, { selection: 'masked', cel: 'held' },
    { rect: [5, 4, 6, 3], layer: 'ink', settings: { angle: -123.5, size: [3, 2],
      swatch: { mode: 'tint', id: 'gold', color: '#EDC426' }, dynamics: { pressure: [.2, 3],
        stabilization: 125, velocity: { speed: 40, size: [1, .6] } } } },
    { rect: [0, 0, 3, 1], settings: {} }, { rect: [0, 0, 3, 1], settings: null },
    { rect: [0, 0, 3, 1], settings: false }, { rect: [0, 0, 3, 1], settings: [] },
  ]) add('original brush capture', options, stack);

  for (const options of [{}, { rect: [0, 0, 1, 1], pixels: [[0, 0]] },
    { rect: [0, 0, 1, 1], layer: 'ink', cel: 'ink-cel' }, { rect: [14, 0, 1, 1] },
    { rect: [0, 0, 15, 1] }, { rect: [0, 0, 0, 1] }, { rect: [0, 0, 1, 1, 2] },
    { rect: [-1, 1, 1, 1] }, { rect: [0, 0, 5, null] },
    { pixels: [] }, { pixels: [[-1, 0]] }, { pixels: [[1, 1], [1, 1]] }, { pixels: [[1.5, 1]] },
    { selection: 'empty' }, { selection: 'unknown' }, { selection: 'pick', frame: 'back' },
    { selection: 'pick', cel: 'held' }, { rect: [0, 0, 1, 1], frame: 'unknown' },
    { rect: [0, 0, 1, 1], frame: 'back', cel: 'ink-cel' }, { rect: [0, 0, 1, 1], layer: 'missing' },
    { rect: [13, 10, 1, 1] }, { rect: [0, 0, 1, 1], anchor: [1, 0] }, { rect: [0, 0, 1, 1], anchor: [0, .5] },
    { rect: [0, 0, 1, 1], settings: { angle: '90' } }, { rect: [0, 0, 1, 1], settings: { size: [513, 1] } },
    { rect: [0, 0, 1, 1], settings: ['invalid'] }, { rect: [0, 0, 1, 1], settings: 'invalid' },
    { rect: [0, 0, 1, 1], settings: { dynamics: null } },
    { rect: [0, 0, 1, 1], settings: { swatch: { mode: 'tint', color: 'ffddee' } } },
  ]) add('capture rejects invalid input', options, stack);

  const clipped = artwork({ layers: [{ id: 'mask', kind: 'mask' }, { id: 'ink', clip: 'mask' }],
    frames: [{ ...base.frames[0], cels: { ...base.frames[0].cels,
      mask: { marks: [{ swatch: 'red', runs: [[0, 2, 1], [3, 5, 1]] }] },
    } }] });
  add('raw layer capture preserves unclipped pigment', { rect: [0, 0, 8, 6], layer: 'ink' }, clipped);
  add('composite capture observes the clip mask', { rect: [0, 0, 8, 6] }, clipped);
  const dense = artwork({ width: 512, height: 512,
    frames: [{ id: 'front', durationMs: 100, cels: {
      ink: { marks: [{ swatch: 'red', shape: { type: 'rect', rect: [0, 0, 512, 512] } }] },
    } }] });
  add('full canvas rectangle', { rect: [0, 0, 512, 512] }, dense);
  add('full literal selection', { pixels: Array.from({ length: 512 * 512 }, (_, i) => [i % 512, Math.floor(i / 512)]) }, dense);
  return fixtures;
}


export function brushSequence(originalRoot) {
  const document = artwork();
  const originalEditor = original(originalRoot)(document);
  const scope = { frame: 'front', layer: 'ink' };
  const id = 'blue';
  const query = { type: 'swatch', id };
  const steps = [
    operation(single(), { at: [2, 3] }, { shading: { mode: 'alpha', value: 0 } }),
    operation(brushTip(), { at: [6, 6] }),
    operation(single(), { at: [2, 3] }, { shading: { mode: 'alpha', value: 255 } }),
    operation(single(), { points: [[0, 2], [9, 4]] }, { shading: { mode: 'ramp', ramp: 'light', step: -1 } }),
  ].map(op => {
    const patch = { id: 'brush-sequence', revision: originalEditor.describe().revision, frame: 'front', operation: op };
    const target = originalEditor.previewEdit(patch).targets[0];
    const saved = originalEditor.apply(patch);
    return { operation: op, target, document: saved, pixels: originalEditor.select(query, scope).pixels };
  });
  return { document, query, scope, steps };
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length < 4) throw new Error('Usage: node tests/pixel-brush.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  const fixtures = brushCases(process.argv[2]);
  const dir = mkdtempSync(join(tmpdir(), 'ink-brush-'));
  try {
    const file = join(dir, 'request.json');
    for (const [i, { label, request, expected, error }] of fixtures.entries()) {
      const { document, operation, ...scope } = request;
      const editor = createPixelEditor(document);
      const title = 'brush case ' + i + ' ' + label;
      if (error) {
        const initial = JSON.stringify(editor.snapshot());
        assert.throws(() => editor.paint(operation, scope), { message: error }, title);
        assert.equal(JSON.stringify(editor.snapshot()), initial, title);
      } else {
        assert.deepEqual(editor.paint(operation, scope), expected.target, title);
        assert.equal(JSON.stringify(editor.snapshot()), JSON.stringify(expected.document), title);
      }
      if (process.argv[3] === '--javascript') continue;
      writeFileSync(file, JSON.stringify(request));
      const native = spawnSync(process.argv[3], ['paint-document', file], { encoding: 'utf8', maxBuffer: 4 << 20 });
      if (native.error) throw native.error;
      assert.equal(native.status, error ? 1 : 0, native.stderr || title);
      if (error) assert.equal(native.stderr.replace(/\r?\n$/, ''), error, title);
      else {
        const result = JSON.parse(native.stdout);
        assert.deepEqual(result.target, expected.target, 'native ' + title);
        assert.equal(JSON.stringify(result.document), JSON.stringify(expected.document), 'native ' + title);
      }
    }
    const captures = captureCases(process.argv[2]);
    for (const [i, { label, document, options, expected, error }] of captures.entries()) {
      const title = 'capture case ' + i + ' ' + label + ' ' + JSON.stringify(options).slice(0, 220);
      const editor = createPixelEditor(document);
      if (error) assert.throws(() => editor.captureBrush(options), { message: error }, title);
      else assert.equal(JSON.stringify(editor.captureBrush(options)), JSON.stringify(expected), title);
      assert.equal(JSON.stringify(editor.snapshot()), JSON.stringify(document), title);
      if (process.argv[3] === '--javascript') continue;
      writeFileSync(file, JSON.stringify({ document, options }));
      const native = spawnSync(process.argv[3], ['capture-brush-document', file], { encoding: 'utf8', maxBuffer: 4 << 20 });
      if (native.error) throw native.error;
      assert.equal(native.status, error ? 1 : 0, native.stderr || title);
      if (error) assert.equal(native.stderr.replace(/\r?\n$/, ''), error, title);
      else assert.equal(native.stdout.trimEnd(), JSON.stringify(expected), title);
    }
    console.log('Matched ' + captures.length + ' original brush captures (' + captures.filter(row => row.error).length + ' rejections).');
    const sequence = brushSequence(process.argv[2]);
    const editor = createPixelEditor(sequence.document);
    for (const step of sequence.steps) {
      assert.deepEqual(editor.paint(step.operation, { frame: sequence.scope.frame }), step.target);
      assert.equal(JSON.stringify(editor.snapshot()), JSON.stringify(step.document));
      assert.deepEqual(editor.select(sequence.query, sequence.scope).pixels, step.pixels);
      assert.deepEqual(createPixelEditor(editor.snapshot()).select(sequence.query, sequence.scope).pixels, step.pixels);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  console.log('Matched ' + fixtures.length + ' original brush operations (' + fixtures.filter(row => row.error).length + ' rejections) and retained sequence.');
}

