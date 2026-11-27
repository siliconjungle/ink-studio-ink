export function shorelineFixture() {
  const rows = [
    [0, -1.1, -5, true],   // Reflected source is in the foreground corridor.
    [0, -1.1, -5],         // Untagged bed projects through water.
    [-2, -1.1, -5],        // The sightline intersects the clamped dry edge.
    [0, -2.0, -2.4],       // The surface intersection is outside the reveal radius.
    [1.5, -1.1, -3],       // The Works pit bypasses the surface tests.
    [2, -1.1, -4, true],   // The source is beyond the Crypt slice.
    [0, -0.4, -5, true],   // The reflected source is below the cut.
    [0, -0.21, -5],        // The water surface itself remains visible.
    [-2, -1.1, -5],        // Moving rows bypass the shoreline tests.
  ].map(([x, y, z, reflected], i) => ({
    position: [x, y, z], covariance0: [0.1, 0, 0], covariance1: [0.1, 0, 0.1],
    reach: 3, rgb: i + 1 + (reflected ? 0x80000000 : 0), alpha: 0.5,
  }));
  const camera = { eye: [0, 2, 0], right: [1, 0, 0], up: [0, 1, 0], back: [0, 0, 1],
    half_viewport: [32, 32], focal: 2, near_clip: 0.1, far_clip: 12, variance: 0, perspective: false };
  const light = { enabled: false, direction: [0, 1, 0], actor_center: [0, 0, 0], actor_rows: 0,
    ambient: [1, 1, 1], key: [0, 0, 0] };
  const reveal = { center: [0, -6], radius: 4, edge_width: 0, floor_height: 0 };
  const clock = { time: 0, latest: 0, block_rows: 0 };
  const cut = { actor_base: [0, 0, -7], radius: 0.8, min_height: 0.3, slice_distance: 2.5, index_base: 0 };
  const water = { occlusion: {
    view: { frame: { clock, clip_motion: true, terrain_rows: rows.length - 1 }, cut },
    roof: { height: 0, amount: 0 },
  }, shore: { level: -0.2, pit: [1, 2, -3.5, -2.5], origin: [-1, -8], width: 8, depth: 8, word_offset: 2 } };
  // Cell 32 is dry in the second packed map. The first map is all land.
  const dry = [0xffffffff, 0xffffffff, 0, 1];
  return { rows, camera, light, reveal, water, dry, visible: [2, 5, 7, 8, 9] };
}
