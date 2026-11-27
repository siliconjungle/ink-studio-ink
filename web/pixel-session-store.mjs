const database = 'ink-studio-pixel-sessions';
const collection = 'checkpoints';
const changed = 'The pixel edit session advanced on disk. Reopen it before writing.';

export async function openPixelSessionStore(name) {
  if (typeof name !== 'string' || !name.trim()) throw new Error('A pixel edit session needs a name');
  if (typeof indexedDB === 'undefined') throw new Error('Browser pixel session storage is unavailable');
  const connection = await new Promise((resolve, reject) => {
    const req = indexedDB.open(database, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(collection);
    req.onerror = () => reject(req.error);
    req.onsuccess = () => resolve(req.result);
  });
  connection.onversionchange = () => connection.close();

  function withCheckpoint(mode, work) {
    return new Promise((resolve, reject) => {
      const transaction = connection.transaction(collection, mode);
      const checkpoints = transaction.objectStore(collection);
      const request = checkpoints.get(name);
      let result, conflict;
      request.onsuccess = () => {
        try {
          result = work(checkpoints, request.result);
        } catch (error) {
          conflict = error;
          transaction.abort();
        }
      };
      transaction.oncomplete = () => resolve(result);
      transaction.onabort = () => reject(conflict ?? transaction.error ?? new Error('Pixel session storage aborted'));
    });
  }

  return {
    name,
    read: () => withCheckpoint('readonly', (_, saved) => saved),
    write: (previous, next) => withCheckpoint('readwrite', (checkpoints, saved) => {
      // A retry of the same checkpoint can finish after another client saved it.
      if (previous !== 0 && saved?.revision === next.revision && saved.slot === next.slot &&
          JSON.stringify(saved) === JSON.stringify(next)) return;
      if ((saved?.revision ?? 0) !== previous || (saved && saved.slot !== next.slot)) throw new Error(changed);
      checkpoints.put(next, name);
    }),
    close: () => connection.close(),
  };
}
