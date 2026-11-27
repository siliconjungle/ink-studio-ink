import { createPixelCommandEditor, openPixelPng, rasterizePixelFrame } from './pixel-document.mjs';

const byId = name => document.getElementById(name);
const canvas = byId('artwork');
const overlay = byId('selection-outline');
const context = canvas.getContext('2d');
const outline = overlay.getContext('2d');
const frame = byId('frame');
const layer = byId('layer');
const view = byId('view');
const saved = byId('saved-selection');
const kind = byId('cleanup-kind');
const mode = byId('cleanup-mode');
const swatch = byId('cleanup-swatch');
const budget = byId('cleanup-budget');
const command = (action, fields) => ({ format: 'ink-studio/pixel-command', version: 1, action, ...fields });

let editor;
let art;
let base;
let repair;
let drag;
let selection;
let cursor = [0, 0];
let history = { undo: [], redo: [] };
let filename = 'staircase';
let busy = false;
let serial = 0;

function status(message) { byId('status').textContent = message; }
function controls() {
  for (const control of [frame, layer, view, saved, byId('cleanup-settings')]) control.disabled = !editor || busy;
  for (const name of ['export', 'select-all', 'clear-selection']) byId(name).disabled = !editor || busy;
  byId('open').disabled = busy;
  byId('undo').disabled = busy || !history.undo.length;
  byId('redo').disabled = busy || !history.redo.length;
  byId('cleanup-preview').disabled = !selectionSize() || busy;
  byId('cleanup-apply').disabled = !repair?.target.pixelCount || busy;
  byId('cleanup-cancel').disabled = !repair || busy;
  byId('cleanup-mode-label').hidden = kind.value !== 'cluster';
  byId('cleanup-swatch-label').hidden = kind.value !== 'fragment';
  byId('selection-info').value = selectionSize() ? selectionSize() + ' selected' : '';
}

async function perform(task) {
  if (busy) return;
  busy = true;
  controls();
  try { await task(); }
  catch (error) { status(error.message); }
  finally { busy = false; controls(); }
}

function options(control, rows, previous = '') {
  control.replaceChildren(...rows.map(([id, label]) => new Option(label, id)));
  if (rows.some(([id]) => id === previous)) control.value = previous;
}
function savedOptions(previous = '') {
  const names = (art.selections ?? []).filter(row => !row.frame || row.frame === frame.value);
  options(saved, [['', 'Canvas selection'], ...names.map(row => [row.id, row.id])], previous);
}

function pixelBytes(raster) {
  const image = new ImageData(raster.width, raster.height);
  for (const [index, packed] of raster.rgba.entries()) {
    const offset = index * 4;
    image.data[offset] = packed >>> 24;
    image.data[offset + 1] = packed >>> 16 & 255;
    image.data[offset + 2] = packed >>> 8 & 255;
    image.data[offset + 3] = packed & 255;
  }
  return image;
}
function hexBytes(color, alpha) {
  if (!color) return [0, 0, 0, 0];
  const rgb = Number.parseInt(color.slice(1), 16);
  return [rgb >>> 16, rgb >>> 8 & 255, rgb & 255, alpha ?? 255];
}
function drawArtwork() {
  if (!base) return;
  if (!repair) { context.putImageData(base, 0, 0); return; }
  const work = new ImageData(new Uint8ClampedArray(base.data), base.width, base.height);
  const rows = view.value === 'layer' ? repair.target.changes : repair.composite;
  for (const { at: [x, y], after } of rows) {
    const rgba = view.value === 'layer' ? after?.rgba : hexBytes(after?.color, after?.alpha);
    work.data.set(rgba ?? [0, 0, 0, 0], (y * art.width + x) * 4);
  }
  context.putImageData(work, 0, 0);
}
function loadRaster() {
  const raster = rasterizePixelFrame(art, { frame: frame.value, layer: view.value === 'layer' ? layer.value : '' });
  base = pixelBytes(raster);
  canvas.width = raster.width;
  canvas.height = raster.height;
  const ratio = art.width * art.pixelAspect[0] / (art.height * art.pixelAspect[1]);
  byId('grid').style.setProperty('--art-ratio', ratio);
  byId('grid').style.setProperty('--art-width', `min(620px, ${ratio * 55}vh)`);
  byId('size').value = `${art.width} × ${art.height}`;
  drawArtwork();
  drawSelection();
}
function selectionSize() {
  if (!selection) return 0;
  const { bounds, points } = selection;
  return bounds ? (bounds.right - bounds.left + 1) * (bounds.bottom - bounds.top + 1) : points.length;
}
function selectedPoints() {
  if (!selection) return [];
  const { bounds, points } = selection;
  return bounds ? rectangle([bounds.left, bounds.top], [bounds.right, bounds.bottom]) : points;
}
function drawEdges(points, occupied, stepX, stepY) {
  outline.beginPath();
  const edge = (x1, y1, x2, y2) => {
    outline.moveTo(x1 * stepX, y1 * stepY);
    outline.lineTo(x2 * stepX, y2 * stepY);
  };
  for (const [x, y] of points) {
    const p = y * art.width + x;
    if (!x || !occupied[p - 1]) edge(x, y, x, y + 1);
    if (x + 1 === art.width || !occupied[p + 1]) edge(x + 1, y, x + 1, y + 1);
    if (!occupied[p - art.width]) edge(x, y, x + 1, y);
    if (!occupied[p + art.width]) edge(x, y + 1, x + 1, y + 1);
  }
  outline.stroke();
}
function drawSelection() {
  if (!art) return;
  const width = overlay.clientWidth, height = overlay.clientHeight;
  if (!width || !height) return;
  const w = Math.round(width * devicePixelRatio), h = Math.round(height * devicePixelRatio);
  if (overlay.width !== w || overlay.height !== h) { overlay.width = w; overlay.height = h; }
  outline.setTransform(w / width, 0, 0, h / height, 0, 0);
  outline.clearRect(0, 0, width, height);
  const x = width / art.width, y = height / art.height;
  outline.strokeStyle = '#90dee5';
  const bounds = selection?.bounds;
  if (bounds) outline.strokeRect(bounds.left * x, bounds.top * y, (bounds.right - bounds.left + 1) * x, (bounds.bottom - bounds.top + 1) * y);
  else if (selection) drawEdges(selection.points, selection.occupied, x, y);
  if (document.activeElement === overlay) {
    outline.strokeStyle = '#ffda86';
    outline.strokeRect(cursor[0] * x + 1, cursor[1] * y + 1, Math.max(0, x - 2), Math.max(0, y - 2));
  }
  byId('coordinate').value = cursor.join(', ');
}

function pixelMask(points) {
  const occupied = new Uint8Array(art.width * art.height);
  for (const [x, y] of points) occupied[y * art.width + x] = 1;
  return { points, occupied };
}

async function install(source, name) {
  const next = await createPixelCommandEditor(source);
  const snapshot = await next.snapshot();
  editor = next;
  art = snapshot;
  filename = name;
  selection = undefined;
  cursor = [0, 0];
  history = await editor.history();
  options(frame, art.frames.map(row => [row.id, row.label ?? row.id]));
  options(layer, art.layers.filter(row => row.kind !== 'group').map(row => [row.id, row.label ?? row.id]));
  options(swatch, [['', 'Auto'], ...Object.keys(art.palette).map(id => [id, id])]);
  savedOptions();
  clearPreview();
  loadRaster();
  status('Opened ' + name);
}
function label(pixel) {
  if (!pixel.rgba) return pixel.state;
  const hex = pixel.rgba.slice(0, 3).map(byte => byte.toString(16).padStart(2, '0')).join('');
  return `${pixel.swatch} · #${hex} · α ${pixel.rgba[3]}`;
}
function showPreview() {
  const target = repair?.target;
  byId('cleanup-info').value = target ? `${target.pixelCount} of ${target.maxChanges} pixels` : '';
  const diff = byId('cleanup-diff');
  diff.hidden = !target;
  const rows = (target?.changes ?? []).map(change => {
    const row = document.createElement('tr');
    for (const value of [change.at.join(', '), label(change.before), label(change.after)]) row.insertCell().textContent = value;
    return row;
  });
  diff.querySelector('tbody').replaceChildren(...rows);
  drawArtwork();
  controls();
}
function clearPreview() {
  repair = undefined;
  showPreview();
}
async function previewCleanup() {
  clearPreview();
  if (!budget.reportValidity()) return;
  if (selectionSize() > 2048) { status('Select at most 2048 pixels for one cleanup'); return; }
  const operation = {
    tool: 'cleanup', kind: kind.value, layer: layer.value, maxChanges: budget.valueAsNumber,
    ...(saved.value ? { selection: saved.value } : { pixels: selectedPoints() }),
    ...(kind.value === 'cluster' ? { mode: mode.value } : {}),
    ...(kind.value === 'fragment' && swatch.value ? { swatch: swatch.value } : {}),
  };
  const patch = { id: 'cleanup-' + ++serial, frame: frame.value, revision: await editor.revision(), operation };
  const action = command('draw', { patch });
  const proposal = await editor.execute(command('preview', { edit: action, options: { exact: true, limit: 0 } }));
  if (!proposal.valid) {
    const issue = proposal.conflicts[0];
    status(issue.message + (Array.isArray(issue.at) ? ' (' + issue.at.join(', ') + ')' : ''));
    return;
  }
  repair = { action, target: proposal.targets[0], composite: proposal.diff.cells.filter(row => row.frame === frame.value && !row.layer) };
  status(repair.target.pixelCount ? '' : 'No pixels to change');
  showPreview();
}
async function refresh(message) {
  art = await editor.snapshot();
  history = await editor.history();
  clearPreview();
  loadRaster();
  status(message);
}

function gridPoint(event) {
  const box = overlay.getBoundingClientRect();
  const x = Math.floor((event.clientX - box.left) * art.width / box.width);
  const y = Math.floor((event.clientY - box.top) * art.height / box.height);
  return [Math.max(0, Math.min(art.width - 1, x)), Math.max(0, Math.min(art.height - 1, y))];
}
function rectangle(a, b) {
  const left = Math.min(a[0], b[0]), top = Math.min(a[1], b[1]);
  const width = Math.abs(a[0] - b[0]) + 1, height = Math.abs(a[1] - b[1]) + 1;
  return Array.from({ length: width * height }, (_, i) => [left + i % width, top + Math.floor(i / width)]);
}
function selectCanvas(a, b = a) {
  if (repair) clearPreview();
  saved.value = '';
  selection = a ? { bounds: {
    left: Math.min(a[0], b[0]), top: Math.min(a[1], b[1]), right: Math.max(a[0], b[0]), bottom: Math.max(a[1], b[1]),
  } } : undefined;
  drawSelection();
  controls();
}
overlay.addEventListener('pointerdown', event => {
  if (!editor || busy || event.button !== 0) return;
  drag = { pointer: event.pointerId, at: gridPoint(event), prior: selection, saved: saved.value };
  cursor = drag.at;
  overlay.focus();
  overlay.setPointerCapture(event.pointerId);
  selectCanvas(cursor);
});
overlay.addEventListener('pointermove', event => {
  if (!editor) return;
  const next = gridPoint(event);
  if (next[0] === cursor[0] && next[1] === cursor[1]) return;
  cursor = next;
  if (drag?.pointer === event.pointerId) selectCanvas(drag.at, cursor);
  else drawSelection();
});
overlay.addEventListener('pointerup', event => {
  if (drag?.pointer !== event.pointerId) return;
  cursor = gridPoint(event);
  selectCanvas(drag.at, cursor);
  drag = undefined;
});
overlay.addEventListener('pointercancel', event => {
  if (drag?.pointer !== event.pointerId) return;
  saved.value = drag.saved;
  selection = drag.prior;
  drag = undefined;
  drawSelection();
  controls();
});
new ResizeObserver(drawSelection).observe(overlay);
overlay.addEventListener('focus', drawSelection);
overlay.addEventListener('blur', drawSelection);
overlay.addEventListener('keydown', event => {
  if (!editor || busy) return;
  const steps = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
  if (event.key === ' ') {
    event.preventDefault();
    selectCanvas(cursor);
  } else if (steps[event.key]) {
    event.preventDefault();
    cursor = cursor.map((n, i) => Math.max(0, Math.min([art.width, art.height][i] - 1, n + steps[event.key][i])));
    drawSelection();
  }
});

byId('open').addEventListener('click', () => byId('artwork-file').click());
byId('artwork-file').addEventListener('change', event => perform(async () => {
  const file = event.target.files[0];
  event.target.value = '';
  if (!file) return;
  const input = /\.png$/i.test(file.name) ? (await openPixelPng(new Uint8Array(await file.arrayBuffer()))).document : await file.text();
  await install(input, file.name);
}));
byId('export').addEventListener('click', () => perform(async () => {
  const json = JSON.stringify(await editor.snapshot(), null, 2) + '\n';
  const url = URL.createObjectURL(new Blob([json], { type: 'application/json' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename.replace(/\.(json|png)$/i, '') + '.json';
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}));
frame.addEventListener('change', () => {
  savedOptions();
  selectCanvas();
  loadRaster();
});
layer.addEventListener('change', () => { clearPreview(); loadRaster(); });
view.addEventListener('change', loadRaster);
saved.addEventListener('change', () => perform(async () => {
  clearPreview();
  selection = saved.value ? pixelMask((await editor.select({ type: 'recall', id: saved.value }, { frame: frame.value })).pixels) : undefined;
  drawSelection();
}));
byId('select-all').addEventListener('click', () => selectCanvas([0, 0], [art.width - 1, art.height - 1]));
byId('clear-selection').addEventListener('click', () => selectCanvas());
byId('cleanup-preview').addEventListener('click', () => perform(previewCleanup));
byId('cleanup-settings').addEventListener('change', () => {
  controls();
  if (repair) perform(previewCleanup);
});
byId('cleanup-cancel').addEventListener('click', () => { clearPreview(); status(''); });
byId('cleanup-apply').addEventListener('click', () => perform(async () => {
  await editor.execute(repair.action);
  await refresh('Applied cleanup');
}));
byId('undo').addEventListener('click', () => perform(async () => { await editor.undo(); await refresh('Undid cleanup'); }));
byId('redo').addEventListener('click', () => perform(async () => { await editor.redo(); await refresh('Redid cleanup'); }));

const sample = {
  format: 'ink-studio/pixel-art', version: 2, width: 16, height: 11, pixelAspect: [1, 1],
  palette: { amber: '#dfb574', slate: '#6d9ba1', clay: '#ba604d' }, layers: [{ id: 'ink', label: 'Ink' }],
  frames: [{ id: 'drawing', label: 'Drawing', durationMs: 100, cels: { ink: { marks: [
    ...[[3, 3], [4, 4], [5, 4], [6, 4], [7, 4], [8, 4], [9, 5]].map(at => ({ at, swatch: 'amber' })),
    { swatch: 'slate', runs: [[7, 10, 3], [8, 10, 2]] },
    { swatch: 'clay', at: [9, 7] },
  ] } } }],
  selections: [{
    id: 'staircase', pixels: rectangle([3, 3], [9, 5]),
  }, { id: 'fragment', pixels: [[9, 7]] }],
};
await perform(async () => {
  await install(sample, 'staircase');
  saved.value = 'staircase';
  selection = pixelMask(sample.selections[0].pixels);
  drawSelection();
});
