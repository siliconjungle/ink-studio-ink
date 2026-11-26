import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [ink, source, output] = process.argv.slice(2);
if (!ink || !source || !output) throw new Error('Usage: build-native-bake.mjs INK SOURCE OUTPUT');
mkdirSync(output, { recursive: true });
const image = join(output, 'bake-input.core.json');
execFileSync(ink, ['emit-core', source, '-o', image]);
const bytes = readFileSync(image);
const { program } = JSON.parse(bytes);
const hash = input => createHash('sha256').update(input).digest('hex');
const moduleHash = hash(bytes);

function containsOwner(type, visited = new Set()) {
  if (typeof type !== 'object' || type === null) return false;
  if ('Buffer' in type || 'Map' in type) return true;
  if ('Named' in type) {
    if (visited.has(type.Named)) return false;
    const fields = program.records[type.Named] ?? [];
    const scope = new Set([...visited, type.Named]);
    return fields.some(([, field]) => containsOwner(field, scope));
  }
  return Object.values(type).some(value =>
    Array.isArray(value) ? value.some(child => containsOwner(child, visited)) : containsOwner(value, visited));
}

// The compiler independently checks
// each lexical site and its carrier before emitting borrowed Rust helpers.
const sites = program.functions.flatMap(fn => fn.params.flatMap(([parameter, type]) => {
  if (typeof type !== 'object' || !['Named', 'List', 'Option', 'Result'].some(carrier => carrier in type) || containsOwner(type)) return [];
  return [hash(JSON.stringify({ capability: 'ink-parameter-read-v1', function: fn.name, parameter }))];
})).sort();
const physical = { schema: 1, semantics: 'ink-physical-plan-v1', input_core_sha256: moduleHash, borrow_reads: sites };
const plan = join(output, 'bake-request.plan.json');
writeFileSync(plan, JSON.stringify({
  schema: 1, semantics: 'ink-compiled-plan-v1', input_core_sha256: moduleHash,
  steps: [{ kind: 'physical', package: physical }],
}));
execFileSync(ink, ['build', image, '--core', '--plan', plan, '--target', 'rust', '-o', output], { stdio: 'inherit' });
