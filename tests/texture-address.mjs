import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { functions as textures } from '../build/texture_address.mjs';

const reference = process.argv[2] && createRequire(import.meta.url)(resolve(process.argv[2], 'src/texture-address.js'));
const source = { width: 3, height: 2, pixels: [
  [1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1],
  [0.25, 0.5, 0.75, 0.5], [1, 1, 0, 1], [0, 0, 0, 0],
] };
const requests = [];
const check = (pure, ...args) => {
  const expected = textures[pure](...args);
  requests.push({ pure, args, expected });
  return expected;
};
const rgb = (red, green, blue, alpha) => ({ red, green, blue, alpha });
const settings = (filter, u, v = u) => check('texture_settings', filter, u, v).Ok;
const clamp = settings('nearest', 'clamp');
const wrap = settings('nearest', 'wrap');
const mirror = settings('nearest', 'mirror');
const clear = settings('linear', 'transparent');
assert.deepEqual(check('sample_texture', source, clamp, 1, 0).Ok, rgb(0, 0, 1, 1));
assert.deepEqual(check('sample_texture', source, wrap, 1, 0).Ok, rgb(1, 0, 0, 1));
assert.deepEqual(check('sample_texture', source, mirror, -0.1, 0).Ok, rgb(1, 0, 0, 1));
assert.deepEqual(check('sample_texture', source, clear, 0, 0).Ok, rgb(0.25, 0, 0, 0.25));
assert('Err' in check('sample_texture', { ...source, pixels: source.pixels.slice(1) }, clamp, 0, 0));
assert('Err' in check('sample_texture', { width: 0, height: 2, pixels: [] }, clamp, 0, 0));
assert('Err' in check('sample_texture', source, clamp, 16385, 0));
assert('Err' in check('texture_settings', 'bicubic', 'clamp', 'wrap'));
assert('Err' in check('texture_settings', 'linear', 'clamp', 'unknown'));

const modes = ['clamp', 'transparent', 'wrap', 'mirror'];
const taps = [[0,0], [1,1], [0.9,0.2], [1/6,1/4], [2/3,1/2], [-1e-8,1], [-0.5,-0.3], [2,1.2],
  [-1.5,2], [-16384,16384], [16383.95,-16383.9], [-1/3,0.5], [0.25,1e-8], [0.50000001,0.49999999]];
for (const filter of ['nearest', 'linear']) for (const edgeU of modes) for (const edgeV of modes) {
  const policy = settings(filter, edgeU, edgeV);
  const sample = reference?.sampler(Float32Array.from(source.pixels.flat()), source.width, source.height,
    reference.settings({ filter, edgeU, edgeV }));
  for (const [u, v] of taps) {
    const result = check('sample_texture', source, policy, u, v).Ok;
    assert(Object.values(result).every(value => value >= 0 && value <= 1), JSON.stringify(result));
    if (sample) {
      const expected = [0, 0, 0, 0];
      sample(u, v, expected);
      assert.deepEqual(result, rgb(...expected), [filter, edgeU, edgeV, u, v].join(' '));
    }
  }
}
for (const [width, height, channels, values] of [[2, 1, 2, [0.125, -0.2, 16384, 1]], [1, 2, 3, [1, 0, 0.3, 2, 1, 0]]]) {
  const actual = check('pack_texture_addresses', width, height, channels, values).Ok;
  assert.equal(actual.length, width * height);
  if (reference) assert.deepEqual(actual.flat(), Array.from(reference.raster({
    width, height, channels, data: values,
  }, width, height)));
}
assert('Err' in check('pack_texture_addresses', 1, 1, 3, [0, 0, 1.1]));
assert('Err' in check('pack_texture_addresses', 1, 1, 3, [0, -16385, 0]));
assert('Err' in check('pack_texture_addresses', 0xffffffff, 0xffffffff, 2, []));
assert('Err' in check('pack_texture_addresses', 1, 2, 4, [0, 0, 0, 0, 0, 0, 0, 0]));

const tmp = mkdtempSync(join(tmpdir(), 'ink-texture-address-'));
try {
  const input = join(tmp, 'cases.json');
  writeFileSync(input, JSON.stringify(requests.map(({ pure, args }) => ({ pure, args }))));
  const manifest = fileURLToPath(new URL('../build/texture_address-rust/Cargo.toml', import.meta.url));
  const actual = JSON.parse(execFileSync('cargo', ['run', '--quiet', '--release', '--manifest-path', manifest, '--', input], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  }));
  assert.equal(actual.length, requests.length);
  for (const [i, row] of requests.entries()) {
    if (row.pure === 'pack_texture_addresses' && row.expected.Ok) {
      assert.deepEqual(actual[i].Ok.map(pixel => pixel.map(Math.fround)), row.expected.Ok);
    } else assert.deepEqual(actual[i], row.expected, row.pure);
  }
  console.log(requests.length + ' texture addressing cases agree in Rust and JavaScript' + (reference ? ' and the original sampler.' : '.'));
} finally {
  rmSync(tmp, { force: true, recursive: true });
}
