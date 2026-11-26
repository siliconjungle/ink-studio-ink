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

export async function createGaussianRenderer(device, format, { width, height, splats }) {
  const halfViewport = [width / 2, height / 2];
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
      inputs: { splats },
      steps: [{ id: 'ellipses', call: 'project', args: [{ input: 'splats' }, halfViewport] }],
      outputs: ['ellipses'],
    }, { backend: 'gpu-required' });
    viewport = device.createBuffer({ size: 8, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    device.queue.writeBuffer(viewport, 0, new Float32Array(halfViewport));

    let bindings;
    let boundBuffer;
    let count = splats.length;
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
      async update(rows) {
        await session.write('splats', rows);
        count = rows.length;
        return project();
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
