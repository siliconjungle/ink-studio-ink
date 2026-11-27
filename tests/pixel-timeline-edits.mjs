import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const document = {
  format: 'ink-studio/pixel-art', version: 2, width: 5, height: 4, pixelAspect: [1, 1],
  palette: { red: '#bd2020', gold: '#f1dc74' },
  layers: [{ id: 'ink' }, { id: 'shadow' }, { id: 'locked', kind: 'group', locked: true },
    { id: 'nested', parent: 'locked' }],
  frames: [
    { id: 'one', durationMs: 100, cels: { ink: { label: 'Pose', slots: Array.from({ length: 20 },
      (_, i) => i === 6 ? 'red' : null), marks: [{ alpha: 128, runs: [[1, 1, 1]] },
      { swatch: 'red', at: [3, 2] }] } } },
    { id: 'two', durationMs: 130, cels: {} },
    { id: 'three', durationMs: 70, cels: {} },
  ],
  tags: [{ id: 'loop', start: 'one', end: 'three', direction: 'ping-pong' }],
};
const address = (frame, layer = 'ink') => ({ frame, layer });
const command = (action, fields = {}) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });
const asJson = value => JSON.parse(JSON.stringify(value));

export function reference(original) {
  const { createEditor } = createRequire(import.meta.url)(join(original, 'cli/pixel-art.js'));
  const cases = [];
  function scenario(name, source, define) {
    const editor = createEditor(source);
    const steps = [], expected = [];
    function step(op, fields = {}) {
      steps.push(asJson({ op, ...fields }));
      try {
        const result = op === 'execute' ? editor.execute(fields.command) : editor[op]();
        expected.push({ value: asJson(result) });
        return result;
      } catch (error) {
        expected.push({ error: error.message, ...(error.receipt && { receipt: asJson(error.receipt) }) });
        return error.receipt;
      }
    }
    const execute = (action, fields) => step('execute', { command: command(action, fields) });
    const snapshot = () => execute('export').data;
    let i = 0;
    const patch = (operation, extra = {}) => ({ id: 'timeline-' + ++i, destination: 'timeline',
      revision: editor.describe().revision, operation, ...extra });
    const preview = (edit, options) => execute('preview', { edit: command('apply', { patch: edit }), options });
    const apply = edit => execute('apply', { patch: edit });
    const edit = (operation, exact = false) => {
      const next = patch(operation);
      assert.equal(preview(next, { exact }).valid, true, JSON.stringify(operation));
      return apply(next);
    };
    define({ editor, execute, snapshot, patch, apply, preview, edit });
    cases.push({ name, request: { document: source, steps }, expected, timeline: editor.timeline() });
  }

  scenario('retiming and playback tags', document, ({ editor, execute, snapshot, patch, apply, preview, edit }) => {
    execute('begin', { label: 'Retime opening' });
    edit({ type: 'add-frame', frame: 'pause', before: 'three', durationMs: 61, label: 'Pause' }, true);
    edit({ type: 'duration', frame: 'two', durationMs: 150 });
    const tag = { id: 'review', start: 'two', end: 'three', direction: 'ping-pong-reverse', repeat: 3 };
    const fitted = edit({ type: 'set-tag', tag });
    assert.deepEqual(fitted.affectedTargets[0].after.order, ['three', 'pause', 'two', 'pause', 'three', 'pause', 'two']);
    edit({ type: 'set-tag', tag: { ...tag, direction: 'reverse', loop: false, repeat: 2 } });
    edit({ type: 'remove-tag', tag: 'loop' });
    apply(patch({ tool: 'pencil', points: [[0, 0]], swatch: 'gold', layer: 'ink' },
      { destination: 'raster', frame: 'three' }));
    execute('preview', { options: { exact: true, limit: 0 } });
    execute('commit');
    snapshot();
    execute('undo');
    assert.deepEqual(snapshot(), document);
    execute('redo');
    snapshot();
    for (const [operation, code] of [
      [{ type: 'add-frame', frame: 'pause', durationMs: 1 }, 'invalid-edit'],
      [{ type: 'duration', frame: 'one', durationMs: Number.MAX_SAFE_INTEGER }, 'invalid-edit'],
      [{ type: 'duration', frame: 'absent', durationMs: 1 }, 'invalid-edit'],
      [{ type: 'duration', frame: 'one', durationMs: 1.5 }, 'invalid-edit'],
      [{ type: 'remove-tag', tag: 'missing' }, 'missing-tag'],
      [{ type: 'set-tag', tag: { ...tag, start: 'three', end: 'one' } }, 'invalid-edit'],
      [{ type: 'set-tag', tag: { ...tag, repeat: 65535 } }, 'invalid-edit'],
    ]) {
      const rejected = patch(operation);
      assert.equal(preview(rejected).conflicts[0].code, code);
      assert.equal(apply(rejected).conflicts[0].code, code);
    }
    assert.equal(editor.timeline().totalDurationMs, 381);
  });

  scenario('packed cels, moving held artwork and detaching chains', document,
    ({ editor, execute, snapshot, patch, apply, preview, edit }) => {
      apply(patch({ tool: 'pencil', points: [[4, 1]], swatch: 'gold', layer: 'ink' },
        { destination: 'raster', frame: 'one' }));
      const painted = snapshot();
      execute('begin', { label: 'Reuse a drawing' });
      const hold = edit({ type: 'hold', from: address('one'), to: address('two') }, true);
      assert.equal(hold.affectedTargets[0].hold, 'one/ink');
      edit({ type: 'copy', from: address('two'), to: address('three', 'shadow') }, true);
      const replaced = edit({ type: 'copy', from: address('one'), to: address('three', 'shadow'), replace: true });
      assert.equal(replaced.affectedTargets[0].replaced, 'three/shadow');
      assert.equal(replaced.affectedTargets[0].to.cel, 'three/shadow-2');
      edit({ type: 'duplicate', from: address('one'), to: address('two', 'shadow') });
      edit({ type: 'move', from: address('one'), to: address('three') });
      edit({ type: 'cel-offset', ...address('two'), offset: [1, -1] }, true);
      edit({ type: 'layer-offset', layer: 'ink', offset: [-1, 1] });
      const unlink = edit({ type: 'unlink', ...address('two') }, true);
      assert.equal(unlink.celLinks.unlinked[0].source.frame, 'three');
      edit({ type: 'blank', ...address('three', 'shadow') });
      execute('preview', { options: { exact: true } });
      const revised = snapshot();
      assert.deepEqual(revised.frames[2].cels.ink.slots, painted.frames[0].cels.ink.slots);
      assert.deepEqual(revised.frames[1].cels.ink.marks, painted.frames[0].cels.ink.marks);
      execute('commit');
      execute('undo');
      assert.deepEqual(snapshot(), painted);
      execute('redo');
      assert.deepEqual(snapshot(), revised);
      for (const [operation, code] of [
        [{ type: 'move', from: address('three'), to: address('two') }, 'occupied-cel'],
        [{ type: 'blank', ...address('three', 'nested') }, 'locked-layer'],
        [{ type: 'cel-offset', ...address('one', 'shadow'), offset: [0, 0] }, 'missing-cel'],
        [{ type: 'unlink', ...address('two') }, 'unlinked-cel'],
        [{ type: 'duplicate', from: address('three') }, 'invalid-edit'],
        [{ type: 'copy', from: address('one'), to: address('two') }, 'missing-cel'],
      ]) {
        const rejected = patch(operation);
        assert.equal(preview(rejected).conflicts[0].code, code);
        assert.equal(apply(rejected).conflicts[0].code, code);
      }
      assert.equal(editor.timeline().linkGroups.length, 0);
    });

  const chained = structuredClone(document);
  chained.frames[1].cels.ink = { id: 'middle', hold: 'one/ink', offset: [1, 0] };
  chained.frames[2].cels.ink = { hold: 'middle' };
  chained.protectedDetails = [{ id: 'locked-ink', kind: 'pixel', frame: 'three', pixels: [[1, 1]] }];
  scenario('retargeting chains and protecting dependent frames', chained, ({ snapshot, patch, apply, preview, edit }) => {
    for (const operation of [
      { type: 'blank', ...address('one') },
      { type: 'layer-offset', layer: 'ink', offset: [1, 0] },
    ]) {
      const rejected = patch(operation);
      assert.deepEqual(preview(rejected).conflicts[0].at, [1, 1]);
      assert.equal(apply(rejected).conflicts[0].code, 'protected-pixel');
    }
    const detached = edit({ type: 'unlink', ...address('two') }, true);
    assert.deepEqual(detached.affectedTargets[0].retargeted, [{ frame: 'three', layer: 'ink', cel: 'three/ink' }]);
    const state = snapshot();
    assert.equal(state.frames[2].cels.ink.hold, 'one/ink');
    const broken = patch({ type: 'hold', from: address('two'), to: address('one'), replace: true });
    assert.deepEqual(preview(broken).conflicts[0], {
      code: 'missing-cel-source', message: 'Unknown hold source cel one/ink', cel: 'three/ink', source: 'one/ink',
    });
    assert.equal(apply(broken).status, 'rejected');
  });
  return cases;
}

function verify(actual, expected, steps, name) {
  assert.equal(actual.length, expected.length, name);
  for (let i = 0; i < expected.length; i++) {
    assert.deepEqual(actual[i], expected[i], name + ' ' + (i + 1) + ' ' + JSON.stringify(steps[i]));
    if (expected[i].value?.artifact === 'document') {
      assert.equal(JSON.stringify(actual[i].value.data), JSON.stringify(expected[i].value.data), name + ' document order ' + i);
    }
  }
}

function fileAndSession(original, native, scratch, sample) {
  const source = join(scratch, 'art.json'), patch = join(scratch, 'patch.json');
  const originalDraft = join(scratch, 'reference-draft'), inkDraft = join(scratch, 'native-draft');
  const originalOutput = join(scratch, 'reference.json'), inkOutput = join(scratch, 'ink.json');
  const originalCli = [process.execPath, join(original, 'cli/ink-studio.js'), 'pixel-art'];
  writeFileSync(source, JSON.stringify(sample.request.document));
  writeFileSync(patch, JSON.stringify(sample.request.steps.find(step => step.command.action === 'apply').command.patch));
  function run([program, ...prefix], args) {
    const result = spawnSync(program, [...prefix, ...args], { cwd: original, encoding: 'utf8',
      env: { ...process.env, INK_STUDIO_PORTABLE_SHOT: '1' }, maxBuffer: 8 * 1024 * 1024 });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, args.join(' ') + '\n' + result.stderr);
    const reply = JSON.parse(result.stdout);
    if (reply.directory) reply.directory = '<session>';
    return reply;
  }
  assert.deepEqual(run([native], ['preview', source, patch, '--exact']), run(originalCli, ['preview', source, patch, '--exact']));
  const applied = run([native], ['edit', source, patch, '--out', inkOutput]);
  assert.deepEqual(applied, run(originalCli, ['edit', source, patch, '--out', originalOutput]));
  assert.deepEqual(run([native], ['timeline', inkOutput]), run(originalCli, ['timeline', originalOutput]));
  const receipt = join(scratch, 'receipt.json'), replayed = join(scratch, 'replay.json');
  writeFileSync(receipt, JSON.stringify(applied));
  run(originalCli, ['replay', source, receipt, '--out', replayed]);
  for (const file of [originalOutput, replayed]) {
    assert.equal(JSON.stringify(JSON.parse(readFileSync(inkOutput))), JSON.stringify(JSON.parse(readFileSync(file))));
  }
  const commands = [
    ['init', source], ['begin', '--label', 'Timeline draft'], ['apply', patch], ['timeline'],
    ['preview', '--exact'], ['commit'], ['undo'], ['timeline'], ['redo'], ['timeline'],
  ];
  for (const [action, ...args] of commands) {
    assert.deepEqual(run([native], ['session', action, inkDraft, ...args]),
      run(originalCli, ['session', action, originalDraft, ...args]), action);
  }
  return commands.length;
}

async function run([original, native]) {
  const { createPixelCommandEditor } = await import('../web/pixel-document.mjs');
  const { runCommands } = await import('./pixel-commands.mjs');
  const cases = reference(original);
  const scratch = mkdtempSync(join(tmpdir(), 'ink-timeline-edits-'));
  let sessionCommands = 0;
  try {
    for (const { name, request, expected, timeline } of cases) {
      const editor = await createPixelCommandEditor(request.document);
      const actual = await runCommands(editor, request.steps);
      verify(actual, expected, request.steps, 'JavaScript ' + name);
      assert.deepEqual(await editor.timeline(), timeline, 'timeline ' + name);
      if (native) {
        const input = join(scratch, 'journal.json');
        writeFileSync(input, JSON.stringify(request));
        const result = spawnSync(native, ['journal-document', input], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
        assert.equal(result.error, undefined);
        assert.equal(result.status, 0, result.stderr);
        verify(result.stdout.trim().split('\n').map(JSON.parse), expected, request.steps, 'Rust ' + name);
      }
    }
    if (native) sessionCommands = fileAndSession(original, native, scratch, cases[0]);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ cases: cases.length, matchedReplies: cases.reduce((sum, row) => sum + row.expected.length, 0),
    native: Boolean(native), sessionCommands }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await run(process.argv.slice(2).map(path => resolve(path)));
}
