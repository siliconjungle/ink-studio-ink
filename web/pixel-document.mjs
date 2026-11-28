import { openPixelSessionStore } from './pixel-session-store.mjs';
import { call, callOwned, compiledValues, createState, functions, JsonCodec } from '../build/pixel_document.mjs';
import { openPixelJournal } from './pixel-journal.mjs';
import { parsePixelSession } from './pixel-session.mjs';
import { decodePixelPng, extractPngPalette } from './pixel-png-import.mjs';
import { packRun, unpackRun } from './pixel-run-words.mjs';

const codec = new JsonCodec(compiledValues.open_pixel_document.params[0]);
const utf8 = new TextEncoder();
// Typed JSON adds several schema levels for each level of authored data.
const documentInputLimits = { depth: 512, nodes: 8000000 };

async function revisionText(json) {
  const bytes = await crypto.subtle.digest('SHA-256', utf8.encode(json));
  return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, '0')).join('');
}

const revision = document => revisionText(JSON.stringify(document));

export async function openPixelDocument(source) {
  const fromText = typeof source === 'string';
  const input = fromText ? JSON.parse(source) : source;
  const { document: metadata, planes, runs } = packCelPlanes(input, fromText);
  const opened = callOwned('open_pixel_document', [codec.fromJS(metadata)]);
  if (Object.hasOwn(opened, 'Err')) throw new Error(opened.Err);
  const document = codec.toJS(opened.Ok.document);
  if (planes.length) restoreSlotPlanes(document, planes, plane => plane.pixels);
  if (runs.length) restoreRunPlanes(document, runs, plane => plane.marks);
  const [current, legacy] = await Promise.all([
    revision(document),
    opened.Ok.legacy ? revision(input) : null,
  ]);
  return { document, revision: current, legacyRevision: legacy };
}

export async function openPixelPng(bytes) {
  const document = await decodePixelPng(bytes, codec);
  return { document, revision: await revision(document), legacyRevision: null };
}

export async function openPixelWorkshopStamp(source) {
  const stamp = typeof source === 'string' ? JSON.parse(source) : source;
  const { metadata, pixels } = packWorkshopStamp(stamp, typeof source === 'string');
  const opened = unwrap(functions.open_pixel_workshop_stamp(codec.fromJS(metadata), pixels));
  const document = codec.toJS(opened.document);
  restoreSlotPlanes(document, opened.slots, plane => plane.pixels);
  restoreRunPlanes(document, opened.runs, plane => plane.marks);
  return { document, revision: await revision(document), legacyRevision: null };
}

export async function createPixelWorkshopEditor(text) {
  const input = JSON.parse(text);
  if (ownData(input, 'format') === 'ink-studio/pixel-art') {
    const core = createPixelEditorCore(input, true);
    const editor = await openPixelJournal({ ...core, codec, revision, revisionText }, input, 100);
    return { editor, stamp: null };
  }
  const { metadata, pixels } = packWorkshopStamp(input, true);
  const source = codec.fromJS(metadata);
  const imported = unwrap(functions.open_pixel_workshop_stamp(source, pixels));
  const document = codec.toJS(imported.document);
  const core = createPixelEditorCore(document, true, imported);
  core.state.bind('retain_pixel_workshop_stamp', { resultOnly: true, inputLimits: documentInputLimits })(source);
  const changes = core.state.bind('export_retained_pixel_workshop_stamp', { resultOnly: true });
  const workshopText = pristine => {
    const stamp = pristine ? input : applyWorkshopChanges(input, unwrap(changes()));
    return JSON.stringify(stamp, null, 2) + '\n';
  };
  const editor = await openPixelJournal({ ...core, codec, revision, revisionText, workshopText }, document, 100);
  return { editor, stamp: codec.toJS(source) };
}

export function exportPixelWorkshopStamp(source, document) {
  const stamp = typeof source === 'string' ? JSON.parse(source) : source;
  const snapshot = typeof document === 'string' ? JSON.parse(document) : document;
  const { metadata, pixels } = packWorkshopStamp(stamp, typeof source === 'string');
  const { document: description, planes, runs } = packCelPlanes(snapshot, typeof document === 'string');
  const changes = unwrap(functions.export_pixel_workshop_stamp(
    codec.fromJS(metadata), pixels, codec.fromJS(description), planes, runs,
  ));
  return applyWorkshopChanges(typeof source === 'string' ? stamp : structuredClone(stamp), changes);
}

export function extractPixelPngPalette(bytes, options = {}) {
  return extractPngPalette(bytes, codec, options);
}

export function rasterizePixelFrame(source, { frame = '', layer = '', cel = '' } = {}) {
  const fromText = typeof source === 'string';
  const input = fromText ? JSON.parse(source) : source;
  const { document, planes, runs } = packCelPlanes(input, fromText);
  const raster = call('rasterize_compact_pixel_frame', [codec.fromJS(document), planes, runs, frame, layer, cel]);
  if (Object.hasOwn(raster, 'Err')) throw new Error(raster.Err);
  const { width, height, frame: active, slots, alpha, clipping, ids, rgba } = raster.Ok;
  return { width, height, frame: active || null, slots: Int32Array.from(slots),
    alpha: Uint32Array.from(alpha), clipping: Uint32Array.from(clipping), ids, rgba: Uint32Array.from(rgba) };
}

export function selectPixelFrame(source, query, { saved, ...scope } = {}) {
  return createPixelEditor(source).select(query, { ...scope, saved });
}

export function createPixelEditor(source) {
  return createPixelEditorCore(source).editor;
}

export async function createPixelCommandEditor(source, { historyLimit = 100, sessionName } = {}) {
  if (!Number.isInteger(historyLimit) || historyLimit < 0 || historyLimit > 0xffffffff) {
    throw new Error('historyLimit must be a non-negative integer within the pixel journal capacity');
  }
  const fromText = typeof source === 'string';
  const input = fromText ? JSON.parse(source) : source;
  const core = createPixelEditorCore(input, fromText);
  const storage = sessionName === undefined ? undefined : await openPixelSessionStore(sessionName);
  try {
    return await openPixelJournal({ ...core, codec, revision, revisionText }, input, historyLimit, undefined, storage);
  } catch (error) {
    storage?.close();
    throw error;
  }
}

export async function openPixelCommandSession(source, { sessionName } = {}) {
  const checkpoint = typeof source === 'string' ? source : structuredClone(source);
  if (sessionName === undefined) return restorePixelSession(checkpoint);
  const storage = await openPixelSessionStore(sessionName);
  try {
    const editor = await restorePixelSession(checkpoint, storage);
    await storage.write(0, await editor.exportSession());
    return editor;
  } catch (error) {
    storage.close();
    throw error;
  }
}

export async function openStoredPixelCommandSession(name) {
  const storage = await openPixelSessionStore(name);
  try {
    const checkpoint = await storage.read();
    if (!checkpoint) throw new Error('No pixel edit session named ' + storage.name);
    return await restorePixelSession(checkpoint, storage);
  } catch (error) {
    storage.close();
    throw error;
  }
}

function restorePixelSession(source, storage) {
  const checkpoint = parsePixelSession(source);
  const input = checkpoint.baseline.design;
  const core = createPixelEditorCore(input, true);
  return openPixelJournal({ ...core, codec, revision, revisionText }, input, checkpoint.journal.historyLimit, checkpoint, storage);
}

function cleanupTarget({ kind, mode, maximum, changes }) {
  const decode = ({ state, swatch, rgba }) => ({ state, swatch: swatch.Some ?? null, rgba: rgba.Some ?? null });
  return {
    cleanup: kind, ...(mode.Some !== undefined && { mode: mode.Some }), maxChanges: maximum,
    changes: changes.map(({ at, before, after }) => ({ at, before: decode(before), after: decode(after) })),
  };
}

function createPixelEditorCore(source, fromText = false, imported) {
  const state = createState();
  const load = state.bind('load_pixel_editor', { resultOnly: true, inputLimits: documentInputLimits });
  const pick = state.bind('select_pixel_editor', { resultOnly: true });
  const draw = state.bind('paint_pixel_editor', { resultOnly: true });
  const read = state.bind('snapshot_pixel_editor', { resultOnly: true });
  const readMetadata = state.bind('pixel_editor_metadata', { resultOnly: true });
  const readRaster = state.bind('rasterize_pixel_editor', { resultOnly: true });
  const readPalette = state.bind('pixel_editor_palette', { resultOnly: true });
  const extractPalette = state.bind('extract_pixel_editor_palette', { resultOnly: true });
  const capture = state.bind('capture_pixel_editor_brush', { resultOnly: true });
  const copy = state.bind('copy_pixel_editor_selection', { resultOnly: true });
  const save = state.bind('save_pixel_editor_selection', { resultOnly: true });
  let grid;
  function installDocument(input, fromText) {
    const named = packNamedPixels(input);
    const { document, planes, runs } = packCelPlanes(named.document, fromText);
    grid = unwrap(load(codec.fromJS(document), named.positions, planes, runs));
  }
  function replaceDocument(source) {
    const fromText = typeof source === 'string';
    installDocument(fromText ? JSON.parse(source) : source, fromText);
  }
  function select(query, { frame, layer, cel, saved = {} } = {}) {
    const { encoded, packedSaved, runs } = prepareSelection(grid.width, grid.height, query, saved);
    const chosen = unwrap(pick(encoded, packedSaved, runs, option(frame), option(layer), option(cel)));
    return { frame: chosen.frame, grid: [chosen.grid.width, chosen.grid.height],
      pixels: maskPixels(chosen.grid.width, chosen.words) };
  }
  function paint(operation, { frame, cel } = {}) {
    const packed = ownData(operation, 'tool') === 'paste' ? packClipboard(operation) : packBrushSlots(operation);
    const { metadata, rows, names } = packRgba(packed.metadata, grid);
    const drawn = draw(codec.fromJS(metadata), packed.slots, packed.alpha ?? [], rows, names, option(frame), option(cel));
    if (Object.hasOwn(drawn, 'Err')) {
      const { code, message, layer, detail, at, frame_id, extra } = drawn.Err;
      const conflict = { code, message, ...(layer && { layer }), ...(detail && { detail }), ...(frame_id && { frame: frame_id }),
        ...(Object.hasOwn(at, 'Some') && { at: at.Some }), ...codec.toJS(extra) };
      throw Object.assign(new Error(message), { conflict });
    }
    const result = drawn.Ok;
    const { pixelPerfect, selection, shape, shading, ramp, addedSwatches, from, to, transform, cleanup, ...target } = result;
    const placement = transform.Some;
    const drawing = ownData(operation, 'drawing');
    return { destination: 'raster', kind: 'raster', ...target,
      ...(pixelPerfect && { pixelPerfect }), ...(Object.hasOwn(shape, 'Some') && { shape: shape.Some }),
      ...(Object.hasOwn(shading, 'Some') && { shading: shading.Some }),
      ...(Object.hasOwn(ramp, 'Some') && { ramp: ramp.Some }),
      ...(addedSwatches.length && { addedSwatches }),
      ...(Object.hasOwn(from, 'Some') && { from: from.Some }),
      ...(Object.hasOwn(to, 'Some') && { to: to.Some }),
      ...(Object.hasOwn(selection, 'Some') && { selection: selection.Some }),
      ...(drawing !== undefined && { drawing: structuredClone(drawing) }),
      ...(cleanup.Some && cleanupTarget(cleanup.Some)),
      ...(placement && {
        bounds: placement.bounds, clippedPixels: placement.clippedPixels,
        ...(Object.hasOwn(placement.mode, 'Some') && { mode: placement.mode.Some }),
        ...(Object.hasOwn(placement.resultSelection, 'Some') && {
          resultSelection: placement.resultSelection.Some, selectionRuns: placement.selectionRuns,
        }),
        ...(placement.carriedProtection.length && { carriedProtection: placement.carriedProtection }),
      }) };
  }
  function saveSelection(operation, { frame } = {}) {
    const query = ownData(operation, 'query');
    const metadata = query === undefined ? operation : replacingDataField(operation, 'query', null);
    const { encoded, runs } = prepareSelection(grid.width, grid.height, query ?? null, {});
    const target = unwrap(save(codec.fromJS(metadata), encoded, runs, option(frame)));
    return { destination: 'selections', kind: 'selections', ...target };
  }
  function captureBrush(options = {}) {
    const pixels = ownData(options, 'pixels');
    let metadata = options, positions = [];
    if (Array.isArray(pixels)) {
      metadata = replacingDataField(options, 'pixels', []);
      if (pixels.length <= grid.width * grid.height) {
        positions = Uint32Array.from({ length: pixels.length }, (_, i) =>
          documentPoint(grid.width, grid.height, ownData(pixels, i)));
      }
    }
    const { width, height, anchor, palette, slots, settings } = unwrap(capture(codec.fromJS(metadata), positions));
    return { format: 'ink-studio/pixel-brush', version: 1, width, height, anchor,
      palette: palette.map(({ id, color }) => ({ ...(id && { id }), color })),
      slots: slots.map(slot => slot < 0 ? null : slot), settings: codec.toJS(settings) };
  }
  function copySelection(options = {}) {
    const { width, height, origin, palette, slots, alpha } = unwrap(copy(codec.fromJS(options)));
    return { format: 'ink-studio/pixel-clipboard', version: 2, width, height, origin,
      palette: palette.map(({ id, color }) => ({ ...(id && { id }), color })),
      slots: slots.map(slot => slot === -3 ? null : slot), ...(alpha.length && { alpha }) };
  }
  function restoreSnapshot(saved) {
    const document = codec.toJS(saved.document);
    if (saved.slot_owners.length) {
      restoreSlotPlanes(document, saved.slot_owners, owner => saved.slot_planes[owner.plane - 1]);
    }
    if (saved.run_owners.length) {
      restoreRunPlanes(document, saved.run_owners, owner => saved.run_planes[owner.plane - 1]);
    }
    for (const [i, positions] of saved.positions.entries()) {
      if (!positions.length) continue;
      document.selections[i].pixels = positions.map(p => [p % document.width, Math.floor(p / document.width)]);
    }
    if (saved.edits.length) {
      const frames = new Map(document.frames.map(frame => [frame.id, frame]));
      for (const edit of saved.edits) {
        const cel = frames.get(edit.frame).cels[edit.layer];
        for (const { swatch, knockout, alpha, runs, point } of edit.marks) {
          if (point) {
            const [[y, x]] = runs;
            cel.marks.push({ swatch: swatch.Some ?? null, at: [x, y] });
          } else cel.marks.push(Object.hasOwn(alpha, 'Some') ? { alpha: alpha.Some, runs }
            : knockout ? { swatch: null, runs }
            : Object.hasOwn(swatch, 'Some') ? { swatch: swatch.Some, runs } : { clear: true, runs });
        }
      }
    }
    return document;
  }
  if (imported) {
    const named = packNamedPixels(source);
    grid = unwrap(load(codec.fromJS(named.document), named.positions, imported.slots, imported.runs));
  } else if (fromText) installDocument(source, true);
  else replaceDocument(source);
  return { state, restoreSnapshot, documentInputLimits, setGrid: restored => { grid = restored; }, editor: Object.freeze({ replaceDocument, select, saveSelection, paint, captureBrush,
    metadata: () => codec.toJS(readMetadata()),
    rasterize: (frame, layer, cel) => unwrap(readRaster(frame, layer, cel)),
    copySelection, snapshot: () => restoreSnapshot(read()), palette: () => codec.toJS(readPalette()),
    extractPalette: (options = {}) => codec.toJS(unwrap(extractPalette(codec.fromJS(options)))) }) };
}

function ownData(value, key) {
  if (!value || typeof value !== 'object') return undefined;
  const field = Object.getOwnPropertyDescriptor(value, key);
  return field?.enumerable && Object.hasOwn(field, 'value') ? field.value : undefined;
}

function restoreSlotPlanes(document, owners, pixels) {
  const frames = new Map(document.frames.map(frame => [frame.id, frame]));
  const ids = Object.keys(document.palette);
  for (const owner of owners) {
    frames.get(owner.frame).cels[owner.layer].slots = Array.from(pixels(owner), slot => slot < 0 ? null : ids[slot]);
  }
}

function restoreRunPlanes(document, owners, drawing) {
  const frames = new Map(document.frames.map(frame => [frame.id, frame]));
  for (const owner of owners) {
    const { marks } = frames.get(owner.frame).cels[owner.layer];
    for (const [i, spans] of drawing(owner).entries()) {
      if (spans.length) marks[i].runs = Array.from(spans, unpackRun);
    }
  }
}

function packedArray(value) {
  return Array.isArray(value) && Object.getPrototypeOf(value) === Array.prototype &&
    Reflect.ownKeys(value).length === value.length + 1;
}

function packWorkshopStamp(stamp, fromText) {
  function packCel(source) {
    const input = { slots: [], alpha: [], knockouts: [] };
    let metadata = source;
    for (const channel of Object.keys(input)) {
      const values = ownData(source, channel);
      if (!Array.isArray(values) || (!fromText && !packedArray(values))) continue;
      const limit = channel === 'slots' ? 16777213 : channel === 'alpha' ? 255 : 262143;
      const target = channel === 'slots' ? new Int32Array(values.length) : new Uint32Array(values.length);
      for (let i = 0; i < values.length; i++) {
        const entry = fromText ? values[i] : ownData(values, i);
        target[i] = channel === 'slots' && entry === null ? -1
          : Number.isInteger(entry) && entry >= 0 && entry <= limit ? entry
          : channel === 'slots' ? -3 : 0xffffffff;
      }
      input[channel] = target;
      metadata = replacingDataField(metadata, channel, []);
    }
    return { metadata, input };
  }
  const frames = ownData(stamp, 'frames');
  if (!packedArray(frames)) {
    const { metadata, input } = packCel(stamp);
    return { metadata, pixels: [[input]] };
  }
  const deck = ownData(stamp, 'format') === 'ink-studio/pixel-layer-deck';
  const pixels = [];
  const rows = [];
  for (let i = 0; i < frames.length; i++) {
    const row = ownData(frames, i);
    if (!deck) {
      const { metadata, input } = packCel(row);
      pixels.push([input]);
      rows.push(metadata);
      continue;
    }
    const cels = ownData(row, 'cels');
    const input = [];
    let metadata = cels;
    if (cels && typeof cels === 'object' && !Array.isArray(cels)) {
      for (const layer of Object.keys(cels)) {
        const cel = ownData(cels, layer);
        const packed = packCel(cel);
        input.push(packed.input);
        if (packed.metadata !== cel) metadata = replacingDataField(metadata, layer, packed.metadata);
      }
    }
    pixels.push(input);
    rows.push(cels === metadata ? row : replacingDataField(row, 'cels', metadata));
  }
  return { metadata: replacingDataField(stamp, 'frames', rows), pixels };
}

function applyWorkshopChanges(stamp, changes) {
  if (!changes.length) return stamp;
  const deck = stamp.format === 'ink-studio/pixel-layer-deck';
  const frames = stamp.frames?.slice();
  const copied = new Set();
  for (const change of changes) {
    const { slots, alpha, knockouts } = change.pixels;
    const cel = codec.toJS(change.info);
    cel.slots = Array.from(slots, slot => slot < 0 ? null : slot);
    if (change.write_alpha) cel.alpha = alpha.length ? Array.from(alpha) : Array(slots.length).fill(255);
    if (knockouts.length) cel.knockouts = Array.from(knockouts);
    if (deck) {
      if (!copied.has(change.index)) {
        const original = frames[change.index];
        frames[change.index] = { ...original, cels: { ...original.cels } };
        copied.add(change.index);
      }
      Object.defineProperty(frames[change.index].cels, change.layer, {
        value: cel, enumerable: true, configurable: true, writable: true,
      });
    } else if (frames) {
      frames[change.index] = cel;
    } else {
      return cel;
    }
  }
  return { ...stamp, frames };
}

function packSpans(source, width, height, fromText) {
  if (!Array.isArray(source) || source.length === 0 || source.length > width * height || !packedArray(source)) return [];
  const words = new Uint32Array(source.length);
  let end = 0;
  for (let i = 0; i < source.length; i++) {
    const row = fromText ? source[i] : ownData(source, i);
    if (!Array.isArray(row) || row.length !== 3 || (!fromText && !packedArray(row))) return [];
    const y = fromText ? row[0] : ownData(row, 0);
    const x = fromText ? row[1] : ownData(row, 1);
    const length = fromText ? row[2] : ownData(row, 2);
    if (!Number.isInteger(y) || y < 0 || y >= height || !Number.isInteger(x) || x < 0 || x >= width ||
      !Number.isInteger(length) || length < 1 || length > width - x) return [];
    const start = y * width + x;
    if (start < end) return [];
    words[i] = packRun(y, x, length);
    end = start + length;
  }
  return words;
}

function packCelPlanes(input, fromText) {
  const version = ownData(input, 'version');
  const width = ownData(input, 'width'), height = ownData(input, 'height');
  const palette = ownData(input, 'palette');
  const planes = [];
  const runs = [];
  if ((version !== 1 && version !== 2) || !palette || typeof palette !== 'object' || Array.isArray(palette) ||
      ![width, height].every(n => Number.isInteger(n) && n > 0 && n <= 512)) {
    return { document: input, planes, runs };
  }
  const ids = new Map(Object.keys(palette).map((id, slot) => [id, slot]));
  const count = width * height;
  function packSlots(cel, frame, layer) {
    const slots = ownData(cel, 'slots');
    if (!Array.isArray(slots) || slots.length !== count || !packedArray(slots)) return cel;
    const pixels = new Int32Array(count);
    for (let i = 0; i < count; i++) {
      const swatch = ownData(slots, i);
      const slot = swatch === null ? -1 : ids.get(swatch);
      if (slot === undefined) return cel;
      pixels[i] = slot;
    }
    planes.push({ frame, layer, pixels });
    // Keep the authored field in its original position for snapshot and SHA-256.
    return replacingDataField(cel, 'slots', []);
  }
  function pack(cel, frame, layer) {
    if (typeof frame !== 'string' || typeof layer !== 'string') return cel;
    const next = packSlots(cel, frame, layer);
    const authored = ownData(cel, 'marks');
    if (!packedArray(authored)) return next;
    const marks = [];
    const metadata = [];
    let changed = false;
    for (let i = 0; i < authored.length; i++) {
      const mark = ownData(authored, i);
      const spans = packSpans(ownData(mark, 'runs'), width, height, fromText);
      marks.push(spans);
      metadata.push(spans.length ? replacingDataField(mark, 'runs', []) : mark);
      changed ||= spans.length !== 0;
    }
    if (!changed) return next;
    runs.push({ frame, layer, marks });
    return replacingDataField(next, 'marks', metadata);
  }
  const key = version === 1 ? 'layers' : 'frames';
  const rows = ownData(input, key);
  if (!packedArray(rows)) return { document: input, planes, runs };
  const packed = [];
  for (let i = 0; i < rows.length; i++) {
    const row = ownData(rows, i);
    if (version === 1) {
      packed.push(pack(row, 'artwork', ownData(row, 'id')));
      continue;
    }
    const cels = ownData(row, 'cels');
    if (!cels || typeof cels !== 'object' || Array.isArray(cels)) {
      packed.push(row);
      continue;
    }
    let updated = cels;
    for (const layer of Object.keys(cels)) {
      const cel = ownData(cels, layer);
      const frame = ownData(row, 'id');
      const next = pack(cel, frame, layer);
      if (next !== cel) updated = replacingDataField(updated, layer, next);
    }
    packed.push(updated === cels ? row : replacingDataField(row, 'cels', updated));
  }
  return { document: planes.length || runs.length ? replacingDataField(input, key, packed) : input, planes, runs };
}

function documentPoint(width, height, point) {
  if (!Array.isArray(point) || point.length !== 2) return 0xffffffff;
  const x = ownData(point, '0'), y = ownData(point, '1');
  return Number.isInteger(x) && Number.isInteger(y) && x >= 0 && x < width && y >= 0 && y < height
    ? y * width + x : 0xffffffff;
}

// Keep authored coordinates in one typed list per saved region so a full native
// canvas does not cross the recursive JSON ABI as hundreds of thousands of tags.
function packNamedPixels(input) {
  if (ownData(input, 'version') !== 2) return { document: input, positions: [] };
  const width = ownData(input, 'width'), height = ownData(input, 'height');
  const selections = ownData(input, 'selections');
  if (!Array.isArray(selections) || ![width, height].every(n => Number.isInteger(n) && n > 0 && n <= 512)) {
    return { document: input, positions: [] };
  }
  const positions = [];
  const rows = [];
  for (let rowIndex = 0; rowIndex < selections.length; rowIndex++) {
    const row = ownData(selections, rowIndex);
    const pixels = ownData(row, 'pixels');
    if (!Array.isArray(pixels)) {
      positions.push([]);
      rows.push(row);
      continue;
    }
    const slots = new Uint32Array(pixels.length);
    for (let i = 0; i < slots.length; i++) slots[i] = documentPoint(width, height, ownData(pixels, i));
    positions.push(slots);
    rows.push(replacingDataField(row, 'pixels', []));
  }
  return { document: replacingDataField(input, 'selections', rows), positions };
}

// Dense tips cross the action boundary as integers. Keep their metadata and
// the authored operation in the existing checked JSON representation.
function packBrushSlots(operation) {
  const brush = ownData(operation, 'brush');
  const source = ownData(brush, 'slots');
  if (!Array.isArray(source)) return { metadata: operation, slots: [] };
  const slots = source.length <= 512 * 512 ? Int32Array.from({ length: source.length }, (_, i) => {
    const slot = ownData(source, i);
    if (slot === null) return -1;
    return Number.isInteger(slot) && slot >= 0 && slot < 255 ? slot : -2;
  }) : [];
  const metadata = replacingDataField(operation, 'brush', replacingDataField(brush, 'slots', []));
  return { metadata, slots };
}

function packClipboard(operation) {
  const source = ownData(operation, 'clipboard');
  const slotValues = ownData(source, 'slots'), alphaValues = ownData(source, 'alpha');
  let clipboard = source, slots = [], alpha = [];
  if (Array.isArray(slotValues)) {
    clipboard = replacingDataField(clipboard, 'slots', []);
    if (slotValues.length <= 512 * 512) {
      slots = Int32Array.from({ length: slotValues.length }, (_, i) => {
        const slot = ownData(slotValues, i);
        if (slot === null) return -3;
        return Number.isInteger(slot) && slot >= -2 && slot < 255 ? slot : -4;
      });
    }
  }
  if (Array.isArray(alphaValues)) {
    clipboard = replacingDataField(clipboard, 'alpha', []);
    if (alphaValues.length <= 512 * 512) {
      alpha = Uint32Array.from({ length: alphaValues.length }, (_, i) => {
        const byte = ownData(alphaValues, i);
        return Number.isInteger(byte) && byte >= 0 && byte <= 255 ? byte : 0xffffffff;
      });
    }
  }
  const metadata = clipboard === source ? operation : replacingDataField(operation, 'clipboard', clipboard);
  return { metadata, slots, alpha };
}

// Each row crosses as position, packed RGBA, and a swatch-name index.
// The upper position bit carries clear. Ink checks the reported shape and values.
function packRgba(operation, grid) {
  const input = ownData(operation, 'tool') === 'rgba' && ownData(operation, 'pixels');
  if (!Array.isArray(input)) return { metadata: operation, rows: [], names: [] };
  const metadata = replacingDataField(operation, 'pixels', []);
  if (input.length > grid.width * grid.height) return { metadata, rows: [], names: [] };
  const ids = new Map();
  const names = [];
  const rows = new Uint32Array(input.length * 3);
  for (let i = 0; i < input.length; i++) {
    const row = ownData(input, i);
    rows[i * 3] = 0xffffffff;
    if (!row || Object.getPrototypeOf(row) !== Object.prototype ||
        Object.keys(row).some(key => !['at', 'rgba', 'swatch'].includes(key))) continue;
    const p = documentPoint(grid.width, grid.height, ownData(row, 'at'));
    if (p === 0xffffffff) continue;
    const rgba = ownData(row, 'rgba');
    const swatch = ownData(row, 'swatch');
    if (rgba === null && swatch === undefined) {
      rows[i * 3] = p + 262144;
      continue;
    }
    if (!Array.isArray(rgba) || rgba.length !== 4) continue;
    const bytes = [0, 1, 2, 3].map(index => ownData(rgba, index));
    if (!bytes.every(n => Number.isInteger(n) && n >= 0 && n <= 255)) continue;
    rows[i * 3] = p;
    rows[i * 3 + 1] = ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) >>> 0;
    rows[i * 3 + 2] = 0xffffffff;
    if (swatch !== undefined) {
      const name = typeof swatch === 'string' ? swatch : '';
      if (!ids.has(name)) {
        ids.set(name, names.length);
        names.push(name);
      }
      rows[i * 3 + 2] = ids.get(name);
    }
  }
  return { metadata, rows, names };
}


function replacingDataField(source, name, value) {
  const fields = Object.getOwnPropertyDescriptors(source);
  fields[name].value = value;
  return Object.create(Object.getPrototypeOf(source), fields);
}

function option(value) {
  return value === undefined ? { None: null } : { Some: value };
}

function unwrap(result) {
  if (Object.hasOwn(result, 'Err')) throw new Error(result.Err);
  return result.Ok;
}

function coordinateRuns(width, height, points, limit) {
  if (!Array.isArray(points) || points.length > limit) return [];
  const result = [points.length];
  for (const point of points) {
    const valid = Array.isArray(point) && point.length === 2 && Number.isInteger(point[0]) &&
      Number.isInteger(point[1]) && point[0] >= 0 && point[0] < width && point[1] >= 0 && point[1] < height;
    const slot = valid ? point[1] * width + point[0] : 0xffffffff;
    const end = result.length - 1;
    if (end > 0 && result[end - 1] + result[end] === slot) result[end]++;
    else result.push(slot, 1);
  }
  return result;
}

function prepareSelection(width, height, query, saved) {
  const runs = [];
  const pack = (points, limit = width * height) => runs.push(coordinateRuns(width, height, points, limit));
  const nodes = [];
  const recalled = new Map();
  let usesColor = false;
  // Put query references in a flat table so the original operation budget
  // governs long chains of modifiers before wire nesting limits are reached.
  function append(value) {
    if (nodes.length === 33) return 0;
    const index = nodes.length;
    nodes.push(value);
    if (value && Object.getPrototypeOf(value) === Object.prototype) {
      const descriptors = Object.getOwnPropertyDescriptors(value);
      const type = descriptors.type?.value;
      if (type === 'wand') usesColor = true;
      if (type === 'pixels' && descriptors.pixels && Object.hasOwn(descriptors.pixels, 'value')) {
        descriptors.pixels.value = pack(descriptors.pixels.value);
      }
      if ((type === 'lasso' || type === 'polygon') && descriptors.points && Object.hasOwn(descriptors.points, 'value')) {
        descriptors.points.value = pack(descriptors.points.value, type === 'lasso' ? 4096 : 128);
      }
      const id = descriptors.id?.value;
      if (type === 'recall' && typeof id === 'string' && !recalled.has(id) && saved != null) {
        const source = Object.getOwnPropertyDescriptor(saved, id);
        if (source) recalled.set(id, pack(source.value));
      }
      for (const key of ['base', 'with', 'source']) {
        if (Object.hasOwn(descriptors, key) && Object.hasOwn(descriptors[key], 'value')) {
          descriptors[key].value = append(descriptors[key].value);
        }
      }
      nodes[index] = Object.defineProperties({}, descriptors);
    }
    return index + 1;
  }
  append(query);
  return { encoded: nodes.map(value => codec.fromJS(value)),
    packedSaved: codec.fromJS(Object.fromEntries(recalled)), runs, usesColor };
}

export function selectPixelMask(width, height, query, { rgba = [], saved = {}, large = false, indexed } = {}) {
  const limit = large ? 8192 : 512;
  if (![width, height].every(n => Number.isInteger(n) && n >= 1 && n <= limit) || width * height > 16777216) {
    throw new RangeError(large ? 'Selection exceeds the material canvas budget' :
      'Pixel selections need a canvas from 1 to 512 pixels on each axis');
  }
  const { encoded, packedSaved, runs, usesColor } = prepareSelection(width, height, query, saved);
  const colors = usesColor && rgba != null && rgba.length === width * height
    ? rgba instanceof Uint32Array ? rgba : checkedColors(rgba) : [];
  const args = [encoded, width, height, colors, packedSaved, runs, large];
  if (indexed != null) {
    const { slots, alpha = [], clipping = [], ids = [] } = indexed;
    const signed = slots instanceof Int16Array || slots instanceof Int32Array
      ? slots : checkedWords(slots, -0x80000000, 0x7fffffff);
    const plane = values => values instanceof Uint8Array || values instanceof Uint32Array
      ? values : checkedWords(values, 0, 0xffffffff);
    if (signed == null || plane(alpha) == null || plane(clipping) == null ||
        !Array.isArray(ids) || ids.some(id => typeof id !== 'string')) {
      throw new TypeError('An indexed selection raster needs integer slots, alpha and clipping planes and string IDs');
    }
    args.push(signed, alpha, clipping, ids);
  }
  const selected = call(indexed == null ? 'select_pixel_words' : 'select_pixel_words_from_raster', args);
  if (Object.hasOwn(selected, 'Err')) throw new Error(selected.Err);
  return Uint32Array.from(selected.Ok);
}

function checkedColors(rgba) {
  return checkedWords(rgba, 0, 0xffffffff) ?? [];
}

function checkedWords(values, min, max) {
  if (!Array.isArray(values)) return null;
  for (const word of values) {
    if (!Number.isInteger(word) || word < min || word > max) return null;
  }
  return values;
}

export function selectPixels(width, height, query, options) {
  return maskPixels(width, selectPixelMask(width, height, query, options));
}

function maskPixels(width, words) {
  const pixels = [];
  for (let i = 0; i < words.length; i++) {
    let bits = words[i];
    while (bits !== 0) {
      const slot = i * 32 + (31 - Math.clz32(bits & -bits));
      pixels.push([slot % width, Math.floor(slot / width)]);
      bits &= bits - 1;
    }
  }
  return pixels;
}
