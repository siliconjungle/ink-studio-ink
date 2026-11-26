import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

const [ink, source, output] = process.argv.slice(2);
if (!ink || !source || !output) throw new Error('Usage: build-native-bake.mjs INK SOURCE OUTPUT');
mkdirSync(output, { recursive: true });
const image = join(output, 'bake-input.core.json');
const plan = join(output, 'bake-request.plan.json');
execFileSync(ink, ['emit-core', source, '-o', image], { stdio: 'inherit' });
execFileSync(ink, ['emit-parameter-loans', image, '--core', '-o', plan], { stdio: 'inherit' });
execFileSync(ink, ['build', image, '--core', '--plan', plan, '--target', 'rust', '-o', output], { stdio: 'inherit' });
