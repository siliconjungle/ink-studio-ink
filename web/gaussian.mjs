import { loadInk } from '../build/gpu/ink-gpu.mjs';

const shaderURL = new URL('../shaders/gaussian.wgsl', import.meta.url);
const bundleURL = new URL('../build/gpu/', import.meta.url);

function assertEllipseLayout(view) {
  const fields = view.type?.element?.fields;
  const layout = fields?.map(({ name, type }) => type.kind === 'vector'
    ? `${name}:${type.element.kind}x${type.size}`
    : `${name}:${type.kind}`).join(',');
  if (!view.header || view.offset !== 4 || view.type.kind !== 'list' ||
    layout !== 'center:f32x2,axis_x:f32x2,axis_y:f32x2,rgb:u32,alpha:f32') {
    throw new Error('Unexpected Ink ellipse buffer layout');
  }
}

export async function createGaussianRenderer(device, format, { width, height, splats, camera, preordered = false, actor, skin }) {
  const halfViewport = [width / 2, height / 2];
  if (!halfViewport.every((dimension) => Number.isFinite(dimension) && dimension > 0)) {
    throw new Error('Gaussian render target must have positive dimensions');
  }
  const cameraInput = (value) => ({ ...value, half_viewport: halfViewport });
  if ((actor || skin) && (!camera || preordered || (actor && skin))) {
    throw new Error('Choose one actor mode with a depth-sorted world view');
  }
  const projection = camera
    ? { call: preordered ? 'project_world' : 'project_sorted_world',
      input: { camera: cameraInput(camera) }, view: [{ input: 'camera' }] }
    : { call: 'project', input: {}, view: [halfViewport] };
  if (actor) {
    projection.call = 'project_sorted_actor';
    projection.input.actor = actor;
    projection.view.push({ input: 'actor' });
  }
  const steps = [{ id: 'ellipses', call: projection.call, args: [{ input: 'splats' }, ...projection.view] }];
  const hasSkin = Boolean(skin);
  const skinRows = skin?.rest.length ?? 0;
  if (skin) {
    const { rest, bones, light } = skin;
    Object.assign(projection.input, { rest, bones, light });
    steps[0] = { id: 'ellipses', call: 'project_sorted_scene',
      args: [{ input: 'splats' }, { step: 'posed' }, { input: 'camera' }] };
    steps.unshift({ id: 'posed', call: 'skin_world',
      args: [{ input: 'rest' }, { input: 'bones' }, { input: 'light' }] });
  }
  const shaderResponse = await fetch(shaderURL);
  if (!shaderResponse.ok) throw new Error(`Gaussian shader could not load (${shaderResponse.status})`);
  const shader = device.createShaderModule({ code: await shaderResponse.text() });
  const over = { srcFactor: 'one', dstFactor: 'one-minus-src-alpha', operation: 'add' };
  const pipeline = await device.createRenderPipelineAsync({
    layout: 'auto',
    vertex: { module: shader, entryPoint: 'vertex' },
    fragment: {
      module: shader,
      entryPoint: 'fragment',
      targets: [{ format, blend: { color: over, alpha: over } }],
    },
    primitive: { topology: 'triangle-strip' },
  });
  const ink = await loadInk(bundleURL, { device });
  let session;
  let viewport;
  try {
    session = await ink.open({
      inputs: { splats, ...projection.input },
      steps,
      outputs: ['ellipses'],
    }, { backend: 'gpu-required' });
    viewport = device.createBuffer({ size: 8, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    device.queue.writeBuffer(viewport, 0, new Float32Array(halfViewport));

    let bindings;
    let boundBuffer;
    let count = splats.length + skinRows;
    async function project() {
      const { counters } = await session.step(1);
      const view = await session.buffer('ellipses');
      assertEllipseLayout(view);
      if (view.capacity < count) throw new Error('Insufficient ellipse capacity');
      if (boundBuffer !== view.buffer) {
        bindings = device.createBindGroup({
          layout: pipeline.getBindGroupLayout(0),
          entries: [
            { binding: 0, resource: { buffer: view.buffer } },
            { binding: 1, resource: { buffer: viewport } },
          ],
        });
        boundBuffer = view.buffer;
      }
      return counters;
    }
    const initialCounters = await project();
    return {
      initialCounters,
      stageRanges(ranges) {
        return session.writeRanges('splats', ranges);
      },
      project,
      async update(rows) {
        await session.write('splats', rows);
        count = rows.length + skinRows;
        return project();
      },
      async updateCamera(value, placement) {
        if (!camera) throw new Error('Camera updates require world-space splats');
        if (placement && !actor) throw new Error('Actor updates require an actor view');
        await session.write('camera', cameraInput(value));
        if (placement) await session.write('actor', placement);
        return project();
      },
      async updateSkinCamera(value, { bones, light }) {
        if (!hasSkin) throw new Error('Skin updates require a skinned world view');
        const boneWrite = await session.writeChanged('bones', bones);
        const lightWrite = await session.write('light', light);
        const rigUploadBytes = boneWrite.counters.upload_bytes + lightWrite.counters.upload_bytes;
        await session.write('camera', cameraInput(value));
        const counters = await project();
        return { counters, rigUploadBytes };
      },
      draw(encoder, target) {
        const pass = encoder.beginRenderPass({
          colorAttachments: [{ view: target, loadOp: 'clear', storeOp: 'store',
            clearValue: { r: 0, g: 0, b: 0, a: 1 } }],
        });
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bindings);
        pass.draw(4, count);
        pass.end();
      },
      async close() {
        viewport.destroy();
        await ink.close();
      },
    };
  } catch (error) {
    viewport?.destroy();
    await ink.close();
    throw error;
  }
}
