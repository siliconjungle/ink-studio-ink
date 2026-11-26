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
