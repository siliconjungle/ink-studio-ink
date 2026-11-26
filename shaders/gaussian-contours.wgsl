struct Palette {
  settings: vec4f,
  depth_range: vec4f,
  colors: array<vec4f,64>,
  mapped: array<vec4f,64>,
}
@group(0) @binding(0) var high: texture_2d<f32>;
@group(0) @binding(1) var depth: texture_2d<f32>;
@group(0) @binding(2) var native: texture_2d<f32>;
@group(0) @binding(3) var<uniform> pal: Palette;
@group(0) @binding(4) var nativeDepth: texture_2d<f32>;
const weights = vec3f(.30,.55,.15);
const bayer = array<f32,16>(0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5);
fn nearest(c: vec3f, solid: bool) -> u32 {
  let count = u32(pal.settings.x);
  var best = select(0u,1u,solid && count > 1u);
  var distance = 1e9;
  for (var i = best; i < count; i++) {
    let delta = c - pal.colors[i].xyz;
    let d = dot(delta * delta,weights);
    if (d < distance) { best = i; distance = d; }
  }
  return best;
}
fn pixelAt(p: vec2i) -> vec2i {
  return clamp(p, vec2i(0), vec2i(textureDimensions(depth)) - 1);
}
fn pixelDepth(p: vec2i) -> f32 {
  var result = 1.0;
  for (var i = 0i; i < 4; i++) {
    // Sample bottom first to preserve WebGL's ordering when votes tie.
    result = min(result,textureLoad(depth,pixelAt(p*2+vec2i(i&1,1-(i>>1))),0).r);
  }
  return result;
}
@vertex fn vertex(@builtin(vertex_index) id: u32) -> @builtin(position) vec4f {
  let corner = vec2f(f32((id << 1u) & 2u),f32(id & 2u));
  return vec4f(corner*2.0-1.0,0.0,1.0);
}
@fragment fn fragment(@builtin(position) xy: vec4f) -> @location(0) vec4f {
  let p = vec2i(xy.xy);
  var mask = 0u;
  for (var i = 0i; i < 4; i++) {
    if (textureLoad(depth,pixelAt(p*2+vec2i(i&1,1-(i>>1))),0).r < .995) { mask |= 1u << u32(i); }
  }
  if (mask != 0u && (mask != 15u || max(max(pixelDepth(p-vec2i(1,0)),pixelDepth(p+vec2i(1,0))),
    max(pixelDepth(p-vec2i(0,1)),pixelDepth(p+vec2i(0,1)))) >= .995)) {
    var labels = array<i32,4>(-1,-1,-1,-1);
    for (var i = 0; i < 4; i++) {
      if ((mask & (1u << u32(i))) != 0u) {
        labels[i] = i32(nearest(textureLoad(high,pixelAt(p*2+vec2i(i&1,1-(i>>1))),0).rgb,true));
      }
    }
    var best = 0i; var score = 0i;
    for (var i = 0; i < 4; i++) {
      if (labels[i] < 0) { continue; }
      var count = 0i;
      for (var j = 0; j < 4; j++) { if (labels[i] == labels[j]) { count++; } }
      if (count > score) { best = labels[i]; score = count; }
    }
    let body = pal.mapped[best].xyz;
    let raw = body * .64;
    let ink = min(vec3f(1),raw * max(1.0,.12 / max(dot(raw,weights),.001)));
    return vec4f(mix(pal.mapped[0].xyz,mix(body,ink,.65),f32(countOneBits(mask))*.25),1);
  }
  let bottomUp = i32(textureDimensions(native).y) - 1 - p.y;
  let noise = ((bayer[(p.x&3) + ((bottomUp&3)<<2)] + .5) / 16.0 - .5) * pal.settings.y;
  var color = textureLoad(native,p,0).rgb;
  if (pal.settings.z > 0.0) {
    let offsets = array<vec2i,8>(vec2i(2,0),vec2i(-2,0),vec2i(0,2),vec2i(0,-2),
      vec2i(1,1),vec2i(-1,1),vec2i(1,-1),vec2i(-1,-1));
    let size = vec2i(textureDimensions(nativeDepth))-1;
    let center = textureLoad(nativeDepth,p,0).r;
    var occlusion = 0.0;
    for (var i = 0u; i < 8u; i++) {
      let neighbor = textureLoad(nativeDepth,clamp(p+offsets[i],vec2i(0),size),0).r;
      let near = (center-neighbor)/pal.settings.w;
      if (near > .08 && near < 3.0) { occlusion += min(1.0,near); }
    }
    color *= 1.0-pal.settings.z*min(1.0,occlusion/4.0);
  }
  let pColor = clamp(color + noise,vec3f(0),vec3f(1));
  return vec4f(pal.mapped[nearest(pColor,false)].xyz,1);
}

// One sorted 13-word row drives both color and depth grids. Projected positions
// and axes are in native-pixel units, independent of the raster target size.
@group(0) @binding(5) var<storage, read> ellipses: array<u32>;
@group(0) @binding(6) var<uniform> half_viewport: vec2f;

struct RasterVertex {
    @builtin(position) position: vec4f,
    @location(0) local: vec2f,
    @location(1) @interpolate(flat) color: vec4f,
    @location(2) @interpolate(flat) depth: f32,
}

fn pair(base: u32) -> vec2f {
    return vec2f(bitcast<f32>(ellipses[base]), bitcast<f32>(ellipses[base + 1u]));
}

fn raster_vertex(corner: u32, index: u32, native: bool) -> RasterVertex {
    if index >= ellipses[0] {
        return RasterVertex(vec4f(2.0, 2.0, 0.0, 1.0), vec2f(0.0), vec4f(0.0), 1.0);
    }
    let row = 1u + index * 13u;
    let local = vec2f(f32(corner & 1u), f32(corner >> 1u)) * 2.0 - 1.0;
    let center = pair(row);
    let origin = select(center, floor(center + half_viewport) + 0.5 - half_viewport, native);
    let axes = row + select(6u, 2u, native);
    let point = origin + local.x * pair(axes) + local.y * pair(axes + 2u);
    let color = vec4f(unpack4x8unorm(ellipses[row + 10u]).rgb, bitcast<f32>(ellipses[row + 11u]));
    let depth = (bitcast<f32>(ellipses[row + 12u]) - pal.depth_range.x) / pal.depth_range.y;
    return RasterVertex(vec4f(point / half_viewport, 0.0, 1.0), local, color, clamp(depth, 0.0, 1.0));
}

struct RasterPixel {
    @location(0) color: vec4f,
    @location(1) depth: vec4f,
}

fn raster_fragment(input: RasterVertex, hard: bool) -> RasterPixel {
    let power = -4.5 * dot(input.local, input.local);
    if power < -4.5 { discard; }
    let gaussian = input.color.a * exp(power);
    let solid = input.color.a >= 1.0;
    var alpha = min(0.99, gaussian);
    if solid {
        alpha = select(0.99 * smoothstep(0.38, 0.62, gaussian),
            select(0.0, 1.0, gaussian > 0.5), hard);
    }
    if alpha < 0.004 { discard; }
    let depth_alpha = select(0.0, alpha, solid);
    return RasterPixel(vec4f(input.color.rgb * alpha, alpha),
        vec4f(input.depth * depth_alpha, 0.0, 0.0, depth_alpha));
}

@vertex fn native_vertex(@builtin(vertex_index) corner: u32, @builtin(instance_index) index: u32) -> RasterVertex {
    return raster_vertex(corner, index, true);
}

@vertex fn high_vertex(@builtin(vertex_index) corner: u32, @builtin(instance_index) index: u32) -> RasterVertex {
    return raster_vertex(corner, index, false);
}

@fragment fn native_fragment(input: RasterVertex) -> RasterPixel {
    return raster_fragment(input, pal.depth_range.z > 0.5);
}

@fragment fn high_fragment(input: RasterVertex) -> RasterPixel {
    return raster_fragment(input, false);
}
