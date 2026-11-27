import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { deflateSync, inflateSync } from 'node:zlib';

import { createPixelCommandEditor, openPixelPng } from '../web/pixel-document.mjs';
import { literalDocument } from './pixel-slot-planes.mjs';

const require = createRequire(import.meta.url);
const pngCommand = { format: 'ink-studio/pixel-command', version: 1, action: 'export',
  artifact: 'png', options: { layer: 'image', colorMode: 'rgba' } };
const signature = Uint8Array.of(137, 80, 78, 71, 13, 10, 26, 10);
const adam7 = [[0,0,8,8],[4,0,8,8],[0,4,4,8],[2,0,4,4],[0,2,2,4],[1,0,2,2],[0,1,1,2]];

function predictor(filter, left, up, corner) {
  if (filter === 0) return 0;
  if (filter === 1) return left;
  if (filter === 2) return up;
  if (filter === 3) return (left + up) >>> 1;
  const sum = left + up - corner;
  const distances = [left, up, corner].map(value => Math.abs(sum - value));
  return [left, up, corner][distances.indexOf(Math.min(...distances))];
}

function authoredPng(chunk, { width, height, color, bits, interlace = false, sample, palette, transparency }) {
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[color];
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = bits;
  header[9] = color;
  header[12] = Number(interlace);
  const bpp = Math.ceil(channels * bits / 8);
  const rows = [];
  let rowNumber = 0;
  for (const [startX, startY, stepX, stepY] of interlace ? adam7 : [[0,0,1,1]]) {
    if (startX >= width || startY >= height) continue;
    const size = Math.ceil(Math.ceil((width - startX) / stepX) * channels * bits / 8);
    let previous = new Uint8Array(size);
    for (let y = startY; y < height; y += stepY) {
      const row = new Uint8Array(size);
      let offset = 0;
      for (let x = startX; x < width; x += stepX) {
        for (const value of sample(x, y)) {
          if (bits === 16) {
            row[offset >>> 3] = value >>> 8;
            row[(offset >>> 3) + 1] = value & 255;
          } else {
            row[offset >>> 3] |= value << (8 - bits - (offset & 7));
          }
          offset += bits;
        }
      }
      const filter = rowNumber++ % 5;
      const bytes = row.map((byte, i) =>
        byte - predictor(filter, row[i - bpp] ?? 0, previous[i], previous[i - bpp] ?? 0));
      rows.push(Uint8Array.of(filter), bytes);
      previous = row;
    }
  }
  const image = deflateSync(Buffer.concat(rows));
  const middle = image.length >>> 1;
  return Buffer.concat([signature, chunk('IHDR', header),
    ...(palette ? [chunk('PLTE', Uint8Array.from(palette.flat()))] : []),
    ...(transparency ? [chunk('tRNS', Uint8Array.from(transparency))] : []),
    chunk('IDAT', image.subarray(0, middle)), chunk('IDAT', image.subarray(middle)), chunk('IEND', new Uint8Array())]);
}

function rewriteChunk(bytes, tag, edit) {
  const parts = [bytes.subarray(0, signature.length)];
  for (let p = signature.length; p < bytes.length;) {
    const length = bytes.readUInt32BE(p);
    const end = p + length + 12;
    const kind = bytes.toString('ascii', p + 4, p + 8);
    if (kind === tag) parts.push(...edit(bytes.subarray(p + 8, end - 4)));
    else parts.push(bytes.subarray(p, end));
    p = end;
  }
  return Buffer.concat(parts);
}

export function importFixtures(root) {
  const oracle = require(resolve(root, 'cli/pixel-art.js'));
  const png = require(resolve(root, 'cli/png.js'));
  const { chunk } = require(resolve(root, 'src/png-bytes.js'));
  const authored = options => authoredPng(chunk, options);
  const fixtures = [];
  function add(label, bytes) {
    try {
      const document = oracle.documentFromPNG(bytes);
      const editor = oracle.createEditor(document);
      const revision = createHash('sha256').update(JSON.stringify(document)).digest('hex');
      assert.equal(editor.describe().revision, revision);
      fixtures.push({ label, bytes, document, revision, png: editor.execute(pngCommand) });
    } catch (error) {
      fixtures.push({ label, bytes, error: error.message });
    }
  }
  const size = { width: 11, height: 9 };
  for (const bits of [1, 2, 4, 8]) {
    add(`Adam7 grayscale ${bits}-bit with filters and tRNS`, authored({
      ...size, color: 0, bits, interlace: true, transparency: [0, 1],
      sample: (x, y) => [(x + 3 * y) & ((1 << bits) - 1)],
    }));
  }
  add('2-bit indexed, aliases, complete and partial transparency', authored({
    ...size, color: 3, bits: 2, interlace: true, sample: (x, y) => [(x + y) % 4],
    palette: [[61,92,123], [61,92,123], [218,129,184], [23,37,61]], transparency: [255,30,0],
  }));
  add('8-bit grayscale and alpha', authored({
    ...size, color: 4, bits: 8, sample: (x, y) => [((x + y) * 18) % 256, y % 2 ? 0 : 90],
  }));
  add('RGB with exact tRNS match', authored({
    ...size, color: 2, bits: 8, transparency: [0,31,0,64,0,127],
    sample: (x, y) => [31 + x % 2, 64, 127 + y % 2],
  }));
  add('RGBA with hidden color and partial alpha', authored({
    ...size, color: 6, bits: 8, interlace: true, sample: (x, y) => [x * 3, 99, y * 9, (x + y) % 3 * 100],
  }));
  const blank = png.encode(3, 1, new Uint8Array(12), 4);
  add('Completely transparent foreign PNG receives a default swatch', blank);
  add('PNG scanline contains an invalid filter', rewriteChunk(blank, 'IDAT', data => {
    const row = inflateSync(data);
    row[0] = 5;
    return [chunk('IDAT', deflateSync(row))];
  }));
  add('PNG decompression cannot exceed the scanline size', rewriteChunk(blank, 'IDAT', () =>
    [chunk('IDAT', deflateSync(new Uint8Array(65536)))]));
  add('Invalid 16-bit PNG for pixel import', authored({
    ...size, color: 0, bits: 16, sample: (x, y) => [(x + y) * 4096 % 65536],
  }));
  add('Indexed PNG sample references a missing palette entry', authored({
    ...size, color: 3, bits: 2, sample: (x, y) => [(x + y) % 4],
    palette: [[61,92,123], [218,129,184]],
  }));
  add('256 opaque first-use colors exceed the document palette', authored({
    width: 256, height: 1, color: 2, bits: 8, sample: x => [x, 60, 70],
  }));
  const paint = { width: 5, height: 1, palette: ['#ac2186', '#ac2186', '#008c7f'],
    swatchIds: ['back', 'front', 'glass'], slots: [0, 1, null, 2, 0], alpha: [255, 0, 255, 170, 73],
    knockouts: [2], swatchLabels: { back: 'Purple 雪' }, lockedSwatches: ['glass'],
    ramps: [{ id: 'echo', swatches: ['front', 'back'] }] };
  for (const mode of ['indexed', 'rgba']) add(`Editable ${mode} with palette metadata`, png.encodePaint(paint, mode));
  const editable = png.encodePaint(paint, 'indexed');
  add('Duplicate editable palette chunks', rewriteChunk(editable, 'inKD', data =>
    [chunk('inKD', data), chunk('inKD', data)]));
  add('Editable annotation disagrees with RGB samples', rewriteChunk(editable, 'inKD', data => {
    const record = JSON.parse(inflateSync(data).toString());
    record.palette[0] = '#34a0ce';
    return [chunk('inKD', deflateSync(JSON.stringify(record)))];
  }));
  add('Same-colour swatches must still match PNG palette indices', rewriteChunk(editable, 'inKD', data => {
    const record = JSON.parse(inflateSync(data).toString());
    record.slots[0] = 1;
    record.slots[1] = 0;
    return [chunk('inKD', deflateSync(JSON.stringify(record)))];
  }));
  add('Not a PNG', Buffer.from('invalid'));
  const full = oracle.createEditor(literalDocument());
  const largest = full.execute({ ...pngCommand, options: { colorMode: 'rgba', layer: 'ink' } });
  add('512×512 editable PNG with the maximum literal slot plane', Buffer.from(largest.data, 'base64'));
  return fixtures;
}

async function main(root, native) {
  const cases = importFixtures(root);
  const valid = cases.filter(row => row.document).length;
  const rejected = cases.filter(row => row.error).length;
  assert.equal(valid, 12);
  assert.equal(rejected, 9);
  const temp = mkdtempSync(join(tmpdir(), 'ink-pixel-png-import-'));
  try {
    for (const { label, bytes, document, revision, error, png } of cases) {
      if (error) {
        await assert.rejects(openPixelPng(bytes), { message: error }, label);
      } else {
        const opened = await openPixelPng(bytes);
        assert.equal(JSON.stringify(opened.document), JSON.stringify(document), label);
        assert.equal(opened.revision, revision, label);
        assert.equal(opened.legacyRevision, null, label);
        const editor = await createPixelCommandEditor(opened.document);
        assert.deepEqual(await editor.execute(pngCommand), png, label);
      }
      if (native) {
        const file = join(temp, 'figure.png');
        writeFileSync(file, bytes);
        const result = spawnSync(resolve(native), ['import-png', file], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
        if (error) {
          assert.equal(result.status, 1, label);
          assert.equal(result.stderr.trim(), error, label);
        } else {
          assert.equal(result.status, 0, result.stderr);
          const opened = JSON.parse(result.stdout);
          assert.equal(JSON.stringify(opened.document), JSON.stringify(document), 'native ' + label);
          assert.equal(opened.revision, revision, 'native ' + label);
          assert.equal(opened.legacyRevision, null, 'native ' + label);
          const request = join(temp, 'command.json');
          writeFileSync(request, JSON.stringify({ document: opened.document, steps: [{ op: 'execute', command: pngCommand }] }));
          const exported = spawnSync(resolve(native), ['journal-document', request],
            { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
          assert.equal(exported.status, 0, exported.stderr);
          assert.deepEqual(JSON.parse(exported.stdout).value, png, 'native ' + label);
        }
      }
    }
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ valid, rejected, exactReexports: valid, pairedWithNative: Boolean(native) }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main(process.argv[2], process.argv[3]);
}
