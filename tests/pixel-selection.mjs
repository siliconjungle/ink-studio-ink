import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { selectPixels } from '../web/pixel-document.mjs';

export function selectionCases(originalRoot) {
  const original = createRequire(import.meta.url)(resolve(originalRoot, 'src/pixel-selections.js'));
  const requests = [];
  const add = (query, width = 8, height = 6, extra = {}) => requests.push({ width, height, query, ...extra });
  const rect = (x, y, w, h) => ({ type: 'rectangle', rect: [x, y, w, h] });
  const literal = (...pixels) => ({ type: 'pixels', pixels });
  const ink = 0xab7d3aff, close = 0xac793af8, glass = 0xab7d3a8a;
  const rgba = [ink, close, 0xff00ff00, glass, ink, 0,
    ink, 0, 0x77003300, glass, ink, 0,
    ink, close, 0, 0, ink, 0];

  add(rect(1, 2, 3, 2));
  add({ type: 'ellipse', rect: [1, 1, 4, 4] });
  add({ type: 'ellipse', rect: [0, 0, 511, 1] }, 512, 1);
  add({ type: 'ellipse', rect: [0, 0, 1, 512] }, 1, 512);
  add({ type: 'polygon', points: [[1, 1], [6, 1], [6, 2], [3, 2], [3, 4], [1, 4]] });
  add({ type: 'lasso', points: [[1, 1], [5, 5], [1, 5], [5, 1]] });
  for (const points of [[[0, 0]], [[1, 1], [3, 3]], [[0, 1], [6, 1]], [[3, 1], [3, 5]],
    [[2, 2], [2, 2], [2, 2]], [[0, 1], [4, 3], [0, 1], [1, 4], [3, 0]]]) add({ type: 'lasso', points });

  for (const connected of [true, false]) {
    for (const tolerance of [0, 4, 7, 117, 255]) {
      for (const at of [[0, 0], [2, 0], [3, 0], [4, 2]]) add({ type: 'wand', at, tolerance, connected }, 6, 3, { rgba });
    }
  }
  const source = literal([1, 1], [2, 2], [3, 3], [7, 5]);
  for (const connectivity of [4, 8]) {
    for (const at of [[1, 1], [0, 1], [7, 5]]) add({ type: 'cluster', source, at, connectivity });
  }
  for (const type of ['combine', 'subtract', 'intersect']) {
    add({ type, base: rect(0, 0, 6, 4), with: { type: 'ellipse', rect: [2, 1, 6, 5] } });
    add({ type, base: literal(), with: source });
    add({ type, base: { type: 'recall', id: 'saved' }, with: source }, 8, 6, { saved: { saved: [[2, 2], [5, 2]] } });
  }
  for (const base of [literal(), source, rect(0, 0, 8, 6), rect(2, 1, 4, 4)]) {
    add({ type: 'invert', source: base });
    for (const amount of [1, 2, 9, 512]) {
      add({ type: 'grow', source: base, amount });
      add({ type: 'shrink', source: base, amount });
      for (const side of ['inside', 'outside', 'both']) add({ type: 'outline', source: base, amount, side });
    }
  }
  let nested = source;
  for (let depth = 1; depth <= 33; depth++) {
    if (depth >= 30) add(nested);
    nested = { type: 'invert', source: nested };
  }
  add({ type: 'outline', side: 'both', source: {
    type: 'subtract', base: { type: 'combine', base: source, with: rect(2, 2, 3, 3) },
    with: { type: 'ellipse', rect: [2, 1, 3, 4] },
  } });

  // Seeded points exercise opposite edge directions, shared vertices and
  // crossing ties without a hand-authored expected mask.
  let seed = 0xd14c3797;
  const random = limit => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return Math.floor(seed / 2 ** 32 * limit);
  };
  for (let i = 0; i < 96; i++) {
    const width = random(23) + 1, height = random(19) + 1;
    const points = Array.from({ length: random(14) + 3 }, () => [random(width), random(height)]);
    add({ type: i % 2 ? 'lasso' : 'polygon', points }, width, height);
  }
  add({ type: 'polygon', points: Array.from({ length: 128 }, (_, i) => [i % 64, (i * 11) % 61]) }, 64, 64);
  add({ type: 'lasso', points: Array.from({ length: 4096 }, (_, i) => [i % 4, (i >>> 2) % 3]) }, 4, 3);

  add(rect(0, 0, 1, 1), 0, 5);
  add(rect(0, 0, 1, 1), 513, 5);
  add(rect(1, 1, 8, 1));
  add({ type: 'ellipse', rect: [1, 1, 1.5, 2] });
  add({ type: 'rectangle', rect: [1, 1, 2, 2], extra: false });
  add({ type: 'lasso', points: [] });
  add({ type: 'lasso', points: [[0, 0], [-1, 1]] });
  add({ type: 'polygon', points: [[1, 1], [3, 3]] });
  add(literal([0, 0], [0, 0]));
  add(literal([0, 8]));
  add({ type: 'pixels', pixels: null });
  add({ type: 'grow', source, amount: 0 });
  add({ type: 'outline', source, side: 'mid' });
  add({ type: 'invert', source, amount: 2 });
  add({ type: 'cluster', source, at: [0, 0], connectivity: 6 });
  add({ type: 'cluster', at: [0, 0] });
  add({ type: 'wand', at: [0, 0] });
  add({ type: 'wand', at: [0, 0], tolerance: 256 }, 6, 3, { rgba });
  add({ type: 'wand', at: [0, 0], connected: 'yes' }, 6, 3, { rgba });
  add({ type: 'recall', id: 20 });
  add({ type: 'recall', id: 'missing' });
  add({ type: 'combine', base: source, with: source, extra: true });

  return requests.map(request => {
    const { width, height, query, rgba, saved = {} } = request;
    try {
      const recalled = id => {
        if (!Object.hasOwn(saved, id)) throw new RangeError('Unknown saved selection ' + id);
        return saved[id];
      };
      const result = original.mask(width, height, query, rgba && (p => rgba[p]), recalled);
      return { request, pixels: original.pixels(width, result) };
    } catch (error) {
      return { request, error: error.message };
    }
  });
}

function check(originalRoot, native) {
  const rows = selectionCases(originalRoot);
  const tmp = mkdtempSync(join(tmpdir(), 'ink-pixel-selection-'));
  try {
    const file = join(tmp, 'selection.json');
    for (const [i, { request, pixels, error }] of rows.entries()) {
      const { width, height, query, ...data } = request;
      const label = 'case ' + i + ' (' + query.type + ')';
      const run = () => selectPixels(width, height, query, { ...data,
        ...(data.rgba && { rgba: Uint32Array.from(data.rgba) }) });
      writeFileSync(file, JSON.stringify(request));
      const output = spawnSync(native, ['select', file], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
      if (output.error) throw output.error;
      if (error) {
        assert.throws(run, { message: error }, 'JavaScript ' + label);
        assert.equal(output.status, 1, 'Native ' + label);
        assert.equal(output.stderr.trimEnd(), error, 'Native ' + label);
      } else {
        assert.deepEqual(run(), pixels, 'JavaScript ' + label);
        assert.equal(output.status, 0, output.stderr);
        assert.deepEqual(JSON.parse(output.stdout), pixels, 'Native ' + label);
      }
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  console.log('JavaScript and native Rust matched ' + rows.length + ' original pixel selection cases.');
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-selection.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  check(process.argv[2], process.argv[3]);
}
