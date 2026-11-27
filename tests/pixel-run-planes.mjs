import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor, openPixelDocument, openPixelPng, rasterizePixelFrame } from '../web/pixel-document.mjs';
import { runCommands, verifyCommands } from './pixel-commands.mjs';

const require = createRequire(import.meta.url);
const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const documentExport = command('export');
const png = options => command('export', { artifact: 'png', options: { colorMode: 'rgba', ...options } });
const revisionOf = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');

export function denseOpacityPng(root, size = 512) {
  const { encode } = require(resolve(root, 'cli/png.js'));
  const pixels = Buffer.alloc(size * size * 4);
  for (let p = 0; p < size * size; p++) {
    pixels[p * 4] = 123;
    pixels[p * 4 + 3] = 1 + p % 2;
  }
  return encode(size, size, pixels, 4);
}

export function runPlaneCases(root) {
  const oracle = require(resolve(root, 'cli/pixel-art.js'));
  const cases = [];
  function add(label, source, scope, commands, inputPng) {
    const editor = oracle.createEditor(source);
    const opened = editor.snapshot();
    const revision = editor.describe().revision;
    const legacyRevision = source.version === 1 ? revisionOf(source) : null;
    assert.equal(revision, revisionOf(opened), label);
    const compiled = oracle.compile(opened, scope.frame, scope.cel, scope.layer);
    const layer = compiled.layerSources.get(scope.layer);
    const raster = { slots: Array.from(layer.slots), alpha: Array.from(layer.alpha ?? []) };
    const steps = commands(revision).map(row => ({ op: 'execute', command: row }));
    const replies = steps.map(step => ({ value: editor.execute(step.command) }));
    cases.push({ label, source, scope, opened, revision, legacyRevision, raster, steps, replies, inputPng });
  }
  const inputPng = denseOpacityPng(root);
  const dense = oracle.documentFromPNG(inputPng);
  assert.equal(dense.frames[0].cels.image.marks.reduce((n, mark) => n + mark.runs.length, 0), 262144);
  const image = { layer: 'image' };
  add('maximum-density opacity import and retained edit', dense, image, revision => {
    const patch = { id: 'raise-opacity', frame: 'artwork', revision, operation: {
      tool: 'rgba', layer: 'image', pixels: [{ at: [0, 0], rgba: [123, 0, 0, 155], swatch: 'rgb-7b0000' }],
    } };
    return [command('validate'), png(image), command('begin', { label: 'Raise pixel opacity' }),
      command('draw', { patch }), documentExport, png(image), command('commit'),
      command('undo'), documentExport, command('redo'), png(image)];
  }, inputPng);

  const mixed = {
    format: 'ink-studio/pixel-art', version: 2, width: 8, height: 4, pixelAspect: [1, 1],
    palette: { sienna: '#bc6834', deep: '#1c2140' },
    layers: [{ id: 'ink' }], frames: [
      { id: 'front', durationMs: 100, cels: { ink: { id: 'drawing', marks: [
        { at: [0, 1], swatch: 'sienna' }, { runs: [[0, 0, 8]], swatch: 'deep' },
        { runs: [[0, 1, 6]], alpha: 16 }, { clear: true, runs: [[0, 2, 1]] },
        { swatch: null, runs: [[0, 7, 1]] },
      ] } } },
      { id: 'back', durationMs: 100, cels: { ink: { id: 'hold', hold: 'drawing', offset: [0, 1] } } },
    ],
  };
  const held = { layer: 'ink', frame: 'back' };
  add('mixed drawing detaches a held packed cel and cancels', mixed, held, revision => {
    const patch = { id: 'held-ink', frame: 'back', cel: 'hold', revision, operation: {
      tool: 'pencil', swatch: 'sienna', points: [[6, 2]],
    } };
    return [documentExport, png(held), command('begin', { label: 'Detach held drawing' }),
      command('draw', { patch }), documentExport, png(held), command('cancel'), documentExport, png(held)];
  });
  const legacy = {
    format: 'ink-studio/pixel-art', version: 1, width: 5, height: 2, palette: { deep: '#1c2140' },
    layers: [{ id: 'ink', marks: [{ runs: [[0, 0, 5]], swatch: 'deep' }, { alpha: 43, runs: [[0, 1, 3]] }] }],
    frames: 'legacy metadata',
  };
  add('legacy run order and raw revision', legacy, { layer: 'ink' }, () =>
    [command('validate'), documentExport, png({ layer: 'ink' })]);
  return cases;
}

function verifyRasters(actual, expected, label) {
  assert.deepEqual(Array.from(actual.slots), expected.slots, label);
  assert.deepEqual(Array.from(actual.alpha), expected.alpha, label);
}

async function main(root, native) {
  const cases = runPlaneCases(root);
  const tmp = mkdtempSync(join(tmpdir(), 'ink-run-planes-'));
  let count = 0;
  try {
    for (const { label, source, scope, opened, revision, legacyRevision, raster, steps, replies, inputPng } of cases) {
      const sourceToOpen = inputPng ? (await openPixelPng(inputPng)).document : source;
      const expected = { document: opened, revision, legacyRevision };
      const actual = await openPixelDocument(JSON.stringify(sourceToOpen));
      assert.deepEqual(actual, expected, label);
      assert.equal(JSON.stringify(actual.document), JSON.stringify(opened), label);
      verifyRasters(rasterizePixelFrame(sourceToOpen, scope), raster, label);
      const editor = await createPixelCommandEditor(inputPng ? JSON.stringify(sourceToOpen) : sourceToOpen);
      verifyCommands(await runCommands(editor, steps), replies, label);
      if (native) {
        const file = join(tmp, 'document.json');
        function call(input, action) {
          writeFileSync(file, JSON.stringify(input));
          const result = spawnSync(resolve(native), action ? [action, file] : [file],
            { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
          assert.equal(result.status, 0, result.stderr);
          return result.stdout.trimEnd().split('\n').map(line => JSON.parse(line));
        }
        const [actual] = call(sourceToOpen);
        assert.deepEqual(actual, expected, 'native ' + label);
        assert.equal(JSON.stringify(actual.document), JSON.stringify(opened), 'native ' + label);
        verifyRasters(call({ document: sourceToOpen, ...scope }, 'raster')[0], raster, 'native ' + label);
        verifyCommands(call({ document: sourceToOpen, steps }, 'journal-document'), replies, 'native ' + label);
      }
      count += replies.length;
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ cases: cases.length, replies: count, denseRuns: 262144, pairedWithNative: Boolean(native) }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
