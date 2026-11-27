const signature = Uint8Array.of(137, 80, 78, 71, 13, 10, 26, 10);
const crcTable = Uint32Array.from({ length: 256 }, (_, key) => {
  let crc = key;
  for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  return crc;
});

function chunk(target, offset, type, bytes) {
  const view = new DataView(target.buffer, offset);
  view.setUint32(0, bytes.length);
  for (let i = 0; i < 4; i++) view.setUint8(4 + i, type.charCodeAt(i));
  target.set(bytes, offset + 8);
  let crc = 0xffffffff;
  for (let i = offset + 4, end = offset + 8 + bytes.length; i < end; i++) {
    crc = (crc >>> 8) ^ crcTable[(crc ^ target[i]) & 255];
  }
  view.setUint32(8 + bytes.length, ~crc);
  return offset + 12 + bytes.length;
}

function scanlines({ width, height, channels, pixels }) {
  const stride = width * channels + 1;
  const bytes = new Uint8Array(stride * height);
  const view = new DataView(bytes.buffer);
  let source = 0;
  for (let y = 0; y < height; y++) {
    let at = y * stride + 1;
    if (channels === 1) {
      for (let x = 0; x < width; x++) bytes[at++] = pixels[source++];
    } else {
      for (let x = 0; x < width; x++, at += 4) view.setUint32(at, pixels[source++]);
    }
  }
  return bytes;
}

async function deflate(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export async function pixelPng(image, metadata) {
  const { width, height, channels, colors, coverage, palette, ids, slots, knockouts } = image;
  const ink = new TextEncoder().encode(JSON.stringify({
    version: 1, palette, swatchIds: ids, slots: slots.map(slot => slot < 0 ? null : slot),
    ...(knockouts.length && { knockouts }), ...metadata,
  }));
  if (ink.length > slots.length * 14 + 8_388_608) throw new RangeError('Ink PNG palette metadata exceeds the export budget');
  const [compressed, annotation] = await Promise.all([deflate(scanlines(image)), deflate(ink)]);
  const header = new Uint8Array(13);
  const view = new DataView(header.buffer);
  view.setUint32(0, width);
  view.setUint32(4, height);
  header[8] = 8;
  header[9] = channels === 1 ? 3 : 6;
  const parts = [['IHDR', header]];
  if (channels === 1) {
    const table = new Uint8Array(colors.length * 3);
    for (let i = 0; i < colors.length; i++) {
      table[i * 3] = colors[i] >>> 16;
      table[i * 3 + 1] = colors[i] >>> 8;
      table[i * 3 + 2] = colors[i];
    }
    parts.push(['PLTE', table]);
    if (coverage.length) parts.push(['tRNS', Uint8Array.from(coverage)]);
  }
  parts.push(['inKD', annotation], ['IDAT', compressed], ['IEND', new Uint8Array(0)]);
  const png = new Uint8Array(parts.reduce((size, [, data]) => size + data.length + 12, signature.length));
  png.set(signature);
  let offset = signature.length;
  for (const [type, data] of parts) offset = chunk(png, offset, type, data);
  return png;
}

export function pngBase64(bytes) {
  if (typeof bytes.toBase64 === 'function') return bytes.toBase64();
  let text = '';
  for (let start = 0; start < bytes.length; start += 16384) {
    text += String.fromCharCode(...bytes.subarray(start, start + 16384));
  }
  return btoa(text);
}
