use super::render::{RenderBindings, RenderFrame};
use wgpu::util::DeviceExt;

/// Palette and depth settings for native-resolution Colored Contours.
pub struct ContourSettings<'a> {
    /// Packed 0xRRGGBB colors. The first color is the background.
    pub colors: &'a [u32],
    /// Optional display RGB for each matching color.
    pub grade: Option<&'a [[f32; 3]]>,
    pub dither: f32,
    pub occlusion: f32,
    pub occlusion_reach: f32,
    pub depth_near: f32,
    pub depth_span: f32,
    pub hard: bool,
}

const MAX_COLORS: usize = 64;
const GRADE_WORD: usize = 8 + MAX_COLORS * 4;
const LIGHTING_WORD: usize = GRADE_WORD + MAX_COLORS * 4;

pub(crate) struct ContourRaster {
    frame: RenderFrame,
    palette: wgpu::Buffer,
    queue: wgpu::Queue,
    initial_grade: Vec<[f32; 3]>,
}

impl ContourRaster {
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        settings: ContourSettings<'_>,
    ) -> Result<Self, String> {
        let count = settings.colors.len();
        if count == 0
            || count > MAX_COLORS
            || settings.colors.iter().any(|color| *color > 0xff_ffff)
            || ![
                settings.dither,
                settings.occlusion,
                settings.occlusion_reach,
                settings.depth_near,
                settings.depth_span,
            ]
            .into_iter()
            .all(f32::is_finite)
            || settings.depth_span <= 0.0
            || settings.occlusion_reach <= 0.0
            || settings.grade.is_some_and(|grade| {
                grade.len() != count || grade.iter().flatten().any(|x| !x.is_finite())
            })
        {
            return Err("Invalid contour palette or depth settings".into());
        }
        let mut words = [0.0f32; LIGHTING_WORD + 8];
        words[..8].copy_from_slice(&[
            count as f32,
            settings.dither,
            settings.occlusion,
            settings.occlusion_reach,
            settings.depth_near,
            settings.depth_span,
            f32::from(settings.hard),
            0.0,
        ]);
        let mut initial_grade = Vec::with_capacity(count);
        for (i, color) in settings.colors.iter().enumerate() {
            let rgb = [16, 8, 0].map(|shift| ((color >> shift) & 255u32) as f32 / 255.0);
            let graded = settings.grade.map_or(rgb, |colors| colors[i]);
            words[8 + i * 4..11 + i * 4].copy_from_slice(&rgb);
            let at = GRADE_WORD + i * 4;
            words[at..at + 3].copy_from_slice(&graded);
            initial_grade.push(graded);
        }
        let palette = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Contour palette"),
            contents: &words
                .iter()
                .flat_map(|value| value.to_le_bytes())
                .collect::<Vec<_>>(),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });
        let background = wgpu::Color {
            r: words[8] as f64,
            g: words[9] as f64,
            b: words[10] as f64,
            a: 1.0,
        };
        let frame = RenderFrame::new(device, format, size, &[("background", background)])?;
        Ok(Self { frame, palette, queue: queue.clone(), initial_grade })
    }

    pub fn bind(&self, device: &wgpu::Device, ellipses: &wgpu::Buffer, viewport: &wgpu::Buffer) -> Result<RenderBindings, String> {
        self.frame.bind(device, &[("palette", &self.palette), ("ellipses", ellipses), ("viewport", viewport)])
    }

    pub fn set_grade(&self, grade: Option<&[[f32; 3]]>) -> Result<(), String> {
        let grade = grade.unwrap_or(&self.initial_grade);
        if grade.len() != self.initial_grade.len() || grade.iter().flatten().any(|value| !value.is_finite()) {
            return Err("Invalid contour grade".into());
        }
        let bytes: Vec<u8> = grade
            .iter()
            .flat_map(|&[r, g, b]| [r, g, b, 0.0f32])
            .flat_map(f32::to_le_bytes)
            .collect();
        self.queue.write_buffer(&self.palette, (GRADE_WORD * 4) as u64, &bytes);
        Ok(())
    }

    pub fn set_lighting(&self, ambient: [f32; 3], key: [f32; 3], enabled: bool) {
        let bytes: Vec<u8> = [ambient[0], ambient[1], ambient[2], f32::from(enabled), key[0], key[1], key[2], 0.0]
            .into_iter().flat_map(f32::to_le_bytes).collect();
        self.queue.write_buffer(&self.palette, (LIGHTING_WORD * 4) as u64, &bytes);
    }

    pub fn draw(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        target: &wgpu::TextureView,
        bindings: &RenderBindings,
        capacity: u32,
    ) {
        self.frame.draw(encoder, target, bindings, |_| capacity);
    }
}
