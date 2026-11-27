import { loadInk } from '../build/gpu/ink-gpu.mjs';
import { createContourRaster } from './gaussian-contours.mjs';

const shaderURL = new URL('../shaders/gaussian.wgsl', import.meta.url);
const bundleURL = new URL('../build/gpu/', import.meta.url);
const contourLightOff = { enabled: false, direction: [0, 1, 0], actor_center: [0, 0, 0], actor_rows: 0,
  ambient: [1, 1, 1], key: [0, 0, 0] };
const contourRevealOff = { center: [0, 0], radius: 0, edge_width: 0, floor_height: 0 };
const contourRoofOff = { height: 0, amount: 0 };
const contourCutOff = { actor_base: [0, 0, 0], radius: 0, min_height: 0, slice_distance: 0, index_base: 0 };

function assertEllipseLayout(view, contours) {
  const fields = view.type?.element?.fields;
  const layout = fields?.map(({ name, type }) => type.kind === 'vector'
    ? `${name}:${type.element.kind}x${type.size}`
    : `${name}:${type.kind}`).join(',');
  const expected = 'center:f32x2,axis_x:f32x2,axis_y:f32x2' +
    (contours ? ',high_axis_x:f32x2,high_axis_y:f32x2' : '') + ',rgb:u32,alpha:f32' + (contours ? ',depth:f32' : '');
  if (!view.header || view.offset !== 4 || view.type.kind !== 'list' || layout !== expected) {
    throw new Error('Unexpected Ink ellipse buffer layout');
  }
}

export async function createGaussianRenderer(device, format, { width, height, splats, camera, preordered = false, actor, skin, contours }) {
  const halfViewport = [width / 2, height / 2];
  if (!halfViewport.every((dimension) => Number.isFinite(dimension) && dimension > 0)) {
    throw new Error('Gaussian render target must have positive dimensions');
  }
  const cameraInput = (value) => ({ ...value, half_viewport: halfViewport });
  if ((actor || skin) && (!camera || preordered || (actor && skin))) {
    throw new Error('Choose one actor mode with a depth-sorted world view');
  }
  if (contours && (!camera || preordered || actor)) {
    throw new Error('Colored Contours requires sorted world or skinned splats');
  }
  const projection = camera
    ? { call: preordered ? 'project_world' : 'project_visible_sorted_world',
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
    steps[0] = { id: 'ellipses', call: contours ? 'project_contour_scene' : 'project_sorted_scene',
      args: [{ input: 'splats' }, { step: 'posed' }, { input: 'camera' }] };
    steps.unshift({ id: 'posed', call: 'skin_world',
      args: [{ input: 'rest' }, { input: 'bones' }, { input: 'light' }] });
  }
  if (contours && !skin) {
    projection.input.actors = [];
    steps[0] = { id: 'ellipses', call: 'project_contour_scene',
      args: [{ input: 'splats' }, { input: 'actors' }, { input: 'camera' }] };
  }
  const directional = contours?.directional === true;
  if (directional) {
    const arrivalBlocks = contours.terrainBlocks ?? 1;
    if (!Number.isInteger(arrivalBlocks) || arrivalBlocks < 1) throw new Error('Invalid terrain block count');
    projection.input.contourLight = contourLightOff;
    projection.input.contourReveal = contourRevealOff;
    projection.input.terrainArrivals = Array(arrivalBlocks).fill(-100);
    projection.input.contourOcclusion = {
      view: { frame: { clock: { time: 0, latest: 0, block_rows: 0 }, clip_motion: false, terrain_rows: 0 }, cut: contourCutOff },
      roof: contourRoofOff,
    };
    steps.at(-1).call = 'project_occluded_lit_contours';
    steps.at(-1).args.push(...['contourLight', 'contourReveal', 'terrainArrivals', 'contourOcclusion'].map(input => ({ input })));
  }
  const compactedWorld = projection.call === 'project_visible_sorted_world' && !contours && !hasSkin;
  const ink = await loadInk(bundleURL, { device, parallelU64Merge: compactedWorld });
  let session;
  let viewport;
  let drawArgs;
  let contourRaster;
  try {
    const pipeline = contours ? undefined : await createSmoothPipeline(device, format);
    if (contours) contourRaster = await createContourRaster(device, format, width, height, contours);
    session = await ink.open({
      inputs: { splats, ...projection.input },
      steps,
      outputs: ['ellipses'],
    }, { backend: 'gpu-required' });
    viewport = device.createBuffer({ size: 8, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    device.queue.writeBuffer(viewport, 0, new Float32Array(halfViewport));
    if (!contours) {
      drawArgs = device.createBuffer({
        label: 'Visible splat draw arguments', size: 16, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.INDIRECT,
      });
      device.queue.writeBuffer(drawArgs, 0, new Uint32Array([4, 0, 0, 0]));
    }

    let bindings;
    let boundBuffer;
    let count = splats.length + skinRows;
    async function project() {
      const { counters } = await session.step(1);
      const view = await session.buffer('ellipses');
      assertEllipseLayout(view, contours);
      if (view.capacity < count) throw new Error('Insufficient ellipse capacity');
      if (boundBuffer !== view.buffer) {
        bindings = contourRaster ? contourRaster.bind(view.buffer, viewport) : device.createBindGroup({
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
    function draw(encoder, target) {
      if (contourRaster) return contourRaster.draw(encoder, target, bindings);
      // Ink's list header is the compacted row count. A GPU copy patches instanceCount.
      encoder.copyBufferToBuffer(boundBuffer, 0, drawArgs, 4, 4);
      const pass = encoder.beginRenderPass({
        colorAttachments: [{ view: target, loadOp: 'clear', storeOp: 'store',
          clearValue: { r: 0, g: 0, b: 0, a: 1 } }],
      });
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindings);
      pass.drawIndirect(drawArgs, 0);
      pass.end();
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
      async updateCameraAndDraw(value, target) {
        if (!compactedWorld) throw new Error('Combined camera draws require a sorted smooth world');
        await session.write('camera', cameraInput(value));
        const { counters } = await session.stepAndEncode(encoder => draw(encoder, target));
        return counters;
      },
      setContourGrade(grade) {
        if (!contourRaster) throw new Error('A contour grade requires Colored Contours');
        contourRaster.setGrade(grade);
      },
      async stageContourLighting(light) {
        if (!directional) throw new Error('Enable directional Colored Contours first');
        const frame = light ?? contourLightOff;
        await session.write('contourLight', frame);
        contourRaster.setLighting(frame);
      },
      stageContourWindow(center, radius, edgeWidth = 0, floorHeight = 0) {
        if (!directional || center?.length !== 2 || !center.every(Number.isFinite) || !Number.isFinite(radius) || radius < 0
            || !Number.isFinite(edgeWidth) || edgeWidth < 0 || !Number.isFinite(floorHeight)) {
          throw new Error('Invalid directional contour reveal');
        }
        return session.write('contourReveal', { center, radius, edge_width: edgeWidth, floor_height: floorHeight });
      },
      stageTerrainArrivals(starts) {
        if (!directional || !starts.every(Number.isFinite)) throw new Error('Invalid contour terrain arrival times');
        return session.writeChanged('terrainArrivals', starts);
      },
      stageContourClock(time, latest, blockRows, terrainRows, cut = contourCutOff, roof = contourRoofOff) {
        if (!directional || !Number.isFinite(time) || !Number.isFinite(latest) ||
            !Number.isInteger(blockRows) || blockRows < 0 || blockRows > 0xffffffff ||
            (terrainRows !== undefined && (!Number.isInteger(terrainRows) || terrainRows < 0 || terrainRows > 0xffffffff))) {
          throw new Error('Invalid contour clock');
        }
        if (cut.actor_base?.length !== 3 || !cut.actor_base.every(Number.isFinite) ||
            !Number.isFinite(cut.radius) || cut.radius < 0 || !Number.isFinite(cut.min_height) ||
            !Number.isFinite(cut.slice_distance) || cut.slice_distance < 0 ||
            !Number.isInteger(cut.index_base) || cut.index_base < 0 || cut.index_base > 0xffffffff) {
          throw new Error('Invalid contour cut');
        }
        if (!Number.isFinite(roof.height) || !Number.isFinite(roof.amount) || roof.amount < 0 || roof.amount > 1) {
          throw new Error('Invalid contour roof');
        }
        return session.write('contourOcclusion', {
          view: { frame: { clock: { time, latest, block_rows: blockRows }, clip_motion: terrainRows !== undefined,
            terrain_rows: terrainRows ?? 0 }, cut }, roof,
        });
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
      draw,
      async close() {
        viewport.destroy();
        drawArgs?.destroy();
        contourRaster?.close();
        await ink.close();
      },
    };
  } catch (error) {
    viewport?.destroy();
    drawArgs?.destroy();
    contourRaster?.close();
    await ink.close();
    throw error;
  }
}

async function createSmoothPipeline(device, format) {
  const shaderResponse = await fetch(shaderURL);
  if (!shaderResponse.ok) throw new Error(`Gaussian shader could not load (${shaderResponse.status})`);
  const shader = device.createShaderModule({ code: await shaderResponse.text() });
  const over = { srcFactor: 'one', dstFactor: 'one-minus-src-alpha', operation: 'add' };
  return device.createRenderPipelineAsync({
    layout: 'auto',
    vertex: { module: shader, entryPoint: 'vertex' },
    fragment: {
      module: shader,
      entryPoint: 'fragment',
      targets: [{ format, blend: { color: over, alpha: over } }],
    },
    primitive: { topology: 'triangle-strip' },
  });
}
