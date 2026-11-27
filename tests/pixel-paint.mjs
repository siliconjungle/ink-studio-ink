import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelEditor } from '../web/pixel-document.mjs';

const at = (swatch, x, y) => ({ swatch, at: [x, y] });
const fill = (swatch, x, y, layer = 'ink') => ({ tool: 'fill', layer, swatch, at: [x, y] });
const path = (tool, points, rest = {}) => ({ tool, layer: 'ink', points,
  ...(tool === 'pencil' && { swatch: 'rust' }), ...rest });
const rect = (swatch, x, y, w, h) => ({ swatch, shape: { type: 'rect', rect: [x, y, w, h] } });

function document(cels = { ink: { marks: [] } }, extra = {}) {
  return {
    format: 'ink-studio/pixel-art', version: 2, width: 8, height: 6, pixelAspect: [1, 1],
    palette: { rust: '#b53129', blue: '#213b71', equal: '#b53129' },
    layers: [{ id: 'ink' }],
    frames: [{ id: 'front', durationMs: 100, cels }],
    ...extra,
  };
}

export function paintCases(originalRoot) {
  const { createEditor } = createRequire(import.meta.url)(resolve(originalRoot, 'cli/pixel-art.js'));
  const rows = [];
  function add(source, operation, options = { frame: 'front' }) {
    const request = { document: source, operation, ...options };
    const editor = createEditor(source);
    const patch = { id: 'paint-test', revision: editor.describe().revision, ...options, operation };
    const preview = editor.previewEdit(patch);
    if (!preview.valid) {
      assert.ok(preview.conflicts.length);
      rows.push({ request, error: preview.conflicts[0].message });
      return;
    }
    const updated = editor.apply(patch);
    rows.push({ request, expected: { target: preview.targets[0], document: updated } });
  }

  const blank = document();
  const filled = document({ ink: { marks: [rect('rust', 0, 0, 8, 6),
    rect('blue', 2, 0, 1, 6), { alpha: 100, runs: [[2, 0, 2]] }] } });
  add(blank, path('pencil', [[1, 1], [2, 1], [2, 2]], { pixelPerfect: true }));
  add(blank, path('pencil', [[1, 1], [2, 1], [2, 2]], { pixelPerfect: false }));
  add(blank, path('eraser', [[0, 0], [7, 5]]));
  add(filled, path('eraser', [[0, 2], [7, 2]], { drawing: { mirrorY: 2.5 } }));
  add(filled, fill('equal', 0, 2));
  add(filled, { ...fill('equal', 0, 2), drawing: { wrapX: true, mirrorY: 3.5 } });
  add(filled, { ...fill('blue', -1, 2), drawing: { wrapX: true, mirrorX: 3 } });
  add(filled, { ...fill('rust', 1, 3), drawing: { wrapX: true, mirrorX: 3.5, mirrorY: 3 } });
  add(blank, { ...fill('rust', 2, 5), drawing: { mirrorX: -0.5, mirrorY: 5.5, wrapY: true } });
  add(blank, path('pencil', [[1, 1]], { drawing: { wrapX: 'no' } }));
  add(blank, path('pencil', [[1, 1]], { drawing: { mirrorX: 0.25 } }));
  add(blank, path('pencil', [[1, 1]], { drawing: { copy: true } }));
  add(blank, path('pencil', [[-1, 0]]));
  add(blank, path('pencil', [[-9, 0]], { drawing: { wrapX: true } }));
  add(blank, path('pencil', [[1, 1]], { swatch: 'unknown' }));
  add(blank, path('pencil', [[1, 1]], { pixelPerfect: 1 }));
  add(blank, path('eraser', [[1, 1]], { pixelPerfect: false }));
  add(blank, path('eraser', [[1, 1]], { swatch: 'rust' }));
  add(blank, path('pencil', []));
  add(blank, path('pencil', [[1, 1]], { layer: 'missing' }));
  add(blank, path('pencil', [[1, 1]]), { frame: 'front', cel: 'front/ink' });
  add(blank, { tool: 'pencil', points: [[1, 1]], swatch: 'rust' }, { cel: 'front/ink' });
  add(blank, { tool: 'pencil', points: [[1, 1]], swatch: 'rust' }, { frame: 'front', cel: 'missing' });

  const selected = document({}, { selections: [
    { id: 'islands', frame: 'front', pixels: [[4, 1], [1, 1], [2, 1], [7, 5]] },
    { id: 'empty', pixels: [] },
  ] });
  add(selected, path('pencil', [[0, 1], [7, 1]], { selection: 'islands' }));
  add(selected, { ...fill('rust', 1, 1), selection: 'islands' });
  add(selected, { ...fill('rust', 5, 2), selection: 'islands' });
  add(selected, { ...fill('rust', 1, 1), selection: 'empty' });
  add(selected, path('pencil', [[0, 1], [7, 1]], { selection: 'missing' }));
  add(document({}, { layers: [{ id: 'under' }, { id: 'ink' }], frames: [
    { id: 'front', durationMs: 100, cels: { under: { id: 'front/ink', marks: [] } } },
    { id: 'back', durationMs: 100, cels: { under: { id: 'front/ink-2', marks: [] } } },
  ] }), path('pencil', [[1, 1]]));
  add(document({ ink: { marks: [] } }, { layers: [{ id: 'ink', locked: true }] }), path('pencil', [[1, 1]]));
  add(document({ ink: { marks: [] } }, { layers: [{ id: 'group', kind: 'group', locked: true }, { id: 'ink', parent: 'group' }] }),
    path('pencil', [[1, 1]]));
  add(document({ ink: { marks: [] } }, { layers: [{ id: 'ink', kind: 'reference' }] }), path('pencil', [[1, 1]]));
  const layered = document({ guard: { marks: [at('blue', 1, 1)] },
    mask: { marks: [rect('blue', 0, 0, 6, 6)] }, ink: { marks: [] } }, { layers: [
    { id: 'guard', protect: true }, { id: 'mask', kind: 'mask' }, { id: 'ink', clip: 'mask' },
  ], protectedDetails: [{ id: 'space', kind: 'gap', pixels: [[2, 2]] }] });
  add(layered, path('pencil', [[1, 1], [3, 1]]));
  add(layered, path('pencil', [[2, 2]]));
  add(layered, path('pencil', [[4, 1], [7, 1]]));
  add(layered, path('pencil', [[4, 1], [5, 1]]));
  add(layered, fill('rust', 4, 3));
  add(layered, fill('rust', 1, 1));
  add(layered, fill('blue', 1, 2, 'mask'));
  add({ ...layered, selections: [{ id: 'only', pixels: [[3, 1]] }] },
    path('pencil', [[1, 1], [7, 1]], { selection: 'only' }));

  const held = document({}, { layers: [{ id: 'ink', offset: [1, 0] }], frames: [
    { id: 'front', durationMs: 100, cels: { ink: { id: 'root', marks: [at('rust', 1, 1)] } } },
    { id: 'back', durationMs: 100, cels: { ink: { id: 'hold', label: 'Held', hold: 'root', offset: [1, 1], opacity: 177 } } },
    { id: 'tail', durationMs: 100, cels: { ink: { hold: 'hold', offset: [-1, 0] } } },
  ] });
  add(held, path('pencil', [[3, 1], [5, 1]], { swatch: 'blue' }));
  add(held, path('pencil', [[0, 1]]));
  add(held, path('pencil', [[4, 3], [6, 3]], { swatch: 'blue' }), { frame: 'back' });
  add(held, { tool: 'eraser', points: [[3, 2]] }, { cel: 'hold' });
  add({ ...held, selections: [{ id: 'elsewhere', frame: 'back', pixels: [[0, 0]] }] },
    path('pencil', [[2, 1]], { selection: 'elsewhere' }));
  add({ ...held, protectedDetails: [{ id: 'held-dot', kind: 'pixel', frame: 'back', pixels: [[3, 2]] }] },
    path('pencil', [[2, 1]], { swatch: 'blue' }));
  add({ ...held, protectedDetails: [{ id: 'held-dot', kind: 'pixel', frames: ['back', 'tail'], pixels: [[3, 2]] }] },
    path('pencil', [[5, 3]], { swatch: 'blue' }));

  const legacy = { format: blank.format, version: 1, width: 8, height: 6, palette: blank.palette,
    layers: [{ id: 'ink', marks: [at('blue', 1, 1)] }], title: 'Legacy fixture' };
  add(legacy, path('pencil', [[2, 1], [3, 1]]), { frame: 'artwork' });
  const relay = JSON.parse(readFileSync(join(originalRoot, 'examples/pixel-art-tooling/relay.json'), 'utf8'));
  add(relay, path('eraser', [[13, 22]], { layer:'freckles' }), { frame:'artwork' });
  add(relay, path('pencil', [[23,28],[24,28]], { layer:'approved-accents', swatch:'spark' }), { frame:'artwork' });
  add(relay, fill('spark', 26, 19, 'freckles'), { frame:'artwork' });
  add(document({}, { width: 512, height: 512 }), fill('equal', 0, 0));
  add(blank, path('pencil', Array.from({ length: 4096 }, (_, i) => [i % 8, 1])));
  add(blank, path('pencil', Array.from({ length: 4097 }, (_, i) => [i % 8, 1])));

  let rng = 0xc674592d;
  function random(n) { rng = (Math.imul(rng, 1664525) + 1013904223) >>> 0; return Math.floor(rng / 2 ** 32 * n); }
  for (let i = 0; i < 96; i++) {
    const wrapX = (i & 1) !== 0, wrapY = (i & 2) !== 0;
    const drawing = { wrapX, wrapY,
      ...(i & 4 ? { mirrorX: random(17)/2-0.5 } : {}),
      ...(i & 8 ? { mirrorY: random(13)/2-0.5 } : {}) };
    const points = Array.from({ length: 1 + random(9) }, () =>
      [random(wrapX ? 24 : 8) - (wrapX ? 8 : 0), random(wrapY ? 18 : 6) - (wrapY ? 6 : 0)]);
    const op = i % 3 === 0 ? { tool:'fill', layer:'ink', swatch:'equal', at:points[0], drawing }
      : i % 3 === 1 ? path('pencil', points, { drawing, pixelPerfect:!!(i & 16), swatch:'equal' })
      : path('eraser', points, { drawing });
    add(i % 2 ? filled : blank, op);
  }
  return rows;
}

export function editorSequence(originalRoot) {
  const source = document({ ink: { id: 'source', marks: [] } }, { selections: [{ id:'pin', pixels:[[5,3],[3,3]] }] });
  const { createEditor } = createRequire(import.meta.url)(resolve(originalRoot, 'cli/pixel-art.js'));
  const original = createEditor(source);
  const editor = createPixelEditor(source);
  const query = { type: 'swatch', id: 'rust' };
  const options = { frame: 'front' };
  assert.deepEqual(editor.select(query, options).pixels, []);
  for (const operation of [path('pencil', [[0,3],[7,3]], { selection:'pin' }),
    path('eraser', [[3,3],[4,3]]), path('pencil', [[1, 1]], { drawing:{ mirrorX:3.5 } })]) {
    const patch = { id:'sequential', revision:original.describe().revision, ...options, operation };
    const target = original.previewEdit(patch).targets[0];
    assert.deepEqual(editor.paint(operation, options), target);
    assert.equal(JSON.stringify(editor.snapshot()), JSON.stringify(original.apply(patch)));
    assert.deepEqual(editor.select(query, options).pixels, original.select(query, options).pixels);
  }
  const before = JSON.stringify(editor.snapshot());
  assert.throws(() => editor.paint(path('pencil', [[20, 1]]), options), /native grid/);
  assert.equal(JSON.stringify(editor.snapshot()), before);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-paint.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  const rows = paintCases(process.argv[2]);
  const dir = mkdtempSync(join(tmpdir(), 'ink-paint-'));
  try {
    const file = join(dir, 'request.json');
    for (const [i, { request, expected, error }] of rows.entries()) {
      const { document, operation, ...scope } = request;
      const editor = createPixelEditor(document);
      const label = 'paint case ' + i + ' ' + JSON.stringify(operation);
      writeFileSync(file, JSON.stringify(request));
      const native = spawnSync(process.argv[3], ['paint-document', file], { encoding: 'utf8' });
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
    editorSequence(process.argv[2]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  console.log('Matched ' + rows.length + ' original raster paint cases and a retained editor sequence.');
}
