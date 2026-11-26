import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const build = fileURLToPath(new URL('../scripts/build-native-bake.mjs', import.meta.url));
const directory = mkdtempSync(join(tmpdir(), 'ink-native-bake-'));
try {
  const source = join(directory, 'recursive.ink');
  const output = join(directory, 'native');
  writeFileSync(source, `module RecursiveBake;
pub fn inspect(data: Option<u32>) -> u32 {
    return data.fold(fn(value) => value, fn(unit) => 0);
}
pub fn visit(n: u32, data: Option<u32>, status: Result<u32, u32>) -> u32 {
    if n > 0 { return visit(n - 1, data, status); }
    return inspect(data) + status.fold(fn(value) => value, fn(error) => error);
}
`);
  execFileSync(process.execPath, [build, process.env.INK || 'ink', source, output], { stdio: 'inherit' });
  const plan = JSON.parse(readFileSync(join(output, 'bake-request.plan.json'), 'utf8'));
  assert.equal(plan.steps[0].package.borrow_reads.length, 1);

  const input = join(directory, 'requests.json');
  writeFileSync(input, JSON.stringify([
    { pure: 'visit', args: [3, { Some: 7 }, { Ok: 4 }] },
    { pure: 'visit', args: [2, { None: null }, { Err: 5 }] },
  ]));
  const result = execFileSync('cargo', [
    'run', '--quiet', '--manifest-path', join(output, 'Cargo.toml'), '--', input,
  ], { encoding: 'utf8' });
  assert.deepEqual(JSON.parse(result), [11, 5]);
} finally {
  rmSync(directory, { recursive: true, force: true });
}
