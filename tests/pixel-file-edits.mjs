import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const [originalRoot, native] = process.argv.slice(2).map(path => resolve(path));
const cli = join(originalRoot, 'cli/ink-studio.js');
const { compile, createEditor } = createRequire(import.meta.url)(join(originalRoot, 'cli/pixel-art.js'));
const scratch = mkdtempSync(join(tmpdir(), 'ink-pixel-files-'));
const options = { encoding: 'utf8', maxBuffer: 12 * 1024 * 1024, cwd: originalRoot,
  env: { ...process.env, INK_STUDIO_PORTABLE_SHOT: '1' } };
let compared = 0;

const design = {
  format: 'ink-studio/pixel-art', version: 2, width: 5, height: 4, pixelAspect: [1, 1],
  palette: { brown: '#a04122', blue: '#527dd1' },
  layers: [{ id: 'ink' }],
  frames: [
    { id: 'front', durationMs: 120, cels: { ink: { id: 'ink-master', marks: [
      { swatch: 'brown', at: [1, 1] }, { swatch: 'blue', at: [3, 2] },
    ] } } },
    { id: 'rear', durationMs: 194, cels: { ink: { hold: 'ink-master', offset: [1, 0] } } },
  ],
  guides: [{ id: 'pivot', kind: 'pivot', at: [1.5, 2], frame: 'front' }],
  selections: [{ id: 'mask', frame: 'front', pixels: [[0, 0], [1, 1], [2, 2]] }],
  protectedDetails: [{ id: 'edge', pixels: [[4, 3]] }],
};
const legacy = { format: 'ink-studio/pixel-art', version: 1, width: 4, height: 3,
  palette: { brown: '#a04122', blue: '#527dd1' },
  layers: [{ id: 'ink', marks: [{ swatch: 'brown', at: [1, 1] }, { swatch: 'blue', at: [2, 1] }] }],
  note: 'A file authoring workflow' };

function file(name, value) {
  const path = join(scratch, name + '.json');
  if (value !== undefined) writeFileSync(path, JSON.stringify(value, null, 2) + '\n');
  return path;
}

function result(binary, prefix, args) {
  const child = spawnSync(binary, [...prefix, ...args], options);
  const { status, stdout, stderr } = child;
  assert.equal(child.error, undefined);
  return { status, reply: stdout.trim() ? JSON.parse(stdout) : null, error: stderr.trim() };
}

const original = (...args) => result(process.execPath, [cli, 'pixel-art'], args);
const rust = (...args) => result(native, [], args);

function orderedDocument(a, b) {
  assert.equal(JSON.stringify(JSON.parse(readFileSync(a, 'utf8'))), JSON.stringify(JSON.parse(readFileSync(b, 'utf8'))));
}

function responses(label, a, b, status = 0) {
  assert.equal(a.status, status, label + ' original: ' + a.error);
  assert.deepEqual(b, a, label);
  compared++;
  return a.reply;
}

function patch(document, id, fields) {
  return { id, revision: compile(document).revision, ...fields };
}

function both(action, doc, input, flags = [], code = 0) {
  return responses(action, original(action, doc, input, ...flags), rust(action, doc, input, ...flags), code);
}

function output(action, doc, input, flags, outputName) {
  const originalFile = file(outputName + '-original'), nativeFile = file(outputName + '-native');
  const reply = responses(action + ' ' + outputName,
    original(action, doc, input, ...flags, '--out', originalFile),
    rust(action, doc, input, ...flags, '--out', nativeFile));
  if (action === 'preview') {
    assert.deepEqual(JSON.parse(readFileSync(nativeFile)), JSON.parse(readFileSync(originalFile)));
  } else orderedDocument(nativeFile, originalFile);
  return { reply, originalFile, nativeFile };
}

function roundtrip(document, id, builder, flags = []) {
  const doc = file(id + '-doc', document);
  const input = file(id + '-patch', patch(document, id, builder));
  const summary = both('preview', doc, input, [...flags, '--limit', '1']);
  const exact = both('preview', doc, input, [...flags, '--exact', '--limit', '0']);
  assert(summary.valid, id);
  assert(exact.valid && exact.diff, id);
  const saved = output('edit', doc, input, flags, id + '-edit');
  const originalReceipt = file(id + '-from-original', saved.reply);
  const produced = rust('edit', doc, input, ...flags, '--out', saved.nativeFile).reply;
  const nativeReceipt = file(id + '-from-native', produced);
  const rustReplay = file(id + '-rust-replay'), originalReplay = file(id + '-original-replay');
  assert.deepEqual(rust('replay', doc, originalReceipt, ...flags, '--out', rustReplay).reply, saved.reply);
  assert.deepEqual(original('replay', doc, nativeReceipt, ...flags, '--out', originalReplay).reply, saved.reply);
  orderedDocument(rustReplay, saved.originalFile);
  orderedDocument(originalReplay, saved.nativeFile);
  compared += 2;
  return { doc, input, originalReceipt, saved, exact };
}

try {
  const crop = { destination: 'canvas', operation: { type: 'crop', rect: [1, 1, 3, 2] } };
  const current = roundtrip(design, 'canvas-crop', crop, ['--frame', 'rear']);
  assert.deepEqual(current.saved.reply.command.options, { frame: 'rear' });
  assert.equal(current.saved.reply.command.frame, null);
  assert.equal(current.exact.diff.grids.length, 2);

  const expanded = roundtrip(legacy, 'legacy-pad',
    { destination: 'canvas', operation: { type: 'pad', margins: [1, 2, 0, 0] } });
  assert.equal(expanded.exact.diff.grids[0].frame, null);
  assert.equal(expanded.saved.reply.command.frame, null);
  assert.equal(JSON.parse(readFileSync(expanded.saved.nativeFile)).version, 1);

  const paint = { frame: 'front', operation: { tool: 'pencil', layer: 'ink', swatch: 'blue', points: [[1, 0]] } };
  roundtrip(design, 'current-paint', paint, ['--frame', 'front']);
  roundtrip(legacy, 'legacy-paint', { operation: paint.operation });
  roundtrip(legacy, 'legacy-guarded', { edits: [{ at: [0, 0], layer: null, from: null, to: 'brown' }] });
  roundtrip(design, 'palette-definition', { destination: 'document:palette',
    operation: { type: 'swatch', swatch: { id: 'blue', color: '#334455' } } });
  roundtrip(design, 'saved-selection', { destination: 'selections', frame: 'front',
    operation: { id: 'window', query: { type: 'rectangle', rect: [0, 1, 3, 2] } } });

  const bound = { ...design, sceneBindings: [{ id: 'scene', scene: 'scene.json', object: 'wall', frame: 'front',
    canvas: { size: [10, 12], offset: [0.1, 4.2], scale: [0.3, 2e-7] } }] };
  roundtrip(bound, 'bound-resample', { destination: 'canvas',
    operation: { type: 'resample', size: [8, 3], filter: 'area', bindingPolicy: 'preserve' } });

  const report = output('preview', current.doc, current.input, ['--exact', '--limit', '1'], 'preview-file');
  assert.equal(report.reply, null);
  const ignored = file('ignored-summary-output');
  both('preview', current.doc, current.input, ['--out', ignored, '--limit', '0']);
  assert.equal(existsSync(ignored), false);
  both('preview', current.doc, current.input, ['--limit', '0x1']);
  both('preview', current.doc, current.input, ['--exact', '--shot-hit-frame', '2']);
  both('preview', current.doc, current.input, ['--exact', 'text'], 1);
  both('preview', current.doc, current.input, ['--limit', '-1'], 1);
  both('preview', current.doc, current.input, ['--shot-hit-frame', '1'], 1);
  both('preview', current.doc, current.input, ['--exact', '--out', current.input], 1);
  const alias = join(scratch, 'alias.json');
  symlinkSync(current.input, alias);
  assert.equal(rust('preview', current.doc, current.input, '--exact', '--out', alias).status, 1);
  assert.equal(JSON.parse(readFileSync(current.input)).id, 'canvas-crop');

  const bad = file('bad-crop', patch(design, 'bad-crop', { destination: 'canvas', operation: { type: 'crop', rect: [5, 0, 1, 1] } }));
  both('preview', current.doc, bad, ['--exact'], 2);
  const badOutput = file('invalid-report-native'), badOriginal = file('invalid-report-original');
  responses('invalid exact preview written to file', original('preview', current.doc, bad, '--exact', '--out', badOriginal),
    rust('preview', current.doc, bad, '--exact', '--out', badOutput), 2);
  const af = JSON.parse(readFileSync(badOutput)), bf = JSON.parse(readFileSync(badOriginal));
  assert.deepEqual(af, bf);
  const unchanged = file('existing', { value: 'unchanged' });
  both('edit', current.doc, bad, ['--out', unchanged], 1);
  assert.deepEqual(JSON.parse(readFileSync(unchanged)), { value: 'unchanged' });
  both('edit', current.doc, bad, [], 1);
  both('edit', current.doc, current.input, ['--shot-hit-frame', '1', '--out', unchanged], 1);

  const wrong = file('wrong-frame', patch(design, 'wrong-frame', paint));
  both('edit', current.doc, wrong, ['--frame', 'rear', '--out', unchanged], 1);
  both('preview', current.doc, wrong, ['--frame', 'not-a-frame'], 2);
  both('preview', expanded.doc, expanded.input, ['--frame', 'artwork'], 2);
  both('replay', current.doc, current.originalReceipt, ['--out', unchanged], 1);
  both('replay', current.doc, current.originalReceipt, ['--out', current.originalReceipt, '--frame', 'rear'], 1);
  const stale = file('stale', { ...design, width: 6 });
  both('replay', stale, current.originalReceipt, ['--out', unchanged, '--frame', 'rear'], 1);
  const tampered = structuredClone(current.saved.reply);
  tampered.affectedTargets[0].offset[1] += 1;
  both('replay', current.doc, file('tampered', tampered), ['--out', unchanged, '--frame', 'rear'], 1);

  const sdk = createEditor(design);
  sdk.apply(patch(design, 'sdk-crop', crop));
  both('replay', current.doc, file('sdk', sdk.receipts()[0]), ['--out', unchanged], 1);
  assert.deepEqual(JSON.parse(readFileSync(unchanged)), { value: 'unchanged' });

  const inPlaceOriginal = file('in-place-original', design), inPlaceNative = file('in-place-native', design);
  responses('in-place edit', original('edit', inPlaceOriginal, current.input, '--out', inPlaceOriginal),
    rust('edit', inPlaceNative, current.input, '--out', inPlaceNative));
  orderedDocument(inPlaceOriginal, inPlaceNative);
  console.log(JSON.stringify({ pairedCliInvocations: compared, roundTrips: 8, supportsVersionOne: true }));
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
