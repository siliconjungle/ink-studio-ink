import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor, createPixelEditor, openPixelDocument, rasterizePixelFrame } from '../web/pixel-document.mjs';
import { runCommands, verifyCommands } from './pixel-commands.mjs';

const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const exportDoc = command('export');
const png = (options = {}) => command('export', { artifact: 'png', options });
const draw = patch => command('draw', { patch });
const sha = document => createHash('sha256').update(JSON.stringify(document)).digest('hex');

export function literalDocument(size = 512) {
  const names = Array.from({ length: 128 }, (_, i) => 'swatch-' + i);
  const palette = Object.fromEntries(names.map((name, i) => [name, '#' +
    ((i * 17547 + 45127) & 0xffffff).toString(16).padStart(6, '0')]));
  let seed = 92187;
  const slots = Array.from({ length: size * size }, () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    const value = (seed >>> 20) & 255;
    return value >= 248 ? null : names[value & 127];
  });
  return {
    format: 'ink-studio/pixel-art', version: 2, width: size, height: size, pixelAspect: [1, 1],
    palette, layers: [{ id: 'ink' }],
    frames: [{ id: 'front', durationMs: 100, cels: { ink: { slots, label: 'Authored drawing', id: 'native-plane', marks: [] } } }],
  };
}

export function planeCases(root) {
  const { createEditor } = createRequire(import.meta.url)(resolve(root, 'cli/pixel-art.js'));
  const cases = [];
  function add(label, document, schedule) {
    const editor = createEditor(document);
    const revision = editor.describe().revision;
    const opened = editor.snapshot();
    const slots = editor.stamp({ layer: 'ink' }).slots.map(slot => slot ?? -1);
    const steps = schedule(editor).map(command => ({ op: 'execute', command }));
    const replies = steps.map(({ command }) => ({ value: editor.execute(command) }));
    cases.push({ label, request: { document, steps }, replies, opened, revision, slots });
  }

  const full = literalDocument();
  add('262,144 literal slots at the native maximum', full, editor => {
    const patch = { id: 'scratch', frame: 'front', cel: 'native-plane', revision: editor.describe().revision,
      operation: { tool: 'rgba', pixels: [{ at: [2, 3], rgba: [21, 33, 56, 0], swatch: 'new-pigment' }] } };
    return [exportDoc, png({ layer: 'ink', colorMode: 'rgba' }), draw(patch), exportDoc,
      png({ layer: 'ink', colorMode: 'rgba' }), command('undo'), exportDoc,
      command('redo'), exportDoc];
  });

  const held = literalDocument(8);
  held.palette['swatch-127'] = held.palette['swatch-126'];
  held.layers.unshift({ id: 'under' });
  held.frames[0].cels.under = { marks: [], slots: Array(64).fill('swatch-4') };
  held.frames.push({ id: 'back', durationMs: 54, cels: {
    ink: { id: 'held', label: 'Instance', offset: [1, 1], hold: 'native-plane' },
  } });
  add('independent slot planes and a shifted held drawing', held, editor => {
    const patch = { id: 'repaint', frame: 'back', cel: 'held', revision: editor.describe().revision,
      operation: { tool: 'rgba', pixels: [{ at: [4, 4], rgba: [12, 11, 10, 31], swatch: 'repainted' }] } };
    const backPng = png({ cel: 'held', layer: 'ink', colorMode: 'indexed' });
    return [exportDoc, backPng, command('begin', { label: 'Try a separate drawing' }), draw(patch), exportDoc,
      backPng, command('cancel'), exportDoc, backPng, draw(patch), command('undo'), exportDoc];
  });

  const legacy = {
    format: 'ink-studio/pixel-art', version: 1, width: 4, height: 3, palette: { black: '#000000', blue: '#0244bc' },
    layers: [{ slots: ['blue', 'black', ...Array(10).fill(null)], id: 'ink', marks: [] }],
  };
  add('legacy slot migration and a stable document revision', legacy, () =>
    [exportDoc, png({ layer: 'ink' }), command('validate')]);
  return cases;
}

export async function jsPlaneWitness(document) {
  const opened = await openPixelDocument(document);
  const direct = rasterizePixelFrame(document, { layer: 'ink' });
  const editor = await createPixelCommandEditor(document);
  return { opened, slots: Array.from(direct.slots), revision: await editor.revision() };
}

async function main(root, native) {
  const cases = planeCases(root);
  const temp = mkdtempSync(join(tmpdir(), 'ink-slot-planes-'));
  try {
    for (const { label, request, replies, opened, revision, slots } of cases) {
      const { document, steps } = request;
      const witness = await jsPlaneWitness(document);
      assert.deepEqual(witness.opened.document, opened, 'direct open ' + label);
      assert.equal(JSON.stringify(witness.opened.document), JSON.stringify(opened), 'direct field order ' + label);
      assert.equal(witness.opened.revision, revision);
      assert.equal(witness.opened.legacyRevision, document.version === 1 ? sha(document) : null);
      assert.equal(witness.revision, revision);
      assert.deepEqual(witness.slots, slots, 'direct raster ' + label);
      const editor = await createPixelCommandEditor(document);
      const retained = createPixelEditor(document);
      const before = retained.snapshot();
      before.frames[0].cels.ink.slots[0] = 'changed-by-caller';
      assert.equal(JSON.stringify(retained.snapshot()), JSON.stringify(opened), 'detached snapshot ' + label);
      verifyCommands(await runCommands(editor, steps), replies, 'JavaScript ' + label);
      if (native) {
        const file = join(temp, 'request.json');
        const call = (name, input) => {
          writeFileSync(file, JSON.stringify(input));
          const result = spawnSync(resolve(native), name ? [name, file] : [file],
            { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
          assert.equal(result.status, 0, result.stderr);
          return result.stdout.trim().split('\n').map(line => JSON.parse(line));
        };
        const open = call(null, document)[0];
        assert.equal(JSON.stringify(open.document), JSON.stringify(opened), 'native open ' + label);
        assert.equal(open.revision, revision);
        const raster = call('raster', { document, layer: 'ink' })[0];
        assert.deepEqual(raster.slots, slots, 'native direct raster ' + label);
        verifyCommands(call('journal-document', request), replies, 'Rust ' + label);
      }
    }
    console.log(JSON.stringify({ cases: cases.length, replies: cases.reduce((n, row) => n + row.replies.length, 0),
      literalSlots: 512 * 512, pairedWithNative: Boolean(native) }));
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
