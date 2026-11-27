import { call, callOwned, compiledValues, createState, JsonCodec } from '../build/pixel_document.mjs';

const codec = new JsonCodec(compiledValues.open_pixel_document.params[0]);
const utf8 = new TextEncoder();

async function revision(document) {
  const bytes = await crypto.subtle.digest('SHA-256', utf8.encode(JSON.stringify(document)));
  return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, '0')).join('');
}

export async function openPixelDocument(source) {
  const input = typeof source === 'string' ? JSON.parse(source) : source;
  const opened = callOwned('open_pixel_document', [codec.fromJS(input)]);
  if (Object.hasOwn(opened, 'Err')) throw new Error(opened.Err);
  const document = codec.toJS(opened.Ok.document);
  const [current, legacy] = await Promise.all([
    revision(document),
    opened.Ok.legacy ? revision(input) : null,
  ]);
  return { document, revision: current, legacyRevision: legacy };
}

export function rasterizePixelFrame(source, { frame = '', layer = '', cel = '' } = {}) {
  const input = typeof source === 'string' ? JSON.parse(source) : source;
  const raster = call('rasterize_pixel_frame', [codec.fromJS(input), frame, layer, cel]);
  if (Object.hasOwn(raster, 'Err')) throw new Error(raster.Err);
  const { width, height, frame: active, slots, alpha, clipping, ids, rgba } = raster.Ok;
  return { width, height, frame: active || null, slots: Int32Array.from(slots),
    alpha: Uint32Array.from(alpha), clipping: Uint32Array.from(clipping), ids, rgba: Uint32Array.from(rgba) };
}

export function selectPixelFrame(source, query, { saved, ...scope } = {}) {
  return createPixelEditor(source).select(query, { ...scope, saved });
}

export function createPixelEditor(source) {
  const state = createState();
  // JSON's typed representation has multiple schema levels per authored level.
  const load = state.bind('load_pixel_editor', { resultOnly: true, inputLimits: { depth: 512, nodes: 8000000 } });
  const pick = state.bind('select_pixel_editor', { resultOnly: true });
  const draw = state.bind('paint_pixel_editor', { resultOnly: true });
  const read = state.bind('snapshot_pixel_editor', { resultOnly: true });
  let grid;
  function replaceDocument(source) {
    const input = typeof source === 'string' ? JSON.parse(source) : source;
    const { document, positions } = packNamedPixels(input);
    grid = unwrap(load(codec.fromJS(document), positions));
  }
  function select(query, { frame, layer, cel, saved = {} } = {}) {
    const { encoded, packedSaved, runs } = prepareSelection(grid.width, grid.height, query, saved);
    const chosen = unwrap(pick(encoded, packedSaved, runs, option(frame), option(layer), option(cel)));
    return { frame: chosen.frame, grid: [chosen.grid.width, chosen.grid.height],
      pixels: maskPixels(chosen.grid.width, chosen.words) };
  }
  function paint(operation, { frame, cel } = {}) {
    const result = unwrap(draw(codec.fromJS(operation), option(frame), option(cel)));
    const { pixelPerfect, selection, ...target } = result;
    const drawing = ownData(operation, 'drawing');
    return { destination: 'raster', kind: 'raster', ...target,
      ...(pixelPerfect && { pixelPerfect }), ...(Object.hasOwn(selection, 'Some') && { selection: selection.Some }),
      ...(drawing !== undefined && { drawing: structuredClone(drawing) }) };
  }
  function snapshot() {
    const saved = read();
    const document = codec.toJS(saved.document);
    for (const [i, positions] of saved.positions.entries()) {
      if (!positions.length) continue;
      document.selections[i].pixels = positions.map(p => [p % document.width, Math.floor(p / document.width)]);
    }
    return document;
  }
  replaceDocument(source);
  return Object.freeze({ replaceDocument, select, paint, snapshot });
}

function ownData(value, key) {
  if (!value || typeof value !== 'object') return undefined;
  const field = Object.getOwnPropertyDescriptor(value, key);
  return field?.enumerable && Object.hasOwn(field, 'value') ? field.value : undefined;
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
