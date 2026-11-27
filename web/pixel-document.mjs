import { callOwned, compiledValues, JsonCodec } from '../build/pixel_document.mjs';

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

export function selectPixels(width, height, query, { rgba = [], saved = {} } = {}) {
  if (![width, height].every(n => Number.isInteger(n) && n >= 1 && n <= 512)) {
    throw new RangeError('Pixel selections need a canvas from 1 to 512 pixels on each axis');
  }
  const nodes = [];
  // Put query references in a flat table so the original operation budget
  // governs long chains of modifiers before wire nesting limits are reached.
  function append(value) {
    if (nodes.length === 33) return 0;
    const index = nodes.length;
    nodes.push(value);
    if (value && Object.getPrototypeOf(value) === Object.prototype) {
      const descriptors = Object.getOwnPropertyDescriptors(value);
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
  const encoded = nodes.map(value => codec.fromJS(value));
  const colors = nodes.some(node => node?.type === 'wand') ? rgba : [];
  const selected = callOwned('select_pixel_indices', [encoded, width, height, colors, codec.fromJS(saved)]);
  if (Object.hasOwn(selected, 'Err')) throw new Error(selected.Err);
  return Array.from(selected.Ok, slot => [slot % width, Math.floor(slot / width)]);
}
