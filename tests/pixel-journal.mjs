import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPixelCommandEditor } from '../web/pixel-document.mjs';
import { fixture } from './pixel-color-edits.mjs';

const clone = value => JSON.parse(JSON.stringify(value));
const pencil = (at, swatch = 'brass') => ({ tool: 'pencil', layer: 'ink', points: [at], swatch });
const transform = (extra = {}) => ({
  tool: 'transform', layer: 'ink', selection: 'badge', transform: { offset: [2, 1] },
  resultSelection: 'moved', ...extra,
});
const recall = { id: 'badge', query: { type: 'rectangle', rect: [1, 1, 2, 1] } };
const front = { frame: 'front' };

export function journalCases(root) {
  const originalApi = createRequire(import.meta.url)(resolve(root, 'cli/pixel-art.js'));
  const create = originalApi.createEditor;
  const cases = [];
  function scenario(label, document, historyLimit, schedule) {
    const original = create(document, { historyLimit });
    const steps = [], replies = [];
    function step(op, fields = {}) {
      const request = clone({ op, ...fields });
      steps.push(request);
      try {
        const { patch, receipt, label, options } = request;
        let value;
        switch (op) {
          case 'preview-patch': {
            const before = original.snapshot();
            const candidate = create(before);
            const predicted = original.previewEdit(patch);
            try {
              const document = candidate.apply(patch);
              const receipt = candidate.receipts().at(-1);
              assert.deepEqual(receipt.affectedTargets, predicted.targets);
              assert.deepEqual(receipt.celLinks, predicted.celLinks);
              value = { document, receipt };
            } catch (cause) {
              if (!cause.receipt) throw cause;
              assert.equal(predicted.valid, false);
              assert.deepEqual(cause.receipt.conflicts, predicted.conflicts);
              value = { document: before, receipt: cause.receipt };
            }
            break;
          }
          case 'apply': value = original.apply(patch); break;
          case 'replay': value = original.replay(receipt); break;
          case 'copy': value = original.copySelection(options); break;
          case 'revision': value = original.describe().revision; break;
          case 'begin': original.begin(label); value = null; break;
          default: value = original[op]();
        }
        replies.push({ value: clone(value) });
        return value;
      } catch (error) {
        if (error instanceof assert.AssertionError) throw error;
        const { message, receipt } = error;
        replies.push({ error: message, ...(receipt && { receipt: clone(receipt) }) });
      }
    }
    let serial = 0;
    const patch = (operation, fields = front) => ({ id: 'patch-' + ++serial, revision: original.describe().revision,
      operation, ...fields });
    schedule(step, patch);
    cases.push({ label, request: { document, historyLimit, steps }, replies });
  }

  scenario('grouped raster, mask, recolor, move, copy and cross-frame paste', fixture(), 8, (step, patch) => {
    step('history');
    step('preview');
    step('begin', { label: 'Paint and move a badge' });
    step('begin', { label: 'Nested drafting' });
    step('undo');
    step('redo');
    const draw = patch({ ...pencil([1, 1]), points: [[1, 1], [2, 1]] });
    step('preview-patch', { patch: draw });
    step('snapshot');
    step('apply', { patch: draw });
    step('apply', { patch: patch(recall, { ...front, destination: 'selections' }) });
    step('apply', { patch: patch({ tool: 'replace-swatch', layer: 'ink',
      selection: 'badge', from: 'brass', to: 'shadow' }) });
    step('apply', { patch: patch(transform()) });
    const copied = step('copy', { options: { selection: 'moved', layer: 'ink', frame: 'front' } });
    const paste = patch({ tool: 'paste', clipboard: copied, transform: { at: [2, 2], angle: 90 },
      resultSelection: 'back-badge' }, { frame: 'back', cel: 'held' });
    step('preview-patch', { patch: paste });
    step('apply', { patch: paste });
    step('preview');
    step('history');
    step('receipts');
    step('revision');
    step('commit');
    step('history');
    step('undo');
    step('snapshot');
    step('receipts');
    step('redo');
    step('copy', { options: { selection: 'back-badge', layer: 'ink', frame: 'back' } });
    step('snapshot');
    step('receipts');
    step('undo');
    step('begin', { label: 'This transaction is empty' });
    step('commit');
    step('history');
    step('redo');
    step('history');
  });

  scenario('stale preview retains its draft, stale apply cancels the group', fixture(), 3, (step, patch) => {
    const stale = patch(pencil([1, 2]));
    step('begin', { label: 'Uncommitted' });
    step('apply', { patch: patch(pencil([0, 1])) });
    step('apply', { patch: patch(recall, { ...front, destination: 'selections' }) });
    step('preview-patch', { patch: stale });
    step('preview');
    step('receipts');
    step('apply', { patch: stale });
    step('history');
    step('receipts');
    step('snapshot');
    step('revision');
    step('cancel');
    step('commit');
    step('preview');
    step('apply', { patch: patch(pencil([2, 2]), {}) });
    step('apply', { patch: patch(pencil([2, 2]), { frame: 'missing' }) });
    step('apply', { patch: patch(pencil([2, 2]), { frame: 'back', cel: 'source' }) });
    step('apply', { patch: patch(pencil([2, 2]), { ...front, destination: 'unknown' }) });
    step('apply', { patch: patch(pencil([2, 2]), { ...front, sourceRevision: '0'.repeat(64) }) });
    step('preview-patch', { patch: { ...patch(pencil([2, 2])), id: 'BAD' } });
    step('apply', { patch: { ...patch(pencil([2, 2])), revision: undefined } });
    step('snapshot');
    step('history');
  });

  scenario('replay checks revisions, old link evidence, actual target and exact snapshot', fixture(), 6, (step, patch) => {
    step('apply', { patch: patch(pencil([1, 1])) });
    const [recorded] = step('receipts');
    step('replay', { receipt: recorded });
    step('undo');
    const corrupt = clone(recorded);
    corrupt.affectedTargets[0].runs = [[0, 0, 1]];
    step('replay', { receipt: corrupt });
    step('snapshot');
    step('history');
    const staleOption = clone(recorded);
    staleOption.command.options.unknown = true;
    step('replay', { receipt: staleOption });
    step('replay', { receipt: { ...recorded, version: 3 } });
    step('replay', { receipt: recorded });
    step('receipts');
    step('history');
    step('undo');
    const legacyReceipt = clone(recorded);
    delete legacyReceipt.celLinks;
    step('replay', { receipt: legacyReceipt });
    step('receipts');
    step('undo');
    step('redo');
    step('receipts');
    step('snapshot');
  });

  for (const limit of [0, 1, 3]) {
    scenario('finite history ' + limit, fixture(), limit, (step, patch) => {
      for (let i = 0; i < 5; i++) step('apply', { patch: patch(pencil([i, 1])) });
      step('history');
      step('receipts');
      for (let i = 0; i < 5; i++) step('undo');
      step('snapshot');
      step('receipts');
      step('history');
      step('redo');
      step('begin', { label: 'Cancellation' });
      step('apply', { patch: patch(pencil([7, 5])) });
      step('cancel');
      step('receipts');
      step('history');
      step('apply', { patch: patch(pencil([8, 5])) });
      step('redo');
      step('snapshot');
      step('history');
    });
  }

  const indexedBrush = { format: 'ink-studio/pixel-brush', version: 1, width: 1, height: 1,
    anchor: [0, 0], palette: [{ id: 'brass', color: '#cb4519' }], slots: [0],
    settings: { angle: 0, size: [1, 1], swatch: { mode: 'original' } },
  };
  const protectedFixture = fixture({
    protectedDetails: [{ id: 'badge-protection', pixels: [[0, 0], [2, 0], [3, 0]] }],
    selections: [{ id: 'badge', frame: 'front', pixels: [[2, 0], [0, 0]] }],
  });
  scenario('guard failures carry exact protected sites and authored selection order', protectedFixture, 8, (step, patch) => {
    const operations = [
      pencil([0, 0]),
      { tool: 'eraser', layer: 'ink', points: [[3, 0]] },
      { tool: 'fill', layer: 'ink', at: [0, 0], swatch: 'accent' },
      { tool: 'shape', layer: 'ink', shape: { type: 'line', from: [0, 0], to: [2, 0] }, swatch: 'accent' },
      { tool: 'brush', layer: 'ink', brush: indexedBrush, at: [0, 0] },
      { tool: 'rgba', layer: 'ink', pixels: [{ at: [2, 0], rgba: null }, { at: [0, 0], rgba: null }] },
      { tool: 'replace-swatch', layer: 'ink', selection: 'badge', from: 'brass', to: 'shadow' },
      transform(),
      { tool: 'paste', layer: 'ink', clipboard: {
        format: 'ink-studio/pixel-clipboard', version: 2, width: 1, height: 1, origin: [0, 0],
        palette: [{ id: 'shadow', color: '#212831' }], slots: [0],
      } },
    ];
    for (const operation of operations) {
      const proposed = patch(operation);
      step('preview-patch', { patch: proposed });
      step('apply', { patch: proposed });
    }
    step('receipts');
    step('snapshot');
  });

  const clip = fixture();
  clip.layers = [{ id: 'matte', kind: 'mask' }, { id: 'ink', clip: 'matte' }];
  clip.frames[0].cels.matte = { marks: [{ swatch: 'brass', at: [0, 0] }] };
  scenario('clipped coordinates appear in both conflicts and skipped hits', clip, 2, (step, patch) => {
    step('apply', { patch: patch(pencil([1, 0])) });
    step('apply', { patch: patch({ tool: 'rgba', layer: 'ink', pixels: [{ at: [1, 0], rgba: null }] }) });
    step('snapshot');
  });

  scenario('a locked layer reports its layer ID without a skipped pixel', fixture({ layers: [{ id: 'ink', locked: true }] }), 6,
    (step, patch) => step('apply', { patch: patch(pencil([1, 0])) }));
  scenario('moving a protected gap reports the exact visible destination', fixture({
    protectedDetails: [{ id: 'negative-space', kind: 'gap', frame: 'front', pixels: [[3, 0]] }],
    selections: [{ id: 'badge', frame: 'front', pixels: [[3, 0]] }],
  }), 3, (step, patch) => step('apply', { patch: patch(transform({
    carryProtection: true, transform: { at: [1, 0] },
  })) }));

  scenario('held-frame changes report the affected frame, lock and coordinates', fixture({
    protectedDetails: [{ id: 'held-detail', kind: 'accent', frame: 'back', pixels: [[1, 1]] }],
  }), 4, (step, patch) => {
    const proposed = patch({ tool: 'eraser', layer: 'ink', points: [[0, 0]] });
    step('preview-patch', { patch: proposed });
    step('apply', { patch: proposed });
    step('snapshot');
  });

  const legacy = { format: 'ink-studio/pixel-art', version: 1, width: 7, height: 4,
    palette: { brass: '#cb4519' }, layers: [{ id: 'ink', marks: [] }], tags: ['legacy'] };
  scenario('legacy revision remains usable after undo', legacy, 5, (step, patch) => {
    const digest = originalApi.validate(legacy).revision;
    const action = { ...patch(pencil([2, 2]), {}), revision: digest };
    step('apply', { patch: action });
    step('revision');
    step('receipts');
    step('undo');
    step('apply', { patch: action });
    step('receipts');
    step('snapshot');
  });

  let seed = 0x923a4d9;
  const rand = bound => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) >>> 6) % bound;
  for (let i = 0; i < 12; i++) {
    scenario('seeded edit history ' + i, fixture(), i % 6, (step, patch) => {
      for (let j = 0; j < 32; j++) {
        const op = ['begin', 'commit', 'cancel', 'undo', 'redo', 'preview-patch', 'apply', 'apply',
          'snapshot', 'receipts', 'history', 'revision'][rand(12)];
        step(op, op === 'apply' || op === 'preview-patch'
          ? { patch: patch(pencil([rand(10), rand(7)], ['brass', 'accent', 'shadow'][rand(3)])) }
          : op === 'begin' ? { label: 'Stroke ' + j } : {});
      }
      step('snapshot');
      step('history');
      step('receipts');
    });
  }
  return cases;
}

export async function runJournal(editor, steps) {
  const replies = [];
  for (const { op, patch, receipt, label, options } of steps) {
    try {
      const methods = { 'preview-patch': 'previewPatch', copy: 'copySelection' };
      const argument = { apply: patch, replay: receipt, begin: label, 'preview-patch': patch, copy: options };
      const value = await editor[methods[op] ?? op](argument[op]);
      replies.push({ value: value ?? null });
    } catch (error) {
      replies.push({ error: error.message, ...(error.receipt && { receipt: error.receipt }) });
    }
  }
  return replies;
}

function compare(actual, expected, label) {
  assert.equal(actual.length, expected.length, label);
  for (const [i, reply] of actual.entries()) {
    assert.deepEqual(reply, expected[i], label + ' at step ' + i);
    const document = reply.value?.document ?? reply.value;
    if (document?.format === 'ink-studio/pixel-art') {
      assert.equal(JSON.stringify(document), JSON.stringify(expected[i].value?.document ?? expected[i].value),
        label + ' ordered document at step ' + i);
    }
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-journal.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  const cases = journalCases(process.argv[2]);
  const dir = mkdtempSync(join(tmpdir(), 'ink-pixel-journal-'));
  try {
    for (const { label, request, replies } of cases) {
      const editor = await createPixelCommandEditor(request.document, { historyLimit: request.historyLimit });
      compare(await runJournal(editor, request.steps), replies, 'JavaScript ' + label);
      if (process.argv[3] === '--javascript') continue;
      const path = join(dir, 'request.json');
      writeFileSync(path, JSON.stringify(request));
      const result = spawnSync(process.argv[3], ['journal-document', path], { encoding: 'utf8', maxBuffer: 16 << 20 });
      if (result.error) throw result.error;
      assert.equal(result.status, 0, result.stderr);
      compare(result.stdout.trimEnd().split('\n').map(line => JSON.parse(line)), replies, 'Rust ' + label);
    }
    const editor = await createPixelCommandEditor(fixture());
    const revision = await editor.revision();
    const patch = { id: 'async-raster', revision, frame: 'front', operation: pencil([3, 3]) };
    const next = { ...patch, id: 'async-repaint' };
    const [preview, applied, rejected, snapshot] = await Promise.all([
      editor.previewPatch(patch), editor.apply(patch), editor.apply(next).catch(error => error.receipt), editor.snapshot(),
    ]);
    assert.deepEqual(preview.document, applied);
    assert.deepEqual(applied, snapshot);
    assert.equal(rejected.conflicts[0].code, 'stale-document');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  console.log('Matched ' + cases.reduce((n, row) => n + row.replies.length, 0) +
    ' original journal replies across ' + cases.length + ' retained sessions.');
}
