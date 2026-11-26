use ink_gpu_program::{Backend, Engine, View};
use serde_json::{Value, json};
use wgpu::util::DeviceExt;

mod contours;
mod present;
pub use contours::ContourSettings;
use contours::ContourRaster;
pub use present::PixelPresenter;

pub struct GaussianRenderer {
    engine: Engine,
    session: u64,
    raster: Raster,
    viewport: wgpu::Buffer,
    half_viewport: [f32; 2],
    bindings: Option<(wgpu::Buffer, wgpu::BindGroup)>,
    draw_args: Option<wgpu::Buffer>,
    count: u32,
    skin_rows: u32,
    directional: bool,
}

enum Raster {
    Smooth(wgpu::RenderPipeline),
    Contours(Box<ContourRaster>),
}

enum SplatDraw<'a> {
    Visible(&'a wgpu::Buffer),
    Capacity(u32),
}

impl SplatDraw<'_> {
    fn raster(&self, pass: &mut wgpu::RenderPass<'_>) {
        match self {
            Self::Visible(args) => pass.draw_indirect(args, 0),
            Self::Capacity(count) => pass.draw(0..4, 0..*count),
        }
    }
}

pub enum WorldOrder {
    Sort,
    Preordered,
    Actor(Value),
    Skinned {
        rest: Value,
        bones: Value,
        light: Value,
    },
}

impl GaussianRenderer {
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
    ) -> Result<Self, String> {
        Self::create(device, queue, format, size, splats, None, None, false)
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
            None,
            false,
        )
    }

    pub fn with_contours(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: &Value,
        ordering: WorldOrder,
        settings: ContourSettings<'_>,
    ) -> Result<Self, String> {
        Self::with_contour_mode(device, queue, format, size, splats, camera, ordering, settings, false)
    }

    pub fn with_directional_contours(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: &Value,
        ordering: WorldOrder,
        settings: ContourSettings<'_>,
    ) -> Result<Self, String> {
        Self::with_contour_mode(device, queue, format, size, splats, camera, ordering, settings, true)
    }

    fn with_contour_mode(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: &Value,
        ordering: WorldOrder,
        settings: ContourSettings<'_>,
        directional: bool,
    ) -> Result<Self, String> {
        if matches!(ordering, WorldOrder::Preordered | WorldOrder::Actor(_)) {
            return Err("Colored Contours requires sorted world or skinned splats".into());
        }
        Self::create(device, queue, format, size, splats, Some((camera, ordering)), Some(settings), directional)
    }

    fn create(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: Option<(&Value, WorldOrder)>,
        contours: Option<ContourSettings<'_>>,
        directional: bool,
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
        let raster = if let Some(settings) = contours {
            Raster::Contours(Box::new(ContourRaster::new(device, queue, format, size, settings)?))
        } else {
            let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("Ink Studio Gaussian raster"),
                source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/gaussian.wgsl").into()),
            });
            Raster::Smooth(device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
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
            }))
        };
        let contour = matches!(raster, Raster::Contours(_));
        let mut engine = Engine::with_device(device.clone(), queue.clone());
        let mut inputs = json!({"splats": splats});
        let mut args = vec![json!({"input": "splats"})];
        let mut steps = Vec::new();
        let mut skin_rows = 0;
        let mut function = if let Some((camera, ordering)) = camera {
            inputs["camera"] = camera_input(camera, half_viewport)?;
            args.push(json!({"input": "camera"}));
            match ordering {
                WorldOrder::Sort if contour => {
                    inputs["actors"] = json!([]);
                    args.insert(1, json!({"input": "actors"}));
                    "project_contour_scene"
                }
                WorldOrder::Sort => "project_sorted_world",
                WorldOrder::Preordered => "project_world",
                WorldOrder::Actor(placement) => {
                    inputs["actor"] = placement;
                    args.push(json!({"input": "actor"}));
                    "project_sorted_actor"
                }
                WorldOrder::Skinned { rest, bones, light } => {
                    skin_rows = splat_count(&rest)?;
                    inputs["rest"] = rest;
                    inputs["bones"] = bones;
                    inputs["light"] = light;
                    steps.push(json!({"id": "posed", "call": "skin_world",
                        "args": [{"input": "rest"}, {"input": "bones"}, {"input": "light"}]}));
                    args.insert(1, json!({"step": "posed"}));
                    if contour { "project_contour_scene" } else { "project_sorted_scene" }
                }
            }
        } else {
            args.push(json!(half_viewport));
            "project"
        };
        if directional {
            inputs["contourLight"] = contour_light_off();
            args.push(json!({ "input": "contourLight" }));
            function = "project_lit_contour_scene";
        }
        steps.push(json!({"id": "ellipses", "call": function, "args": args}));
        let plan = json!({"inputs": inputs, "steps": steps, "outputs": ["ellipses"]});
        let count = count.checked_add(skin_rows).ok_or("Too many splats")?;
        let session = engine.open(&plan, Backend::GpuRequired)?["session"]
            .as_u64()
            .ok_or("Missing Ink GPU session")?;
        let draw_args = match device.adapter_info().backend {
            wgpu::Backend::Vulkan | wgpu::Backend::Metal | wgpu::Backend::Dx12 | wgpu::Backend::BrowserWebGpu => {
                let args = wgpu::util::DrawIndirectArgs { vertex_count: 4, ..Default::default() };
                Some(device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("Visible splat draw arguments"),
                    contents: args.as_bytes(),
                    usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::INDIRECT,
                }))
            }
            _ => None,
        };
        let mut renderer = Self {
            engine,
            session,
            raster,
            viewport,
            half_viewport,
            bindings: None,
            draw_args,
            count,
            skin_rows,
            directional,
        };
        renderer.project(device)?;
        Ok(renderer)
    }

    pub fn project(&mut self, device: &wgpu::Device) -> Result<Value, String> {
        let outcomes = self.engine.step(self.session, 1)?;
        let view = self.engine.view(self.session, "ellipses")?;
        assert_ellipse_layout(&view, matches!(self.raster, Raster::Contours(_)))?;
        if view.capacity < self.count as usize {
            return Err("Insufficient ellipse capacity".into());
        }
        if self.bindings.as_ref().map(|(buffer, _)| buffer) != Some(&view.buffer) {
            let plain_layout;
            let (layout, entries) = match &self.raster {
                Raster::Smooth(pipeline) => {
                    plain_layout = pipeline.get_bind_group_layout(0);
                    (&plain_layout, vec![buffer_entry(0, &view.buffer), buffer_entry(1, &self.viewport)])
                }
                Raster::Contours(contour) => (&contour.layout,
                    vec![buffer_entry(3, &contour.palette), buffer_entry(5, &view.buffer), buffer_entry(6, &self.viewport)]),
            };
            let bindings = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("Resident Ink ellipse output"),
                layout,
                entries: &entries,
            });
            self.bindings = Some((view.buffer, bindings));
        }
        Ok(outcomes["counters"].clone())
    }

    pub fn update(&mut self, device: &wgpu::Device, splats: &Value) -> Result<Value, String> {
        let count = splat_count(splats)?
            .checked_add(self.skin_rows)
            .ok_or("Too many splats")?;
        self.engine.write(self.session, "splats", splats)?;
        self.count = count;
        self.project(device)
    }

    pub fn stage_ranges(&mut self, ranges: &[(usize, Value)]) -> Result<Value, String> {
        self.engine.write_ranges(self.session, "splats", ranges)
    }

    /// Replaces the display colors, or restores the original grade with `None`.
    pub fn set_contour_grade(&self, grade: Option<&[[f32; 3]]>) -> Result<(), String> {
        match &self.raster {
            Raster::Contours(contour) => contour.set_grade(grade),
            Raster::Smooth(_) => Err("A contour grade requires Colored Contours".into()),
        }
    }

    /// Stages light for the next projection without replacing resident splats.
    pub fn stage_contour_lighting(&mut self, light: Option<&Value>) -> Result<(), String> {
        let Raster::Contours(contour) = &self.raster else {
            return Err("Enable directional Colored Contours first".into());
        };
        if !self.directional {
            return Err("Enable directional Colored Contours first".into());
        }
        let disabled;
        let frame = match light {
            Some(frame) => frame,
            None => { disabled = contour_light_off(); &disabled }
        };
        let rgb = |field: &str| -> Result<[f32; 3], String> {
            let values = serde_json::from_value::<[f32; 3]>(frame[field].clone()).map_err(|e| e.to_string())?;
            if values.iter().any(|value| !value.is_finite()) {
                return Err("Invalid contour light".into());
            }
            Ok(values)
        };
        let ambient = rgb("ambient")?;
        let key = rgb("key")?;
        let enabled = frame["enabled"].as_bool().ok_or("Missing contour light enable flag")?;
        self.engine.write(self.session, "contourLight", frame)?;
        contour.set_lighting(ambient, key, enabled);
        Ok(())
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

    pub fn update_actor_camera(
        &mut self,
        device: &wgpu::Device,
        camera: &Value,
        placement: &Value,
    ) -> Result<Value, String> {
        self.engine.write(self.session, "actor", placement)?;
        self.update_camera(device, camera)
    }

    pub fn update_skin_camera(
        &mut self,
        device: &wgpu::Device,
        camera: &Value,
        bones: &Value,
        light: &Value,
    ) -> Result<u64, String> {
        let camera = camera_input(camera, self.half_viewport)?;
        let bone_write = self.engine.write_changed(self.session, "bones", bones)?;
        let light_write = self.engine.write(self.session, "light", light)?;
        self.engine.write(self.session, "camera", &camera)?;
        self.project(device)?;
        let upload_bytes = |result: &Value| {
            result["counters"]["upload_bytes"]
                .as_u64()
                .ok_or("Missing rig upload count")
        };
        Ok(upload_bytes(&bone_write)? + upload_bytes(&light_write)?)
    }

    pub fn draw(&self, encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView) {
        let (ellipses, bindings) = self.bindings.as_ref().expect("renderer prepared");
        let draw = if let Some(args) = &self.draw_args {
            // Ink's list header is the compacted row count. A GPU copy patches instance_count.
            encoder.copy_buffer_to_buffer(ellipses, 0, args, 4, 4);
            SplatDraw::Visible(args)
        } else {
            SplatDraw::Capacity(self.count)
        };
        let pipeline = match &self.raster {
            Raster::Smooth(pipeline) => pipeline,
            Raster::Contours(contour) => {
                contour.draw(encoder, target, bindings, &draw);
                return;
            }
        };
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
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, bindings, &[]);
        draw.raster(&mut pass);
    }
}

fn buffer_entry(binding: u32, buffer: &wgpu::Buffer) -> wgpu::BindGroupEntry<'_> {
    wgpu::BindGroupEntry { binding, resource: buffer.as_entire_binding() }
}

fn contour_light_off() -> Value {
    json!({ "enabled": false, "direction": [0,1,0], "actor_center": [0,0,0], "actor_rows": 0,
        "ambient": [1,1,1], "key": [0,0,0] })
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

fn assert_ellipse_layout(view: &View, contour: bool) -> Result<(), String> {
    let vector = json!({"kind": "vector", "element": {"kind": "f32"}, "size": 2});
    let mut fields = vec![
        json!({"name": "center", "type": vector}),
        json!({"name": "axis_x", "type": vector}),
        json!({"name": "axis_y", "type": vector}),
    ];
    if contour {
        fields.extend([json!({"name": "high_axis_x", "type": vector}), json!({"name": "high_axis_y", "type": vector})]);
    }
    fields.extend([json!({"name": "rgb", "type": {"kind": "u32"}}), json!({"name": "alpha", "type": {"kind": "f32"}})]);
    if contour {
        fields.push(json!({"name": "depth", "type": {"kind": "f32"}}));
    }
    if !view.header
        || view.offset != 4
        || view.ty["kind"] != "list"
        || view.ty["element"]["fields"] != Value::Array(fields)
    {
        return Err("Unexpected Ink ellipse buffer layout".into());
    }
    Ok(())
}
