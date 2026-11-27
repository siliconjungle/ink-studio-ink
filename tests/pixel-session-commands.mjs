import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const [original, native] = process.argv.slice(2).map(path => resolve(path));
const cli = join(original, 'cli/ink-studio.js');
const { openEditorSession } = createRequire(import.meta.url)(join(original, 'cli/pixel-art.js'));
const directory = mkdtempSync(join(tmpdir(), 'ink-named-session-'));
const folders = { original: join(directory, 'reference'), native: join(directory, 'port') };
const document = { format: 'ink-studio/pixel-art', version: 2, width: 5, height: 4, pixelAspect: [1, 1],
  palette: { blue: '#2439a1', ochre: '#99690d' }, layers: [{ id: 'ink' }],
  frames: [{ id: 'front', durationMs: 90, cels: { ink: { marks: [{ swatch: 'blue', at: [0, 0] }] } } }],
  protectedDetails: [{ id: 'protected', pixels: [[4, 3]] }],
};
let paired = 0;
function write(name, value) {
  const file = join(directory, name + '.json');
  writeFileSync(file, JSON.stringify(value));
  return file;
}
const envelope = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });

function call(engine, action, args = [], folder = folders[engine]) {
  const cmd = engine === 'native' ? [native] : [process.execPath, cli, 'pixel-art'];
  const result = spawnSync(cmd[0], [...cmd.slice(1), 'session', action, folder, ...args],
    { cwd: original, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, INK_STUDIO_PORTABLE_SHOT: '1' } });
  assert.equal(result.error, undefined);
  const reply = result.stdout ? JSON.parse(result.stdout) : null;
  return { reply, status: result.status, error: result.stderr.trim() };
}
function comparison(response) {
  const { reply, ...status } = response;
  if (!reply) return response;
  const result = { ...reply };
  if (result.directory) result.directory = '<session>';
  if (result.file && (result.artifact || result.format === 'ink-studio/pixel-brush')) result.file = '<artifact>';
  return { reply: result, ...status };
}
function both(action, args = [], status = 0) {
  const ref = call('original', action, args);
  const port = call('native', action, args);
  assert.equal(ref.status, status, action + ' original: ' + ref.error);
  assert.deepEqual(comparison(port), comparison(ref), action);
  paired++;
  return port.reply;
}
function output(action, args, stem, binary = false) {
  const refPath = join(directory, stem + '-ref');
  const nativePath = join(directory, stem + '-native');
  const ref = call('original', action, [...args, '--out', refPath]);
  const port = call('native', action, [...args, '--out', nativePath]);
  assert.equal(ref.status, 0, ref.error);
  assert.deepEqual(comparison(port), comparison(ref), action + ' ' + stem);
  const a = readFileSync(refPath), b = readFileSync(nativePath);
  if (binary) assert(b.equals(a), stem);
  else assert.deepEqual(JSON.parse(b), JSON.parse(a), stem);
  paired++;
  return nativePath;
}

try {
  const input = write('source', document);
  const initial = both('init', [input]);
  assert.equal(initial.revision, 1);
  assert.equal(both('begin', ['--label', 'Resize then paint']).pending, true);
  let revision = initial.documentRevision;
  const pad = write('pad', { id: 'pad', revision, operation: { type: 'pad', margins: [1, 0, 0, 1] } });
  revision = both('transform', [pad]).outputs.documentRevision;
  const pencil = write('pencil', { id: 'paint', revision, frame: 'front',
    operation: { tool: 'pencil', layer: 'ink', swatch: 'ochre', points: [[5, 4]] } });
  revision = both('draw', [pencil]).outputs.documentRevision;
  const mask = write('mask', { id: 'mask', revision, frame: 'front',
    operation: { id: 'mark', query: { type: 'rectangle', rect: [4, 3, 2, 2] } } });
  revision = both('mask', [mask]).outputs.documentRevision;
  const palette = write('palette', { id: 'palette', revision,
    operation: { type: 'swatch', swatch: { id: 'ochre', color: '#bc8133' } } });
  revision = both('recolor', [palette]).outputs.documentRevision;
  assert.equal(both('preview', ['--exact', '--limit', '2']).targets.length, 4);
  assert.equal(both('inspect', ['--at', '5,4', '--frame', 'front', '--references']).swatch, 'ochre');
  both('inspect', ['--at', 'one,2'], 1);

  const query = write('query', { type: 'recall', id: 'mark' });
  assert.equal(both('select', [query, '--layer', 'ink']).pixelCount, 4);
  both('copy', ['--selection', 'mark', '--layer', 'ink']);
  assert.equal(both('validate').revision, revision);
  const before = both('status').revision;

  const captured = output('brush', ['--rect', '4,3,2,2', '--layer', 'ink'], 'brush-rectangle', true);
  assert.equal(JSON.parse(readFileSync(captured)).format, 'ink-studio/pixel-brush');
  const tinted = output('brush', ['--selection', 'mark', '--cel', 'front/ink', '--anchor', '1,1',
    '--angle', '-37.5', '--size', '8,3', '--tint', 'ochre', '--stabilization', '42.5',
    '--pressure', '0.2,1.5', '--velocity', '160,1.5,0.4'], 'brush-shaped', true);
  assert.deepEqual(JSON.parse(readFileSync(tinted)).settings.swatch, { mode: 'tint', id: 'ochre', color: '#bc8133' });
  const unused = join(directory, 'rejected-brush.json');
  both('brush', ['--rect', '4,3,2,2'], 1);
  both('brush', ['--rect', '4,3,2', '--out', unused], 1);
  both('brush', ['--rect', '4,3,2,2', '--tint', 'missing', '--out', unused], 1);
  both('brush', ['--rect', '4,3,2,2', '--pressure', '0,9', '--out', unused], 1);
  assert.equal(existsSync(unused), false);
  for (const engine of ['original', 'native']) {
    const next = join(folders[engine], 'checkpoint-999.json');
    assert.deepEqual(call(engine, 'brush', ['--selection', 'mark', '--out', next]),
      { reply: null, status: 1, error: 'Write the brush to a separate output' });
    assert.equal(existsSync(next), false);
  }
  paired++;

  const artifact = output('export', [], 'document');
  const exportDoc = JSON.parse(readFileSync(artifact));
  assert.deepEqual([exportDoc.width, exportDoc.height], [6, 5]);
  output('export', ['--artifact', 'stamp', '--frame', 'front', '--cel', 'front/ink'], 'stamp');
  output('export', ['--artifact', 'layer-deck'], 'deck');
  output('export', ['--artifact', 'png', '--frame', 'front', '--layer', 'ink', '--color-mode', 'indexed'], 'png', true);
  const select = write('run-query', envelope('select', { query: { type: 'rectangle', rect: [0, 0, 2, 3] } }));
  output('run', [select], 'report');

  const missing = call('native', 'run', [select, '--out', join(folders.native, 'checkpoint-999.json')]);
  assert.match(missing.error, /outside the session checkpoints/);
  assert.equal(missing.status, 1);
  const alias = join(directory, 'session-alias');
  symlinkSync(folders.native, alias);
  const disguised = join(alias, 'checkpoint-999.json');
  assert.match(call('native', 'export', ['--out', disguised]).error, /outside the session checkpoints/);
  assert.match(call('native', 'brush', ['--selection', 'mark', '--out', disguised]).error, /separate output/);
  assert.equal(existsSync(disguised), false);
  assert.match(call('native', 'run', [select, '--out', select]).error, /separately from its inputs/);
  assert.equal(both('status').revision, before);

  const stale = write('stale', { id: 'stale', revision: '0'.repeat(64), frame: 'front',
    operation: { tool: 'pencil', layer: 'ink', swatch: 'ochre', points: [[3, 2]] } });
  const rejected = both('apply', [stale], 1);
  assert.equal(rejected, null);
  assert.equal(both('status').pending, false);
  assert.equal(both('validate').revision, initial.documentRevision);
  assert.equal(both('status').revision, before + 1);
  assert.deepEqual(openEditorSession(folders.native).snapshot(), document);

  const failedCommand = write('stale-command', envelope('draw', { patch: JSON.parse(readFileSync(stale)) }));
  const refBad = join(directory, 'bad-ref.json'), nativeBad = join(directory, 'bad-port.json');
  assert.deepEqual(comparison(call('native', 'run', [failedCommand, '--out', nativeBad])),
    comparison(call('original', 'run', [failedCommand, '--out', refBad])));
  assert.equal(JSON.parse(readFileSync(nativeBad)).status, 'rejected');
  assert.deepEqual(JSON.parse(readFileSync(nativeBad)), JSON.parse(readFileSync(refBad)));
  paired++;

  both('begin', ['--label', 'Final crop']);
  const final = write('final', { id: 'crop', revision: initial.documentRevision, destination: 'canvas',
    operation: { type: 'crop', rect: [0, 0, 4, 3] } });
  both('apply', [final]);
  assert.equal(both('commit').changed, true);
  assert.equal(both('undo').changed, true);
  assert.equal(both('redo').changed, true);
  assert.equal(both('cancel').changed, false);
  assert.equal(openEditorSession(folders.native).snapshot().width, 4);

  const reloaded = call('native', 'status', [], folders.original);
  assert.equal(reloaded.status, 0);
  assert.deepEqual(reloaded.reply.history, both('status').history);
  console.log(JSON.stringify({ pairedSessionCalls: paired, binaryExport: true, brushFilesByteIdentical: 2, staleDraftRolledBack: true }));
} finally {
  rmSync(directory, { recursive: true, force: true });
}
