import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelEditor } from '../web/pixel-document.mjs';
import { denseFixture, fixture } from './pixel-color-edits.mjs';

const oracle = root => createRequire(import.meta.url)(resolve(root, 'cli/pixel-art.js')).createEditor;
const front = { frame: 'front' };
const copySource = { selection: 'badge', layer: 'ink' };
const move = (transform, extra = {}) => ({
  tool: 'transform', layer: 'ink', selection: 'badge', resultSelection: 'landed', transform, ...extra,
});
const paste = (clipboard, transform, extra = {}) => ({
  tool: 'paste', layer: 'ink', clipboard, resultSelection: 'pasted', transform, ...extra,
});
const badge = { id: 'badge', frame: 'front', pixels: [[4, 0], [0, 0], [1, 0], [5, 0], [6, 0], [3, 0], [0, 1], [6, 2]] };

function revisionPatch(editor, operation, scope, index) {
  return { id: 'transform-' + index, revision: editor.describe().revision, operation, ...scope };
}

export function transformCases(root, { large = true } = {}) {
  const create = oracle(root);
  const base = fixture({ selections: [badge, { id: 'empty', pixels: [] },
    { id: 'rear', frame: 'back', pixels: [[1, 1], [3, 1], [5, 1], [1, 3]] },
  ] });
  const source = create(base).copySelection(copySource);
  const rows = [];
  function edit(label, operation, document = base, scope = front) {
    const editor = create(document);
    const patch = revisionPatch(editor, operation, Object.keys(scope).length ? scope : front, rows.length);
    const preview = editor.previewEdit(patch);
    rows.push({ label, command: 'paint-document', request: { document, operation, ...scope },
      ...(preview.valid ? { expected: { target: preview.targets[0], document: editor.apply(patch) } }
        : { error: preview.conflicts[0].message }) });
  }
  function copy(label, options, document = base) {
    const row = { label, command: 'copy-selection-document', request: { document, options } };
    try {
      row.expected = create(document).copySelection(options);
    } catch (error) {
      row.error = error.message;
    }
    rows.push(row);
  }

  copy('sparse bounds, raw alpha, transparent mask sites, knockout, RGB aliases', copySource);
  copy('same clipboard from explicit cel', { selection: 'badge', cel: 'source', frame: 'front' });
  copy('clip resolves a held cel and its placement', { selection: 'rear', cel: 'held' });
  copy('painted slots without an alpha lane', copySource, fixture({
    selections: [{ ...badge, pixels: [[0, 0], [1, 0], [3, 0], [4, 0]] }],
  }));
  for (const options of [{}, { ...copySource, cel: 'source' }, { ...copySource, layer: 'missing' },
    { selection: 'empty', layer: 'ink' }, { selection: 'unknown', layer: 'ink' },
    { ...copySource, frame: 'back' }, { ...copySource, frame: 'missing' },
    { selection: 'rear', cel: 'source' }, { selection: 'badge', cel: 'missing' },
    { selection: 'badge', layer: null }, { layer: 'missing' },
  ]) copy('copy scope diagnostic', options);

  const booleanId = { ...base, selections: [{ ...badge, id: 'true' }] };
  copy('non-string selection cannot resolve a namesake ID', { selection: true, layer: 'ink' }, booleanId);
  copy('null frame defaults to active frame for unscoped selections', { ...copySource, frame: null },
    { ...base, selections: [{ ...badge, frame: undefined }] });
  copy('reject null cel with no chosen frame', { selection: 'badge', cel: null },
    { ...base, selections: [{ ...badge, frame: undefined }] });
  edit('non-string selection cannot resolve a namesake ID', move({}, { selection: true }), booleanId);

  edit('move overlaps source, carries alpha bytes, clears old knockout, writes new knockout', move({ offset: [1, 0] }));
  edit('partially clipped, transparent cells count toward footprint', move({ at: [-2, -1] }));
  edit('fully clipped copy still saves empty selection and retains authored raster', move({ at: [-4096, 4096] }, { mode: 'copy' }));
  edit('no-op saves the transformed mask', move({}));
  edit('default transform settings', move(undefined, { mode: 'copy' }));
  edit('cel offset and inherited marks materialize locally', move({ offset: [1, 1] }, { selection: 'rear', layer: undefined }), base, { cel: 'held' });
  edit('result mask replaces original row without moving row order', move({ at: [2, 1], flipX: true }, { resultSelection: 'badge' }));
  edit('result mask can be omitted from report', move({ at: [2, 2] }, { resultSelection: undefined }));
  edit('copy an empty selection rejected', move({}, { selection: 'empty' }));
  edit('move with absent selection rejected', move({}, { selection: undefined }));
  edit('move from another frame rejected', move({}, { selection: 'rear' }));
  edit('frame-less patch still targets the default frame', move({ at: [1, 1] }), base, {});
  edit('locked layer rejects whole operation', move({ offset: [1, 0] }),
    { ...base, layers: [{ id: 'ink', locked: true }] });

  const isolated = { ...base, palette: {
    brass: '#556677', accent: '#ccddee', 'brass-cb4519': '#111111', 'brass-cb4519-2': '#CB4519',
    'brush-212831': '#aabbcc',
  }, frames: [{ ...base.frames[0], cels: {} }], selections: [] };
  edit('v2 can reuse a suffixed ID and create multiple RGB aliases', paste(source, { at: [1, 2] }), isolated);
  edit('v1 uses compatible RGB before creating aliases', paste({ ...source, version: 1 }, { at: [1, 2] }), isolated);
  edit('palette insertion orders used clip entries and ignores all clipped colors', paste(source, { at: [9, 6] }), isolated);
  const unnamed = { ...source, palette: source.palette.map(({ color }) => ({ color })) };
  edit('unnamed clipboard uses stable RGB names and suffix for unrelated color', paste(unnamed, { at: [1, 1] }), isolated);
  edit('full palette still supports compatible colors', paste({ ...source, version: 1 }, {}),
    { ...isolated, palette: Object.fromEntries(Array.from({ length: 255 }, (_, i) =>
      ['color-' + i, source.palette[i % source.palette.length].color])) });
  edit('palette limit rejects new aliases', paste(source, {}),
    { ...isolated, palette: Object.fromEntries(Array.from({ length: 255 }, (_, i) => ['color-' + i, '#222222'])) });

  for (const settings of [null, [], 3, { bad: true }, { at: [0, 0], offset: [0, 0] }, { at: [4097, 0] },
    { at: [-4097, 0] }, { at: [.5, 0] }, { size: [1, 0] }, { size: [1, 513] },
    { size: null }, { angle: 360001 }, { angle: '0' }, { angle: null }, { flipX: 1 },
    { flipY: null }, { rotation: 'antialias' }]) edit('reject invalid geometry', move(settings));
  for (const extra of [{ extra: true }, { mode: 'draw' }, { mode: 'copy', carryProtection: true },
    { carryProtection: null }, { resultSelection: null }, { resultSelection: 'BAD' }]) edit('reject invalid selection operation', move({}, extra));
  for (const clip of [null, [], { ...source, version: 0 }, { ...source, origin: [512, 2] },
    { ...source, width: 0 }, { ...source, height: 513 }, { ...source, palette: '#fff' },
    { ...source, slots: null }, { ...source, alpha: null }, { ...source, alpha: [0] },
    { ...source, palette: source.palette.map(row => ({ ...row, id: null })) },
    { ...source, slots: source.slots.map(() => null) }, { ...source, slots: source.slots.map(() => -3) },
    { ...source, slots: source.slots.map(() => source.palette.length) },
    { ...source, alpha: source.alpha.map(() => -1) },
    { ...source, alpha: source.alpha.map(() => '255') },
  ]) edit('reject invalid clipboard input', paste(clip, {}));

  const lock = (id, kind, pixels, scope = front) => ({ id, kind, ...scope, pixels });
  const protectedFixture = details => ({ ...base, protectedDetails: details });
  const tint = lock('pigment', 'accent', [[0, 0], [1, 0]]);
  const gap = lock('negative-space', 'gap', [[3, 0]]);
  const carry = { carryProtection: true };
  edit('carry pigment and a transparent gap through a flip', move({ at: [2, 4], flipX: true }, carry),
    protectedFixture([tint, gap]));
  edit('carry and enlarge an entire lock', move({ at: [0, 3], size: [10, 3] }, carry),
    protectedFixture([lock('single', 'pixel', [[0, 0]])]));
  edit('carried lock with unchanged raster leaves original marks alone', move({}, carry), protectedFixture([gap]));
  edit('no carry requested rejects moving protected source', move({ at: [2, 4] }), protectedFixture([tint]));
  edit('cannot carry a partially selected lock', move({ at: [2, 4] }, carry),
    protectedFixture([lock('partial', 'accent', [[0, 0], [2, 0]])]));
  edit('cannot carry a global lock', move({ at: [2, 4] }, carry),
    protectedFixture([lock('global', 'accent', [[0, 0]], {})]));
  edit('cannot carry a lock with a one-frame span', move({ at: [2, 4] }, carry),
    protectedFixture([lock('range', 'accent', [[0, 0]], { frames: ['front', 'front'] })]));
  edit('cannot carry an unnamed-kind frame lock', move({ at: [2, 4] }, carry),
    protectedFixture([{ id: 'old-lock', frame: 'front', pixels: [[0, 0]] }]));
  edit('clipping can discard a protected sample', move({ at: [-1, 0] }, carry), protectedFixture([tint]));
  edit('downsampling can discard a protected sample', move({ at: [1, 4], size: [1, 1] }, carry), protectedFixture([tint]));
  edit('would change a carried gap over existing art', move({ at: [2, 0] }, carry), protectedFixture([gap]));
  edit('other locks still guard newly written destination', move({ at: [2, 4] }, carry),
    protectedFixture([tint, lock('remain', 'pixel', [[2, 4]])]));
  edit('carrying current lock still checks dependent held frames', move({ at: [2, 4] }, carry),
    protectedFixture([tint, lock('held-pigment', 'contour', [[1, 1]], { frame: 'back' })]));
  const clipped = { ...base, layers: [{ id: 'mask', kind: 'mask' }, { id: 'ink', clip: 'mask' }],
    frames: [{ ...base.frames[0], cels: { ...base.frames[0].cels, mask: {
      marks: [{ swatch: 'brass', runs: [[0, 0, 3]] }],
    } } }, base.frames[1]] };
  edit('clipped target rejects actual edits', move({ at: [2, 2] }, { mode: 'copy' }), clipped);
  copy('copy includes raw pixels outside clip mask', copySource, clipped);

  let seed = 47031;
  const random = max => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) >>> 5) % max;
  const palette = source.palette.concat([{ id: 'sky', color: '#738da7' }]);
  const turns = [0, -90, 90, 180, 270, 360000, -360000, 15, 30, -30, 45, -45, 60, 120, 135, 210, 225, 240, 300, 315, 359.5, 19.25];
  for (const [i, angle] of turns.entries()) {
    for (const rotation of ['nearest', 'pixel-aware']) {
      edit('geometry regression ' + angle + ' ' + rotation, move({ at: [0, 0], angle, rotation,
        ...(i % 3 === 0 && { size: [4, 6] }), flipX: i % 2 === 0, flipY: i % 4 === 0 },
      { mode: i % 3 ? 'copy' : 'move' }));
    }
  }
  for (let i = 0; i < 83; i++) {
    const width = 1 + random(9), height = 1 + random(7);
    const slots = Array.from({ length: width * height }, () => [null, -2, -1, 0, 1, 2, 3][random(7)]);
    slots[0] = random(4);
    const alpha = slots.map(() => [0, 1, 92, 251, 255][random(5)]);
    const settings = { at: [random(9) - 2, random(7) - 2], size: [1 + random(11), 1 + random(8)],
      angle: turns[random(turns.length)], flipX: !!random(2), flipY: !!random(2),
      rotation: random(2) ? 'pixel-aware' : 'nearest' };
    edit('seeded paste with a typed clipboard', paste({ ...source, version: 1 + random(2), width, height,
      palette, slots, alpha }, settings));
  }
  if (large) {
    const width = 512, height = 512;
    const slots = Array.from({ length: width * height }, (_, p) =>
      [0, 1, -2, -1, null, 2, 0, 3][(p >>> 6) & 7]);
    const alpha = slots.map((_, p) => [0, 128, 255, 255, 255, 23, 255, 255][(p >>> 6) & 7]);
    const clipboard = { ...source, width, height, palette, slots, alpha };
    const pixels = Array.from({ length: width * height }, (_, i) => [i % width, Math.floor(i / width)]);
    copy('copy index and opacity planes from a full native selection', copySource, { ...denseFixture(),
      selections: [{ ...badge, pixels }],
      frames: [{ id: 'front', durationMs: 100, cels: { ink: { marks: [
        { swatch: 'accent', shape: { type: 'rect', rect: [0, 0, 512, 470] } },
        { alpha: 0, runs: [[0, 0, 512], [511, 0, 512]] },
        { swatch: null, shape: { type: 'rect', rect: [0, 10, 512, 1] } },
      ] } } }],
    });
    edit('complete 512 × 512 slot and alpha planes with a saved result selection',
      paste(clipboard, { flipY: true }), denseFixture());
  }
  return rows;
}

export function transformSequence(root) {
  const document = fixture({ selections: [badge] });
  const editor = oracle(root)(document);
  const initial = editor.copySelection(copySource);
  const operations = [
    move({ offset: [1, 1] }),
    move({ at: [2, 3], angle: -90 }, { mode: 'copy', selection: 'landed', resultSelection: 'stamp' }),
    paste(initial, { at: [-1, 4], flipX: true }),
    move({ at: [0, 0] }, { selection: 'pasted', resultSelection: 'badge' }),
    paste(initial, { at: [-10, -10] }, { resultSelection: 'unused' }),
    move({}, { selection: 'unused' }),
  ];
  return { document, steps: operations.map((operation, i) => {
    const patch = revisionPatch(editor, operation, front, i);
    const preview = editor.previewEdit(patch);
    if (!preview.valid) return { operation, error: preview.conflicts[0].message };
    const next = editor.apply(patch);
    return { operation, target: preview.targets[0], document: next, clipboard: editor.copySelection(copySource) };
  }) };
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-transforms.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  const original = process.argv[2];
  const cases = transformCases(original);
  const dir = mkdtempSync(join(tmpdir(), 'ink-transform-'));
  try {
    const file = join(dir, 'request.json');
    for (const [i, row] of cases.entries()) {
      const request = JSON.parse(JSON.stringify(row.request));
      const { document, operation, options, ...scope } = request;
      const editor = createPixelEditor(document);
      const before = JSON.stringify(editor.snapshot());
      const title = i + ' ' + row.label + ' ' + JSON.stringify(operation?.transform);
      const copy = row.command === 'copy-selection-document';
      const run = () => copy ? editor.copySelection(options) : editor.paint(operation, scope);
      if (row.error) {
        assert.throws(run, { message: row.error }, title);
        assert.equal(JSON.stringify(editor.snapshot()), before, title);
      } else if (copy) {
        assert.deepEqual(run(), row.expected, title);
        assert.equal(JSON.stringify(editor.snapshot()), before, title);
      } else {
        assert.deepEqual(run(), row.expected.target, title);
        assert.equal(JSON.stringify(editor.snapshot()), JSON.stringify(row.expected.document), title);
      }
      if (process.argv[3] === '--javascript') continue;
      writeFileSync(file, JSON.stringify(request));
      const native = spawnSync(process.argv[3], [row.command, file], { encoding: 'utf8', maxBuffer: 8 << 20 });
      if (native.error) throw native.error;
      assert.equal(native.status, row.error ? 1 : 0, native.stderr || title);
      if (row.error) assert.equal(native.stderr.trimEnd(), row.error, 'native ' + title);
      else {
        const result = JSON.parse(native.stdout);
        if (copy) assert.deepEqual(result, row.expected, 'native ' + title);
        else {
          assert.deepEqual(result.target, row.expected.target, 'native ' + title);
          assert.equal(JSON.stringify(result.document), JSON.stringify(row.expected.document), 'native ' + title);
        }
      }
    }
    const sequence = transformSequence(original);
    const editor = createPixelEditor(sequence.document);
    for (const step of sequence.steps) {
      const before = JSON.stringify(editor.snapshot());
      if (step.error) {
        assert.throws(() => editor.paint(step.operation, front), { message: step.error });
        assert.equal(JSON.stringify(editor.snapshot()), before);
      } else {
        assert.deepEqual(editor.paint(step.operation, front), step.target);
        assert.equal(JSON.stringify(editor.snapshot()), JSON.stringify(step.document));
        assert.deepEqual(editor.copySelection(copySource), step.clipboard);
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  console.log('Matched ' + cases.length + ' original transforms and clipboard cases (' +
    cases.filter(row => row.error).length + ' rejections) and a retained sequence.');
}
