import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { rasterizePixelFrame, selectPixelFrame } from '../web/pixel-document.mjs';

export function rasterValues(raster) {
  return { ...raster, slots: [...raster.slots], alpha: [...raster.alpha],
    clipping: [...raster.clipping], rgba: [...raster.rgba] };
}

export function cases(originalRoot) {
  const require = createRequire(import.meta.url);
  const { compile, createEditor } = require(resolve(originalRoot, 'cli/pixel-art.js'));
  const format = 'ink-studio/pixel-art';
  const width = 12, height = 8;
  const palette = { rust: '#b53129', alias: { color: '#b53129', label: 'Alias' }, blue: '#243b6a', mint: '#33e3ab' };
  const legacyPalette = { rust: '#b53129', blue: '#243b6a' };
  const relay = JSON.parse(readFileSync(join(originalRoot, 'examples/pixel-art-tooling/relay.json'), 'utf8'));
  const rect = (swatch, x, y, w, h) => ({ swatch, shape: { type: 'rect', rect: [x, y, w, h] } });
  const at = (swatch, x, y) => ({ swatch, at: [x, y] });
  const steps = { swatch: 'mint', steps: { from: [3, 5], axis: 'y', direction: [1, -1], lengths: [2, 1, 2] } };
  const dense = Array.from({ length: width * height }, (_, i) => i % 9 === 0 ? 'blue' : null);
  const legacy = { format, version: 1, width, height, palette: legacyPalette, layers: [
    { id: 'floor', marks: [rect('blue', 0, 1, 10, 4)] },
    { id: 'paint', clip: 'floor', marks: [rect('rust', -0.25, 1.5, 6.75, 4), at(null, 1, 2),
      { swatch: 'rust', runs: [[3, 3, 3], [4, 0, 9]] }, { alpha: 50, runs: [[4, 1, 8]] },
      { clear: true, runs: [[4, 2, 1]] }, at('rust', 2, 4)] },
  ] };
  const timeline = { format, version: 2, width, height, pixelAspect: [1, 1], palette, layers: [
    { id: 'base', protect: false }, { id: 'group', kind: 'group', opacity: 0.77 }, { id: 'overlay', blend: 'overlay', opacity: 0.25 },
    { id: 'cut', parent: 'group', kind: 'mask' }, { id: 'nested', parent: 'group', kind: 'group' },
    { id: 'fill', parent: 'group', clip: 'cut', blend: 'screen', offset: [1, 0] },
    { id: 'under', parent: 'nested', blend: 'multiply' }, { id: 'ignored', kind: 'reference' },
    { id: 'hidden', visible: false }, { id: 'add', blend: 'add', opacity: 0.3333333333333333 },
  ], frames: [
    { id: 'front', durationMs: 80, cels: {
      base: { marks: [rect('blue', 0, 0, 12, 8)] },
      cut: { marks: [rect('blue', 0, 0, 8, 6), { alpha: 90, runs: [[2, 0, 8]] }] },
      fill: { id: 'seed', slots: dense, marks: [rect('rust', 1, 1, 8, 5), steps, at('alias', 1, 2),
        { alpha: 0, runs: [[1, 1, 2]] }, at(null, 1, 1), at('alias', 1, 1),
        rect('rust', 8.499999999999998, 2, 0.5000000149011612, 2),
        { swatch: 'mint', shape: { type: 'polygon', rings: [
          [[0.5, -0.25], [5.5, 1.25], [2.25, 7.5], [-1, 7]], [[1, 2], [2, 3], [1, 4]],
        ] } },
        { swatch: 'blue', shape: { type: 'polygon', points: [[1, 1], [6, 7], [1, 7], [6, 1]],
          fillFalloff: { type: 'radial', center: [3, 4], radii: [1, 3], curve: 'linear' } } },
        { swatch: 'rust', shape: { type: 'rect', rect: [1, 3, 10, 1.8],
          falloff: { from: [2, 3], to: [8, 4], opacity: [0.9, 0.1] } } },
        { swatch: 'alias', shape: { type: 'path', points: [[-1, 1.1], [2, 2.6], [2, 2.6], [7, 6], [6, 0]],
          width: 2, weights: [0, 1.25, 0.4, 1, 1], closed: true } },
        { swatch: 'alias', shape: { type: 'polygon', points: [[7, 2], [11, 5], [7, 7]],
          fill: '#00000388', stroke: '#000004', width: 1.45,
          strokeFalloff: { from: [7, 2], to: [11, 6], curve: 'linear' } } },
        { swatch: 'rust', shape: { type: 'polygon', points: [[0, 2], [2, 3], [0, 5]],
          fill: false, stroke: '#000002', width: 0.7 } },
      ] },
      overlay: { opacity: 199, marks: [rect('mint', 4.5, 3, 6.2, 6), at(null, 4, 3)] },
      under: { marks: [rect('alias', 0, 0, 5, 5), { alpha: 170, runs: [[3, 2, 3]] }] },
      ignored: { marks: [rect('rust', 0, 0, 12, 8)] },
      hidden: { marks: [at('mint', 11, 7)] },
      add: { marks: [rect('mint', 7, 3, 4, 2), { swatch: null, runs: [[2, 0, 2]] }] },
    } },
    { id: 'side', durationMs: 130, cels: {
      base: { marks: [rect('blue', 0, 0, 12, 8)] }, cut: { marks: [rect('blue', 0, 0, 12, 8)] },
      fill: { id: 'held-side', hold: 'seed', opacity: 108, offset: [-2, 1] },
    } },
    { id: 'back', durationMs: 90, cels: {
      fill: { id: 'held-back', hold: 'held-side', opacity: 2, offset: [1000000, -1000000] },
    } },
  ] };
  const rows = [];
  function add(document, scope, checkSelection = true) {
    const request = { document, ...scope };
    try {
      if (scope.layer !== undefined && scope.cel !== undefined) throw new Error('Select from the composite, a layer or a cel');
      const capture = scope.layer ?? (scope.cel === undefined ? undefined : true);
      if (document.version === 1) compile(document);
      const input = document.version === 1 ? createEditor(document).snapshot() : document;
      const active = compile(input, scope.frame, scope.cel, capture);
      const layer = scope.layer ?? (scope.cel === undefined ? undefined :
        [...active.cels].find(([, id]) => id === scope.cel)?.[0]);
      const raster = layer === undefined ? active : active.layerSources.get(layer);
      if (!raster) throw new Error('Unknown pixel layer ' + layer);
      const slots = [...raster.slots];
      const opacity = layer === undefined ? (raster.opacity ?? slots.map(slot => slot < 0 ? 0 : 255)) : raster.alpha;
      const alpha = opacity ? [...opacity] : [];
      const clipping = raster.clipping ? [...raster.clipping] : [];
      const rgba = slots.map((slot, p) => slot < 0 || clipping[p] === 0 ? 0 :
        (((raster.mixedColors?.[p] ?? active.colors[slot]) << 8) | (alpha[p] ?? 255)) >>> 0);
      rows.push({ request, raster: { width: document.width, height: document.height,
        frame: active.id, slots, alpha, clipping, ids: active.swatches, rgba } });
      if (!checkSelection) return;
      const editor = createEditor(document);
      for (const query of [{ type: 'swatch', id: 'rust' }, { type: 'swatch', at: [2, 2] },
        { type: 'cluster', at: [2, 2], connectivity: 8 }, { type: 'wand', at: [2, 2], connected: false, tolerance: 7 }]) {
        const { frame, grid, pixels } = editor.select(query, scope);
        rows.push({ request: { ...request, query }, selection: { frame, grid, pixels } });
      }
    } catch (error) {
      rows.push({ request, error: error.message });
    }
  }
  for (const scope of [{}, { layer: 'floor' }, { layer: 'paint' }, { cel: 'artwork/paint' }]) add(legacy, scope);
  for (const scope of [{}, { layer: 'ceramic-masses' }, { cel: 'artwork/visor' }]) add(relay, scope);
  for (const scope of [{}, { frame: 'front' }, { frame: 'side' }, { layer: 'fill' }, { layer: 'hidden' },
    { layer: 'ignored' }, { layer: 'cut' }, { cel: 'seed' }, { cel: 'held-side' }, { cel: 'held-back' },
    { frame: 'side', layer: 'fill' }, { frame: 'back' }, { frame: 'missing' }, { layer: 'missing' },
    { frame: 'side', cel: 'seed' }, { layer: 'fill', cel: 'seed' }, { layer: 'group' }]) add(timeline, scope);
  for (const mark of [
    { swatch: 'missing', at: [2, 3] }, at('rust', 12, 0),
    { swatch: 'rust', runs: [[0, 2, 2], [0, 3, 1]] }, { alpha: 256, runs: [[0, 0, 1]] },
    { swatch: 'rust', runs: [[2, 11, 2]] }, { swatch: 'rust', at: [2, 1], shape: { type: 'rect', rect: [0, 0, 2, 3] } },
    { swatch: 'rust', steps: { from: [1, 1], axis: 'x', direction: [-1, -1], lengths: [4] } },
    rect('rust', 1, 1, 0, 2),
    { swatch: 'rust', shape: { type: 'path', points: [[0, 0], [1, 1]], weights: [1] } },
    { swatch: 'rust', shape: { type: 'polygon', points: [[0, 0], [1, 1]] } },
  ]) add({ ...legacy, layers: [{ id: 'paint', marks: [mark] }] }, {}, false);
  add({ ...legacy, layers: [{ id: 'floor', protect: true, marks: [at('blue', 1, 2)] },
    { id: 'paint', marks: [at('rust', 1, 2)] }] }, {}, false);
  return rows;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-frame-raster.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  const rows = cases(process.argv[2]);
  const tmp = mkdtempSync(join(tmpdir(), 'ink-pixel-frame-'));
  try {
    const requestPath = join(tmp, 'request.json');
    for (const [i, { request, raster, selection, error }] of rows.entries()) {
      const { document, query, ...scope } = request;
      writeFileSync(requestPath, JSON.stringify(request));
      const native = spawnSync(process.argv[3], [query ? 'select-document' : 'raster', requestPath], { encoding: 'utf8' });
      if (native.error) throw native.error;
      const label = 'frame case ' + i + ' ' + JSON.stringify(scope);
      const run = () => query ? selectPixelFrame(document, query, scope) : rasterValues(rasterizePixelFrame(document, scope));
      if (error) {
        assert.throws(run, { message: error }, label);
        assert.equal(native.status, 1, label);
        assert.equal(native.stderr.trimEnd(), error, label);
      } else {
        assert.deepEqual(run(), selection ?? raster, label);
        assert.equal(native.status, 0, native.stderr || label);
        assert.deepEqual(JSON.parse(native.stdout), selection ?? raster, 'native ' + label);
      }
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  console.log('JavaScript and native Rust matched ' + rows.length + ' authored frame and document selection cases.');
}
