use ink_gpu_program::{Engine, PackedInput};
use serde_json::{json, Value};

pub(super) trait GpuWords {
    fn layout() -> Value;
    fn append(self, words: &mut Vec<u32>);

    fn words(self) -> Vec<u32> where Self: Sized {
        let mut words = Vec::new();
        self.append(&mut words);
        words
    }
}

impl GpuWords for f32 {
    fn layout() -> Value { json!({"kind": "f32"}) }
    fn append(self, words: &mut Vec<u32>) { words.push(self.to_bits()); }
}

impl GpuWords for u32 {
    fn layout() -> Value { json!({"kind": "u32"}) }
    fn append(self, words: &mut Vec<u32>) { words.push(self); }
}

impl GpuWords for bool {
    fn layout() -> Value { json!({"kind": "bool"}) }
    fn append(self, words: &mut Vec<u32>) { words.push(u32::from(self)); }
}

impl<const N: usize> GpuWords for [f32; N] {
    fn layout() -> Value { json!({"kind": "vector", "size": N, "element": f32::layout()}) }
    fn append(self, words: &mut Vec<u32>) { words.extend(self.map(f32::to_bits)); }
}

// The same ordered fields describe the layout and write the words. Ink
// checks that layout against the active shader input when it is first used.
macro_rules! gpu_record {
    ($name:ident { $($field:ident: $type:ty),+ $(,)? }) => {
        #[derive(Clone, Copy)]
        pub struct $name { $( pub $field: $type, )+ }
        impl GpuWords for $name {
            fn layout() -> Value {
                json!({"kind": "record", "fields": [
                    $( {"name": stringify!($field), "type": <$type>::layout()}, )+
                ]})
            }
            fn append(self, words: &mut Vec<u32>) { $( self.$field.append(words); )+ }
        }
    };
}

gpu_record!(WorldSplat {
    position: [f32; 3], covariance0: [f32; 3], covariance1: [f32; 3],
    reach: f32, rgb: u32, alpha: f32,
});

impl WorldSplat {
    pub fn pack(rows: impl IntoIterator<Item = Self>) -> Vec<u32> {
        let rows = rows.into_iter();
        let mut words = Vec::with_capacity(rows.size_hint().0.saturating_mul(12));
        for row in rows { row.append(&mut words); }
        words
    }
}

gpu_record!(Camera {
    eye: [f32; 3], right: [f32; 3], up: [f32; 3], back: [f32; 3], half_viewport: [f32; 2],
    focal: f32, near_clip: f32, far_clip: f32, variance: f32, perspective: bool,
});

gpu_record!(Bone {
    axis_x: [f32; 3], axis_y: [f32; 3], axis_z: [f32; 3], offset: [f32; 3],
});

gpu_record!(RigLight {
    sun: [f32; 3], ambient: f32, diffuse: f32, blink: f32,
});

gpu_record!(ContourLight {
    enabled: bool, direction: [f32; 3], actor_center: [f32; 3], actor_rows: u32,
    ambient: [f32; 3], key: [f32; 3],
});

impl ContourLight {
    pub(super) const OFF: Self = Self {
        enabled: false, direction: [0.0, 1.0, 0.0], actor_center: [0.0; 3],
        actor_rows: 0, ambient: [1.0; 3], key: [0.0; 3],
    };
}

gpu_record!(ContourWindow { center: [f32; 2], radius: f32 });
gpu_record!(ContourReveal { center: [f32; 2], radius: f32, edge_width: f32, floor_height: f32 });
gpu_record!(ContourClock { time: f32, latest: f32, block_rows: u32 });

pub(super) fn list<T: GpuWords>() -> Value {
    json!({"kind": "list", "element": T::layout()})
}

pub(super) fn binding<'a>(
    slot: &'a mut Option<PackedInput>, engine: &Engine, session: u64, name: &str,
    layout: fn() -> Value,
) -> Result<&'a PackedInput, String> {
    if slot.is_none() {
        *slot = Some(engine.packed_input(session, name, &layout())?);
    }
    Ok(slot.as_ref().expect("prepared input"))
}

#[derive(Default)]
pub(super) struct PackedInputs {
    pub(super) splats: Option<PackedInput>,
    pub(super) camera: Option<PackedInput>,
    pub(super) bones: Option<PackedInput>,
    pub(super) rig_light: Option<PackedInput>,
    pub(super) contour_light: Option<PackedInput>,
    pub(super) contour_reveal: Option<PackedInput>,
    pub(super) contour_clock: Option<PackedInput>,
    pub(super) terrain_arrivals: Option<PackedInput>,
}
