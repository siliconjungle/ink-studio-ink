import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor, openPixelCommandSession } from '../web/pixel-document.mjs';

export const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const design = {
  format: 'ink-studio/pixel-art', version: 1, width: 7, height: 4, palette: { copper: '#AD7738', glass: '#47ae96' },
  layers: [{ id: 'ink', marks: [{ swatch: 'copper', at: [0, 0] }] }], tags: ['checkpoint'],
};

function draw(id, at, swatch = 'glass', revision) {
  return command('draw', { patch: { id, frame: 'artwork',
    operation: { tool: 'pencil', layer: 'ink', swatch, points: [at] }, ...(revision && { revision }) } });
}

function apply(editor, id, at, swatch = 'glass') {
  return editor.execute(draw(id, at, swatch, editor.describe().revision));
}

function newest(dir) {
  return Math.max(...readdirSync(dir).map(name => Number(/^checkpoint-(\d+)\.json$/.exec(name)?.[1]) || 0));
}

function read(dir, generation = newest(dir)) {
  return JSON.parse(readFileSync(join(dir, 'checkpoint-' + generation + '.json'), 'utf8'));
}

function save(dir, checkpoint) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'checkpoint-' + checkpoint.revision + '.json'), JSON.stringify(checkpoint));
}

function compareCheckpoint(a, b) {
  function decoded(checkpoint) {
    return JSON.parse(JSON.stringify(checkpoint), (key, value) => key === 'content' ? JSON.parse(value) : value);
  }
  assert.deepEqual(decoded(a), decoded(b));
}

export function sessionFixture(original, directory) {
  const { createEditor } = createRequire(import.meta.url)(resolve(original, 'cli/pixel-art.js'));
  const sample = join(directory, 'original');
  const editor = createEditor(design, { sessionDirectory: sample, historyLimit: 3 });
  const initial = read(sample);
  apply(editor, 'committed', [1, 0]);
  const batch = editor.applyBatch({ revision: editor.describe().revision, label: 'Group',
    commands: [draw('first', [2, 0]), draw('second', [3, 0])] });
  const complete = read(sample);
  assert.equal(editor.undo(), true);
  editor.begin('Interrupted 🖋 Draft');
  apply(editor, 'pending', [4, 0]);
  const mixed = read(sample);
  assert.equal(mixed.journal.draft.label, 'Interrupted 🖋 Draft');
  assert.deepEqual(editor.history(), { undo: ['committed'], redo: ['Group'] });
  const expected = { document: editor.snapshot(), history: editor.history(), receipts: editor.receipts(),
    preview: editor.previewChanges({ exact: true }), batch: editor.recordBatch() };
  const rejectStale = draw('bad', [5, 0], 'glass', '0'.repeat(64));
  assert.throws(() => editor.execute(rejectStale), error => error.receipt.conflicts[0].code === 'stale-document');
  const canceled = read(sample);
  assert.equal(canceled.journal.draft, undefined);
  assert.equal(editor.redo(), true);
  assert.deepEqual(editor.receipts().slice(-2), batch.steps);
  const redone = read(sample);
  assert.equal(editor.undo(), true);
  const undone = read(sample);
  assert.equal(editor.redo(), true);
  return { initial, complete, mixed, canceled, redone, undone, expected, rejectStale };
}

export async function browserSession(fixture) {
  const editor = await openPixelCommandSession(fixture.mixed);
  const before = { document: await editor.snapshot(), history: await editor.history(), receipts: await editor.receipts(),
    preview: await editor.previewChanges({ exact: true }), batch: await editor.recordBatch() };
  const roundTrip = await editor.exportSession();
  let rejected;
  try { await editor.execute(fixture.rejectStale); }
  catch (error) { rejected = error.receipt?.conflicts[0].code; }
  const canceled = await editor.exportSession(fixture.canceled.revision);
  const redo = await editor.redo();
  const redone = await editor.exportSession(fixture.redone.revision);
  const undo = await editor.undo();
  const undone = await editor.exportSession(fixture.undone.revision);
  const fresh = await createPixelCommandEditor(fixture.initial.baseline.design);
  const generated = await fresh.exportSession(1);
  const reopened = await openPixelCommandSession(JSON.stringify(generated));
  let lastError;
  const corrupt = structuredClone(fixture.mixed);
  const content = JSON.parse(corrupt.journal.draft.snapshot.entities[corrupt.slot].content);
  content.receipts.at(-1).outputs.documentRevision = '0'.repeat(64);
  corrupt.journal.draft.snapshot.entities[corrupt.slot].content = JSON.stringify(content);
  try { await openPixelCommandSession(corrupt); }
  catch (error) { lastError = error.message; }
  return { before, roundTrip, canceled, redone, undone, redo, undo, rejected,
    fresh: await reopened.snapshot(), lastError };
}

export function verifyBrowser(result, fixture) {
  assert.deepEqual(result.before, fixture.expected);
  for (const key of ['canceled', 'redone', 'undone']) compareCheckpoint(result[key], fixture[key]);
  compareCheckpoint(result.roundTrip, fixture.mixed);
  assert.deepEqual(result.fresh, fixture.initial.baseline.design);
  assert.equal(result.redo, true);
  assert.equal(result.undo, true);
  assert.equal(result.rejected, 'stale-document');
  assert.equal(result.lastError, 'Invalid retained pixel document revision');
}

function nativeSession(binary, original, scratch, fixture) {
  const { openEditorSession } = createRequire(import.meta.url)(resolve(original, 'cli/pixel-art.js'));
  const directory = join(scratch, 'native');
  const input = join(scratch, 'command.json');
  function cli(action, extra = [], status = 0, dir = directory) {
    const result = spawnSync(binary, ['session', action, dir, ...extra],
      { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
    assert.equal(result.status, status, result.stderr || result.stdout);
    return result.stdout ? JSON.parse(result.stdout) : result.stderr.trim();
  }
  function run(command, status = 0, dir = directory) {
    writeFileSync(input, JSON.stringify(command));
    return cli('run', [input], status, dir);
  }

  save(directory, fixture.mixed);
  assert.deepEqual(cli('status').history, fixture.expected.history);
  assert.equal(cli('status').pending, true);
  assert.deepEqual(run(command('export')).data, fixture.expected.document);
  assert.deepEqual(run(command('preview', { options: { exact: true } })), fixture.expected.preview);
  assert.deepEqual(run(command('record-batch')), fixture.expected.batch);
  assert.equal(newest(directory), fixture.mixed.revision);
  assert.equal(run(fixture.rejectStale, 2).conflicts[0].code, 'stale-document');
  compareCheckpoint(read(directory), fixture.canceled);
  assert.equal(cli('redo').changed, true);
  compareCheckpoint(read(directory), fixture.redone);
  assert.equal(read(directory, fixture.mixed.revision), null);
  assert.equal(cli('undo').changed, true);
  compareCheckpoint(read(directory), fixture.undone);
  const originalEditor = openEditorSession(directory);
  assert.equal(originalEditor.redo(), true);
  assert.deepEqual(run(command('export')).data, originalEditor.snapshot());
  assert.deepEqual(cli('status').history, originalEditor.history());

  const created = join(scratch, 'created');
  writeFileSync(input, JSON.stringify(design));
  assert.equal(cli('init', [input], 0, created).revision, 1);
  assert.match(cli('init', [input], 1, created), /session advanced on disk/);
  const revision = cli('status', [], 0, created).documentRevision;
  assert.equal(cli('begin', ['--label', 'Stopped draft'], 0, created).pending, true);
  run(draw('native-edit', [1, 2], 'glass', revision), 0, created);
  const stopped = openEditorSession(created);
  assert.equal(stopped.sessionStatus().pending, true);
  assert.equal(stopped.recordBatch().label, 'Stopped draft');
  assert.equal(cli('commit', [], 0, created).changed, true);
  const freshOpened = openEditorSession(created);
  assert.deepEqual(freshOpened.history(), { undo: ['Stopped draft'], redo: [] });
  assert.equal(freshOpened.undo(), true);
  assert.equal(cli('redo', [], 0, created).changed, true);

  const prettified = structuredClone(fixture.mixed);
  const entity = prettified.journal.draft.snapshot.entities[prettified.slot];
  entity.content = JSON.stringify(JSON.parse(entity.content), null, 2);
  const prettyDirectory = join(scratch, 'pretty-printed');
  save(prettyDirectory, prettified);
  assert.deepEqual(run(command('export'), 0, prettyDirectory).data, fixture.expected.document);

  const corruptDirectory = join(scratch, 'corrupt');
  const corrupt = structuredClone(fixture.mixed);
  corrupt.journal.historyLimit = 0;
  save(corruptDirectory, corrupt);
  assert.match(cli('status', [], 1, corruptDirectory), /incompatible history limit/);
}

async function main(original, binary) {
  const scratch = mkdtempSync(join(tmpdir(), 'ink-pixel-session-'));
  try {
    const fixture = sessionFixture(original, scratch);
    const result = await browserSession(fixture);
    verifyBrowser(result, fixture);
    const exported = join(scratch, 'browser-export');
    save(exported, result.redone);
    const { openEditorSession } = createRequire(import.meta.url)(resolve(original, 'cli/pixel-art.js'));
    const reopened = openEditorSession(exported);
    assert.equal(reopened.undo(), true);
    assert.deepEqual(reopened.history(), { undo: ['committed'], redo: ['Group'] });
    if (binary) nativeSession(resolve(binary), original, scratch, fixture);
    console.log(JSON.stringify({ checkpointStages: 6, historyLimit: 3, native: Boolean(binary) }));
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
