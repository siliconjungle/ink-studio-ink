import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelEditor } from '../web/pixel-document.mjs';

const baseColor = [203, 69, 25];
const withAlpha = (color, alpha = 255) => [...color, alpha];
const at = (x, y, rgba, swatch) => ({ at: [x, y], rgba, ...(swatch !== undefined && { swatch }) });
const rgba = pixels => ({ tool: 'rgba', layer: 'ink', pixels });
const replace = (selection = 'pair', from = 'brass', to = 'shadow') => ({
  tool: 'replace-swatch', layer: 'ink', selection, from, to,
});
const save = (id, query, settings = {}) => ({ id, query, ...settings });

export function fixture(extra = {}) {
  const marks = [
    { swatch: 'brass', runs: [[0, 0, 1], [0, 2, 1], [0, 6, 2], [2, 0, 5], [4, 5, 4]] },
    { swatch: 'accent', runs: [[0, 1, 1], [1, 3, 4]] },
    { swatch: 'shadow', runs: [[0, 5, 1], [2, 6, 3], [3, 2, 6]] },
    { swatch: null, at: [4, 0] },
    { alpha: 3, runs: [[0, 2, 1]] },
    { alpha: 0, runs: [[0, 5, 1], [0, 6, 1]] },
    { alpha: 127, runs: [[1, 3, 4], [2, 7, 2]] },
  ];
  return {
    format: 'ink-studio/pixel-art', version: 2, width: 10, height: 7, pixelAspect: [1, 1],
    palette: { brass: '#cb4519', accent: { color: '#CB4519', label: 'Alias' },
      shadow: '#212831', 'rgb-0c2238': '#aabbcc', 'rgb-0c2238-2': '#ddeeff' },
    layers: [{ id: 'ink' }],
    frames: [{ id: 'front', durationMs: 100, cels: { ink: { id: 'source', marks } } },
      { id: 'back', durationMs: 200, cels: { ink: { id: 'held', hold: 'source', offset: [1, 1] } } }],
    selections: [{ id: 'pair', pixels: [[1, 0], [0, 0], [6, 0], [9, 6], [3, 2]] },
      { id: 'empty', pixels: [] }, { id: 'rear', frame: 'back', pixels: [[1, 1], [3, 1], [1, 3]] }],
    ...extra,
  };
}

export function denseFixture() {
  return fixture({ width: 512, height: 512,
    frames: [{ id: 'front', durationMs: 100, cels: {} }],
    selections: [] });
}

export function densePixels(width, height) {
  return Array.from({ length: width * height }, (_, i) =>
    at(i % width, Math.floor(i / width), [33, 40, 49, 255]));
}

const oracle = root => createRequire(import.meta.url)(resolve(root, 'cli/pixel-art.js')).createEditor;

export function pixelsEditCases(root, { large = true } = {}) {
  const create = oracle(root);
  const rows = [];
  const base = fixture();
  function add(kind, label, operation, document = base, scope = { frame: 'front' }) {
    const editor = create(document);
    const patch = { id: 'case', revision: editor.describe().revision, operation, ...scope,
      ...(kind === 'mask' && { destination: 'selections' }) };
    const request = { document, operation, ...scope };
    const preview = editor.previewEdit(patch);
    rows.push(preview.valid ? { kind, label, request, expected: { target: preview.targets[0], document: editor.apply(patch) } }
      : { kind, label, request, error: preview.conflicts[0].message });
  }
  const mask = (label, operation, document, scope) => add('mask', label, operation, document, scope);
  const edit = (label, operation, document, scope) => add(operation.tool === 'rgba' ? 'rgba' : 'replace', label, operation, document, scope);
  const queries = [
    { type: 'rectangle', rect: [1, 0, 7, 3] }, { type: 'ellipse', rect: [1, 0, 7, 5] },
    { type: 'lasso', points: [[0, 0], [5, 4], [0, 5]] },
    { type: 'polygon', points: [[1, 1], [6, 3], [3, 5], [5, 0]] },
    { type: 'pixels', pixels: [[6, 0], [2, 0], [5, 1], [3, 4]] }, { type: 'pixels', pixels: [] },
    { type: 'wand', at: [0, 0], connected: false },
    { type: 'wand', at: [2, 0], tolerance: 100, connected: true },
    { type: 'swatch', id: 'accent' }, { type: 'swatch', at: [1, 0] }, { type: 'swatch', id: 'none' },
    { type: 'recall', id: 'pair' }, { type: 'recall', id: 'empty' },
    { type: 'cluster', at: [1, 0], connectivity: 8, source: { type: 'swatch', id: 'accent' } },
    { type: 'combine', base: { type: 'swatch', id: 'brass' }, with: { type: 'recall', id: 'pair' } },
    { type: 'subtract', base: { type: 'recall', id: 'pair' }, with: { type: 'pixels', pixels: [[1, 0]] } },
    { type: 'intersect', base: { type: 'recall', id: 'pair' }, with: { type: 'rectangle', rect: [0, 0, 6, 4] } },
    { type: 'grow', amount: 1, source: { type: 'swatch', id: 'accent' } },
    { type: 'outline', amount: 2, side: 'inside', source: { type: 'rectangle', rect: [0, 0, 5, 4] } },
  ];
  for (const query of queries) {
    mask('save composite query', save('one', query));
    mask('replace saved row from layer', save('pair', query, { layer: 'ink' }));
    mask('save held cel query', save('one', query, { cel: 'held' }), base, { frame: 'back' });
  }
  mask('save existing frame scope with empty result', save('rear', { type: 'pixels', pixels: [] }));
  mask('save existing name from a different frame', save('pair', { type: 'recall', id: 'rear' }), base, { frame: 'back' });
  mask('source check accepts empty sources', save('one', queries[0], { sources: [] }));
  for (const input of [{}, save('Invalid', queries[0]), save('ok', queries[0], { extra: true }),
    save('ok', queries[0], { layer: 'ink', cel: 'source' }), save('ok', queries[0], { layer: 'missing' }),
    save('ok', queries[0], { cel: 'held' }), save('ok', queries[0], { sources: [{ id: 'synthetic' }] }),
    save('ok', queries[0], { sources: null }), save('ok', queries[0], { targetRevision: '0'.repeat(64) }),
    save('ok', { type: 'pixels', pixels: [[0, 0], [0, 0]] }), save('ok', { type: 'pixels', pixels: [[10, 7]] }),
    save('ok', { type: 'recall', id: 'rear' }), save('ok', { type: 'recall', id: 'missing' }),
    save('ok', null), save('ok', undefined),
  ]) mask('invalid saved selection edit', input);

  edit('replace raw slot including hidden pigment', replace());
  edit('swatch aliases remain distinct', replace('pair', 'accent', 'brass'));
  edit('save empty selection is a no-op for replacement', replace('empty'));
  edit('no matching slot', replace('pair', 'shadow', 'brass'));
  edit('held-cel replacement', { ...replace('rear'), layer: undefined }, base, { cel: 'held' });
  edit('recolor protected relevant site', replace(), fixture({ protectedDetails: [{ id: 'lock', pixels: [[6, 0]] }] }));
  edit('recolor skips protected non-matching site', replace(), fixture({ protectedDetails: [{ id: 'lock', pixels: [[1, 0]] }] }));
  edit('recolor protected held frame', replace(), fixture({ protectedDetails: [{ id: 'lock', frame: 'back', pixels: [[1, 1]] }] }));
  for (const input of [replace('missing'), replace('rear'), replace(5), replace('bad id'), replace('pair','brass','brass'),
    replace('pair','missing','brass'), replace('pair','brass','missing'), { ...replace(), tool: 'replace-swatch', swatch: 'brass' },
    { ...replace(), layer: 'missing' }
  ]) edit('invalid swatch replacement', input);

  edit('RGBA aliases, hidden pigment, clear and knocked out sites',
    rgba([at(1, 0, withAlpha(baseColor, 17)), at(3, 0, withAlpha(baseColor, 0), 'glaze'),
      at(2, 0, null), at(4, 0, [12, 34, 56, 200]), at(5, 0, [33, 40, 49, 255]),
      at(7, 0, [12, 34, 56, 64])]));
  edit('palette order follows input order, run order follows first pixel',
    rgba([at(8, 0, [10, 20, 30, 230], 'new-a'), at(0, 0, [40, 50, 60, 1], 'new-b'),
      at(3, 0, [10, 20, 30, 0]), at(1, 0, [40, 50, 60, 0]), at(2, 0, [40, 50, 60, 230]), at(5, 0, null)]));
  edit('same color with new explicit alias', rgba([at(1, 0, withAlpha(baseColor), 'explicit-alias')]));
  edit('first compatible color chosen for empty site', rgba([at(3, 0, withAlpha(baseColor))]));
  edit('retained pigment keeps existing duplicate swatch', rgba([at(1, 0, withAlpha(baseColor))]));
  edit('restore zero alpha without a pigment mark', rgba([at(6, 0, withAlpha(baseColor))]));
  edit('clear an existing knockout', rgba([at(4, 0, null)]));
  edit('RGBA marks remain in local offset and preserve alpha', { ...rgba([at(2, 1, [12, 34, 56, 24]),
    at(7, 1, withAlpha(baseColor, 147)), at(6, 1, null)]), layer: undefined }, base, { cel: 'held' });
  edit('no-op protected', rgba([at(0, 0, withAlpha(baseColor))]),
    fixture({ protectedDetails: [{ id: 'lock', pixels: [[0, 0]] }] }));
  edit('reject protected', rgba([at(0, 0, null)]),
    fixture({ protectedDetails: [{ id: 'lock', pixels: [[0, 0]] }] }));

  const clipped = fixture({ selections: base.selections.filter(row => row.frame !== 'back'), layers: [{ id: 'mask', kind: 'mask' }, { id: 'ink', clip: 'mask' }],
    frames: [{ ...base.frames[0], cels: { ...base.frames[0].cels, mask: { marks: [
      { swatch: 'brass', at: [0, 0] },
    ] } } }] });
  edit('accept in clip mask', rgba([at(0, 0, [232, 121, 45, 20])]), clipped);
  edit('reject beyond clip mask', rgba([at(1, 0, null)]), clipped);
  edit('accept clipped RGBA no-op', rgba([at(1, 0, withAlpha(baseColor))]), clipped);
  edit('reject clipped swatch replacement', replace('pair', 'accent', 'brass'), clipped);
  edit('reject paint outside shifted cel after validation',
    { ...rgba([at(0, 0, [120, 131, 140, 5])]), layer: undefined }, base, { cel: 'held' });

  for (const pixels of [[], null, 1, [{ rgba: [0, 0, 0, 255] }], [{ at: [0, 0] }], [at(0, 0, [1, 2, 3])],
    [at(0, 0, [1, 2, 3, 256])], [at(0, 0, [1, 2, 3, -1])], [at(0, 0, [1, 2, 3, .5])],
    [at(0, 0, [1, 2, 3, '255'])], [at(10, 0, null)], [at(0, -1, null)], [at(.5, 0, null)],
    [at(0, 0, null, 'alias')], [{ ...at(0, 0, [1, 2, 3, 255]), extra: true }],
    [at(0, 0, [1, 2, 3, 255], '')], [at(0, 0, [1, 2, 3, 255], 'BAD')],
    [at(0, 0, [1, 2, 3, 255], null)], [at(0, 0, [1, 2, 3, 255], 'accent')],
    [at(2, 0, null), at(2, 0, null)], [at(8, 6, null), at(8, 6, [1, 2, 3, 45], 'BAD')],
    Array.from({ length: 71 }, () => at(0, 0, null)),
  ]) edit('invalid RGBA operation', rgba(pixels));
  const full = fixture({ width: 10, height: 7, frames: [{ id: 'front', durationMs: 100, cels: {} }], selections: [],
    palette: Object.fromEntries(Array.from({ length: 255 }, (_, i) => ['color-' + i, '#121212'])) });
  edit('palette capacity blocks additional RGB', rgba([at(1, 1, [1, 2, 3, 255])]), full);
  edit('palette capacity permits a compatible swatch', rgba([at(1, 1, [18, 18, 18, 0], 'color-254')]), full);

  let seed = 214817;
  const random = max => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) >>> 7) % max;
  for (let i = 0; i < 125; i++) {
    const used = new Set();
    const count = 1 + random(25);
    while (used.size < count) used.add(random(70));
    const colors = [withAlpha(baseColor, 0), withAlpha(baseColor, 255), [33, 40, 49, 23],
      [12, 34, 56, 97], [0, 0, 0, 0], [254, 255, 252, 255], null];
    const points = [...used].map((p, j) => {
      const color = colors[random(colors.length)];
      return at(p % 10, Math.floor(p / 10), color, color && j === 1 ? 'new-' + i : undefined);
    });
    edit('seeded exact RGBA write', rgba(points));
  }
  if (large) {
    const dense = denseFixture();
    mask('full 512 × 512 saved mask', save('all', { type: 'rectangle', rect: [0, 0, 512, 512] }), dense);
    edit('full 512 × 512 exact alpha/RGB operation', rgba(densePixels(512, 512)), dense);
    const existing = Array.from({ length: 512 * 512 }, (_, i) => [i % 512, Math.floor(i / 512)]);
    mask('two full 512 × 512 masks survive one snapshot',
      save('second', { type: 'recall', id: 'first' }),
      { ...dense, selections: [{ id: 'first', frame: 'front', pixels: existing }] });
  }
  return rows;
}

export function editSequence(root) {
  const document = fixture({ layers: [{ id: 'base' }, { id: 'ink' }, { id: 'top' }] });
  const editor = oracle(root)(document);
  const scope = { frame: 'front' };
  const query = { type: 'recall', id: 'pair' };
  const steps = [
    ['mask', save('pair', { type: 'rectangle', rect: [0, 0, 8, 1] }, { layer: 'ink' })],
    ['replace', replace()],
    ['rgba', rgba([at(3, 0, [21, 12, 140, 97], 'glaze'), at(4, 0, null), at(6, 0, [33, 40, 49, 255])])],
    ['mask', save('pair', { type: 'swatch', id: 'glaze' }, { cel: 'source' })],
    ['replace', replace('pair', 'glaze', 'accent')],
    ['mask', save('pair', { type: 'pixels', pixels: [] })],
    ['rgba', rgba([at(3, 0, withAlpha(baseColor, 255), 'accent')])],
    ['rgba', { ...rgba([at(7, 1, [25, 41, 95, 121])]), layer: 'top' }],
    ['rgba', { ...rgba([at(8, 1, [13, 45, 22, 112])]), layer: 'base' }],
  ].map(([kind, operation], i) => {
    const patch = { id: 'edit-sequence-' + i, operation, revision: editor.describe().revision, ...scope,
      ...(kind === 'mask' && { destination: 'selections' }) };
    const target = editor.previewEdit(patch).targets[0];
    const saved = editor.apply(patch);
    return { kind, operation, target, document: saved, selected: editor.select(query, scope).pixels };
  });
  return { document, scope, query, steps };
}

function perform(editor, kind, operation, scope) {
  return kind === 'mask' ? editor.saveSelection(operation, scope) : editor.paint(operation, scope);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-color-edits.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  const original = process.argv[2];
  const cases = pixelsEditCases(original);
  const dir = mkdtempSync(join(tmpdir(), 'ink-color-'));
  try {
    const file = join(dir, 'request.json');
    for (const [i, { kind, label, request, expected, error }] of cases.entries()) {
      const { document, operation, ...args } = request;
      const scope = Object.fromEntries(Object.entries(args).filter(([, value]) => value !== undefined));
      const op = JSON.parse(JSON.stringify(operation));
      const editor = createPixelEditor(document);
      const before = JSON.stringify(editor.snapshot());
      const title = i + ' ' + kind + ' ' + label;
      if (error) {
        assert.throws(() => perform(editor, kind, op, scope), { message: error }, title);
        assert.equal(JSON.stringify(editor.snapshot()), before, title);
      } else {
        assert.deepEqual(perform(editor, kind, op, scope), expected.target, title);
        assert.equal(JSON.stringify(editor.snapshot()), JSON.stringify(expected.document), title);
      }
      if (process.argv[3] === '--javascript') continue;
      writeFileSync(file, JSON.stringify(request));
      const command = kind === 'mask' ? 'save-selection-document' : 'paint-document';
      const native = spawnSync(process.argv[3], [command, file], { encoding: 'utf8', maxBuffer: 8 << 20 });
      if (native.error) throw native.error;
      assert.equal(native.status, error ? 1 : 0, native.stderr || title);
      if (error) assert.equal(native.stderr.replace(/\r?\n$/, ''), error, title);
      else {
        const result = JSON.parse(native.stdout);
        assert.deepEqual(result.target, expected.target, 'native ' + title);
        assert.equal(JSON.stringify(result.document), JSON.stringify(expected.document), 'native ' + title);
      }
    }
    const sequence = editSequence(original);
    const editor = createPixelEditor(sequence.document);
    for (const step of sequence.steps) {
      assert.deepEqual(perform(editor, step.kind, step.operation, sequence.scope), step.target);
      const saved = editor.snapshot();
      assert.equal(JSON.stringify(saved), JSON.stringify(step.document));
      assert.deepEqual(editor.select(sequence.query, sequence.scope).pixels, step.selected);
      assert.deepEqual(createPixelEditor(saved).select(sequence.query, sequence.scope).pixels, step.selected);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  console.log('Matched ' + cases.length + ' original edit operations (' + cases.filter(row => row.error).length +
    ' rejections) and a retained sequence.');
}

