import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { selectPixelMask } from '../web/pixel-document.mjs';

export function* capacityCases() {
  const full = (width, height) => Array.from({ length: width * height },
    (_, i) => [i % width, Math.floor(i / width)]);
  const literal = pixels => ({ type: 'pixels', pixels });
  const recall = id => ({ type: 'recall', id });
  const rect = (x, y, w, h) => ({ type: 'rectangle', rect: [x, y, w, h] });
  const normal = (query, extra = {}) => ({ width: 512, height: 512, query, ...extra });
  const material = (name, width, height, query, extra = {}) =>
    [name, { width, height, query, large: true, ...extra }];

  const pixels = full(512, 512);
  yield ['Full literal', normal(literal(pixels))];
  yield ['Full saved mask', normal(recall('all'), { saved: { all: pixels } })];
  yield ['Full literal and saved mask overlap', normal({
    type: 'subtract', base: literal(pixels), with: recall('other'),
  }, { saved: { other: pixels.filter((p, i) => i % 65 !== 0) } })];
  yield ['Duplicate before invalid coordinate', normal(literal([[2, 0], [2, 0], [512, 0]]))];
  yield ['Invalid coordinate before duplicate', normal(literal([[0, -1], [2, 0], [2, 0]]))];
  yield ['Overfull list', normal(literal(pixels.concat([[0, 0]])))];
  yield ['Overlap across word boundaries', normal(literal([
    ...Array.from({ length: 34 }, (_, i) => [30 + i, 0]), [31, 0],
  ]))];
  yield ['Two isolated bits at a word boundary', {
    width: 33, height: 1, query: literal([[31, 0], [32, 0]]),
  }];
  yield ['Inverting a partial final word', { width: 33, height: 1, query: { type: 'invert', source: literal([[0, 0]]) } }];
  yield ['Full rectangle with a partial final word', { width: 33, height: 1, query: rect(0, 0, 33, 1) }];
  yield ['Full literal with a partial final word', { width: 33, height: 1, query: literal(full(33, 1)) }];
  yield material('Full material literal', 1025, 257, literal(full(1025, 257)));
  yield material('Maximum area', 8192, 2048, rect(0, 0, 8192, 2048));
  yield material('Maximum height', 1, 8192, rect(0, 8189, 1, 3));
  yield material('Maximum area exceeded', 8192, 2049, rect(0, 0, 1, 1));
  yield material('Maximum axis exceeded', 8193, 1, rect(0, 0, 1, 1));
  yield material('Wide ellipse', 8192, 7, { type: 'ellipse', rect: [7003, 1, 1189, 5] });
  yield material('Wide lasso', 8192, 7, { type: 'lasso', points: [[0, 5], [8061, 0], [8191, 6], [3001, 2]] });
  yield material('Outline near material edge', 8192, 7, {
    type: 'outline', side: 'both', amount: 2, source: rect(8188, 1, 4, 5),
  });
  const colors = Array(1024 * 3).fill(0xff113300);
  colors[1022] = 0xab3179ff;
  colors[1023] = 0xab3179ff;
  colors[1024] = 0xab3179ff;
  yield material('Wand across a material row boundary', 1024, 3, {
    type: 'wand', at: [1023, 0], tolerance: 0,
  }, { rgba: colors });
}

export function expectedMask(originalRoot, request) {
  const original = createRequire(import.meta.url)(resolve(originalRoot, 'src/pixel-selections.js'));
  const { width, height, query, rgba, saved = {}, large } = request;
  try {
    const mask = original.mask(width, height, query, rgba && (i => rgba[i]), id => saved[id],
      undefined, undefined, large);
    const words = new Uint32Array(Math.ceil(mask.length / 32));
    for (let i = 0; i < mask.length; i++) if (mask[i]) words[i >>> 5] |= 1 << (i & 31);
    return { words };
  } catch (error) {
    return { error: error.message };
  }
}

function digest(words) {
  return createHash('sha256').update(Buffer.from(words.buffer, words.byteOffset, words.byteLength)).digest('hex');
}

function check(originalRoot, native) {
  const tmp = mkdtempSync(join(tmpdir(), 'ink-pixel-selection-capacity-'));
  const file = join(tmp, 'mask.json');
  let count = 0;
  try {
    for (const [name, request] of capacityCases()) {
      const { width, height, query, ...opts } = request;
      const expected = expectedMask(originalRoot, request);
      writeFileSync(file, JSON.stringify(request));
      const run = () => selectPixelMask(width, height, query, opts);
      if (expected.error) {
        assert.throws(run, { message: expected.error }, name);
        const result = spawnSync(native, ['select-mask', file], { encoding: 'utf8' });
        assert.equal(result.status, 1, name);
        assert.equal(result.stderr.trimEnd(), expected.error, name);
      } else {
        const result = execFileSync(native, ['select-mask', file], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
        const words = Uint32Array.from(JSON.parse(result));
        assert.equal(digest(run()), digest(expected.words), 'JavaScript ' + name);
        assert.equal(digest(words), digest(expected.words), 'Native ' + name);
      }
      count++;
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  console.log('JavaScript and native Rust matched ' + count + ' original dense and material mask cases.');
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-selection-capacity.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  check(process.argv[2], process.argv[3]);
}
