import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { call as sculpt } from '../build/sculpt.mjs';
import { call as marks } from '../build/marks.mjs';
import { call as noise } from '../build/noise.mjs';
import { call as brush } from '../build/brush.mjs';
import { call as trees } from '../build/trees.mjs';

const point = (x, y, z) => ({ x, y, z });
const origin = point(0, 0, 0);
const none = { None: null };
const frames = [];
const strokes = [];
const brushes = [];
const treeCases = [];
const normalize = state => JSON.parse(JSON.stringify(state));
function check(call, tests, pure, args, reference) {
  const output = call(pure, args);
  if (reference !== undefined) assert.deepEqual(normalize(output), reference);
  tests.push({ pure, args, output });
  return output;
}
const shape = (pure, args, reference) => check(sculpt, frames, pure, args, reference);
const stroke = (pure, args, reference) => check(marks, strokes, pure, args, reference);
const paint = (pure, args, reference) => check(brush, brushes, pure, args, reference);
const tree = (pure, args) => check(trees, treeCases, pure, args);

const rotation = { Some: { x: point(0, 0, -1), y: point(0, 1, 0), z: point(1, 0, 0) } };
const box = shape('boxed', [origin, rotation, Math.sqrt(6), point(2, 1, 1), 0.1]);
shape('solid_distance', [box, point(0, 0, 2)], 0);
const ball = shape('ellipsoid', [origin, none, 2, point(1, 2, 1)]);
shape('solid_distance', [ball, point(0, 2, 0)], 0);
shape('solid_distance', [ball, origin], -1);
const turned = shape('turned', [origin, none, Math.sqrt(5), 2, 2, -1]);
shape('solid_distance', [turned, point(1.5, 0, 0)], 0);
for (const exponent of [0.35, 1, 1.3, 4]) {
  const profile = shape('turned_power', [origin, none, 2, 2, 1, exponent]);
  for (const y of [-0.9999999999, -0.75, 0, 0.8, 0.9999999999]) {
    const radius = 2 - Math.pow(y / 2 + 0.5, exponent);
    assert(Math.abs(shape('solid_distance', [profile, point(radius, y, 0)]) < 1e-14));
  }
}
const ripple = { height: 1.5, base: 0.5, taper: 0.5, amplitude: 0.1, frequency: 9 };
const rippleModel = shape('turned_ripple', [origin, none, 1, ripple]);
for (const t of [0.1, 0.3, 0.5, 0.7, 0.9]) {
  const radius = ripple.base * (1 - ripple.taper * t) * (1 + ripple.amplitude * Math.sin(ripple.frequency * t));
  assert(Math.abs(shape('solid_distance', [rippleModel, point(radius, (t - 0.5) * ripple.height, 0)]) < 1e-14));
}
const powerRipple = { height: 3.2, radius: 1.4, tip: 0.05, exponent: 0.72, amplitude: 0.14, frequency: 10, phase: 1.3 };
const powerRippleModel = shape('turned_power_ripple', [origin, none, powerRipple]);
for (const t of [0, 0.125, 0.5, 0.9375, 1]) {
  const { height, radius, tip, exponent, amplitude, frequency, phase } = powerRipple;
  const edge = radius * (1 - t) ** exponent * (1 + amplitude * Math.sin(t * frequency + phase)) + tip;
  assert(Math.abs(shape('solid_distance', [powerRippleModel, point(edge, (t - 0.5) * height, 0)])) < 1e-13);
}
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

const seeds = paint('brush_noise', [2]);
const position = point(10.026, 0.114, -16.866);
const pattern = paint('grass_pattern', [seeds, position]);
assert(Object.values(pattern).every(value => value >= 0 && value <= 1));
const band = paint('leaf_band', [seeds, position]);
const surface = { position, normal: point(0, 1, 0), spacing: 0.17, tone: 0.56 };
const colors = [4, 5, 6, 7];
const random = 0x5bd1e995;
const advanced = count => (random + count * 1831565813) >>> 0;
const grass = { height: 0.17, width: 0.032, fat: 0.46, shadow: 0.24, pattern: { ...pattern, wear: 0.5 } };
const full = paint('paint_grass', [surface, colors, grass, random]);
assert.equal(full.marks.length, 3);
assert.equal(full.random, advanced(6));
assert.deepEqual(full.marks[0].position, position);
const worn = paint('paint_grass', [surface, colors, { ...grass, pattern: { ...pattern, wear: 0.94 } }, random]);
assert.equal(worn.marks.length, 1);
assert.equal(worn.random, advanced(1));
const leaf = { lift: 0.3, length: 0, width: 0.085, jitter: 1.3, band, ao: 0.7, sun: point(0.45, 0.72, 0.52) };
const foliage = paint('paint_leaf', [surface, colors, leaf, random]);
assert.equal(foliage.random, advanced(5));
assert(foliage.marks[0].position.y > position.y);
const feather = paint('paint_leaf', [surface, colors, { ...leaf, length: 0.32 }, random]);
assert.equal(feather.random, advanced(2));
assert.equal(feather.marks[0].along, 0.32);
assert.equal(paint('brush_splats', [full, [0, 0, 0, 0, 10, 20, 30, 40]]).length, 3);

const maple = { base: origin, height: 5.5, radius: .3, lean: { x: .1, z: -.2 }, spacing: .1,
  roots: 3, limbs: 5, spread: 3, cluster_scale: 1, leaf_scale: 0, leaf_count: 72, leafy: true };
const growth = tree('grow_tree', [maple, random, false]);
const collision = tree('grow_tree', [maple, random, true]);
assert(growth.wood.length > collision.wood.length);
assert.equal(collision.wood.length, maple.roots + 1);
assert.deepEqual(tree('tree_colliders', [maple, random]), collision.wood);
assert.deepEqual(collision.clusters, growth.clusters);
assert.equal(collision.random, growth.random);
const trunk = tree('wood_tube', [growth.wood[0]]);
assert.equal(trunk.segments.length, 10);
assert.deepEqual(trunk.start.center, growth.wood[0].points[0]);
assert.deepEqual(trunk.end.center, growth.top);
const crownOptions = { sun: point(.45, .72, .52), basic: [4, 4, 5], lit: [5, 6, 7], local: [20],
  lamps: [{ position: point(0, 5, 0), radius: 50, strength: 1 }], scale: growth.scale };
const crown = tree('paint_crown', [growth.clusters, crownOptions, growth.leaf_count, none, growth.random]);
assert.equal(crown.leaves.length, maple.leaf_count);
assert(crown.leaves.every(leaf => leaf.mark.pigment === 20));
const outside = { Some: { x0: 10, z0: 10, x1: 15, z1: 15 } };
const clipped = tree('paint_crown', [growth.clusters, crownOptions, growth.leaf_count, outside, growth.random]);
assert.equal(clipped.leaves.length, 0);
assert.notEqual(clipped.random, crown.random);
const falling = tree('falling_leaves', [{ center: growth.top, radius: 3, colors: [22, 23, 26] }, 14, crown.random]);
assert.equal(falling.leaves.length, 14);
assert.equal(falling.random, (crown.random + 14 * 8 * 1831565813) >>> 0);

const scratch = mkdtempSync(join(tmpdir(), 'ink-studio-sculpt-'));
try {
  for (const [project, cases] of [['sculpt', frames], ['marks', strokes], ['brush', brushes], ['trees', treeCases]]) {
    const requests = join(scratch, 'requests.json');
    writeFileSync(requests, JSON.stringify(cases.map(({ pure, args }) => ({ pure, args }))));
    const manifest = fileURLToPath(new URL(`../build/${project}-rust/Cargo.toml`, import.meta.url));
    const result = execFileSync('cargo', ['run', '--quiet', '--manifest-path', manifest, '--', requests],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    const actual = JSON.parse(result);
    const expected = cases.map(({ output }) => output);
    if (project === 'brush' || project === 'trees') assert.deepEqual(normalize(actual), normalize(expected));
    else assert.deepEqual(actual, expected);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
console.log('Sculpt distances, splat covariances, brush strokes and tree generation matched on JavaScript and Rust.');
