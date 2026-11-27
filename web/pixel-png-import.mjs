import { callOwned } from '../build/pixel_document.mjs';
import { unpackRun } from './pixel-run-words.mjs';

function unwrap(result) {
  if (Object.hasOwn(result, 'Err')) throw new Error(result.Err);
  return result.Ok;
}

function packBytes(bytes) {
  const words = new Uint32Array(Math.ceil(bytes.byteLength / 4));
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let p = 0;
  for (; p + 4 <= bytes.byteLength; p += 4) words[p >>> 2] = view.getUint32(p, true);
  for (let i = p; i < bytes.byteLength; i++) words[p >>> 2] |= bytes[i] << ((i - p) * 8);
  return words;
}

async function inflate(blob, limit) {
  const stream = blob.stream().pipeThrough(new DecompressionStream('deflate'));
  const read = stream.getReader();
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const { value, done } = await read.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await read.cancel();
        throw new RangeError(`Cannot create a Buffer larger than ${limit} bytes`);
      }
      chunks.push(value);
    }
  } finally {
    read.releaseLock();
  }
  if (chunks.length === 1) return chunks[0];
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, at);
    at += chunk.byteLength;
  }
  return bytes;
}

function unsigned(value, limit) {
  return Number.isInteger(value) && value >= 0 && value <= limit ? value : 0xffffffff;
}

function signedSlot(value) {
  if (value === null) return -1;
  const word = unsigned(value, 0x7fffffff);
  return word === 0xffffffff ? -3 : word;
}

function unpackMetadata(metadata) {
  const packed = Object.create(null);
  for (const key of ['slots', 'alpha', 'knockouts']) {
    const rows = metadata?.[key];
    if (!Array.isArray(rows)) {
      packed[key] = [];
      continue;
    }
    packed[key] = key === 'slots'
      ? Int32Array.from(rows, signedSlot)
      : Uint32Array.from(rows, row => unsigned(row, 0xffffffff));
    metadata[key] = [];
  }
  return packed;
}

async function pngScanlines(bytes, inspect) {
  if (!(bytes instanceof Uint8Array)) throw new TypeError('PNG import needs a Uint8Array');
  if (bytes.byteLength > 0xffffffff) throw new RangeError('PNG file exceeds the import byte limit');
  const layout = unwrap(callOwned(inspect, [packBytes(bytes), bytes.byteLength]));
  const parts = layout.data.map(({ start, length }) => bytes.subarray(start, start + length));
  return { layout, data: await inflate(new Blob(parts), layout.raw_size) };
}

export async function extractPngPalette(bytes, codec, options) {
  const { layout, data } = await pngScanlines(bytes, 'inspect_palette_png');
  return codec.toJS(unwrap(callOwned('extract_png_palette', [
    layout, packBytes(data), data.byteLength, codec.fromJS(options),
  ])));
}

export async function decodePixelPng(bytes, codec) {
  const { layout, data } = await pngScanlines(bytes, 'inspect_pixel_png');
  const { start, length } = layout.annotation;
  const palette = start === 0 ? null : new Blob([bytes.subarray(start, start + length)]);
  const samples = unwrap(callOwned('decode_pixel_png', [layout, packBytes(data), data.byteLength]));
  let metadata = null;
  if (palette) {
    const annotation = await inflate(palette, layout.width * layout.height * 14 + 8388608);
    metadata = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(annotation));
  }
  const { slots, alpha, knockouts } = unpackMetadata(metadata);
  const imported = unwrap(callOwned('restore_pixel_png', [
    layout, samples, codec.fromJS(metadata), slots, alpha, knockouts,
  ]));
  const document = codec.toJS(imported.template);
  const cel = document.frames[0].cels.image;
  const ids = Object.keys(document.palette);
  cel.slots = Array.from(imported.slots, slot => slot < 0 ? null : ids[slot]);
  cel.marks = imported.marks.map(({ alpha, first, length }) => ({
    ...(alpha === 255 ? { swatch: null } : { alpha }),
    runs: Array.from({ length }, (_, i) => unpackRun(imported.spans[first + i])),
  }));
  return document;
}
