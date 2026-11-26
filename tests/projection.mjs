import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { call } from '../build/gaussian.mjs';

const row = { center: [0, 0], xx: 4, xy: 0, yy: 1, variance: 0, reach: 3,
  rgb: 0x0000ff, alpha: 0.5 };
const viewport = [32, 32];
const splats = [
  row,
  { ...row, center: [40, 0] },
  { ...row, yy: 4 },
  { ...row, xx: 2, xy: 1, yy: 2 },
  { ...row, xx: 1, xy: 2 },
  { ...row, alpha: 0 },
];
const args = [splats, viewport];
const result = call('project', args);
assert.deepEqual(result[0], { center: [0, 0], axis_x: [6, 0], axis_y: [-0, 3], rgb: 255, alpha: 0.5 });
assert.deepEqual(result[2].axis_x, [6, 0]);
assert.deepEqual(result[2].axis_y, [-0, 6]);
assert.ok(Math.abs(Math.hypot(...result[3].axis_x) - 3 * Math.sqrt(3)) < 1e-5);
assert.ok(Math.abs(result[3].axis_x[0] - result[3].axis_x[1]) < 1e-6);
for (const i of [1, 4, 5]) assert.equal(result[i].alpha, 0);
assert.deepEqual(call('project', [[], viewport]), []);

const directory = mkdtempSync(join(tmpdir(), 'ink-projection-'));
function run(cmd, args) {
  const result = spawnSync(cmd, args, { encoding: 'utf8' });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
// The JSON boundary may explicitly tag either sign of zero.
function bitsToValue(value) {
  if (!value || typeof value !== 'object') return value;
  if ('F32Bits' in value) {
    const bits = new Uint32Array([value.F32Bits]);
    return new Float32Array(bits.buffer)[0];
  }
  if (Array.isArray(value)) return value.map(bitsToValue);
  return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, bitsToValue(v)]));
}
try {
  const argsPath = join(directory, 'args.json');
  const requestsPath = join(directory, 'requests.json');
  writeFileSync(argsPath, JSON.stringify(args));
  writeFileSync(requestsPath, JSON.stringify([{ pure: 'project', args }]));
  const native = fileURLToPath(new URL('../build/rust/Cargo.toml', import.meta.url));
  const [rust] = run('cargo', ['run', '--quiet', '--manifest-path', native, '--', requestsPath]);
  assert.deepEqual(bitsToValue(rust), result);
  if (process.env.INK_WGPU_PROGRAM) {
    const gpu = run(process.env.INK_WGPU_PROGRAM, ['project', argsPath, '--backend', 'gpu-required']);
    assert.equal(gpu.backend, 'gpu');
    assert.deepEqual(bitsToValue(gpu.value), result);
  }
} finally {
  rmSync(directory, { recursive: true, force: true });
}
console.log('Gaussian projection cases matched.');
