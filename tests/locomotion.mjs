import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { call } from '../build/locomotion.mjs';

const requests = [];
const expected = [];
for (const current of [-12.5, -1, 0, 1, 12.5]) {
  for (const target of [-5.6, 0, 5.6]) {
    for (const [ground, slippery] of [[true, true], [true, false], [false, true]]) {
      const seconds = 1 / 60;
      const air = 26;
      const rate = ground ? slippery
        ? target * current < 0 ? 10 : Math.abs(target) > Math.abs(current) ? 8 : 4.5
        : 42 : air;
      const delta = target - current;
      const velocity = current + Math.sign(delta) * Math.min(Math.abs(delta), rate * seconds);
      const args = [current, target, seconds, ground, slippery, air];
      assert.equal(call('axis_velocity', args), velocity);
      expected.push(velocity);
      requests.push({ pure: 'axis_velocity', args });
    }
  }
}
function testCall(pure, args, want) {
  const result = call(pure, args);
  assert.deepEqual(result, want);
  requests.push({ pure, args });
  expected.push(want);
  return result;
}

const zero = { x: 0, y: 0, z: 0 };
const front = { x: 0, y: 0, z: 1 };
const back = { x: 0, y: 0, z: -1 };
const idle = { normal: zero, contact: 0, last: zero, lock: 0 };
testCall('wall_idle', [], idle);
const contact = testCall('wall_step', [idle, front, back, false, 0, false, 1 / 60], {
  wall: { normal: front, contact: 0.16, last: zero, lock: 0 }, kick: false, slide: true,
});
const kicked = testCall('wall_step', [contact.wall, front, back, false, 0, true, 1 / 60], {
  wall: { normal: front, contact: 0, last: front, lock: 0.16 }, kick: true, slide: false,
});
testCall('wall_step', [kicked.wall, back, front, false, 0, true, 1 / 60], {
  wall: { normal: back, contact: 0.16, last: front, lock: 0.16 - 1 / 60 }, kick: false, slide: true,
});
testCall('wall_step', [kicked.wall, front, back, false, 0, true, 0.2], {
  wall: { normal: front, contact: 0.16, last: front, lock: 0 }, kick: false, slide: true,
});
const opposite = testCall('wall_step', [kicked.wall, back, front, false, 0, true, 0.2], {
  wall: { normal: back, contact: 0, last: back, lock: 0.16 }, kick: true, slide: false,
});
testCall('wall_step', [opposite.wall, zero, zero, true, 0, false, 1 / 60], {
  wall: idle, kick: false, slide: false,
});
testCall('wall_step', [contact.wall, zero, zero, false, 0, false, 0.2], {
  wall: { normal: front, contact: 0, last: zero, lock: 0 }, kick: false, slide: false,
});
testCall('wall_impulse', [back, 8.5], { x: 0, y: 8.5 * 0.97, z: -7.6 });

const directory = mkdtempSync(join(tmpdir(), 'ink-locomotion-'));
try {
  const input = join(directory, 'requests.json');
  writeFileSync(input, JSON.stringify(requests));
  const manifest = fileURLToPath(new URL('../build/locomotion-rust/Cargo.toml', import.meta.url));
  const native = execFileSync('cargo', ['run', '--quiet', '--manifest-path', manifest, '--', input], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  });
  assert.deepEqual(JSON.parse(native), expected);
} finally {
  rmSync(directory, { recursive: true, force: true });
}
console.log(`Matched ${requests.length} locomotion cases on JavaScript and Rust`);
