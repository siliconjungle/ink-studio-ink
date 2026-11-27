import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { selectPixels } from '../web/pixel-document.mjs';

export function rasterCases(originalRoot) {
  const require = createRequire(import.meta.url);
  const { compile, createEditor } = require(resolve(originalRoot, 'cli/pixel-art.js'));
  const width = 8, height = 6;
  const artwork = {
    format: 'ink-studio/pixel-art', version: 2, width, height, pixelAspect: [1, 1],
    palette: { rust: '#b53129', alias: '#b53129', blue: '#243b6a' },
    layers: [{ id: 'clip', kind: 'mask' }, { id: 'ink', clip: 'clip' }, { id: 'top' }],
    frames: [
      { id: 'front', durationMs: 100, cels: {
        clip: { marks: [{ swatch: 'blue', shape: { type: 'rect', rect: [0, 0, 5, 6] } }] },
        ink: { id: 'drawing', marks: [
          { swatch: 'rust', at: [1, 1] }, { swatch: 'alias', at: [2, 1] },
          { swatch: 'rust', at: [5, 1] }, { swatch: 'rust', at: [3, 2] },
          { swatch: 'rust', at: [2, 2] }, { alpha: 128, runs: [[2, 2, 1]] },
          { swatch: 'rust', at: [1, 3] }, { alpha: 0, runs: [[1, 3, 1]] },
        ] },
        top: { marks: [{ swatch: 'blue', at: [2, 1] }, { swatch: 'rust', at: [6, 3] }] },
      } },
      { id: 'back', durationMs: 100, cels: {} },
    ],
  };
  const editor = createEditor(artwork);
  const requests = [];
  function add(query, scope = {}, includeRaster = true) {
    const capture = scope.layer ?? (scope.cel === undefined ? undefined : true);
    const active = compile(artwork, scope.frame, scope.cel, capture);
    const layer = scope.layer ?? (scope.cel && [...active.cels].find(([, id]) => id === scope.cel)?.[0]);
    const raster = layer === undefined ? active : active.layerSources.get(layer);
    const alpha = layer === undefined ? raster.opacity : raster.alpha;
    const indexed = includeRaster ? { slots: [...raster.slots], ids: active.swatches,
      ...(alpha && { alpha: [...alpha] }), ...(raster.clipping && { clipping: [...raster.clipping] }) } : undefined;
    const request = { width, height, query, ...(indexed && { indexed }) };
    try {
      const pixels = editor.select(query, scope).pixels;
      requests.push({ request, pixels });
    } catch (error) {
      requests.push({ request, error: error.message });
    }
  }
  for (const scope of [{}, { layer: 'ink' }, { cel: 'drawing' }, { frame: 'back' }]) {
    for (const id of ['rust', 'alias', 'blue', 'missing']) add({ type: 'swatch', id }, scope);
    for (const at of [[1, 1], [2, 1], [5, 1], [2, 2], [1, 3], [0, 0]]) {
      add({ type: 'swatch', at }, scope);
      for (const connectivity of [4, 8]) add({ type: 'cluster', at, connectivity }, scope);
    }
  }
  add({ type: 'subtract', base: { type: 'swatch', id: 'rust' },
    with: { type: 'cluster', at: [1, 1], connectivity: 8 } }, { cel: 'drawing' });
  for (const query of [{ type: 'swatch' }, { type: 'swatch', id: null },
    { type: 'swatch', id: '\u00a0\u3000\ufeff' }, { type: 'swatch', at: [1, 1], id: 'rust' },
    { type: 'swatch', at: [-1, 1] }, { type: 'swatch', id: 'rust', scope: 'visible' }]) {
    add(query, {}, false);
  }
  let query = { type: 'cluster', at: [1, 1] };
  for (let i = 0; i <= 31; i++) {
    if (i >= 29) add(query);
    query = { type: 'invert', source: query };
  }
  return requests;
}

function checkRasterNative(rows, native) {
  const tmp = mkdtempSync(join(tmpdir(), 'ink-pixel-raster-'));
  try {
    const file = join(tmp, 'request.json');
    for (const [i, { request, pixels, error }] of rows.entries()) {
      writeFileSync(file, JSON.stringify(request));
      const output = spawnSync(native, ['select', file], { encoding: 'utf8' });
      if (output.error) throw output.error;
      const label = 'native raster case ' + i;
      assert.equal(output.status, error ? 1 : 0, output.stderr || label);
      if (error) assert.equal(output.stderr.trimEnd(), error, label);
      else assert.deepEqual(JSON.parse(output.stdout), pixels, label);
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-selection-raster.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  const rows = rasterCases(process.argv[2]);
  checkRasterNative(rows, process.argv[3]);
  for (const [i, { request: { width, height, query, indexed }, pixels, error }] of rows.entries()) {
    const run = () => selectPixels(width, height, query, { indexed: indexed && {
      slots: Int16Array.from(indexed.slots), ids: indexed.ids,
      ...(indexed.alpha && { alpha: Uint8Array.from(indexed.alpha) }),
      ...(indexed.clipping && { clipping: Uint8Array.from(indexed.clipping) }),
    } });
    const label = 'JavaScript raster case ' + i;
    if (error) assert.throws(run, { message: error }, label);
    else assert.deepEqual(run(), pixels, label);
  }
  console.log('JavaScript and native Rust matched ' + rows.length + ' original indexed-raster selection cases.');
}
