import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { openPixelDocument } from '../web/pixel-document.mjs';

export function referenceCases(originalRoot) {
  const original = createRequire(import.meta.url)(resolve(originalRoot));
  const relay = readFileSync(join(originalRoot, 'examples/pixel-art-tooling/relay.json'), 'utf8');
  const design = {
    format: 'ink-studio/pixel-art', version: 2, width: 5, height: 3, pixelAspect: [2, 1],
    palette: { mud: { color: '#a713Ff', label: '泥', locked: true }, clear: '#acdefa' },
    layers: [{ id: 'group', kind: 'group' }, { id: 'ink', parent: 'group', opacity: 0.75, offset: [-1, 0] },
      { id: 'rim', parent: 'group', clip: 'ink' }],
    frames: [{ id: 'first', label: '🖌️', durationMs: 110, cels: {
      rim: { id: 'rim-root', marks: [] }, ink: { marks: [{ swatch: 'mud', at: [1, 1] }], opacity: 128 },
    } }, { id: 'second', durationMs: 130, cels: { ink: { hold: 'first/ink', offset: [1, 0] } } },
    { id: 'third', durationMs: 70, cels: { ink: { hold: 'second/ink' } } }],
    legacyMetadata: { '10': [1e+22, 0.000001, 1e-7], '2': { ordered: true }, source: 'Å\n\u2028字' },
  };
  const legacy = {
    prologue: { '8': 'screen', '3': 'fill', alpha: [1e+22, 1e-7] },
    format: design.format, version: 1, width: 2, height: 2,
    palette: { ink: '#123456', rim: '#a9b8c7' },
    layers: [
      { protect: true, id: 'paint', marks: [{ swatch: 'ink', at: [1, 0] }], slots: [null, 'ink', null, null] },
      { id: 'foot', clip: 'paint', marks: [] },
    ],
    tail: '낙서',
  };
  const raw = JSON.stringify(design).replace('"version":2', '"version":2.0').replace('"width":5', '"width":9,"width":5e0')
    .replace('"opacity":0.75', '"opacity":75e-2').replace('"offset":[-1,0]', '"offset":[-1,-0]')
    .replace('"opacity":128', '"opacity":-0');
  const change = (source, edit) => {
    const copy = structuredClone(source);
    edit(copy);
    return JSON.stringify(copy);
  };
  const sources = [
    relay, JSON.stringify(legacy), JSON.stringify(design), raw,
    change(design, d => { d.layers[1].opacity = 1e-7; }),
    change(design, d => { d.layers[1].offset = [-1_000_000, 1_000_000]; }),
    change(design, d => { d.frames[0].durationMs = 9_007_199_254_740_000; }),
    change(design, d => { d.frames[1].cels.ink.hold = 'third/ink'; d.frames[2].cels.ink = { marks: [] }; }),
    change(legacy, d => { delete d.prologue; delete d.tail; }),
    'null',
    change(design, d => { d.version = 3; }),
    change(design, d => { d.width = 513; }),
    change(design, d => { d.width = 512; d.height = 512; d.layers = Array(16).fill({ id: 'ink' }); }),
    change(design, d => { d.palette.mud.color = '#a713Fg'; }),
    change(design, d => { d.palette.mud.label = '\u00a0\u3000'; }),
    change(design, d => { d.extra = []; }),
    change(design, d => { d.pixelAspect = [1, 0]; }),
    change(design, d => { d.legacyMetadata = null; }),
    change(design, d => { d.layers[1].parent = 'rim'; }),
    change(design, d => { d.layers[2].clip = 'group'; }),
    change(design, d => { d.layers[1].opacity = 1.01; }),
    change(design, d => { d.layers[1].offset = [0, 1_000_001]; }),
    change(design, d => { d.frames = []; }),
    change(design, d => { d.frames[2].id = 'second'; }),
    change(design, d => { d.frames[0].durationMs = 9_007_199_254_740_991; }),
    change(design, d => { d.frames[0].cels.group = { marks: [] }; }),
    change(design, d => { d.frames[0].cels.ink.marks = null; }),
    change(design, d => { d.frames[1].cels.ink.id = 'first/ink'; }),
    change(design, d => { d.frames[1].cels.ink.hold = 'missing/ink'; }),
    change(design, d => { d.frames[1].cels.ink.hold = 'third/ink'; }),
    change(legacy, d => { d.layers[0].kind = 'mask'; }),
  ];
  return sources.map(source => {
    const input = JSON.parse(source);
    try {
      const editor = original.createPixelEditor(source);
      const document = editor.snapshot();
      const legacyRevision = input?.version === 1 ?
        createHash('sha256').update(JSON.stringify(input)).digest('hex') : null;
      return { source, expected: { document, revision: editor.describe().revision, legacyRevision } };
    } catch (error) {
      return { source, error: error.message };
    }
  });
}

async function check(originalRoot, native) {
  const cases = referenceCases(originalRoot);
  const temp = mkdtempSync(join(tmpdir(), 'ink-pixel-load-'));
  try {
    for (const [i, row] of cases.entries()) {
      const path = join(temp, 'source.json');
      writeFileSync(path, row.source);
      const result = spawnSync(native, [path], { encoding: 'utf8' });
      if (result.error) throw result.error;
      if (row.error) {
        await assert.rejects(openPixelDocument(row.source), { message: row.error }, 'JavaScript case ' + i);
        assert.equal(result.status, 1, 'Native case ' + i);
        assert.equal(result.stderr.trimEnd(), row.error, 'Native case ' + i);
      } else {
        assert.deepEqual(await openPixelDocument(row.source), row.expected, 'JavaScript case ' + i);
        assert.equal(result.status, 0, result.stderr);
        assert.deepEqual(JSON.parse(result.stdout), JSON.parse(JSON.stringify(row.expected)), 'Native case ' + i);
      }
    }
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
  console.log('JavaScript and native Rust matched ' + cases.length + ' original pixel document cases.');
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) throw new Error('Usage: node tests/pixel-document.mjs ORIGINAL_STUDIO NATIVE_BINARY');
  await check(process.argv[2], process.argv[3]);
}
