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

const INTERMEDIATE: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

pub(crate) struct ContourRaster {
    pub layout: wgpu::BindGroupLayout,
    pub palette: wgpu::Buffer,
    native: Grid,
    high: Grid,
    resolve: wgpu::RenderPipeline,
    inputs: wgpu::BindGroup,
    background: wgpu::Color,
}

struct Grid {
    color: wgpu::TextureView,
    depth: wgpu::TextureView,
    pipeline: wgpu::RenderPipeline,
}

impl Grid {
    fn new(
        device: &wgpu::Device,
        size: [u32; 2],
        shader: &wgpu::ShaderModule,
        layout: &wgpu::PipelineLayout,
        vertex: &str,
        fragment: &str,
    ) -> Self {
        let view = || {
            device
                .create_texture(&wgpu::TextureDescriptor {
                    label: Some("Contour grid"),
                    size: wgpu::Extent3d {
                        width: size[0],
                        height: size[1],
                        depth_or_array_layers: 1,
                    },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: INTERMEDIATE,
                    usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                        | wgpu::TextureUsages::TEXTURE_BINDING,
                    view_formats: &[],
                })
                .create_view(&Default::default())
        };
        let target = Some(wgpu::ColorTargetState {
            format: INTERMEDIATE,
            blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
            write_mask: wgpu::ColorWrites::ALL,
        });
        Self {
            color: view(),
            depth: view(),
            pipeline: pipeline(
                device,
                shader,
                Some(layout),
                vertex,
                fragment,
                wgpu::PrimitiveTopology::TriangleStrip,
                &[target.clone(), target],
            ),
        }
    }

    fn draw(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        bindings: &wgpu::BindGroup,
        count: u32,
        background: wgpu::Color,
    ) {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("Contour grid raster"),
            color_attachments: &[
                attachment(&self.color, background),
                attachment(
                    &self.depth,
                    wgpu::Color {
                        r: 1.0,
                        g: 0.0,
                        b: 0.0,
                        a: 1.0,
                    },
                ),
            ],
            ..Default::default()
        });
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, bindings, &[]);
        pass.draw(0..4, 0..count);
    }
}

impl ContourRaster {
    pub fn new(
        device: &wgpu::Device,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        settings: ContourSettings<'_>,
    ) -> Result<Self, String> {
        let count = settings.colors.len();
        if count == 0
            || count > 64
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
        let limit = device.limits().max_texture_dimension_2d / 2;
        if size.into_iter().any(|value| value > limit) {
            return Err("Double-resolution contour grid exceeds texture limits".into());
        }
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Ink Studio Colored Contours"),
            source: wgpu::ShaderSource::Wgsl(
                include_str!("../../shaders/gaussian-contours.wgsl").into(),
            ),
        });
        let mut words = [0.0f32; 8 + 64 * 8];
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
        for (i, color) in settings.colors.iter().enumerate() {
            let rgb = [16, 8, 0].map(|shift| ((color >> shift) & 255u32) as f32 / 255.0);
            let graded = settings.grade.map_or(rgb, |colors| colors[i]);
            words[8 + i * 4..11 + i * 4].copy_from_slice(&rgb);
            words[264 + i * 4..267 + i * 4].copy_from_slice(&graded);
        }
        let palette = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Contour palette"),
            contents: &words
                .iter()
                .flat_map(|value| value.to_le_bytes())
                .collect::<Vec<_>>(),
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let buffer = |binding, visibility, ty| wgpu::BindGroupLayoutEntry {
            binding,
            visibility,
            ty: wgpu::BindingType::Buffer {
                ty,
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        };
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Contour raster resources"),
            entries: &[
                buffer(
                    3,
                    wgpu::ShaderStages::VERTEX_FRAGMENT,
                    wgpu::BufferBindingType::Uniform,
                ),
                buffer(
                    5,
                    wgpu::ShaderStages::VERTEX,
                    wgpu::BufferBindingType::Storage { read_only: true },
                ),
                buffer(
                    6,
                    wgpu::ShaderStages::VERTEX,
                    wgpu::BufferBindingType::Uniform,
                ),
            ],
        });
        let raster_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Contour raster pipeline layout"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let native = Grid::new(
            device,
            size,
            &shader,
            &raster_layout,
            "native_vertex",
            "native_fragment",
        );
        let high = Grid::new(
            device,
            size.map(|value| value * 2),
            &shader,
            &raster_layout,
            "high_vertex",
            "high_fragment",
        );
        let resolve = pipeline(
            device,
            &shader,
            None,
            "vertex",
            "fragment",
            wgpu::PrimitiveTopology::TriangleList,
            &[Some(format.into())],
        );
        let texture = |binding, view| wgpu::BindGroupEntry {
            binding,
            resource: wgpu::BindingResource::TextureView(view),
        };
        let inputs = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Contour resolve resources"),
            layout: &resolve.get_bind_group_layout(0),
            entries: &[
                texture(0, &high.color),
                texture(1, &high.depth),
                texture(2, &native.color),
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: palette.as_entire_binding(),
                },
                texture(4, &native.depth),
            ],
        });
        let background = wgpu::Color {
            r: words[8] as f64,
            g: words[9] as f64,
            b: words[10] as f64,
            a: 1.0,
        };
        Ok(Self {
            layout,
            palette,
            native,
            high,
            resolve,
            inputs,
            background,
        })
    }

    pub fn draw(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        target: &wgpu::TextureView,
        bindings: &wgpu::BindGroup,
        count: u32,
    ) {
        self.high.draw(encoder, bindings, count, self.background);
        self.native.draw(encoder, bindings, count, self.background);
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("Colored Contours resolve"),
            color_attachments: &[attachment(target, wgpu::Color::BLACK)],
            ..Default::default()
        });
        pass.set_pipeline(&self.resolve);
        pass.set_bind_group(0, &self.inputs, &[]);
        pass.draw(0..3, 0..1);
    }
}

fn pipeline(
    device: &wgpu::Device,
    shader: &wgpu::ShaderModule,
    layout: Option<&wgpu::PipelineLayout>,
    vertex: &str,
    fragment: &str,
    topology: wgpu::PrimitiveTopology,
    targets: &[Option<wgpu::ColorTargetState>],
) -> wgpu::RenderPipeline {
    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("Colored Contours"),
        layout,
        vertex: wgpu::VertexState {
            module: shader,
            entry_point: Some(vertex),
            compilation_options: Default::default(),
            buffers: &[],
        },
        fragment: Some(wgpu::FragmentState {
            module: shader,
            entry_point: Some(fragment),
            compilation_options: Default::default(),
            targets,
        }),
        primitive: wgpu::PrimitiveState {
            topology,
            ..Default::default()
        },
        depth_stencil: None,
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    })
}

fn attachment(
    view: &wgpu::TextureView,
    clear: wgpu::Color,
) -> Option<wgpu::RenderPassColorAttachment<'_>> {
    Some(wgpu::RenderPassColorAttachment {
        view,
        depth_slice: None,
        resolve_target: None,
        ops: wgpu::Operations {
            load: wgpu::LoadOp::Clear(clear),
            store: wgpu::StoreOp::Store,
        },
    })
}
