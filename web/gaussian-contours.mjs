const shaderUrl = new URL('../shaders/gaussian-contours.wgsl', import.meta.url);
const maxColors = 64;
const gradeWord = 8 + maxColors * 4;
const over = { srcFactor: 'one', dstFactor: 'one-minus-src-alpha', operation: 'add' };

export async function createContourRaster(device, format, width, height, {
  colors, grade, dither = 0.25, occlusion = 0, occlusionReach = 1,
  depthNear = 0, depthSpan = 1, hard = true,
}) {
  const count = colors?.length ?? 0;
  const graded = grade && Array.from(grade);
  if (!count || count > maxColors || Array.from(colors).some(color => !Number.isInteger(color) || color < 0 || color > 0xffffff) ||
      ![dither, occlusion, occlusionReach, depthNear, depthSpan].every(Number.isFinite) ||
      depthSpan <= 0 || occlusionReach <= 0 || (graded && (graded.length !== count * 3 || graded.some(value => !Number.isFinite(value))))) {
    throw new Error('Invalid contour palette or depth settings');
  }
  if (![width, height].every(size => Number.isInteger(size) && size * 2 <= device.limits.maxTextureDimension2D)) {
    throw new Error('Double-resolution contour grid exceeds texture limits');
  }
  const response = await fetch(shaderUrl);
  if (!response.ok) throw new Error(`Colored Contours shader could not load (${response.status})`);
  const module = device.createShaderModule({ label: 'Ink Studio Colored Contours', code: await response.text() });
  const gridFormat = 'rgba8unorm';
  const target = { format: gridFormat, blend: { color: over, alpha: over } };
  const rasterResources = device.createBindGroupLayout({ entries: [
    { binding: 3, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: 'uniform' } },
    { binding: 5, visibility: GPUShaderStage.VERTEX, buffer: { type: 'read-only-storage' } },
    { binding: 6, visibility: GPUShaderStage.VERTEX, buffer: { type: 'uniform' } },
  ] });
  const rasterLayout = device.createPipelineLayout({ bindGroupLayouts: [rasterResources] });
  const raster = grid => device.createRenderPipelineAsync({
    label: `Colored Contours ${grid} raster`,
    layout: rasterLayout,
    vertex: { module, entryPoint: `${grid}_vertex` },
    fragment: { module, entryPoint: `${grid}_fragment`, targets: [target, target] },
    primitive: { topology: 'triangle-strip' },
  });
  const [highPipeline, nativePipeline, resolve] = await Promise.all([
    raster('high'), raster('native'),
    device.createRenderPipelineAsync({
      label: 'Colored Contours palette resolve', layout: 'auto',
      vertex: { module, entryPoint: 'vertex' }, fragment: { module, entryPoint: 'fragment', targets: [{ format }] },
    }),
  ]);
  const words = new Float32Array(8 + maxColors * 8);
  words.set([count, dither, occlusion, occlusionReach, depthNear, depthSpan, Number(hard)]);
  for (let i = 0; i < count; i++) {
    const rgb = [16, 8, 0].map(shift => (colors[i] >>> shift & 255) / 255);
    words.set(rgb, 8 + i * 4);
    words.set(graded ? graded.slice(i * 3, i * 3 + 3) : rgb, gradeWord + i * 4);
  }
  const palette = device.createBuffer({ label: 'Contour palette', size: words.byteLength,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(palette, 0, words);
  const textures = [];
  const texture = scale => {
    const source = device.createTexture({
      label: 'Contour grid', size: [width * scale, height * scale], format: gridFormat,
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
    });
    textures.push(source);
    return source.createView();
  };
  const [highColor, highDepth, nativeColor, nativeDepth] = [texture(2), texture(2), texture(1), texture(1)];
  const inputs = device.createBindGroup({
    layout: resolve.getBindGroupLayout(0),
    entries: [highColor, highDepth, nativeColor, { buffer: palette }, nativeDepth].map((resource, binding) => ({ binding, resource })),
  });
  const background = { r: words[8], g: words[9], b: words[10], a: 1 };
  const depthClear = { r: 1, g: 0, b: 0, a: 1 };
  const attachment = (view, clearValue) => ({ view, clearValue, loadOp: 'clear', storeOp: 'store' });
  function drawGrid(encoder, pipeline, color, depth, bindings, drawArgs) {
    const pass = encoder.beginRenderPass({ colorAttachments: [attachment(color, background), attachment(depth, depthClear)] });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindings);
    pass.drawIndirect(drawArgs, 0);
    pass.end();
  }
  return {
    setGrade(grade) {
      const channels = grade == null ? null : Array.from(grade);
      if (channels && (channels.length !== count * 3 || channels.some(channel => !Number.isFinite(channel)))) {
        throw new Error('Invalid contour grade');
      }
      const mapped = words.slice(gradeWord, gradeWord + count * 4);
      if (channels) {
        for (let i = 0; i < count; i++) mapped.set(channels.slice(i * 3, i * 3 + 3), i * 4);
      }
      device.queue.writeBuffer(palette, gradeWord * 4, mapped);
    },
    bind(buffer, viewport) {
      return device.createBindGroup({ layout: rasterResources, entries: [
        { binding: 3, resource: { buffer: palette } },
        { binding: 5, resource: { buffer } },
        { binding: 6, resource: { buffer: viewport } },
      ] });
    },
    draw(encoder, target, bindings, drawArgs) {
      drawGrid(encoder, highPipeline, highColor, highDepth, bindings, drawArgs);
      drawGrid(encoder, nativePipeline, nativeColor, nativeDepth, bindings, drawArgs);
      const pass = encoder.beginRenderPass({ colorAttachments: [attachment(target, background)] });
      pass.setPipeline(resolve);
      pass.setBindGroup(0, inputs);
      pass.draw(3);
      pass.end();
    },
    close() {
      for (const source of textures) source.destroy();
      palette.destroy();
    },
  };
}
