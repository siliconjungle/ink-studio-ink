import { createPixelCommandEditor, openPixelCommandSession, openStoredPixelCommandSession } from '../web/pixel-document.mjs';

const document = { format: 'ink-studio/pixel-art', version: 2, width: 4, height: 3, pixelAspect: [1, 1],
  palette: { blue: '#204c93' }, layers: [{ id: 'ink' }],
  frames: [{ id: 'front', durationMs: 100, cels: { ink: { marks: [] } } }],
};
const name = 'persistent drawing';
const expect = (condition, description) => {
  if (!condition) throw new Error(description);
};

async function error(run, message) {
  try { await run(); } catch (error) {
    expect(error.message.includes(message), error.message);
    return;
  }
  throw new Error('Expected error: ' + message);
}

export async function createDraft() {
  await error(() => openStoredPixelCommandSession('missing'), 'No pixel edit session named');
  const detached = await createPixelCommandEditor(document);
  expect(await detached.sessionStatus() === null, 'unattached editor status');
  expect(await detached.flushSession() === false, 'unattached editor flush');
  const editor = await createPixelCommandEditor(document, { sessionName: name, historyLimit: 4 });
  expect((await editor.sessionStatus()).revision === 1, 'initial saved checkpoint');
  await error(() => createPixelCommandEditor(document, { sessionName: name }), 'advanced on disk');
  await editor.begin('Wider draft');
  const patch = { id: 'pad', revision: await editor.revision(), destination: 'canvas',
    operation: { type: 'pad', margins: [1, 0, 0, 1] } };
  expect((await editor.previewEdit(patch)).valid, 'draft preview');
  expect((await editor.sessionStatus()).revision === 2, 'preview may not advance storage');
  await editor.apply(patch);
  const peer = await openStoredPixelCommandSession(name);
  expect((await peer.sessionStatus()).pending && (await peer.snapshot()).height === 4, 'peer reopened draft');
  const good = { id: 'dot', revision: await editor.revision(), frame: 'front',
    operation: { tool: 'pencil', layer: 'ink', swatch: 'blue', points: [[4, 3]] } };
  await editor.apply(good);
  await peer.cancel();
  const stale = await peer.sessionStatus();
  expect(!stale.saved && stale.error.includes('advanced on disk'), 'compare-and-write conflict');
  expect(await peer.flushSession() === false && await peer.closeSession() === false, 'stale editor remains attached');
  const latest = await openStoredPixelCommandSession(name), status = await latest.sessionStatus();
  expect(status.saved && status.pending && status.revision === 4, 'stale tab left checkpoint intact');
  expect(await latest.closeSession(), 'saved attachment closes');
  expect(await latest.sessionStatus() === null, 'close detaches persistence');
  return { checkpoint: await editor.exportSession(), revision: await editor.revision() };
}

export async function resumeDraft(expected) {
  const restored = await openStoredPixelCommandSession(name);
  expect((await restored.sessionStatus()).revision === 4, 'reload generation');
  expect(await restored.revision() === expected.revision, 'reload document fingerprint');
  const portable = await openPixelCommandSession(expected.checkpoint);
  expect(JSON.stringify(await portable.snapshot()) === JSON.stringify(await restored.snapshot()), 'importable portable checkpoint');
  await error(() => restored.apply({ id: 'stale', frame: 'front', revision: '0'.repeat(64),
    operation: { tool: 'pencil', layer: 'ink', swatch: 'blue', points: [[0, 0]] } }), 'observed revision');
  expect((await restored.sessionStatus()).revision === 5, 'rejection publishes rolled-back draft');
  expect(!(await restored.sessionStatus()).pending && (await restored.snapshot()).width === 4, 'rejection restores baseline');
  expect(await restored.closeSession(), 'close after rollback');
  const conn = await openStoredPixelCommandSession(name);
  expect((await conn.sessionStatus()).revision === 5, 'rollback survives restart');
  const patch = { id: 'saved-plan', revision: await conn.revision(), destination: 'canvas',
    operation: { type: 'pad', margins: [1, 0, 0, 0] } };
  await conn.applyBatch({ revision: patch.revision, label: 'Saved batch', commands: [
    { format: 'ink-studio/pixel-command', version: 1, action: 'apply', patch },
  ] });
  expect(await conn.undo(), 'undo persisted edit');
  expect(await conn.redo(), 'redo persisted edit');
  const result = await conn.exportSession();
  expect(result.revision === 8 && await conn.closeSession(), 'saved batch history round trip');
  return { generation: result.revision, width: (await conn.snapshot()).width };
}

export async function importOriginal(fixture) {
  const name = 'imported drawing';
  const editor = await openPixelCommandSession(fixture.mixed, { sessionName: name });
  const status = await editor.sessionStatus();
  expect(status.pending && status.revision === fixture.mixed.revision, 'imported draft generation');
  expect(JSON.stringify(await editor.snapshot()) === JSON.stringify(fixture.expected.document), 'imported original artwork');
  expect(await editor.closeSession(), 'imported session close');
  await error(() => openPixelCommandSession(fixture.mixed, { sessionName: name }), 'advanced on disk');
  const restored = await openStoredPixelCommandSession(name);
  expect(JSON.stringify(await restored.history()) === JSON.stringify(fixture.expected.history), 'imported history survives the reopen');
  expect((await restored.sessionStatus()).saved, 'imported checkpoint saved');
  const retry = await openStoredPixelCommandSession(name);
  expect(await restored.cancel() && await retry.cancel(), 'the same rollback may be retried');
  const [first, second] = await Promise.all([restored.sessionStatus(), retry.sessionStatus()]);
  expect(first.saved && second.saved && first.revision === second.revision && first.revision === status.revision + 1,
    'same checkpoint saved once');
  expect(await restored.closeSession() && await retry.closeSession(), 'reopened sessions close');
}
