import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import {
  createPixelCommandEditor, createPixelWorkshopEditor, exportPixelWorkshopStamp, openPixelWorkshopStamp, rasterizePixelFrame,
} from '../web/pixel-document.mjs';

const [original, native] = process.argv.slice(2);
if (!original) throw new Error('Pass the pinned original Studio checkout and optionally the native Studio executable');
const require = createRequire(import.meta.url);
const stamps = require(resolve(original, 'src/pixel-stamps.js'));
const originalStudio = require(resolve(original, 'cli/pixel-art.js'));
const colors = ['#112233', '#a06030', '#5BFFAB'];
const ids = ['outline', 'leather', 'light'];
const palette = {
  palette: colors, swatchIds: ids, swatchLabels: { outline: 'Night ink' },
  lockedSwatches: ['light'], ramps: [{ id: 'shade', swatches: ids }],
};
const tests = [];
const size = { width: 6, height: 5 };
const bytePlane = overrides => Array.from({ length: size.width * size.height }, (_, index) => overrides[index] ?? 255);
const rowPixels = ['01....', '110...', '0..1..', '01....', '......'];
const still = {
  ...size, ...palette, origin: 'top-left', fps: 14, playback: 'once', phase: 0.125,
  rows: rowPixels,
  alpha: bytePlane({ 0: 0, 1: 107, 27: 5 }),
  knockouts: [29],
  selections: [{ id: 'focus', pixels: [[0, 0], [1, 0]] }],
  drawing: { mirrorX: true },
  notes: { reviewed: ['front', 'outline'] },
};
const strokeCommands = [
  { slot: 2, shape: { type: 'rect', rect: [-0.25, 1.15, 5.5, 2.4],
    falloff: { type: 'linear', from: [0, 1], to: [6, 1], opacity: [1, 0.4] } } },
  { slot: 1, shape: { type: 'polygon', rings: [[[0, 0], [6, 0], [5, 5], [0, 5]], [[1, 1], [1, 3.5], [4, 3.5], [4, 1]]],
    stroke: '#00000380', width: 1 } },
  { slot: 2, shape: { type: 'path', points: [[-1, 2], [4.5, 0.4], [5, 4]], width: 1.7, closed: true, weights: [0, 1, 0.5] } },
  { slot: null, shape: { type: 'rect', rect: [1, 2, 1, 2] } },
];
const animation = {
  ...size, ...palette, playback: 'once', fps: 8, phase: 0.7,
  frames: [
    { id: 'front', label: 'Front', duration: 0.123456, rows: rowPixels, strokes: strokeCommands.slice(0, 3),
      selections: [{ id: 'focus', pixels: [[1, 0]] }], memo: 'first pose' },
    { id: 'side', strokes: strokeCommands, selections: [{ id: 'focus', pixels: [[4, 4]] }] },
    { id: 'frame-3', rows: rowPixels, duration: 0.25 },
    { duration: 0.3 },
    { id: 'WIDE POSE', rows: rowPixels },
    { id: 'front', rows: rowPixels, duration: 0.15 },
  ],
};

const design = {
  format: 'ink-studio/pixel-art', version: 2, ...size, pixelAspect: [2, 1],
  palette: {
    outline: { color: '#112233', label: 'Night ink' },
    leather: '#a06030', light: { color: '#5BFFAB', locked: true },
  },
  ramps: palette.ramps,
  layers: [{ id: 'background' }, { id: 'actors', kind: 'group' }, { id: 'paint', parent: 'actors' }],
  frames: [
    { id: 'front', durationMs: 70, cels: {
      background: { marks: [{ swatch: 'light', runs: [[4, 0, 6]] }] },
      paint: { id: 'hero', opacity: 230, slots: rowPixels.flatMap(row => [...row].map(c => ids[c] ?? null)),
        marks: [{ alpha: 0, runs: [[0, 0, 1]] }, { alpha: 107, runs: [[0, 1, 1]] }, { swatch: null, runs: [[4, 5, 1]] }] },
    } },
    { id: 'side', durationMs: 250, cels: { paint: { hold: 'hero' } } },
  ],
  selections: [{ id: 'shared', pixels: [[1, 2]] }, { id: 'focus', frame: 'front', pixels: [[1, 0]] }],
  legacyMetadata: { source: 'reference-artwork' },
};
const deck = originalStudio.createEditor(design).layerDeck();
deck.frames[1].cels.paint.authorNote = 'keep this during a front edit';
originalStudio.documentFromDeck(deck);

function expectedRaster(source, raw) {
  const { width, height, palette } = source;
  const { entries: [paint] } = stamps.prepare({ width, height, palette, frames: [raw] }, { preserveHidden: true });
  return {
    slots: paint.slots.map((slot, p) => slot ?? (raw.knockouts?.includes(p) ? -2 : -1)),
    alpha: paint.slots.map((slot, p) => slot === null ? 255 : (paint.alpha?.[p] ?? 255)),
  };
}
function verifyCel(source, cel, document, id, layer) {
  const actual = rasterizePixelFrame(document, { frame: id, layer });
  const wanted = expectedRaster(source, cel);
  assert.deepEqual([...actual.slots], wanted.slots, id + '/' + layer + ' index plane');
  assert.deepEqual(wanted.alpha.map((_, p) => actual.alpha[p] ?? 255), wanted.alpha, id + '/' + layer + ' alpha plane');
}
async function verify(source) {
  const { document } = await openPixelWorkshopStamp(source);
  assert.deepEqual(exportPixelWorkshopStamp(source, document), source);
  const frames = source.frames ?? [source];
  for (const [index, raw] of frames.entries()) {
    const id = document.frames[index].id;
    for (const [layer, cel] of Object.entries(raw.cels ?? { image: raw })) {
      verifyCel(source, cel, document, id, layer);
    }
  }
  tests.push({ source, document });
  return document;
}
const stillDocument = await verify(still);
assert.deepEqual(stillDocument.palette.outline, { color: '#112233', label: 'Night ink' });
assert.deepEqual(stillDocument.palette.light, { color: '#5BFFAB', locked: true });
assert.equal(stillDocument.frames[0].durationMs, 71);

const animated = await verify(animation);
assert.deepEqual(animated.frames.map(frame => frame.durationMs), [123, 125, 250, 300, 125, 150]);
assert.deepEqual(animated.frames.map(frame => frame.id), ['front', 'side', 'frame-3', 'frame-4', 'frame-5', 'frame-6']);
assert.deepEqual(animated.selections.map(mask => [mask.id, mask.frame]), [['focus', 'front'], ['stamp-mask-2', 'side']]);

const layered = await verify(deck);
assert.deepEqual(layered.pixelAspect, [2, 1]);
const referenceDeck = originalStudio.documentFromDeck(deck);
for (const frame of layered.frames) {
  const { rgba: actual } = rasterizePixelFrame(layered, { frame: frame.id });
  const { rgba: expected } = rasterizePixelFrame(referenceDeck, { frame: frame.id });
  assert.deepEqual(actual, expected);
}

const edit = createPixelCommandEditor;
const op = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
for (const [source, document, target] of [
  [still, stillDocument, 'image'], [animation, animated, 'image'], [deck, layered, 'paint'],
]) {
  const editor = await edit(document);
  const frame = document.frames[0].id;
  const base = rasterizePixelFrame(document, { frame, layer: target });
  const newSlot = base.slots[28] === 1 ? 0 : 1;
  const patch = { id: 'restored-paint', frame, revision: await editor.revision(),
    operation: { tool: 'pencil', layer: target, swatch: ids[newSlot], points: [[4, 4]] } };
  await editor.execute(op('draw', { patch }));
  const snapshot = await editor.snapshot();
  const saved = exportPixelWorkshopStamp(source, snapshot);
  const reopened = (await openPixelWorkshopStamp(saved)).document;
  const raw = saved.frames ? saved.frames[0].cels?.[target] ?? saved.frames[0] : saved;
  verifyCel(saved, raw, reopened, frame, target);
  assert.equal(raw.slots[28], newSlot);
  if (source.frames) assert.deepEqual(saved.frames.slice(1), source.frames.slice(1));
  if (source === still) {
    assert.deepEqual(saved.notes, source.notes);
    assert.deepEqual(saved.drawing, source.drawing);
    assert.equal(saved.alpha[0], 0);
    assert.equal(saved.alpha[1], 107);
    assert.equal(saved.alpha[27], 255);
    assert.deepEqual(saved.knockouts, [29]);
  }
  await editor.undo();
  assert.deepEqual(exportPixelWorkshopStamp(source, await editor.snapshot()), source);
  await editor.redo();
  assert.deepEqual(exportPixelWorkshopStamp(source, await editor.snapshot()), saved);
  tests.find(row => row.source === source).edited = { snapshot, saved };

  const { editor: retained } = await createPixelWorkshopEditor(JSON.stringify(source));
  async function verifyRetainedRasters(expected) {
    for (const { id: frame } of expected.frames) {
      for (const layer of ['', ...expected.layers.filter(row => row.kind !== 'group').map(row => row.id)]) {
        const scope = { frame, layer };
        const actual = await retained.rasterize(scope);
        const reference = rasterizePixelFrame(expected, scope);
        assert.deepEqual(Uint32Array.from(actual.rgba), reference.rgba, frame + '/' + layer);
        assert.deepEqual([actual.width, actual.height], [reference.width, reference.height]);
      }
    }
  }
  assert.equal(await retained.revision(), patch.revision);
  const pristine = JSON.stringify(source, null, 2) + '\n';
  assert.equal(await retained.exportWorkshopStamp(), pristine);
  await verifyRetainedRasters(document);
  await retained.execute(op('draw', { patch }));
  assert.deepEqual(await retained.snapshot(), snapshot);
  assert.deepEqual(JSON.parse(await retained.exportWorkshopStamp()), saved);
  await verifyRetainedRasters(snapshot);
  await retained.undo();
  assert.equal(await retained.exportWorkshopStamp(), pristine);
  await verifyRetainedRasters(document);
  await retained.redo();
  assert.deepEqual(JSON.parse(await retained.exportWorkshopStamp()), saved);
  await verifyRetainedRasters(snapshot);
}

const rejected = [
  { ...still, rows: ['x', ...rowPixels.slice(1)] },
  { ...still, slots: Array(30).fill(null) },
  { ...still, knockouts: [0] },
  { ...still, alpha: [0] },
  { ...still, palette: ['#dd0o00'] },
  { ...animation, selections: [] },
  { ...still, strokes: [{ shape: strokeCommands[0].shape }] },
  { ...still, selections: [...still.selections, ...still.selections] },
  { ...still, selections: [{ id: 'outside', pixels: [[6, 5]] }] },
];
for (const source of rejected) {
  await assert.rejects(openPixelWorkshopStamp(source));
  await assert.rejects(createPixelWorkshopEditor(JSON.stringify(source)));
}
assert.throws(() => exportPixelWorkshopStamp(still, { ...stillDocument, pixelAspect: [2, 1] }), /only accepts raster/);

if (native) {
  const scratch = mkdtempSync(join(tmpdir(), 'ink-workshop-stamp-'));
  try {
    const sourceFile = join(scratch, 'stamp.json');
    const documentFile = join(scratch, 'document.json');
    const run = (...args) => JSON.parse(execFileSync(resolve(native), args, { encoding: 'utf8' }));
    for (const { source, document, edited } of tests) {
      writeFileSync(sourceFile, JSON.stringify(source));
      assert.deepEqual(run('import-stamp', sourceFile).document, document);
      for (const [snapshot, expected] of [[document, source], [edited.snapshot, edited.saved]]) {
        writeFileSync(documentFile, JSON.stringify(snapshot));
        assert.deepEqual(run('export-stamp', sourceFile, documentFile), expected);
      }
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}
console.log(JSON.stringify({ formats: tests.length, rejected: rejected.length, checkedNative: Boolean(native) }));
