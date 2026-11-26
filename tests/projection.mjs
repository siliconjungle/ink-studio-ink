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

const camera = {
  eye: [0, 0, 0], right: [1, 0, 0], up: [0, 1, 0], back: [0, 0, 1],
  half_viewport: viewport, focal: 2, near_clip: 0.1, far_clip: 9, variance: 0, perspective: false,
};
const world = {
  position: [1, 0, -4], covariance0: [4, 0, 0], covariance1: [1, 0, 0],
  reach: 3, rgb: 255, alpha: 0.5,
};
const worldRows = [world, { ...world, position: [0, 0, -10] }];
const orthographic = call('project_world', [worldRows, camera]);
assert.deepEqual(orthographic[0], {
  center: [2, 0], axis_x: [12, 0], axis_y: [-0, 6], rgb: 255, alpha: 0.5,
});
assert.equal(orthographic[1].alpha, 0);
const perspective = { ...camera, focal: 8, perspective: true };
assert.deepEqual(call('project_world', [worldRows, perspective]), orthographic);
const deep = { ...world, covariance1: [1, 0, 1] };
assert.ok(call('project_world', [[deep], perspective])[0].axis_x[0] > 12);
const colors = [255, 65280, 16711680, 65535];
const unordered = [4, 7, 4, 6].map((depth, i) => ({ ...world, position: [0, 0, -depth], rgb: colors[i] }));
const ordered = call('project_sorted_world', [unordered, camera]);
assert.deepEqual(ordered.map((splat) => splat.rgb), [65280, 65535, 255, 16711680]);
const actor = { first: 1, origin: [1, -1, -7], forward: [0, 1] };
const scenery = { ...world, position: [0, 0, -5], rgb: 65280 };
const local = { ...world, position: [1, 2, 1], covariance0: [4, 0.5, 0.25], covariance1: [2, -0.75, 1] };
const rotated = { ...local, position: [0, 1, -6], covariance0: [1, 0.75, -0.25], covariance1: [2, 0.5, 4] };
const placed = call('project_sorted_world', [[scenery, rotated], camera]);
const actorArgs = [[scenery, local], camera, actor];
assert.deepEqual(call('project_sorted_actor', actorArgs), placed);
assert.deepEqual(placed.map(splat => splat.rgb), [local.rgb, scenery.rgb]);
const bindSplat = { center: [1, 0, -4], covariance0: [1, 0, 0], covariance1: [4, 0.25, 1],
  normal: [1, 0, 0], joints: [0, 1], weight: 0.5, shade: 0,
  palette: [255, 65280, 16711680, 16711680], tones: 3, eye: true, alpha: 0.5 };
const firstBone = { axis_x: [1, 0, 0], axis_y: [0, 1, 0], axis_z: [0, 0, 1], offset: [0, 0, 0] };
const secondBone = { ...firstBone, axis_x: [3, 0, 0], offset: [2, 0, 0] };
const skinArgs = [[bindSplat], [firstBone, secondBone], { sun: [1, 0, 0], ambient: 0, diffuse: 1, blink: 0.5 }];
const skinned = [{ position: [3, 0, -4], covariance0: [4, 0, 0], covariance1: [1, 0.125, 1], reach: 3,
  rgb: 16711680, alpha: 0.5 }];
assert.deepEqual(call('skin_world', skinArgs), skinned);
const sceneArgs = [[{ ...world, alpha: 0 }, scenery, world], skinned, camera];
const visible = call('project_sorted_world', [sceneArgs[0].concat(skinned), camera]).filter(row => row.alpha > 0);
assert.deepEqual(call('project_sorted_scene', sceneArgs), visible);
assert.deepEqual(visible.map(row => row.rgb), [scenery.rgb, world.rgb, skinned[0].rgb]);
assert.deepEqual(call('project_sorted_scene', [[], [], camera]), []);
const hiddenScene = [[{ ...world, alpha: 0 }], [{ ...world, position: [100, 0, -4] }], camera];
assert.deepEqual(call('project_sorted_scene', hiddenScene), []);
const lamp = { enabled: true, direction: [1, 0, 0], actor_center: [0, 0, -4], actor_rows: 2,
  ambient: [1, 1, 1], key: [0.25, 0.25, 0.25] };
const disc = { ...world, covariance0: [1, 0, 0], covariance1: [1, 0, 1], alpha: 1 };
const actorDabs = [disc, { ...disc, position: [-1, 0, -4] }];
const litArgs = [[{ ...disc, position: [0, 0, -5], alpha: 0.5 }], actorDabs, camera, lamp];
const lit = call('project_lit_contour_scene', litArgs);
const fromLeft = [...litArgs.slice(0, 3), { ...lamp, direction: [-1, 0, 0] }];
const left = call('project_lit_contour_scene', fromLeft);
assert.deepEqual(lit.map(row => row.rgb >>> 24), [0, 255, 1]);
assert.deepEqual(left.map(row => row.rgb >>> 24), [0, 1, 255]);
const unlit = [...litArgs.slice(0, 3), { ...lamp, enabled: false }];
assert.deepEqual(lit.map(row => ({ ...row, rgb: row.rgb & 0xffffff })), call('project_contour_scene', litArgs.slice(0, 3)));
assert.deepEqual(call('project_lit_contour_scene', unlit), call('project_contour_scene', litArgs.slice(0, 3)));
const sourceRow = [1, 2, 3, 0.5, 4, 5, 6, 0xf08010, 7, 8, 9, 128, 11, 12, 13, 14];
const imported = [{ position: [1, 2, 3], covariance0: [4, 5, 6], covariance1: [7, 8, 9],
  reach: 3, rgb: 0xf08010, alpha: 0.5 }];
assert.deepEqual(call('import_builder_splats', [new Float32Array(sourceRow)]), imported);

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
  const tests = [
    { pure: 'project', args, expected: result },
    { pure: 'project_world', args: [worldRows, camera], expected: orthographic },
    { pure: 'project_world', args: [worldRows, perspective], expected: orthographic },
    { pure: 'project_sorted_world', args: [unordered, camera], expected: ordered },
    { pure: 'project_sorted_actor', args: actorArgs, expected: placed },
    { pure: 'skin_world', args: skinArgs, expected: skinned },
    { pure: 'project_sorted_scene', args: sceneArgs, expected: visible },
    { pure: 'project_sorted_scene', args: hiddenScene, expected: [] },
    { pure: 'project_lit_contour_scene', args: litArgs, expected: lit },
    { pure: 'project_lit_contour_scene', args: fromLeft, expected: left },
    { pure: 'project_lit_contour_scene', args: unlit, expected: call('project_contour_scene', litArgs.slice(0, 3)) },
    { pure: 'import_builder_splats', args: [sourceRow], expected: imported, cpuOnly: true },
  ];
  writeFileSync(requestsPath, JSON.stringify(tests.map(({ pure, args }) => ({ pure, args }))));
  const native = fileURLToPath(new URL('../build/rust/Cargo.toml', import.meta.url));
  const rust = run('cargo', ['run', '--quiet', '--manifest-path', native, '--', requestsPath]);
  assert.equal(rust.length, tests.length);
  for (const [i, test] of tests.entries()) {
    assert.deepEqual(bitsToValue(rust[i]), test.expected);
    if (process.env.INK_WGPU_PROGRAM && !test.cpuOnly) {
      writeFileSync(argsPath, JSON.stringify(test.args));
      const gpu = run(process.env.INK_WGPU_PROGRAM, [test.pure, argsPath, '--backend', 'gpu-required']);
      assert.equal(gpu.backend, 'gpu');
      assert.deepEqual(bitsToValue(gpu.value), test.expected);
    }
  }
} finally {
  rmSync(directory, { recursive: true, force: true });
}
console.log('Gaussian projection cases matched.');
