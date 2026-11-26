import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { call } from '../build/frost.mjs';

const results = [];
function check(pure, args, expected) {
  assert.deepEqual(call(pure, args), expected);
  results.push({ pure, args, expected });
}
let current = 0, published = -1;
for (const winter of [1, 0]) {
  for (let frame = 0; frame < 840; frame++) {
    const dt = 1 / 60;
    const next = Math.max(0, Math.min(1, current + dt * (winter > 0.5 ? 1 / 12 : -1 / 8)));
    const dirty = Math.abs(next - published) > 0.03 || ((next === 0 || next === 1) && next !== published);
    const snapshot = { current: next, published: dirty ? next : published, dirty };
    check('step_season', [current, published, dt, winter], snapshot);
    current = snapshot.current;
    published = snapshot.published;
  }
}
for (const timer of [3, 0.08, 0, -0.08, -8].map(Math.fround)) {
  for (const dt of [0, 0.2, 9]) {
    const expected = timer > 0 ? Math.max(0, timer - dt) : Math.min(0, timer + dt);
    check('step_timer', [timer, dt], Math.fround(expected));
  }
  for (const ice of [0.25, 0.6, 1]) {
    check('frozen_at', [timer, ice], (timer > 0 ? 1 : timer < 0 ? 0 : ice) > 0.6);
  }
}
const colors = new Uint32Array([0x11223344, 0x11223344, 0x11223344]);
const timers = new Float32Array([3, 0, -8]);
const expected = [0x11ff3344, 0x11803344, 0x11003344];
check('pack_ice', [colors, timers, 128], expected);

const directory = mkdtempSync(join(tmpdir(), 'ink-frost-'));
try {
  const requests = join(directory, 'requests.json');
  const args = value => value.map(x => ArrayBuffer.isView(x) ? Array.from(x) : x);
  writeFileSync(requests, JSON.stringify(results.map(row => ({ pure: row.pure, args: args(row.args) }))));
  const project = fileURLToPath(new URL('../build/frost-rust/Cargo.toml', import.meta.url));
  const rust = execFileSync('cargo', ['run', '--quiet', '--manifest-path', project, '--', requests], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 4 * 1024 * 1024,
  });
  assert.deepEqual(JSON.parse(rust), results.map(({ expected }) => expected));
} finally {
  rmSync(directory, { recursive: true, force: true });
}
console.log(`Frost and packed ice matched in ${results.length} JavaScript and native Rust calls.`);
