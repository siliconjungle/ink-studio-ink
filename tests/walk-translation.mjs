import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { call } from '../build/walker.mjs';

const point = (x, y, z) => ({ x, y, z });
const walk = {
  time: 1.25, phase: 0.75, move_mix: 1, run_mix: 0.5, air_mix: 0.25, yaw: 1.5,
  land_age: 0.5, land_strength: 0.125,
  springs: { lean: 0.5, lean_velocity: 1, nod: 0.25, nod_velocity: 0.75 },
  pose: { stretch: 1, flare: 1, hip_offset: -0.125, bend: 0, twist: 0, feet: [{ x: 0.25, y: 0.125, angle: -0.25 }] },
  hem: point(-3, 0.75, -181),
  hem_velocity: point(0.25, 0, 2.5),
  tails: [{ current: [point(-3, 1, -181), point(-2.75, 0.75, -181.25)],
    previous: [point(-3, 1, -180.75), point(-2.75, 0.75, -181)] }],
};
const offset = point(3, 11.25, 187);
const expected = {
  ...walk,
  hem: point(0, 12, 6),
  tails: [{ current: [point(0, 12.25, 6), point(0.25, 12, 5.75)],
    previous: [point(0, 12.25, 6.25), point(0.25, 12, 6)] }],
};
const reverse = point(-offset.x, -offset.y, -offset.z);
const requests = [{ pure: 'translate_walk', args: [walk, offset] }, { pure: 'translate_walk', args: [expected, reverse] }];
for (const [index, request] of requests.entries()) assert.deepEqual(call(request.pure, request.args), [expected, walk][index]);

const directory = mkdtempSync(join(tmpdir(), 'ink-walk-translation-'));
try {
  const input = join(directory, 'requests.json');
  writeFileSync(input, JSON.stringify(requests));
  const manifest = fileURLToPath(new URL('../build/walker-rust/Cargo.toml', import.meta.url));
  const native = execFileSync('cargo', ['run', '--quiet', '--manifest-path', manifest, '--', input], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  });
  assert.deepEqual(JSON.parse(native), [expected, walk]);
} finally {
  rmSync(directory, { recursive: true, force: true });
}
console.log('Walk translation preserved gait, momentum, and cloth history on JavaScript and Rust.');
