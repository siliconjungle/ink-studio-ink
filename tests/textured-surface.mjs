import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { functions as surface } from '../build/textured_surface.mjs';
import { functions as rail } from '../build/rail.mjs';

const original = process.argv[2] && createRequire(import.meta.url)(resolve(process.argv[2], 'src/textured-surface.js'));
const checks = [];
const vec = (x, y, z) => ({ x, y, z });
const array = p => [p.x, p.y, p.z];
const cmpVec = (p, expected) => array(p).forEach((value, i) => assert(Math.abs(value - expected[i]) < 1e-12));
const none = { None: null };
const some = value => ({ Some: value });
const up = vec(0, 1, 0);
const check = (name, ...args) => {
  const expected = surface[name](...args);
  checks.push({ pure: name, args, expected });
  return expected;
};
const okay = (name, ...args) => {
  const result = check(name, ...args);
  assert('Ok' in result, JSON.stringify(result));
  return result.Ok;
};
function meshParity(mesh, reference) {
  const columns = mesh.divisions.columns;
  assert.equal(mesh.positions.length, (columns + 1) * (mesh.divisions.rows + 1));
  if (!reference) return;
  assert.deepEqual(mesh.positions.flat(), Array.from(reference.points));
  assert.deepEqual(mesh.uvs.flat(), Array.from(reference.uvs));
  assert.deepEqual(mesh.triangles.flatMap(face => [face.a, face.b, face.c]), Array.from(reference.triangles));
}

const point = (u, v) => [u * u, (u - 0.3) * (v + 0.2) + v * v, v];
const divisions = { columns: 2, rows: 3 };
const points = Array.from({ length: 12 }, (_, i) => vec(...point((i % 3) / 2, Math.floor(i / 3) / 3)));
for (const flip of [false, true]) {
  const grid = okay('textured_grid', divisions, 12, points, flip);
  const reference = original?.grid({ segments: [2, 3], point, flip });
  meshParity(grid, reference);
  assert.equal(grid.triangles.length, 12);
  assert.deepEqual(grid.triangles[0], flip ? { a: 0, b: 3, c: 1 } : { a: 0, b: 1, c: 3 });
  assert.deepEqual(grid.uvs.at(-1), [1, 1]);
  for (const [u, v] of [[0, 0], [0.15, 0.15], [0.42, 0.31], [0.5, 0.5], [0.8, 0.83], [1, 1]]) {
    const attachment = okay('surface_at', grid, u, v);
    if (reference) {
      const sample = reference.sample(u, v);
      cmpVec(attachment.position, sample.point);
      cmpVec(attachment.normal, sample.normal);
    }
  }
  assert('Err' in check('surface_at', grid, -0.1, 1));
}
assert('Err' in check('textured_grid', divisions, 11, points, false));
assert('Err' in check('textured_grid', { columns: 0xffffffff, rows: 0xffffffff }, 2000000, [], false));
assert('Err' in check('textured_grid', divisions, 12, points.slice(1), false));
assert('Err' in check('textured_grid', divisions, 12, [...points.slice(0, -1), vec(1e100, 0, 0)], false));

const bounds = { x0: -3, x1: 1, z0: -2, z1: 4 };
const heights = [0, 1, 1, 5];
const hill = okay('textured_heightfield', bounds, { columns: 1, rows: 1 }, 2, heights);
const heightRef = original?.heightfield({ bounds: [-3, 1, -2, 4], segments: [1, 1], height: heights });
meshParity(hill.surface, heightRef);
for (const [x, z, expected] of [[-1, 1, 1], [-2, 2.5, 0.5], [0, -0.5, 3], [-6, 9, 0], [8, -3, 5]]) {
  assert.equal(okay('surface_height', hill, x, z), expected);
  if (heightRef) assert.equal(heightRef.height(x, z), expected);
}
assert('Err' in check('textured_heightfield', { ...bounds, x1: bounds.x0 }, { columns: 1, rows: 1 }, 2, heights));
assert('Err' in check('textured_heightfield', bounds, { columns: 1, rows: 1 }, 2, heights.slice(1)));

const profile = [{ x: -0.5, y: 0 }, { x: 0, y: 0.25 }, { x: 0.5, y: 0 }];
const frame = z => ({ position: vec(0, 0, z), tangent: vec(0, 0, 1), right: none, up: none });
const path = { length: 4, at: d => ({ p: [0, 0, d], tan: [0, 0, 1] }) };
const strip = okay('textured_sweep', profile, [frame(0), frame(2), frame(4)], up, false, 8);
meshParity(strip, original?.sweep({ path, profile: profile.map(p => [p.x, p.y]), segments: 2 }));
assert.deepEqual(strip.positions[4], [0, 0.25, 2]);
const railPath = rail.prepare_rail([vec(0, 0, 0), vec(0, 0, 1), vec(0, 0, 4)]);
assert.deepEqual(okay('rail_surface', railPath, profile, 2, up, false, 8), strip);
const frames = [frame(0), frame(2), { ...frame(3), right: some(vec(-1, 0, 0)), up: some(up) }, frame(4)];
const closed = okay('textured_sweep', profile, frames, up, true, 12);
meshParity(closed, original?.sweep({
  path: { ...path, length: 3 }, segments: 3, closed: true, profile: profile.map(p => [p.x, p.y]),
  frame(d) {
    const at = frames[d];
    return { p: array(at.position), tan: array(at.tangent),
      right: at.right.Some && array(at.right.Some), up: at.up.Some && array(at.up.Some) };
  },
}));
assert.deepEqual(closed.positions.slice(-3), closed.positions.slice(0, 3));
assert.deepEqual(closed.positions[6], [0.5, 0, 3]);
assert.deepEqual(closed.uvs.at(-1), [1, 1]);
assert('Err' in check('textured_sweep', profile, [frame(0), { ...frame(1), tangent: up }], up, false, 4));
const longAxes = [0, 2, 4].map(z => ({
  ...frame(z), tangent: vec(0, 0, 1e300), right: some(vec(1e300, 0, 0)), up: some(vec(0, 1e300, 0)),
}));
assert.deepEqual(okay('textured_sweep', profile, longAxes, up, false, 8), strip);

const tmp = mkdtempSync(join(tmpdir(), 'ink-textured-surface-'));
try {
  const input = join(tmp, 'surface.json');
  writeFileSync(input, JSON.stringify(checks.map(({ pure, args }) => ({ pure, args }))));
  const project = fileURLToPath(new URL('../build/textured_surface-rust/Cargo.toml', import.meta.url));
  const actual = JSON.parse(execFileSync('cargo', ['run', '--quiet', '--release', '--manifest-path', project, '--', input], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  }));
  // Rust serializes packed float32 components using the shortest decimal that round-trips to float32.
  const match = (got, expected, label) => {
    if (typeof expected === 'number' && /\.(positions|uvs)\./.test(label)) {
      assert.equal(Math.fround(got), Math.fround(expected), label);
    } else if (typeof expected === 'number' && !Number.isInteger(expected)) {
      assert(Math.abs(got - expected) < 1e-12, label + ' ' + got + ' ' + expected);
    } else if (expected && typeof expected === 'object') {
      assert.deepEqual(Object.keys(got).sort(), Object.keys(expected).sort(), label);
      for (const key of Object.keys(expected)) match(got[key], expected[key], label + '.' + key);
    } else assert.equal(got, expected, label);
  };
  assert.equal(actual.length, checks.length);
  checks.forEach((test, i) => match(actual[i], test.expected, test.pure));
  console.log(checks.length + ' textured surface cases agree in Rust and JavaScript' + (original ? ' with original mesh fixtures.' : '.'));
} finally {
  rmSync(tmp, { force: true, recursive: true });
}
