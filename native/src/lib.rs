use ink_gpu_program::{Backend, Engine, View};
use serde_json::{Value, json};
use wgpu::util::DeviceExt;

mod present;
pub use present::PixelPresenter;

pub struct GaussianRenderer {
    engine: Engine,
    session: u64,
    pipeline: wgpu::RenderPipeline,
    viewport: wgpu::Buffer,
    half_viewport: [f32; 2],
    bindings: Option<(wgpu::Buffer, wgpu::BindGroup)>,
    count: u32,
}

pub enum WorldOrder {
    Sort,
    Preordered,
}

impl GaussianRenderer {
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
    ) -> Result<Self, String> {
        Self::create(device, queue, format, size, splats, None)
    }

    pub fn with_camera(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: &Value,
        ordering: WorldOrder,
    ) -> Result<Self, String> {
        Self::create(
            device,
            queue,
            format,
            size,
            splats,
            Some((camera, ordering)),
        )
    }

    fn create(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: Option<(&Value, WorldOrder)>,
    ) -> Result<Self, String> {
        if size.contains(&0) {
            return Err("Gaussian render target must have positive dimensions".into());
        }
        let count = splat_count(splats)?;
        let half_viewport = [size[0] as f32 / 2.0, size[1] as f32 / 2.0];
        let constants: Vec<u8> = half_viewport.iter().flat_map(|v| v.to_le_bytes()).collect();
        let viewport = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Gaussian half viewport"),
            contents: &constants,
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Ink Studio Gaussian raster"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/gaussian.wgsl").into()),
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Ink Studio Gaussian raster"),
            layout: None,
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vertex"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                buffers: &[],
            },
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleStrip,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fragment"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let mut engine = Engine::with_device(device.clone(), queue.clone());
        let (function, inputs, view) = if let Some((camera, ordering)) = camera {
            (
                match ordering {
                    WorldOrder::Sort => "project_sorted_world",
                    WorldOrder::Preordered => "project_world",
                },
                json!({"splats": splats, "camera": camera_input(camera, half_viewport)?}),
                json!({"input": "camera"}),
            )
        } else {
            ("project", json!({"splats": splats}), json!(half_viewport))
        };
        let plan = json!({
            "inputs": inputs,
            "steps": [{"id": "ellipses", "call": function, "args": [{"input": "splats"}, view]}],
            "outputs": ["ellipses"]
        });
        let session = engine.open(&plan, Backend::GpuRequired)?["session"]
            .as_u64()
            .ok_or("Missing Ink GPU session")?;
        let mut renderer = Self {
            engine,
            session,
            pipeline,
            viewport,
            half_viewport,
            bindings: None,
            count,
        };
        renderer.project(device)?;
        Ok(renderer)
    }

    pub fn project(&mut self, device: &wgpu::Device) -> Result<Value, String> {
        let outcomes = self.engine.step(self.session, 1)?;
        let view = self.engine.view(self.session, "ellipses")?;
        assert_ellipse_layout(&view)?;
        if view.capacity < self.count as usize {
            return Err("Insufficient ellipse capacity".into());
        }
        if self.bindings.as_ref().map(|(buffer, _)| buffer) != Some(&view.buffer) {
            let bindings = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("Resident Ink ellipse output"),
                layout: &self.pipeline.get_bind_group_layout(0),
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: view.buffer.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: self.viewport.as_entire_binding(),
                    },
                ],
            });
            self.bindings = Some((view.buffer, bindings));
        }
        Ok(outcomes["counters"].clone())
    }

    pub fn update(&mut self, device: &wgpu::Device, splats: &Value) -> Result<Value, String> {
        let count = splat_count(splats)?;
        self.engine.write(self.session, "splats", splats)?;
        self.count = count;
        self.project(device)
    }

    pub fn stage_ranges(&mut self, ranges: &[(usize, Value)]) -> Result<Value, String> {
        self.engine.write_ranges(self.session, "splats", ranges)
    }

    pub fn update_camera(
        &mut self,
        device: &wgpu::Device,
        camera: &Value,
    ) -> Result<Value, String> {
        self.engine.write(
            self.session,
            "camera",
            &camera_input(camera, self.half_viewport)?,
        )?;
        self.project(device)
    }

    pub fn draw(&self, encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView) {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("Ink Studio Gaussian raster"),
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
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(
            0,
            &self.bindings.as_ref().expect("renderer prepared").1,
            &[],
        );
        pass.draw(0..4, 0..self.count);
    }
}

fn camera_input(camera: &Value, half_viewport: [f32; 2]) -> Result<Value, String> {
    let mut camera = camera
        .as_object()
        .ok_or("Expected a camera object")?
        .clone();
    camera.insert("half_viewport".into(), json!(half_viewport));
    Ok(Value::Object(camera))
}

fn splat_count(splats: &Value) -> Result<u32, String> {
    let count = splats
        .as_array()
        .ok_or("Expected an array of splats")?
        .len();
    u32::try_from(count).map_err(|_| "Too many splats".into())
}

fn assert_ellipse_layout(view: &View) -> Result<(), String> {
    let vector = json!({"kind": "vector", "element": {"kind": "f32"}, "size": 2});
    let fields = json!([
        {"name": "center", "type": vector},
        {"name": "axis_x", "type": vector},
        {"name": "axis_y", "type": vector},
        {"name": "rgb", "type": {"kind": "u32"}},
        {"name": "alpha", "type": {"kind": "f32"}}
    ]);
    if !view.header
        || view.offset != 4
        || view.ty["kind"] != "list"
        || view.ty["element"]["fields"] != fields
    {
        return Err("Unexpected Ink ellipse buffer layout".into());
    }
    Ok(())
}
