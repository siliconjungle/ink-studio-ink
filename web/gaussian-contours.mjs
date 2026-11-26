import { createRenderFrame } from '../build/contour-render/render.mjs';
const maxColors = 64;
const gradeWord = 8 + maxColors * 4;
const lightingWord = gradeWord + maxColors * 4;

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
  const words = new Float32Array(lightingWord + 8);
  words.set([count, dither, occlusion, occlusionReach, depthNear, depthSpan, Number(hard)]);
  for (let i = 0; i < count; i++) {
    const rgb = [16, 8, 0].map(shift => (colors[i] >>> shift & 255) / 255);
    words.set(rgb, 8 + i * 4);
    words.set(graded ? graded.slice(i * 3, i * 3 + 3) : rgb, gradeWord + i * 4);
  }
  const background = { r: words[8], g: words[9], b: words[10], a: 1 };
  const frame = await createRenderFrame(device, format, width, height, { background });
  const palette = device.createBuffer({ label: 'Contour palette', size: words.byteLength,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(palette, 0, words);
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
    setLighting({ ambient, key, enabled }) {
      device.queue.writeBuffer(palette, lightingWord * 4,
        new Float32Array([...ambient, Number(enabled), ...key, 0]));
    },
    bind(ellipses, viewport) {
      return frame.bind({ palette, ellipses, viewport });
    },
    draw: frame.draw,
    close() {
      frame.close();
      palette.destroy();
    },
  };
}
