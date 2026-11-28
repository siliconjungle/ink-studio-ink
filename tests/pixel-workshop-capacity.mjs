import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import {
  createPixelCommandEditor, exportPixelWorkshopStamp, openPixelWorkshopStamp, rasterizePixelFrame,
} from '../web/pixel-document.mjs';

const [original, native] = process.argv.slice(2);
if (!original) throw new Error('Pass the pinned original Studio checkout and optionally the native Studio executable');
const require = createRequire(import.meta.url);
const stamps = require(resolve(original, 'src/pixel-stamps.js'));
const originalStudio = require(resolve(original, 'cli/pixel-art.js'));
const palette = ['#112233', '#aa2030'];
const ids = ['slot-0', 'slot-1'];
const budget = 64 * 1024 * 1024;
const options = { encoding: 'utf8', maxBuffer: budget };

function artwork(width, height, cell) {
  return Array.from({ length: width * height }, (_, p) => cell(p));
}
function still() {
  const width = 512, height = 512;
  return { width, height, palette,
    slots: artwork(width, height, p => p === 1 ? null : p % 2),
    alpha: artwork(width, height, p => p % 2 ? 37 : 0), knockouts: [1],
  };
}
function animation() {
  const width = 512, height = 512;
  const rows = Array(height).fill('01'.repeat(width / 2));
  return { width, height, palette,
    frames: [
      { id: 'first', duration: 0.125, rows },
      { id: 'second', duration: 0.085, slots: artwork(width, height, p => p % 2) },
      { id: 'third', duration: 0.2, rows },
      { id: 'final', duration: 0.123456, rows },
    ],
  };
}
function deck() {
  const width = 500, height = 500;
  const layers = Array.from({ length: 16 }, (_, n) => ({ id: 'paint-' + n }));
  const cels = Object.fromEntries(layers.map(({ id }) => [id, {
    slots: artwork(width, height, p => p % 2),
  }]));
  cels['paint-15'].alpha = artwork(width, height, p => p % 2 ? 128 : 255);
  return { format: 'ink-studio/pixel-layer-deck', version: 1, width, height, palette, swatchIds: ids, layers,
    frames: [{ id: 'spare', duration: 0.1, cels: {} }, { id: 'deck-frame', duration: 0.25, cels }],
  };
}
const command = (action, fields) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const reports = [];
const scratch = native ? mkdtempSync(join(tmpdir(), 'ink-workshop-capacity-')) : null;
try {
  for (const [make, layer, cellCount] of [[still, 'image', 262144], [animation, 'image', 1048576], [deck, 'paint-15', 4000000]]) {
    const source = make();
    const raw = source.frames ? source.frames.at(-1).cels?.[layer] ?? source.frames.at(-1) : source;
    if (make === deck) assert.equal(originalStudio.documentFromDeck(source).layers.length, 16);
    else assert.equal(stamps.prepare(source).entries.length, source.frames?.length ?? 1);
    const document = (await openPixelWorkshopStamp(source)).document;
    const id = document.frames.at(-1).id;
    assert.equal(document.frames.reduce((total, frame) =>
      total + Object.values(frame.cels).reduce((sum, cel) => sum + cel.slots.length, 0), 0), cellCount);
    const raster = rasterizePixelFrame(document, { frame: id, layer });
    const expected = stamps.prepare({ width: source.width, height: source.height, palette, frames: [raw] }, { preserveHidden: true }).entries[0];
    assert.deepEqual(raster.slots, Int32Array.from(expected.slots, (s, p) => s ?? (raw.knockouts?.includes(p) ? -2 : -1)));
    if (raw.alpha) {
      assert.deepEqual(raster.alpha, Uint32Array.from(raw.alpha, (a, i) => expected.slots[i] === null ? 255 : a));
    }
    assert.deepEqual(exportPixelWorkshopStamp(source, document), source);
    const editor = await createPixelCommandEditor(document);
    const patch = { id: 'capacity-edit', frame: id, revision: await editor.revision(),
      operation: { tool: 'pencil', layer, swatch: 'slot-1', points: [[0, 0]] } };
    const receipt = await editor.execute(command('draw', { patch }));
    assert.equal(receipt.affectedTargets[0].pixelCount, 1);
    const snapshot = await editor.snapshot();
    const edited = exportPixelWorkshopStamp(source, snapshot);
    assert.equal((edited.frames?.at(-1).cels?.[layer] ?? edited.frames?.at(-1) ?? edited).slots[0], 1);
    if (source.frames) assert.deepEqual(edited.frames.slice(0, -1), source.frames.slice(0, -1));
    if (source.frames?.at(-1).cels) {
      for (const entry of source.layers.slice(0, -1)) {
        assert.deepEqual(edited.frames.at(-1).cels[entry.id], source.frames.at(-1).cels[entry.id]);
      }
    }
    let overflow;
    if (make === deck) {
      overflow = { ...document, frames: [
        { ...document.frames[0], cels: { 'paint-0': { marks: [{ at: [0, 0], swatch: 'slot-0' }] } } },
        document.frames[1],
      ] };
      assert.throws(() => exportPixelWorkshopStamp(source, overflow), /native pixel budget/);
    }
    const reopened = (await openPixelWorkshopStamp(edited)).document;
    assert.equal(rasterizePixelFrame(reopened, { frame: id, layer }).slots[0], 1);
    if (native) {
      const sourceFile = join(scratch, 'stamp.json');
      const documentFile = join(scratch, 'document.json');
      writeFileSync(sourceFile, JSON.stringify(source));
      const opened = JSON.parse(execFileSync(resolve(native), ['import-stamp', sourceFile], options));
      assert.deepEqual(opened.document, document);
      for (const [version, expected] of [[document, source], [snapshot, edited]]) {
        writeFileSync(documentFile, JSON.stringify(version));
        const exported = execFileSync(resolve(native), ['export-stamp', sourceFile, documentFile], options);
        assert.deepEqual(JSON.parse(exported), expected);
      }
      if (overflow) {
        writeFileSync(documentFile, JSON.stringify(overflow));
        assert.throws(() => execFileSync(resolve(native), ['export-stamp', sourceFile, documentFile], {
          ...options, stdio: ['ignore', 'pipe', 'pipe'],
        }), { message: /native pixel budget/ });
      }
    }
    const report = { format: make.name, cells: cellCount, native: Boolean(native) };
    reports.push(report);
    console.log(JSON.stringify(report));
  }
} finally {
  if (scratch) rmSync(scratch, { recursive: true, force: true });
}
assert.equal(reports.length, 3);
