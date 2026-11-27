import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelEditor } from '../web/pixel-document.mjs';

export function shapeCases(originalRoot) {
  const { createEditor } = createRequire(import.meta.url)(resolve(originalRoot, 'cli/pixel-art.js'));
  const fixtures = [];
  const document = (width, height, extra = {}) => ({
    format: 'ink-studio/pixel-art', version: 2, width, height, pixelAspect: [1, 1],
    palette: { rust: '#b53129', blue: '#213b71' }, layers: [{ id: 'ink' }],
    frames: [{ id: 'front', durationMs: 100, cels: { ink: { marks: [] } } }], ...extra,
  });
  function add(source, shape, rest = {}, scope = { frame: 'front' }) {
    const operation = { tool: 'shape', layer: 'ink', swatch: 'rust', shape, ...rest };
    if (scope.cel && !Object.hasOwn(rest, 'layer')) delete operation.layer;
    const request = { document: source, operation, ...scope };
    const editor = createEditor(source);
    const patch = { id: 'shape-test', revision: editor.describe().revision, operation, ...scope };
    const preview = editor.previewEdit(patch);
    fixtures.push(preview.valid ? { request, expected: { target: preview.targets[0], document: editor.apply(patch) } }
      : { request, error: preview.conflicts[0].message });
  }

  const small = document(8, 7);
  const middle = document(37, 29);
  for (const settings of [undefined, {}, { mirrorX: 7.5, mirrorY: 6.5 },
    { mirrorX: -0.5, mirrorY: -0.5 }, { wrapX: true, wrapY: true, mirrorX: 4 }]) {
    const drawing = settings === undefined ? {} : { drawing: settings };
    const a = settings?.wrapX ? [-2, -2] : [0, 0];
    const b = settings?.wrapX ? [11, 9] : [7, 6];
    for (const width of [1, 2, 3, 32]) {
      add(small, { type: 'line', from: a, to: b, width }, drawing);
      add(small, { type: 'line', from: b, to: a, width }, drawing);
      add(small, { type: 'curve', points: [a, [5, 1], b], width }, drawing);
      add(small, { type: 'curve', points: [b, [3, 1], [7, 2], a], width }, drawing);
    }
    for (const type of ['rect', 'ellipse']) for (const fill of [false, true]) {
      add(small, { type, rect: [...a, 12, 13], fill, width: 2 }, drawing);
      add(small, { type, rect: [7, 6, 5, 7], fill, width: 1 }, drawing);
      add(small, { type, rect: [1, 1, 1, 6], fill }, drawing);
      add(small, { type, rect: [1, 1, 7, 1], fill, width: 32 }, drawing);
    }
    add(small, { type: 'polygon', points: [a, b, [2, 5], [7, 2], [2, 2]] }, drawing);
    add(small, { type: 'polygon', points: [b, b, [2, 5], a], fill: false, width: 2 }, drawing);
    add(small, { type: 'polygon', points: [a, b, b, a] }, drawing);
    for (const direction of [[1, 1], [1, -1], [-1, 1], [-1, -1]]) {
      const from = [direction[0] < 0 ? 6 : 1, direction[1] < 0 ? 5 : 1];
      for (const axis of ['x', 'y']) add(small, { type: 'staircase', from, axis, direction, lengths: [1, 2, 2] }, drawing);
    }
  }

  add(document(1, 1), { type: 'ellipse', rect: [1, 1, 512, 512], fill: false }, {
    drawing: { wrapX: true, wrapY: true, mirrorX: -0.5, mirrorY: 0.5 },
  });
  add(document(2, 2), { type: 'rect', rect: [3, -2, 512, 512] }, {
    drawing: { wrapX: true, wrapY: true, mirrorX: -0.5, mirrorY: 1.5 },
  });
  const large = document(512, 512);
  add(large, { type: 'rect', rect: [0, 0, 512, 512] });
  add(large, { type: 'ellipse', rect: [-512, 511, 1536, 1536], fill: false, width: 31 },
    { drawing: { wrapX: true, wrapY: true } });
  add(large, { type: 'polygon', fill: false, width: 32,
    points: Array.from({ length: 128 }, (_, i) => i % 2 ? [511, 511] : [0, 0]) }, { drawing: {} });

  for (const align of ['left', 'right', 'center']) {
    for (const drawing of [undefined, { mirrorY: 28.5, mirrorX: 36.5 }, { wrapX: true, wrapY: true, mirrorX: -0.5 }]) {
      const common = { at: drawing?.wrapX ? [-3, -5] : [1, 0], align };
      for (const text of ['', ' ', 'AZ[!]', 'Åç█⠟', '🙂?\r\nA\rü\n⠛★', '  \nabcde\nZ\n', '\t\u0000\u00a0'])
        add(middle, { type: 'text', ...common, text, tracking: 1, leading: 2, columns: 4 },
          drawing === undefined ? {} : { drawing });
    }
  }
  const atlas = createRequire(import.meta.url)(resolve(originalRoot, 'index.js')).load().KIT.ascii.atlas();
  for (let i = 0; i < atlas.chars.length; i += 56) {
    add(middle, { type: 'text', at: [0, 0], text: atlas.chars.slice(i, i + 56).join(''),
      columns: 5, scale: 2, align: 'center' }, { drawing: { wrapX: true, wrapY: true } });
  }
  add(middle, { type: 'text', at: [0, 0], text: 'A👾Z', columns: Number.MAX_SAFE_INTEGER });
  add(middle, { type: 'text', at: [36, 28], text: 'wide', scale: 32, tracking: 64, align: 'right' },
    { drawing: { mirrorY: 28.5, mirrorX: 36.5, wrapX: true, wrapY: true } });
  add(middle, { type: 'text', at: [0, 0], text: '🙂'.repeat(2049) });
  add(middle, { type: 'text', at: [0, 0], text: 'a'.repeat(2048) });
  add(middle, { type: 'text', at: [0, 0], text: 'A\n'.repeat(300), scale: 32 });
  add(middle, { type: 'text', at: [0, 0], text: '\n'.repeat(1030) });

  for (const shape of [null, {}, [], { type: 'transform' }, { type: 'line', from: [0, 0], to: [7, 6], extra: 1 },
    { type: 'line', from: ['1', 2], to: [2, 2] }, { type: 'line', from: [0, 0], to: [7, 6], width: 33 },
    { type: 'line', from: [0, 0], to: [8, 6] }, { type: 'curve', points: [] },
    { type: 'polygon', points: [[1, 1], [2, 2]] }, { type: 'polygon', points: Array.from({ length: 129 }, () => [3, 3]) },
    { type: 'polygon', fill: 'true', points: [[0, 0], [0, 1], [1, 0]] }, { type: 'rect', rect: [0, 0, 0, 1] },
    { type: 'ellipse', rect: [0, 0, 1, 513] }, { type: 'text', at: [-1, 0], text: '?' },
    { type: 'text', at: [0, 0], text: null }, { type: 'text', at: [0, 0], scale: 0, text: 'x' },
    { type: 'text', at: [0, 0], text: 'x', align: 'middle' }, { type: 'text', at: [0, 0], text: 'x', columns: 0 },
    { type: 'text', at: [0, 0], text: 'x', columns: Number.MAX_SAFE_INTEGER + 1 },
    { type: 'staircase', from: [0, 0], axis: 'z', direction: [1, 1], lengths: [2] },
    { type: 'staircase', from: [0, 0], axis: 'x', direction: [1, 0], lengths: [2] },
    { type: 'staircase', from: [0, 0], axis: 'x', direction: [1, 1], lengths: [2, 0] },
    { type: 'staircase', from: [0, 0], axis: 'x', direction: [1, 1], lengths: [8, 1] },
  ]) add(small, shape);

  const line = { type: 'line', from: [0, 1], to: [7, 1] };
  for (const rest of [{ at: [0, 0] }, { points: [[0, 0]] }, { brush: 'b' }, { samples: [] },
    { drawing: { wrapX: 1 } }, { selection: 'missing' }, { pixelPerfect: true }, { swatch: 'unknown' }]) add(small, line, rest);
  const named = { selections: [{ id: 'fence', pixels: [[1, 1], [5, 1], [0, 6]] }],
    protectedDetails: [{ id: 'edge', pixels: [[4, 1]] }] };
  add(document(8, 7, named), line);
  add(document(8, 7, named), line, { selection: 'fence' });
  const clipped = document(8, 7, { layers: [{ id: 'clip' }, { id: 'ink', clip: 'clip' }],
    frames: [{ id: 'front', durationMs: 100,
      cels: { clip: { marks: [{ swatch: 'blue', runs: [[1, 0, 2], [1, 5, 1]] }] }, ink: { id: 'artist', marks: [] } } }] });
  add(clipped, line, {}, { cel: 'artist' });
  add(clipped, { ...line, to: [1, 1] }, {}, { cel: 'artist' });
  const painted = document(8, 7, { frames: [{ id: 'front', durationMs: 100,
    cels: { ink: { id: 'artist', marks: [{ swatch: 'rust', runs: [[1, 0, 8]] }] } } }] });
  add(painted, line);
  add(painted, line, { swatch: 'blue' }, { frame: 'front', cel: 'artist' });

  let seed = 4791;
  const next = n => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) >>> 5) % n;
  for (let i = 0; i < 180; i++) {
    const wrapping = i % 3 === 1;
    const drawing = wrapping ? { drawing: { wrapX: true, wrapY: true, mirrorY: 17.5 } }
      : i % 3 === 2 ? { drawing: {} } : {};
    const coord = (w, n) => wrapping ? next(w * 3) - w : next(n);
    const point = () => [coord(37, 37), coord(29, 29)];
    const width = 1 + next(6);
    let shape;
    if (i % 5 < 2) shape = { type: 'curve', width, points: Array.from({ length: 3 + i % 2 }, point) };
    else if (i % 5 === 2) shape = { type: 'polygon', width, fill: i % 2 === 0,
      points: Array.from({ length: 3 + next(14) }, point) };
    else shape = { type: i % 5 === 3 ? 'ellipse' : 'rect', width, fill: i % 2 === 0,
      rect: [...point(), 1 + next(75), 1 + next(60)] };
    add(middle, shape, drawing);
  }
  return fixtures;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-shapes.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  const rows = shapeCases(process.argv[2]);
  const dir = mkdtempSync(join(tmpdir(), 'ink-shape-'));
  try {
    const file = join(dir, 'request.json');
    for (const [i, { request, expected, error }] of rows.entries()) {
      const { document, operation, ...scope } = request;
      const editor = createPixelEditor(document);
      const label = 'shape case ' + i + ' ' + JSON.stringify(operation).slice(0, 220);
      writeFileSync(file, JSON.stringify(request));
      const native = spawnSync(process.argv[3], ['paint-document', file], { encoding: 'utf8', maxBuffer: 4 << 20 });
      if (native.error) throw native.error;
      if (error) {
        const before = JSON.stringify(editor.snapshot());
        assert.throws(() => editor.paint(operation, scope), { message: error }, label);
        assert.equal(JSON.stringify(editor.snapshot()), before, label);
        assert.equal(native.status, 1, label);
        assert.equal(native.stderr.replace(/\r?\n$/, ''), error, label);
      } else {
        assert.deepEqual(editor.paint(operation, scope), expected.target, label);
        assert.equal(JSON.stringify(editor.snapshot()), JSON.stringify(expected.document), label);
        assert.equal(native.status, 0, native.stderr || label);
        const result = JSON.parse(native.stdout);
        assert.deepEqual(result.target, expected.target, 'native ' + label);
        assert.equal(JSON.stringify(result.document), JSON.stringify(expected.document), 'native ' + label);
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  console.log('Matched ' + rows.length + ' original shape operations (' + rows.filter(row => row.error).length + ' rejections).');
}

