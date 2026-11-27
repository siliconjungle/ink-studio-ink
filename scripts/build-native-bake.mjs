import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

const [ink, source, output] = process.argv.slice(2);
if (!ink || !source || !output) throw new Error('Usage: build-native-bake.mjs INK SOURCE OUTPUT');
mkdirSync(output, { recursive: true });
const plan = join(output, 'bake-request.plan.json');
execFileSync(ink, ['emit-parameter-loans', source, '-o', plan], { stdio: 'inherit' });
execFileSync(ink, ['build', source, '--plan', plan, '--target', 'rust', '-o', output], { stdio: 'inherit' });
