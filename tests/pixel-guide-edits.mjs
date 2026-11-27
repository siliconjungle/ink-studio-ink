import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { document } from './pixel-session-tools.mjs';

export { document };
const badge = { id: 'badge', kind: 'pivot', at: [4, 3.5], frame: 'side' };
const front = { id: 'front-pin', kind: 'registration', at: [7, 8], frame: 'front' };
const operation = { upsert: [front, badge], remove: ['z-axis'] };
const edit = (revision, changes, more = {}) =>
  ({ id: 'guide-alignment', revision, destination: 'guides', operation: changes, ...more });

export async function trace(editor, revision) {
  const patch = edit(await revision(), operation);
  const before = await editor.snapshot();
  const preview = await editor.previewEdit(patch);
  assert.equal(preview.pixelCount, 0);
  assert.deepEqual(preview.guides.map(({ id, change }) => [id, change]), [
    ['z-axis', 'removed'], ['front-pin', 'modified'], ['badge', 'added'],
  ]);
  const exact = await editor.previewEdit(patch, { exact: true, limit: 0 });
  await editor.begin('Align the poses');
  const applied = await editor.apply(patch);
  assert.deepEqual(applied.frames, before.frames);
  assert.deepEqual(applied.guides.map(({ id }) => id), ['tile', 'a-axis', 'front-pin', 'side-pin', 'badge']);
  const draft = await editor.previewChanges();
  assert.deepEqual(draft, preview);
  assert.equal(await editor.commit(), true);
  const [receipt] = await editor.receipts();
  assert.equal(receipt.outputs.kind, 'guides');
  const sideSnap = await editor.snap([4, 3.5], { frame: 'side', radius: 0 });
  const frontSnap = await editor.snap([7, 8], { frame: 'front', radius: 0 });
  assert.equal(await editor.undo(), true);
  assert.deepEqual(await editor.snapshot(), before);
  assert.equal(await editor.redo(), true);
  assert.deepEqual(await editor.snapshot(), applied);

  const changedRevision = await revision();
  const reordered = await editor.previewEdit(edit(changedRevision, {
    upsert: [{ frame: 'side', at: [4, 3.5], kind: 'pivot', id: 'badge' }],
  }));
  assert.deepEqual(reordered.guides ?? [], []);
  const invalid = [];
  for (const bad of [
    patch,
    edit(changedRevision, { remove: ['gone', 'other'] }),
    edit(changedRevision, { remove: ['badge', 'badge'] }),
    edit(changedRevision, { upsert: [badge, badge] }),
    edit(changedRevision, { upsert: [badge], remove: ['badge'] }),
    edit(changedRevision, { upsert: null }),
    edit(changedRevision, { upsert: [{ ...badge, at: [4, 3.25] }] }),
    edit(changedRevision, { upsert: [{ ...badge, frame: 'absent' }] }),
    edit(changedRevision, {}),
    edit(changedRevision, operation, { cel: 'ink' }),
    edit(changedRevision, operation, { edits: [] }),
  ]) {
    try { await editor.apply(bad); }
    catch (error) { invalid.push({ message: error.message, receipt: error.receipt }); continue; }
    assert.fail(JSON.stringify(bad));
  }
  assert.deepEqual(await editor.snapshot(), applied);
  const blank = await editor.apply(edit(changedRevision, { remove: applied.guides.map(({ id }) => id) }));
  assert.deepEqual(blank.guides, []);
  return { preview, exact, applied, receipt, sideSnap, frontSnap, reordered, invalid, blank };
}

async function run([original, native]) {
  const { createEditor } = createRequire(import.meta.url)(join(original, 'cli/pixel-art.js'));
  const { createPixelCommandEditor } = await import('../web/pixel-document.mjs');
  const reference = createEditor(document);
  const port = await createPixelCommandEditor(document);
  const expected = await trace(reference, () => reference.describe().revision);
  const actual = await trace(port, () => port.revision());
  for (const key of Object.keys(expected)) assert.deepEqual(actual[key], expected[key], key);
  assert.deepEqual(await (await createPixelCommandEditor(document)).replay(expected.receipt), expected.applied);
  assert.deepEqual(createEditor(document).replay(actual.receipt), actual.applied);

  const { guides, ...withoutGuides } = document;
  for (const source of [withoutGuides, {
    ...document, guides: Array.from({ length: 256 }, (_, index) => ({ ...badge, id: 'pin-' + index })),
  }]) {
    const baseline = createEditor(source);
    const target = await createPixelCommandEditor(source);
    const add = edit(baseline.describe().revision, { upsert: [badge] });
    assert.deepEqual(await target.previewEdit(add), baseline.previewEdit(add));
    if (!source.guides) {
      assert.equal(JSON.stringify(await target.apply(add)), JSON.stringify(baseline.apply(add)));
    }
  }

  const scratch = mkdtempSync(join(tmpdir(), 'ink-guide-edits-'));
  try {
    const input = join(scratch, 'input.json');
    const patch = join(scratch, 'patch.json');
    writeFileSync(input, JSON.stringify(document));
    writeFileSync(patch, JSON.stringify(expected.receipt.command.patch));
    const originalCli = [process.execPath, join(original, 'cli/ink-studio.js'), 'pixel-art'];
    const call = ([bin, ...cli], ...args) => {
      const result = spawnSync(bin, [...cli, ...args], {
        cwd: original, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024,
        env: { ...process.env, INK_STUDIO_PORTABLE_SHOT: '1' },
      });
      assert.equal(result.error, undefined);
      assert.equal(result.status, 0, args.join(' ') + '\n' + result.stderr);
      return JSON.parse(result.stdout);
    };
    const a = join(scratch, 'reference.json'), b = join(scratch, 'port.json');
    assert.deepEqual(call([native], 'edit', input, patch, '--out', b),
      call(originalCli, 'edit', input, patch, '--out', a));
    assert.equal(JSON.stringify(JSON.parse(readFileSync(b))), JSON.stringify(JSON.parse(readFileSync(a))));
    assert.deepEqual(call([native], 'preview', input, patch, '--exact'),
      call(originalCli, 'preview', input, patch, '--exact'));

    const nativeDir = join(scratch, 'port'), originalDir = join(scratch, 'reference');
    const portable = (reply) => { if (reply.directory) reply.directory = '<session>'; return reply; };
    const session = (action, ...args) => {
      const target = call([native], 'session', action, nativeDir, ...args);
      const source = call(originalCli, 'session', action, originalDir, ...args);
      assert.deepEqual(portable(target), portable(source), action);
      return target;
    };
    session('init', input);
    session('begin', '--label', 'Align the poses');
    session('apply', patch);
    session('status');
    session('preview', '--exact', '--limit', '0');
    session('snap', '--frame', 'side', '--at', '4,3.5', '--radius', '0');
    session('commit');
    session('undo');
    session('redo');
    session('status');
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ sdkReportGroups: Object.keys(expected).length, rejectedSdkEdits: expected.invalid.length,
    guideListBoundaries: 2, crossReplays: 2, pairedFileCommands: 2, pairedSessionCommands: 10 }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await run(process.argv.slice(2).map(path => resolve(path)));
}
