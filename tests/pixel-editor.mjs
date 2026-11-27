import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelEditor, selectPixelFrame } from '../web/pixel-document.mjs';
import { compiledValues, createState, JsonCodec } from '../build/pixel_document.mjs';

const recall = id => ({ type: 'recall', id });
const swatch = { type: 'swatch', id: 'rust' };
const cell = (x, y) => ({ swatch: 'rust', at: [x, y] });

export function editorFixture() {
  return {
    format: 'ink-studio/pixel-art', version: 2, width: 6, height: 5, pixelAspect: [1, 1],
    palette: { rust: '#b53129', lilac: '#a793cf' },
    layers: [{ id: 'ink' }, { id: 'finish' }],
    frames: [
      { id: 'front', durationMs: 100, cels: { ink: { id: 'ink-front', marks: [cell(1, 2), cell(4, 3)] } } },
      { id: 'back', durationMs: 100, cels: {
        ink: { id: 'ink-back', hold: 'ink-front', offset: [1, 0] },
        finish: { marks: [{ swatch: 'lilac', at: [5, 3] }] },
      } },
    ],
    selections: [
      { id: 'front-pin', frame: 'front', pixels: [[4, 3], [1, 2]] },
      { id: 'back-pin', frame: 'back', pixels: [[0, 4], [2, 2]] },
      { id: 'shared', pixels: [[1, 3], [4, 0]] },
      { id: 'blank', pixels: [] },
    ],
  };
}

function reference(originalRoot, document) {
  const { createEditor } = createRequire(import.meta.url)(resolve(originalRoot, 'cli/pixel-art.js'));
  return createEditor(document);
}

function report(value) {
  const { frame, grid, pixels } = value;
  return { frame, grid, pixels };
}

export function selectionCases(originalRoot) {
  const document = editorFixture();
  const oracle = reference(originalRoot, document);
  const rows = [];
  function add(query, options = {}, supplied) {
    const request = { document, query, ...options };
    try {
      rows.push({ request, expected: supplied ?? report(oracle.select(query, options)) });
    } catch (error) {
      rows.push({ request, error: error.message });
    }
  }
  for (const id of ['front-pin', 'back-pin', 'shared', 'blank', 'absent', '', null, 13, undefined]) {
    const query = id === undefined ? { type: 'recall' } : recall(id);
    for (const scope of [{}, { frame: 'front' }, { frame: 'back' }, { layer: 'ink' },
      { cel: 'ink-front' }, { cel: 'ink-back' }]) add(query, scope);
  }
  add(recall('front-pin'), { frame: '' });
  add(recall('front-pin'), { layer: '' });
  add(recall('front-pin'), { cel: '' });
  add(recall('front-pin'), { frame: 'back', layer: 'ink', cel: 'ink-back' });
  add({ type: 'recall', id: 'shared', extra: true });
  add({ type: 'recall', id: 'missing', extra: true });
  add({ type: 'subtract', base: swatch, with: recall('front-pin') });
  add({ type: 'subtract', base: swatch, with: recall('back-pin') });
  add({ type: 'subtract', base: swatch, with: recall('back-pin') }, { frame: 'back', layer: 'ink' });
  add({ type: 'outline', source: recall('shared'), side: 'both' });
  add({ type: 'cluster', source: recall('front-pin'), at: [1, 2], connectivity: 8 });
  add({ type: 'combine', base: recall('missing-base'), with: recall('missing-with') });
  add(recall('back-pin'), { saved: { 'back-pin': [[5, 0]] } },
    { frame: 'front', grid: [6, 5], pixels: [[5, 0]] });

  for (const invalid of [null, {}, [{ id: 'bad ?', pixels: [] }],
    [{ id: 'pin', pixels: [] }, { id: 'pin', pixels: [] }],
    [{ id: 'pin', frame: 'absent', pixels: [] }],
    [{ id: 'pin', frame: null, pixels: [] }],
    [{ id: 'pin', pixels: [[5, 5]] }],
    [{ id: 'pin', pixels: [[2, 3], [2, 3]] }],
    [{ id: 'pin', pixels: {} }],
    [{ id: 'pin', pixels: [[2, 3], [2, 3], [7, 0]] }, { id: 'pin', pixels: [] }]]) {
    const broken = { ...document, selections: invalid };
    try {
      reference(originalRoot, broken);
      throw new Error('Original accepted fixture marked invalid');
    } catch (error) {
      assert.notEqual(error.message, 'Original accepted fixture marked invalid');
      rows.push({ request: { document: broken, query: recall('pin') }, error: error.message });
    }
  }
  return rows;
}

export function checkReplacement() {
  const document = editorFixture();
  const editor = createPixelEditor(document);
  const front = { frame: 'front', grid: [6, 5], pixels: [[1, 2], [4, 3]] };
  assert.deepEqual(editor.select(swatch), front);
  document.frames[0].cels.ink.marks = [cell(0, 1)];
  assert.deepEqual(editor.select(swatch), front, 'opening owns its source');
  assert.throws(() => editor.select({ type: 'subtract', base: swatch, with: recall('front-pin') },
    { frame: 'back' }), { message: 'Pixel selection belongs to frame front' });
  assert.deepEqual(editor.select(swatch), front);
  assert.throws(() => editor.replaceDocument({ ...document, selections: null }),
    { message: 'Pixel selections must be an array' });
  assert.deepEqual(editor.select(swatch), front, 'rejected loads preserve the open artwork');
  editor.replaceDocument(document);
  assert.deepEqual(editor.select(swatch), { ...front, pixels: [[0, 1]] });
  document.width = 7;
  document.selections[0].pixels = [[6, 2]];
  editor.replaceDocument(document);
  assert.deepEqual(editor.select(recall('front-pin')), { frame: 'front', grid: [7, 5], pixels: [[6, 2]] });
  assert.deepEqual(editor.select(swatch, { frame: 'back', cel: 'ink-back' }), { frame: 'back', grid: [7, 5], pixels: [[1, 1]] });
}

function checkCache() {
  const state = createState();
  const codec = new JsonCodec(compiledValues.open_pixel_document.params[0]);
  const load = state.bind('load_pixel_editor', { resultOnly: true, inputLimits: { depth: 512 } });
  const pick = state.bind('select_pixel_editor', { resultOnly: true });
  const none = { None: null };
  const some = id => ({ Some: id });
  const encoded = codec.fromJS(swatch);
  const saved = codec.fromJS({});
  assert.ok(load(codec.fromJS(editorFixture()), [], [], []).Ok);

  const cold = state.changeToken();
  const first = pick([encoded], saved, [], some('front'), some('ink'), none);
  assert.ok(first.Ok);
  assert.deepEqual(state.changesSince(cold).changes.map(change => change.table).sort(), ['EditorImage', 'EditorScope']);
  state.releaseChangeToken(cold);

  const warm = state.changeToken();
  assert.deepEqual(pick([encoded], saved, [], none, none, some('ink-front')), first);
  assert.deepEqual(state.changesSince(warm).changes, []);
  const failure = pick([codec.fromJS(recall('front-pin'))], saved, [], some('back'), none, none);
  assert.deepEqual(failure, { Err: 'Pixel selection belongs to frame front' });
  assert.deepEqual(state.changesSince(warm).changes, []);
  assert.deepEqual(pick([encoded], saved, [], none, none, some('ink-front')), first);
  assert.deepEqual(state.changesSince(warm).changes, []);
  state.releaseChangeToken(warm);
}

function checkDenseRecall(originalRoot, native, path) {
  const document = editorFixture();
  document.width = document.height = 512;
  document.selections = [{ id: 'whole', frame: 'front',
    pixels: Array.from({ length: 512 * 512 }, (_, p) => [p % 512, Math.floor(p / 512)]).reverse() }];
  const query = recall('whole');
  const expected = report(reference(originalRoot, document).select(query));
  const editor = createPixelEditor(document);
  assert.deepEqual(editor.select(query), expected);
  assert.deepEqual(editor.select({ type: 'intersect', base: query,
    with: { type: 'rectangle', rect: [479, 511, 33, 1] } }).pixels, expected.pixels.slice(-33));
  writeFileSync(path, JSON.stringify({ document, query }));
  const result = spawnSync(native, ['select-document', path], { encoding: 'utf8', maxBuffer: 12_000_000 });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), expected);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-editor.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  const rows = selectionCases(process.argv[2]);
  const dir = mkdtempSync(join(tmpdir(), 'ink-pixel-editor-'));
  try {
    const path = join(dir, 'request.json');
    for (const [i, { request, expected, error }] of rows.entries()) {
      const { document, query, ...options } = request;
      writeFileSync(path, JSON.stringify(request));
      const native = spawnSync(process.argv[3], ['select-document', path], { encoding: 'utf8' });
      if (native.error) throw native.error;
      const label = 'editor case ' + i + ' ' + JSON.stringify({ query, options });
      const run = () => selectPixelFrame(document, query, options);
      if (error) {
        assert.throws(run, { message: error }, label);
        assert.equal(native.status, 1, label);
        assert.equal(native.stderr.replace(/\r?\n$/, ''), error, label);
      } else {
        assert.deepEqual(run(), expected, label);
        assert.equal(native.status, 0, native.stderr || label);
        assert.deepEqual(JSON.parse(native.stdout), expected, label);
      }
    }
    checkReplacement();
    checkCache();
    checkDenseRecall(process.argv[2], process.argv[3], path);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  console.log('Matched ' + rows.length + ' original editor selection and validation cases in JavaScript and native Rust.');
}
