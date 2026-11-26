import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { call } from '../build/rail.mjs';

const point = (x, y, z) => ({ x, y, z });
const a = point(0, 0, 0);
const b = point(4, 3, 0);
const c = point(4, 3, 4);
const nodes = [a, a, b, c];
const path = { length: 9, segments: [
  { start: a, delta: b, length: 5, offset: 0 },
  { start: b, delta: point(0, 0, 4), length: 4, offset: 5 },
] };
const empty = { segments: [], length: 0 };
const rise = point(0.8, 0.6000000000000001, 0);
const forward = point(0, 0, 1);
const step = (position, direction) => ({ position, direction });
const some = Some => ({ Some });
const none = { None: null };
const requests = [
  ['sample_spline', [[], 4], []],
  ['sample_spline', [[a], 4], [a]],
  ['sample_spline', [[a, b, c], 2], [a, point(2, 1.5, -0.25), b, point(4.25, 3.1875, 2), c]],
  ['prepare_rail', [nodes], path],
  ['prepare_rail', [[]], empty],
  ['prepare_rail', [[a, a]], empty],
  ['rail_at', [empty, 0], none],
  ['rail_nearest', [empty, 1, 9], none],
  ['rail_at', [path, -3], some(step(a, rise))],
  ['rail_at', [path, 5], some(step(b, rise))],
  ['rail_at', [path, 9.5], some(step(c, forward))],
  ['rail_at', [path, 2.5], some(step(point(2, 1.5, 0), rise))],
  ['rail_nearest', [path, 2, 1.25], some({ distance: 1.25, arc: 2.5, point: step(point(2, 1.5, 0), rise) })],
  ['rail_nearest', [path, 3, 2], some({ distance: 1, arc: 7, point: step(point(4, 3, 2), forward) })],
  ['rail_nearest', [path, 3, 1], some({ distance: 1, arc: 3.75, point: step(point(3, 2.25, 0), rise) })],
  ['rail_nearest', [{ length: 2, segments: [{ start: a, delta: point(0, 2, 0), length: 2, offset: 0 }] }, 2, 0],
    some({ distance: 2, arc: 0, point: step(a, point(0, 1, 0)) })],
];
const js = requests.map(([pure, args, expected]) => {
  const actual = call(pure, args);
  assert.deepEqual(actual, expected, pure);
  return actual;
});
const manifest = fileURLToPath(new URL('../build/rail-rust/Cargo.toml', import.meta.url));
const directory = mkdtempSync(join(tmpdir(), 'ink-rail-'));
try {
  const input = join(directory, 'requests.json');
  writeFileSync(input, JSON.stringify(requests.map(([pure, args]) => ({ pure, args }))));
  const rust = JSON.parse(execFileSync('cargo', ['run', '--quiet', '--manifest-path', manifest, '--', input], { encoding: 'utf8' }));
  assert.deepEqual(rust, js);
} finally {
  rmSync(directory, { recursive: true, force: true });
}
console.log(JSON.stringify({ crossTargetQueries: requests.length }));
