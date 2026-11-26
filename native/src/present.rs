/// Presents an art-resolution texture with nearest-neighbor scaling.
pub struct PixelPresenter {
    pipeline: wgpu::RenderPipeline,
    source: wgpu::BindGroup,
    art_size: [u32; 2],
}

impl PixelPresenter {
    pub fn new(
        device: &wgpu::Device,
        art: &wgpu::Texture,
        surface_format: wgpu::TextureFormat,
    ) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Pixel-art presentation"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/present.wgsl").into()),
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Pixel-art presentation"),
            layout: None,
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vertex"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some(if surface_format.is_srgb() {
                    "fragment_srgb"
                } else {
                    "fragment"
                }),
                compilation_options: Default::default(),
                targets: &[Some(surface_format.into())],
            }),
            multiview_mask: None,
            cache: None,
        });
        let source = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Art texture view"),
            layout: &pipeline.get_bind_group_layout(0),
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(&art.create_view(&Default::default())),
            }],
        });
        Self {
            pipeline,
            source,
            art_size: [art.width(), art.height()],
        }
    }

    pub fn present(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        target: &wgpu::TextureView,
        size: [u32; 2],
    ) {
        if size.contains(&0) {
            return;
        }
        let [w, h] = size.map(|x| x as f32);
        let [art_w, art_h] = self.art_size.map(|x| x as f32);
        let mut scale = (w / art_w).min(h / art_h);
        if scale >= 1.0 {
            scale = scale.floor();
        }
        let width = (art_w * scale).round().clamp(1.0, w);
        let height = (art_h * scale).round().clamp(1.0, h);
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_viewport(
            ((w - width) * 0.5).floor(),
            ((h - height) * 0.5).floor(),
            width,
            height,
            0.0,
            1.0,
        );
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, &self.source, &[]);
        pass.draw(0..3, 0..1);
    }
}
