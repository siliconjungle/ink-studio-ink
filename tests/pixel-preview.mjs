import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor } from '../web/pixel-document.mjs';
import { fixture } from './pixel-color-edits.mjs';

const exact = { exact: true };
const pencil = (layer, swatch, ...points) => ({ tool: 'pencil', layer, swatch, points });
const color = (layer, at, rgba, swatch) => ({ tool: 'rgba', layer, pixels: [{ at, rgba, swatch }] });
const mark = (swatch, ...runs) => ({ swatch, runs });
const cel = (...marks) => ({ marks });
const frame = (id, cels) => ({ id, durationMs: 100, cels });

export function previewCases(root) {
  const { createEditor } = createRequire(import.meta.url)(resolve(root, 'cli/pixel-art.js'));
  const cases = [];
  function scenario(label, document, schedule) {
    const original = createEditor(document);
    const steps = [], replies = [];
    function step(op, fields = {}) {
      const request = JSON.parse(JSON.stringify({ op, ...fields }));
      steps.push(request);
      let value;
      try {
        switch (op) {
          case 'preview-edit': value = original.previewEdit(request.patch, request.options); break;
          case 'preview-changes': value = original.previewChanges(request.options); break;
          case 'begin': value = original.begin(request.label); break;
          case 'apply': value = original.apply(request.patch); break;
          case 'revision': value = original.describe().revision; break;
          default: value = original[op]();
        }
        replies.push({ value: structuredClone(value ?? null) });
        return value;
      } catch (error) {
        replies.push({ error: error.message, ...(error.receipt && { receipt: error.receipt }) });
      }
    }
    let serial = 0;
    const patch = (operation, settings = {}) => ({ id: 'preview-' + ++serial, revision: original.describe().revision,
      frame: 'front', operation, ...settings });
    const preview = (operation, options, settings) => step('preview-edit', { patch: patch(operation, settings), options });
    schedule(step, patch, preview);
    cases.push({ label, request: { document, steps }, replies });
  }

  const stacked = fixture({ layers: [
    { id: 'paper' }, { id: 'colors', kind: 'group', blend: 'multiply', opacity: 0.75 },
    { id: 'base', parent: 'colors' }, { id: 'stack', kind: 'group', parent: 'colors' },
    { id: 'matte', parent: 'stack', kind: 'mask' }, { id: 'ink', parent: 'stack', clip: 'matte', offset: [1, 0] },
    { id: 'frontmost' }, { id: 'hidden', visible: false },
  ], selections: [], frames: [frame('front', {
    paper: cel(mark('brass', [0, 0, 8], [1, 0, 8])),
    base: cel(mark('shadow', [0, 1, 4], [1, 2, 3])),
    matte: cel(mark('accent', [0, 1, 7], [1, 1, 7]), { alpha: 64, runs: [[0, 2, 1]] }),
    ink: { id: 'ink-front', marks: [mark('brass', [0, 1, 2]), { alpha: 120, runs: [[0, 2, 1]] }] },
    frontmost: cel(mark('shadow', [1, 2, 1])),
  })], protectedDetails: [{ id: 'corner', kind: 'pixel', frame: 'front', pixels: [[0, 0]] }] });

  scenario('stacked ownership, alpha clips, offsets, hidden paint and same-RGB swatches', stacked, (step, patch, preview) => {
    const changed = preview(pencil('ink', 'accent', [2, 0], [3, 0], [4, 0]), exact);
    assert.equal(changed.pixelCount, 3);
    assert.equal(changed.pixels[0].after.layer, 'ink');
    assert.equal(changed.pixels[0].after.underneath.layer, 'base');
    assert.equal(changed.pixels[0].after.cel, 'ink-front');
    const covered = preview(pencil('base', 'brass', [2, 1]), exact);
    assert.equal(covered.pixelCount, 0);
    assert.equal(covered.diff.cells.length, 1);
    const hidden = preview(pencil('hidden', 'brass', [1, 0]), exact);
    assert.equal(hidden.pixelCount, 0);
    assert.equal(hidden.diff.cells[0].layer, 'hidden');
    preview(pencil('ink', 'shadow', [0, 1]), exact);
    preview(pencil('paper', 'shadow', [0, 0]), exact);
    preview(color('ink', [3, 1], [17, 72, 189, 127]), exact);
    step('snapshot');
    step('receipts');
    step('history');
    step('revision');
  });

  const erasures = fixture({ layers: [{ id: 'paper' }, { id: 'veil', opacity: 0.4 }, { id: 'ink' }],
    selections: [], frames: [frame('front', {
      paper: cel(mark('brass', [0, 0, 6])),
      veil: cel(mark('shadow', [0, 0, 5]), mark(null, [0, 2, 1])),
      ink: cel(mark('brass', [0, 0, 2]), mark(null, [0, 0, 1])),
    })] });
  scenario('knockout ownership, fractional erasure and ownership-only edits', erasures, (step, patch, preview) => {
    step('begin', { label: 'Remove ink' });
    const erase = patch(color('ink', [0, 0], null));
    const deletion = step('preview-edit', { patch: erase, options: exact });
    assert.equal(deletion.pixels[0].before.layer, 'ink');
    assert.equal(deletion.pixels[0].before.color, null);
    assert.equal(deletion.pixels[0].before.underneath.layer, 'veil');
    assert.equal(deletion.pixels[0].after.layer, 'veil');
    step('apply', { patch: erase });
    const fade = preview(color('veil', [2, 0], null), exact);
    assert.equal(fade.pixels[0].before.layer, 'paper');
    assert.equal(fade.pixels[0].before.alpha, 153);
    assert.equal(fade.pixels[0].after.alpha, 255);
    step('apply', { patch: patch(color('veil', [2, 0], null)) });
    const top = preview(pencil('ink', 'brass', [5, 0]), exact);
    assert.equal(top.pixels[0].before.color, top.pixels[0].after.color);
    assert.equal(top.pixels[0].after.layer, 'ink');
    step('preview-changes', { options: { exact: true, limit: 0 } });
    step('preview-changes', { options: { exact: true, limit: 1 } });
    step('snapshot');
    step('receipts');
    step('cancel');
    step('preview-changes', { options: exact });
    step('snapshot');
    step('receipts');
  });

  const held = fixture();
  held.frames.push(frame('third', { ink: { id: 'third-cel', hold: 'held', opacity: 153 } }));
  scenario('held source is redrawn on each dependent frame and detach keeps owning cel IDs', held, (step, patch) => {
    step('begin', { label: 'Edit held drawing' });
    const source = patch(pencil('ink', 'shadow', [0, 0], [1, 0]));
    const shared = step('preview-edit', { patch: source, options: exact });
    assert.deepEqual([...new Set(shared.pixels.map(row => row.frame))], ['front', 'back', 'third']);
    assert.deepEqual([...new Set(shared.pixels.map(row => row.after.cel))], ['source', 'held', 'third-cel']);
    assert.equal(shared.celLinks.sharedDrawings[0].holds.length, 2);
    step('apply', { patch: source });
    const unshare = patch(pencil(undefined, 'accent', [3, 4]), { frame: 'back', cel: 'held' });
    const detached = step('preview-edit', { patch: unshare, options: exact });
    assert.equal(detached.celLinks.unlinked[0].instance.cel, 'held');
    step('apply', { patch: unshare });
    step('preview-changes', { options: exact });
    step('preview-changes', { options: { limit: 2 } });
    step('snapshot');
    step('receipts');
    step('commit');
    step('history');
    step('undo');
    step('receipts');
    step('redo');
    step('snapshot');
  });

  const guarded = fixture({ protectedDetails: [
    { id: 'moving-badge', kind: 'accent', frame: 'front', pixels: [[0, 0]] },
    { id: 'held-accent', kind: 'accent', frame: 'back', pixels: [[3, 3]] },
  ], selections: [{ id: 'badge', frame: 'front', pixels: [[0, 0]] }] });
  scenario('protection changes, rejected previews and selection-only drafts', guarded, (step, patch, preview) => {
    step('preview-changes');
    step('begin');
    step('preview-changes', { options: exact });
    const blocked = preview(pencil('ink', 'accent', [0, 0]), exact);
    assert.equal(blocked.diff.protection.blocked.length, 1);
    const move = patch({ tool: 'transform', layer: 'ink', selection: 'badge', carryProtection: true,
      transform: { offset: [0, 1] } });
    const carried = step('preview-edit', { patch: move, options: exact });
    assert.equal(carried.diff.protection.details[0].key, 'moving-badge');
    assert.equal(carried.diff.protection.cells.length, 2);
    step('apply', { patch: move });
    const mask = patch({ id: 'saved-box', query: { type: 'rectangle', rect: [1, 1, 2, 1] } }, { destination: 'selections' });
    step('preview-edit', { patch: mask, options: exact });
    step('apply', { patch: mask });
    preview(pencil('ink', 'brass', [0, 1]), exact);
    step('preview-edit', { patch: move, options: exact });
    step('preview-changes', { options: exact });
    step('history');
    step('receipts');
    step('revision');
    step('snapshot');
  });

  const dense = fixture({ width: 20, height: 16, frames: [frame('front', {})], selections: [] });
  scenario('row-major reports and limits on a dense edit', dense, (step, patch) => {
    const fill = patch({ tool: 'fill', layer: 'ink', swatch: 'brass', at: [0, 0] });
    const capped = step('preview-edit', { patch: fill });
    assert.equal(capped.pixelCount, 320);
    assert.equal(capped.pixels.length, 256);
    assert.deepEqual(capped.pixels.at(-1).at, [15, 12]);
    const complete = step('preview-edit', { patch: fill, options: { limit: Number.MAX_SAFE_INTEGER } });
    assert.equal(complete.pixels.length, 320);
    const countOnly = step('preview-edit', { patch: fill, options: { exact: true, limit: 0 } });
    assert.equal(countOnly.pixelCount, 320);
    assert.equal(countOnly.diff.cells.length, 640);
    assert.equal(countOnly.pixels.length, 0);
    for (const options of [{ limit: -1 }, { limit: 0.5 }, { limit: null }, { limit: 9007199254740992 },
      { exact: 'true' }, { shotHitFrame: 0 }, { exact: true, shotHitFrame: -1 }]) {
      step('preview-edit', { patch: fill, options });
      step('preview-changes', { options });
    }
    step('preview-edit', { patch: fill, options: { exact: true, shotHitFrame: 0, limit: 1 } });
    step('snapshot');
    step('receipts');
  });
  return cases;
}

export async function runPreviews(editor, steps) {
  const replies = [];
  for (const { op, patch, label, options } of steps) {
    try {
      let value;
      switch (op) {
        case 'preview-edit': value = await editor.previewEdit(patch, options); break;
        case 'preview-changes': value = await editor.previewChanges(options); break;
        case 'apply': value = await editor.apply(patch); break;
        case 'begin': value = await editor.begin(label); break;
        default: value = await editor[op]();
      }
      replies.push({ value: value ?? null });
    } catch (error) {
      replies.push({ error: error.message, ...(error.receipt && { receipt: error.receipt }) });
    }
  }
  return replies;
}

export function verify(actual, expected, label) {
  assert.equal(actual.length, expected.length, label);
  for (const [i, reply] of actual.entries()) {
    assert.deepEqual(reply, expected[i], label + ' at step ' + i);
    if (reply.value?.format === 'ink-studio/pixel-art') {
      assert.equal(JSON.stringify(reply.value), JSON.stringify(expected[i].value), label + ' ordered snapshot at step ' + i);
    }
  }
}

async function main(root, native) {
  const cases = previewCases(root);
  const temp = mkdtempSync(join(tmpdir(), 'ink-studio-pixel-preview-'));
  try {
    for (const { label, request, replies } of cases) {
      verify(await runPreviews(await createPixelCommandEditor(request.document), request.steps), replies, 'JavaScript ' + label);
      if (!native) continue;
      const file = join(temp, 'request.json');
      writeFileSync(file, JSON.stringify(request));
      const result = spawnSync(resolve(native), ['journal-document', file], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
      assert.equal(result.status, 0, result.stderr);
      verify(result.stdout.trim().split('\n').map(line => JSON.parse(line)), replies, 'Rust ' + label);
    }
    console.log(JSON.stringify({ cases: cases.length, replies: cases.reduce((count, row) => count + row.replies.length, 0),
      pairedWithNative: Boolean(native) }));
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
