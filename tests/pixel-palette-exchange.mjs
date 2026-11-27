import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor, createPixelEditor, extractPixelPngPalette } from '../web/pixel-document.mjs';
import { authoredPng } from './pixel-png-import.mjs';

const require = createRequire(import.meta.url);
const document = {
  format: 'ink-studio/pixel-art', version: 2, width: 4, height: 2, pixelAspect: [1, 1],
  palette: { brass: { color: '#CB4519', label: 'Brass', locked: true }, ochre: '#cb4519', dusk: '#557799' },
  ramps: [{ id: 'metal', label: 'Metal', swatches: ['brass', 'dusk'] }],
  layers: [{ id: 'back' }, { id: 'ink', opacity: 0.5 }],
  frames: [
    { id: 'first', durationMs: 100, cels: {
      back: { slots: ['brass', 'dusk', 'ochre', null, null, null, 'brass', 'dusk'], marks: [] },
      ink: { slots: ['dusk', 'ochre', null, 'brass', null, null, 'dusk', null],
        marks: [{ alpha: 0, runs: [[0, 1, 1]] }, { alpha: 127, runs: [[0, 3, 1]] }] },
    } },
    { id: 'held', durationMs: 120, cels: { back: { hold: 'first/back' }, ink: { hold: 'first/ink' } } },
  ],
};
const old = { format: 'ink-studio/pixel-art', version: 1, width: 3, height: 1,
  palette: { ink: '#102030', edge: '#998800' }, layers: [{ id: 'art', marks: [{ swatch: 'ink', at: [0, 0] }] }] };
const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const asReply = async action => {
  try { return { value: await action() }; }
  catch (error) { return { error: error.message }; }
};

export function exchangeCases(root) {
  const original = require(resolve(root, 'cli/pixel-art.js'));
  const extract = require(resolve(root, 'src/palette-extract.js')).extract;
  const fromExtraction = require(resolve(root, 'src/pixel-palette.js')).fromExtraction;
  const { paletteSource, encode, encodeIndexed } = require(resolve(root, 'cli/png.js'));
  const { chunk } = require(resolve(root, 'src/png-bytes.js'));
  const legacy = original.createEditor(old);
  const retained = original.createEditor(document);
  const palette = retained.palette();
  const documentRows = [
    { label: 'composite preserves the original blends', settings: {} },
    { label: 'raw held layer keeps invisible pigment', settings: { frame: 'held', layer: 'ink', alpha: 'all' } },
    { label: 'opaque excludes partial and hidden paint', settings: { frame: 'first', layer: 'ink', alpha: 'opaque' } },
    { label: 'weighted mean on the selected held frame', settings: { frame: 'held', size: 1, alpha: 'all' } },
    { label: 'invalid palette size', settings: { size: 0 } },
    { label: 'invalid alpha mode', settings: { alpha: 'mixed' } },
    { label: 'unknown layer', settings: { layer: 'other' } },
    { label: 'unknown frame', settings: { frame: 'other' } },
  ];
  const reply = action => {
    try { return { value: action() }; } catch (error) { return { error: error.message }; }
  };
  for (const row of documentRows) row.expected = reply(() => retained.extractPalette(row.settings));
  const changes = [];
  const start = retained.describe().revision;
  const definition = command('apply', { patch: { id: 'palette-rename', revision: start,
    destination: 'palette', operation: { type: 'swatch', swatch: { id: 'brass', label: 'New brass' } } } });
  changes.push({ request: command('begin', { label: 'Palette draft' }), expected: retained.execute(command('begin', { label: 'Palette draft' })) });
  changes.push({ request: definition, expected: retained.execute(definition) });
  changes.push({ request: { palette: true }, expected: retained.palette() });
  changes.push({ request: command('cancel'), expected: retained.execute(command('cancel')) });
  changes.push({ request: { palette: true }, expected: retained.palette() });

  const indexed = encodeIndexed(5, 1, [2, 1, 0, 2, null], [[18, 52, 86], [18, 52, 86], [190, 78, 20], [0, 0, 255]]);
  const indexedAdam = authoredPng(chunk, { width: 13, height: 7, color: 3, bits: 2, interlace: true,
    palette: [[220, 29, 3], [220, 29, 3], [30, 80, 120], [9, 9, 9]],
    transparency: [255, 128, 0], sample: (x, y) => [(x + y) % 3] });
  const indexedTransparent = authoredPng(chunk, { width: 1, height: 1, color: 3, bits: 1,
    palette: [[220, 29, 3]], transparency: [0], sample: () => [0] });
  const rgba16 = authoredPng(chunk, { width: 7, height: 5, color: 6, bits: 16, interlace: true,
    sample: (x, y) => [x * 5432, y * 12345, 32768 + x, [0, 1, 65534, 65535][(y + x) % 4]] });
  const gray16 = authoredPng(chunk, { width: 5, height: 2, color: 0, bits: 16, transparency: [0, 1],
    sample: (x, y) => [[0, 1, 32767, 32768, 65535][x]] });
  const rgbKey = authoredPng(chunk, { width: 5, height: 3, color: 2, bits: 8, transparency: [0, 10, 0, 20, 0, 30],
    sample: (x, y) => [10 + x, 20, 30 + y] });
  const rgba = (w, h) => encode(w, h, Uint8Array.from({ length: w * h * 4 }, (_, n) => {
    const i = n >>> 2, rgb = (i * 8402641) & 0xffffff;
    return n % 4 === 3 ? [255, 128, 0, 255, 255][i % 5] : (rgb >>> ((2 - n % 4) * 8)) & 255;
  }), 4);
  const ordinary = rgba(31, 19);
  const many = rgba(257, 257);
  const wide = rgba(769, 7);
  const duplicateAnnotation = Buffer.concat([indexed.subarray(0, 33), chunk('inKD', Uint8Array.of(1)),
    chunk('inKD', Uint8Array.of(2)), indexed.subarray(33)]);
  const capacity = Array.from({ length: 256 }, (_, i) => [i, 41, 88]);
  const limit = encodeIndexed(255, 1, Array.from({ length: 255 }, (_, i) => i), capacity);
  const aboveLimit = encodeIndexed(256, 1, Array.from({ length: 256 }, (_, i) => i), capacity);
  const indexedFiltered = authoredPng(chunk, { width: 7, height: 5, color: 3, bits: 8,
    palette: [[220, 29, 3], [30, 80, 120]], sample: (x, y) => [(x + y) % 2] });
  const invalidSlot = authoredPng(chunk, { width: 2, height: 1, color: 3, bits: 8,
    palette: [[220, 29, 3]], sample: x => [x] });
  const invalid = Buffer.from([137, 80, 78]);
  const pngRows = [
    ['unused slots and duplicate visible RGB', indexed, { size: 1 }],
    ['transparent source slots and equal colors', indexed, { alpha: 'all' }],
    ['Adam7 indexed with mixed opacity', indexedAdam, {}],
    ['Adam7 indexed opaque only', indexedAdam, { alpha: 'opaque' }],
    ['all indexed pixels excluded', indexedTransparent, {}],
    ['sixteen-bit visible distinguishes alpha one', rgba16, { alpha: 'visible', size: 12 }],
    ['sixteen-bit opaque excludes 65534', rgba16, { alpha: 'opaque', size: 12 }],
    ['sixteen-bit grayscale transparency', gray16, { alpha: 'all', size: 4 }],
    ['true-color tRNS alpha', rgbKey, { alpha: 'opaque' }],
    ['deterministic weighted median cut', ordinary, { alpha: 'all', size: 17 }],
    ['256 output rows exceed editable palette capacity', ordinary, { alpha: 'all', size: 256 }],
    ['larger-than-editable reference', wide, { size: 7 }],
    ['more than 65,536 colors', many, { alpha: 'all', size: 32 }],
    ['reference extraction ignores paint annotations', duplicateAnnotation, { alpha: 'all' }],
    ['255 used slots with a 256-entry source table', limit, { size: 1 }],
    ['256 used indexed slots exceed editable capacity', aboveLimit, {}],
    ['filtered eight-bit indices use the full decoder', indexedFiltered, {}],
    ['unfiltered indexed scan validates every source slot', invalidSlot, {}],
    ['bad format', invalid, {}],
  ].map(([label, bytes, settings]) => ({ label, bytes, settings,
    expected: reply(() => fromExtraction(extract(paletteSource(bytes), settings))) }));
  return { document, old, legacy: legacy.palette(), palette, documentRows, pngRows, changes };
}

export async function browserExchange(fixture, open, raw, png, reply) {
  const editor = await open(fixture.document);
  const result = { palette: await editor.palette(), legacy: raw(fixture.old).palette(), documentRows: [], pngRows: [], changes: [] };
  for (const row of fixture.documentRows) result.documentRows.push(await reply(() => editor.extractPalette(row.settings)));
  for (const row of fixture.pngRows) result.pngRows.push(await reply(() => png(Uint8Array.from(row.bytes), row.settings)));
  for (const row of fixture.changes) result.changes.push(row.request.palette ? await editor.palette() : await editor.execute(row.request));
  return result;
}

export function verifyExchange(result, fixture, label) {
  assert.deepEqual(result.palette, fixture.palette, label);
  assert.deepEqual(result.legacy, fixture.legacy, label);
  for (const section of ['documentRows', 'pngRows']) {
    assert.equal(result[section].length, fixture[section].length, label);
    result[section].forEach((row, i) => assert.deepEqual(row, fixture[section][i].expected, label + ' ' + fixture[section][i].label));
  }
  assert.deepEqual(result.changes, fixture.changes.map(row => row.expected), label + ' draft');
}

function nativeExchange(binary, original, scratch, fixture) {
  const write = (name, value) => {
    const path = join(scratch, name);
    writeFileSync(path, value);
    return path;
  };
  const read = file => JSON.parse(readFileSync(file, 'utf8'));
  function run(command, status = 0, cwd) {
    const result = spawnSync(command[0], command.slice(1), { cwd, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    assert.equal(result.status, status, result.stderr || result.stdout);
    return result;
  }
  const sdk = (args, status) => run([process.execPath, 'cli/ink-studio.js', 'pixel-art', 'palette', ...args], status, original);
  const cli = (args, status) => run([binary, 'palette', ...args], status);
  const source = write('source.json', JSON.stringify(fixture.document));
  const old = write('old.json', JSON.stringify(fixture.old));
  const out = join(scratch, 'out.json'), reference = join(scratch, 'original-output.json');
  const report = list => list.stdout.trimEnd().split('\n').map(JSON.parse);
  const steps = [{ op: 'palette' }, ...fixture.documentRows.map(row => ({ op: 'extract-palette', options: row.settings })),
    ...fixture.changes.map(row => row.request.palette ? { op: 'palette' } : { op: 'execute', command: row.request })];
  const replies = report(run([binary, 'journal-document', write('journal.json', JSON.stringify({ document: fixture.document, steps }))]));
  assert.deepEqual(replies, [{ value: fixture.palette }, ...fixture.documentRows.map(row => row.expected),
    ...fixture.changes.map(row => ({ value: row.expected }))], 'retained SDK');
  cli(['export', old, '--out', out]);
  sdk(['export', old, '--out', reference], 0);
  assert.deepEqual(read(out), read(reference));
  cli(['export', source, '--out', out]);
  assert.deepEqual(read(out), fixture.palette);
  const target = write('target.json', JSON.stringify({ ...fixture.document, palette: { black: '#000000' }, ramps: [],
    frames: [{ id: 'blank', durationMs: 100, cels: {} }] }));
  const imported = join(scratch, 'imported.json'), importedOriginal = join(scratch, 'imported-original.json');
  const receipt = JSON.parse(cli(['import', target, out, '--out', imported]).stdout);
  const expected = JSON.parse(sdk(['import', target, out, '--out', importedOriginal], 0).stdout);
  assert.deepEqual(receipt, expected);
  assert.equal(receipt.command.runner, 'cli');
  assert.equal(JSON.stringify(read(imported)), JSON.stringify(read(importedOriginal)));
  const replayed = join(scratch, 'replayed-original.json');
  run([process.execPath, 'cli/ink-studio.js', 'pixel-art', 'replay', target,
    write('receipt.json', JSON.stringify(receipt)), '--out', replayed], 0, original);
  assert.deepEqual(read(replayed), read(imported));
  const lost = join(scratch, 'never-written.json');
  cli(['import', old, out, '--out', lost], 1);
  assert.ok(!existsSync(lost));
  const collision = cli(['import', target, out, '--out', out], 1);
  assert.match(collision.stderr, /separately from its inputs/);
  assert.deepEqual(read(out), fixture.palette);
  const flags = settings => Object.entries(settings).flatMap(([key, value]) => ['--' + key, String(value)]);
  for (const [i, row] of fixture.pngRows.entries()) {
    const file = write('source-' + i + '.png', row.bytes);
    const result = cli(['extract', file, '--out', out, ...flags(row.settings)], row.expected.error ? 1 : 0);
    assert.deepEqual(row.expected.error ? { error: result.stderr.trim() } : { value: read(out) }, row.expected, row.label);
  }
  cli(['extract', source, '--out', out, '--frame', 'held', '--layer', 'ink', '--size=3', '--alpha', 'all']);
  sdk(['extract', source, '--out', reference, '--frame', 'held', '--layer', 'ink', '--size', '3', '--alpha', 'all'], 0);
  assert.deepEqual(read(out), read(reference));
}

async function main(root, binary) {
  const fixture = exchangeCases(root);
  const actual = await browserExchange(fixture, createPixelCommandEditor, createPixelEditor, extractPixelPngPalette, asReply);
  verifyExchange(actual, fixture, 'JS');
  if (binary) {
    const scratch = mkdtempSync(join(tmpdir(), 'ink-studio-palette-exchange-'));
    try { nativeExchange(resolve(binary), resolve(root), scratch, fixture); }
    finally { rmSync(scratch, { recursive: true, force: true }); }
  }
  console.log(JSON.stringify({ documentCases: fixture.documentRows.length, pngCases: fixture.pngRows.length,
    draftReplies: fixture.changes.length, native: Boolean(binary) }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
