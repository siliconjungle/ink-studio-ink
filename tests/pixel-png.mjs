import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor } from '../web/pixel-document.mjs';
import { runCommands } from './pixel-commands.mjs';

const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const png = options => command('export', { artifact: 'png', ...(options === undefined ? {} : { options }) });
const copy = value => JSON.parse(JSON.stringify(value));

export function pngCases(root) {
  const require = createRequire(import.meta.url);
  const { createEditor } = require(resolve(root, 'cli/pixel-art.js'));
  const layered = {
    format: 'ink-studio/pixel-art', version: 2, width: 7, height: 4, pixelAspect: [2, 1],
    palette: { brass: { color: '#CB4519', label: 'Brass 雪 🚲', locked: true }, alias: '#cb4519',
      shadow: '#212831', 'blend-80007f': '#777777', red: '#ff0000', blue: '#0000ff' },
    ramps: [{ swatches: ['shadow', 'brass', 'alias'], label: 'Ramp', id: 'warm' }],
    layers: [{ id: 'base' }, { id: 'group', kind: 'group' }, { id: 'matte', kind: 'mask', parent: 'group' },
      { id: 'ink', parent: 'group', clip: 'matte' }, { id: 'reference', kind: 'reference' }],
    frames: [{ id: 'front', durationMs: 100, cels: {
      base: { marks: [{ swatch: 'blue', at: [0, 1] }] },
      matte: { marks: [{ swatch: 'alias', runs: [[0, 0, 3], [1, 0, 2]] }] },
      ink: { id: 'front-ink', marks: [
        { swatch: 'brass', runs: [[0, 0, 3]] }, { swatch: 'alias', at: [3, 0] },
        { swatch: 'shadow', at: [6, 0] }, { swatch: null, at: [4, 0] },
        { swatch: 'red', at: [0, 1] }, { alpha: 3, runs: [[0, 2, 1]] },
        { alpha: 0, runs: [[0, 6, 1]] }, { alpha: 128, runs: [[1, 0, 1]] },
      ] },
      reference: { marks: [{ swatch: 'red', at: [1, 1] }] },
    } }, { id: 'back', durationMs: 67, cels: {
      ink: { id: 'back-ink', hold: 'front-ink', offset: [1, 1], opacity: 192 },
    } }],
    selections: [{ id: 'pair', pixels: [[0, 0], [1, 0]] }],
  };
  const cases = [];
  function add(label, document, schedule) {
    const editor = createEditor(document);
    const steps = [], replies = [];
    function run(command) {
      steps.push(copy({ op: 'execute', command }));
      try {
        const value = copy(editor.execute(command));
        replies.push({ value });
        return value;
      } catch (issue) {
        replies.push({ error: issue.message });
        return undefined;
      }
    }
    schedule(run, editor);
    cases.push({ label, request: { document, steps }, replies });
  }

  add('palette identity, raw and clipped layers, held frames, blended colors and mode validation', layered, run => {
    for (const options of [{}, { layer: 'ink' }, { layer: 'base' }, { layer: 'reference' },
      { frame: 'back' }, { cel: 'back-ink' }, { frame: 'back', layer: 'ink', cel: 'back-ink' }]) {
      for (const colorMode of ['auto', 'rgba', 'indexed']) assert.ok(run(png({ ...options, colorMode })));
    }
    assert.ok(run(png()));
    for (const options of [null, { references: false }, { colorMode: '' }, { colorMode: null }, { colorMode: ['auto'] },
      { colorMode: 'rgb' }, { frame: null }, { frame: 'missing' }, { cel: 'missing' }, { frame: 'front', cel: 'back-ink' },
      { layer: 'group' }, { layer: 'missing' }, { layer: null }]) assert.equal(run(png(options)), undefined);
  });

  const plain = (width, palette, marks) => ({
    format: 'ink-studio/pixel-art', version: 2, width, height: 1, pixelAspect: [1, 1],
    palette, layers: [{ id: 'ink' }], frames: [{ id: 'front', durationMs: 16, cels: { ink: { marks } } }],
  });
  const alphaRows = [{ swatch: 'ink', runs: [[0, 0, 256]] },
    ...Array.from({ length: 256 }, (_, alpha) => ({ alpha, runs: [[0, alpha, 1]] }))];
  add('exact 256 palette entries and indexed overflow', plain(256, { ink: '#a2339d' }, alphaRows), run => {
    assert.equal(Buffer.from(run(png({ layer: 'ink', colorMode: 'indexed' })).data, 'base64')[25], 3);
    assert.ok(run(png({ layer: 'ink', colorMode: 'rgba' })));
  });
  add('auto selects RGBA when a hole pushes the palette past capacity', plain(257, { ink: '#a2339d' }, alphaRows), run => {
    assert.equal(Buffer.from(run(png({ layer: 'ink' })).data, 'base64')[25], 6);
    assert.equal(run(png({ layer: 'ink', colorMode: 'indexed' })), undefined);
    assert.ok(run(png({ layer: 'ink', colorMode: 'rgba' })));
  });
  const fullPalette = Object.fromEntries(Array.from({ length: 255 }, (_, i) =>
    ['color-' + i, '#' + (i * 10147).toString(16).padStart(6, '0')]));
  add('unused swatches keep their original order and a hole uses the final available entry', plain(3, fullPalette, []), run => {
    assert.ok(run(png()));
    assert.ok(run(png({ layer: 'ink', colorMode: 'indexed' })));
  });
  add('opaque indexed PNG omits the transparency chunk', plain(3, { ink: '#000000', unused: '#ffffff' },
    [{ swatch: 'ink', runs: [[0, 0, 3]] }]), run => {
    assert.ok(run(png()));
    assert.ok(run(png({ colorMode: 'rgba' })));
  });

  add('draft export follows applied edits, rollback and redo', layered, (run, editor) => {
    const settings = { layer: 'ink', colorMode: 'rgba' };
    const first = run(png(settings));
    const patch = { id: 'paint', frame: 'front', revision: editor.describe().revision,
      operation: { tool: 'pencil', layer: 'ink', swatch: 'alias', points: [[1, 0]] } };
    run(command('begin', { label: 'Draft export' }));
    assert.equal(run(command('draw', { patch })).status, 'applied');
    const after = run(png(settings));
    assert.notEqual(after.data, first.data);
    run(command('cancel'));
    assert.deepEqual(run(png(settings)), first);
    run(command('draw', { patch }));
    run(command('undo'));
    assert.deepEqual(run(png(settings)), first);
    run(command('redo'));
    assert.deepEqual(run(png(settings)), after);
  });

  add('legacy palette and document upgrade', {
    format: 'ink-studio/pixel-art', version: 1, width: 3, height: 2,
    palette: { line: '#ad4634' }, layers: [{ id: 'ink', marks: [{ swatch: 'line', at: [1, 1] }] }],
  }, run => {
    assert.ok(run(png()));
    assert.ok(run(png({ layer: 'ink', colorMode: 'rgba' })));
  });
  return cases;
}

export function verifyPng(actual, expected, name, reader) {
  assert.equal(actual.length, expected.length, name);
  for (let i = 0; i < actual.length; i++) {
    const value = actual[i].value, original = expected[i].value;
    if (value?.artifact === 'png' && original?.artifact === 'png') {
      const png = Buffer.from(value.data, 'base64'), reference = Buffer.from(original.data, 'base64');
      if (reader) {
        assert.deepEqual(reader.raster(png), reader.raster(reference), name + ' straight RGBA ' + i);
        assert.deepEqual(reader.paintRaster(png), reader.paintRaster(reference), name + ' editable pixels ' + i);
      }
      assert.equal(Buffer.compare(png, reference), 0, name + ' complete PNG bytes ' + i);
      assert.deepEqual(Object.keys(value), Object.keys(original));
      assert.equal(value.encoding, original.encoding);
    } else assert.deepEqual(actual[i], expected[i], name + ' command ' + i);
  }
}

async function main(root, native) {
  const cases = pngCases(root);
  const reader = createRequire(import.meta.url)(resolve(root, 'cli/png.js'));
  const temp = mkdtempSync(join(tmpdir(), 'ink-studio-png-'));
  try {
    for (const { label, request, replies } of cases) {
      const editor = await createPixelCommandEditor(request.document);
      verifyPng(await runCommands(editor, request.steps), replies, 'JavaScript ' + label, reader);
      if (request.steps.every(step => step.command.action === 'export')) {
        const raw = await editor.png(request.steps[0].command.options);
        assert.deepEqual(Buffer.from(raw), Buffer.from(replies[0].value.data, 'base64'), label + ' SDK byte export');
      }
      if (!native) continue;
      const file = join(temp, 'request.json');
      writeFileSync(file, JSON.stringify(request));
      const result = spawnSync(resolve(native), ['journal-document', file], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
      assert.equal(result.status, 0, result.stderr);
      verifyPng(result.stdout.trim().split('\n').map(line => JSON.parse(line)), replies, 'Rust ' + label, reader);
    }
    console.log(JSON.stringify({ cases: cases.length, replies: cases.reduce((n, row) => n + row.replies.length, 0),
      pngs: cases.flatMap(row => row.replies).filter(row => row.value?.artifact === 'png').length, pairedWithNative: Boolean(native) }));
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
