import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { call as sculpt } from '../build/sculpt.mjs';
import { call as marks } from '../build/marks.mjs';
import { call as noise } from '../build/noise.mjs';

const point = (x, y, z) => ({ x, y, z });
const origin = point(0, 0, 0);
const none = { None: null };
const frames = [];
const strokes = [];
const normalize = state => JSON.parse(JSON.stringify(state));
function check(call, tests, pure, args, reference) {
  const output = call(pure, args);
  if (reference !== undefined) assert.deepEqual(normalize(output), reference);
  tests.push({ pure, args, output });
  return output;
}
const shape = (pure, args, reference) => check(sculpt, frames, pure, args, reference);
const stroke = (pure, args, reference) => check(marks, strokes, pure, args, reference);

const rotation = { Some: { x: point(0, 0, -1), y: point(0, 1, 0), z: point(1, 0, 0) } };
const box = shape('boxed', [origin, rotation, Math.sqrt(6), point(2, 1, 1), 0.1]);
shape('solid_distance', [box, point(0, 0, 2)], 0);
const ball = shape('ellipsoid', [origin, none, 2, point(1, 2, 1)]);
shape('solid_distance', [ball, point(0, 2, 0)], 0);
shape('solid_distance', [ball, origin], -1);
const turned = shape('turned', [origin, none, Math.sqrt(5), 2, 2, -1]);
shape('solid_distance', [turned, point(1.5, 0, 0)], 0);
const tube = shape('tube', [origin, 4, [
  { start: point(0, -1, 0), delta: point(0, 2, 0), length_squared: 4, base: 1.5, tip: 0.5 },
]]);
shape('solid_distance', [tube, point(1, 0, 0)], 0);
shape('solid_distance', [tube, point(0, 2, 0)], 0.5);
const ring = shape('ring', [origin, none, 4, 3, 1]);
shape('solid_distance', [ring, point(3, 0, 0)], -1);
shape('solid_distance', [ring, origin], 2);

const shells = [-0.25, 0.25].map(x => sculpt('ellipsoid', [point(x, 0, 0), none, 0.2, point(0.2, 0.2, 0.2)]));
const tables = noise('make_noise', [2]);
const member = (model, group, blend = 0) => ({ model, group, blend, bump: 0, frequency: 0 });
const joined = sculpt('prepare_scene', [shells, { positive: [member(0, 2, 0.4), member(1, 2, 0.4)], negative: [] }]);
const separated = sculpt('prepare_scene', [shells, { positive: [member(0, 2, 0.4), member(1, 3, 0.4)], negative: [] }]);
assert(Math.abs(shape('scene_distance', [joined, tables, origin, 1]) + 0.05) < 1e-12);
assert(Math.abs(shape('scene_distance', [separated, tables, origin, 1]) - 0.05) < 1e-12);

const cov = (first, rest) => ({ first, rest });
stroke('round_mark', [2], cov(point(4, 0, 0), point(4, 0, 4)));
stroke('axial_mark', [point(1e300, 0, 0), 2, 3], {
  Ok: { normal: point(1, 0, 0), covariance: cov(point(4, 0, 0), point(9, 0, 9)) },
});
assert('Err' in stroke('axial_mark', [origin, 2, 3]));
stroke('surface_mark', [point(0, 1, 0), point(1, 0, 0), 1, 2, 3],
  cov(point(1, 0, 0), point(9, 0, 4)));

const scratch = mkdtempSync(join(tmpdir(), 'ink-studio-sculpt-'));
try {
  for (const [project, cases] of [['sculpt', frames], ['marks', strokes]]) {
    const requests = join(scratch, 'requests.json');
    writeFileSync(requests, JSON.stringify(cases.map(({ pure, args }) => ({ pure, args }))));
    const manifest = fileURLToPath(new URL(`../build/${project}-rust/Cargo.toml`, import.meta.url));
    const result = execFileSync('cargo', ['run', '--quiet', '--manifest-path', manifest, '--', requests],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    assert.deepEqual(JSON.parse(result), cases.map(({ output }) => output));
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log('Sculpt distances, smooth groups, and splat covariances matched on JavaScript and Rust.');
