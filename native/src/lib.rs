use ink_gpu_program::{Backend, Engine, View};
use serde_json::{Value, json};
use wgpu::util::DeviceExt;

mod contours;
mod packed_inputs;
mod present;
#[path = "../../build/contour-render/render.rs"]
mod render;
pub use contours::ContourSettings;
use contours::ContourRaster;
pub use packed_inputs::{Bone, Camera, ContourLight, RigLight, WorldSplat};
use packed_inputs::{GpuWords, PackedInputs, binding};
pub use present::PixelPresenter;

pub struct GaussianRenderer {
    engine: Engine,
    session: u64,
    raster: Raster,
    viewport: wgpu::Buffer,
    half_viewport: [f32; 2],
    bindings: Option<(wgpu::Buffer, Bindings)>,
    draw_args: Option<wgpu::Buffer>,
    count: u32,
    skin_rows: u32,
    directional: bool,
    compacted_world: bool,
    packed_inputs: PackedInputs,
}

enum Raster {
    Smooth(wgpu::RenderPipeline),
    Contours(Box<ContourRaster>),
}

enum Bindings {
    Smooth(wgpu::BindGroup),
    Contours(render::RenderBindings),
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

#[derive(Clone, Copy, Default)]
pub struct ContourOptions {
    pub directional: bool,
    /// Select after measuring the renderer's scene and device.
    pub parallel_u64_merge: bool,
}

impl GaussianRenderer {
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
    ) -> Result<Self, String> {
        Self::create(device, queue, format, size, splats, None, None, ContourOptions::default(), false)
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
            ContourOptions::default(),
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
        Self::with_contour_options(device, queue, format, size, splats, camera, ordering, settings, ContourOptions::default())
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
        Self::with_contour_options(device, queue, format, size, splats, camera, ordering, settings,
            ContourOptions { directional: true, ..Default::default() })
    }

    pub fn with_contour_options(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: &Value,
        ordering: WorldOrder,
        settings: ContourSettings<'_>,
        options: ContourOptions,
    ) -> Result<Self, String> {
        Self::build_contours(device, queue, format, size, splats, camera, ordering, settings, options, false)
    }

    /// Keep camera-independent terrain normals resident between terrain writes.
    pub fn with_retained_terrain_contours(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: &Value,
        ordering: WorldOrder,
        settings: ContourSettings<'_>,
        options: ContourOptions,
    ) -> Result<Self, String> {
        Self::build_contours(device, queue, format, size, splats, camera, ordering, settings, options, true)
    }

    fn build_contours(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: &Value,
        ordering: WorldOrder,
        settings: ContourSettings<'_>,
        options: ContourOptions,
        retain_terrain: bool,
    ) -> Result<Self, String> {
        if matches!(ordering, WorldOrder::Preordered | WorldOrder::Actor(_)) {
            return Err("Colored Contours requires sorted world or skinned splats".into());
        }
        Self::create(device, queue, format, size, splats, Some((camera, ordering)), Some(settings), options, retain_terrain)
    }

    fn create(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        splats: &Value,
        camera: Option<(&Value, WorldOrder)>,
        contours: Option<ContourSettings<'_>>,
        options: ContourOptions,
        retain_terrain: bool,
    ) -> Result<Self, String> {
        if size.contains(&0) {
            return Err("Gaussian render target must have positive dimensions".into());
        }
        let count = splat_count(splats)?;
        let directional = options.directional;
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
        let compacted_world = !contour && camera.as_ref()
            .is_some_and(|(_, ordering)| matches!(ordering, WorldOrder::Sort));
        if options.parallel_u64_merge || compacted_world {
            engine.prefer_parallel_u64_merge()?;
        }
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
                WorldOrder::Sort => "project_visible_sorted_world",
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
        let retained_steps = if directional && retain_terrain {
            steps.push(json!({"id": "terrain-normals", "call": "prepare_contour_terrain",
                "args": [{"input": "splats"}]}));
            args[0] = json!({"step": "terrain-normals"});
            function = "project_prepared_lit_contour_scene";
            &["terrain-normals"][..]
        } else {
            &[]
        };
        steps.push(json!({"id": "ellipses", "call": function, "args": args}));
        let plan = json!({"inputs": inputs, "steps": steps, "outputs": ["ellipses"], "retained_steps": retained_steps});
        let count = count.checked_add(skin_rows).ok_or("Too many splats")?;
        let session = engine.open(&plan, Backend::GpuRequired)?["session"]
            .as_u64()
            .ok_or("Missing Ink GPU session")?;
        let draw_args = match (contour, device.adapter_info().backend) {
            (false, wgpu::Backend::Vulkan | wgpu::Backend::Metal | wgpu::Backend::Dx12 | wgpu::Backend::BrowserWebGpu) => {
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
            compacted_world,
            packed_inputs: PackedInputs::default(),
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
            let bindings = match &self.raster {
                Raster::Smooth(pipeline) => Bindings::Smooth(device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("Resident Ink ellipse output"),
                    layout: &pipeline.get_bind_group_layout(0),
                    entries: &[buffer_entry(0, &view.buffer), buffer_entry(1, &self.viewport)],
                })),
                Raster::Contours(contour) => Bindings::Contours(contour.bind(device, &view.buffer, &self.viewport)?),
            };
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

    /// Stage world-space rows encoded by `WorldSplat::pack`.
    pub fn stage_world_ranges(&mut self, ranges: Vec<(usize, Vec<u32>)>) -> Result<u64, String> {
        let input = binding(&mut self.packed_inputs.splats, &self.engine, self.session,
            "splats", packed_inputs::list::<WorldSplat>)?;
        upload_bytes(&self.engine.write_ranges_packed(input, ranges)?)
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

    /// Pass camera words straight into the resident projection.
    pub fn update_packed_camera(&mut self, device: &wgpu::Device, camera: Camera) -> Result<Value, String> {
        self.write_packed_camera(camera)?;
        self.project(device)
    }

    fn write_packed_camera(&mut self, mut camera: Camera) -> Result<(), String> {
        camera.half_viewport = self.half_viewport;
        let input = binding(&mut self.packed_inputs.camera, &self.engine, self.session, "camera", Camera::layout)?;
        self.engine.write_packed(input, camera.words())?;
        Ok(())
    }

    pub fn stage_packed_contour_lighting(&mut self, light: Option<ContourLight>) -> Result<(), String> {
        let Raster::Contours(contour) = &self.raster else {
            return Err("Enable directional Colored Contours first".into());
        };
        if !self.directional {
            return Err("Enable directional Colored Contours first".into());
        }
        let light = light.unwrap_or(ContourLight::OFF);
        if light.ambient.iter().chain(&light.key).any(|value| !value.is_finite()) {
            return Err("Invalid contour light".into());
        }
        let input = binding(&mut self.packed_inputs.contour_light, &self.engine, self.session,
            "contourLight", ContourLight::layout)?;
        self.engine.write_packed(input, light.words())?;
        contour.set_lighting(light.ambient, light.key, light.enabled);
        Ok(())
    }

    /// Update a native skinned frame without building a JSON rig or camera.
    pub fn update_packed_skin_camera(
        &mut self, device: &wgpu::Device, camera: Camera,
        bones: impl IntoIterator<Item = Bone>, light: RigLight,
    ) -> Result<u64, String> {
        let bones = bones.into_iter();
        let mut words = Vec::with_capacity(bones.size_hint().0.saturating_mul(12));
        for bone in bones { bone.append(&mut words); }
        let input = binding(&mut self.packed_inputs.bones, &self.engine, self.session,
            "bones", packed_inputs::list::<Bone>)?;
        let bone_bytes = upload_bytes(&self.engine.write_changed_packed(input, words)?)?;
        let input = binding(&mut self.packed_inputs.rig_light, &self.engine, self.session, "light", RigLight::layout)?;
        let light_bytes = upload_bytes(&self.engine.write_packed(input, light.words())?)?;
        self.write_packed_camera(camera)?;
        self.project(device)?;
        Ok(bone_bytes + light_bytes)
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
        Ok(upload_bytes(&bone_write)? + upload_bytes(&light_write)?)
    }

    /// Project and draw a sorted world camera update in one GPU submission.
    pub fn update_packed_camera_and_draw(
        &mut self, camera: Camera, target: &wgpu::TextureView,
    ) -> Result<Value, String> {
        if !self.compacted_world {
            return Err("combined camera draws require WorldOrder::Sort with the smooth renderer".into());
        }
        self.write_packed_camera(camera)?;
        let output = self.bindings.as_ref().expect("renderer prepared");
        let raster = &self.raster;
        let draw_args = self.draw_args.as_ref();
        let count = self.count;
        let outcome = self.engine.step_and_encode(self.session, |encoder| {
            Self::encode_draw(raster, output, draw_args, count, encoder, target);
        })?;
        Ok(outcome["counters"].clone())
    }

    pub fn draw(&self, encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView) {
        let output = self.bindings.as_ref().expect("renderer prepared");
        Self::encode_draw(&self.raster, output, self.draw_args.as_ref(), self.count, encoder, target);
    }

    fn encode_draw(
        raster: &Raster, (ellipses, bindings): &(wgpu::Buffer, Bindings),
        draw_args: Option<&wgpu::Buffer>, count: u32,
        encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView,
    ) {
        let (pipeline, bindings) = match (raster, bindings) {
            (Raster::Smooth(pipeline), Bindings::Smooth(bindings)) => (pipeline, bindings),
            (Raster::Contours(contour), Bindings::Contours(bindings)) => {
                contour.draw(encoder, target, bindings, count);
                return;
            }
            _ => unreachable!("bindings have the same raster as their renderer"),
        };
        let draw = if let Some(args) = draw_args {
            // Ink's list header is the compacted row count. A GPU copy patches instance_count.
            encoder.copy_buffer_to_buffer(ellipses, 0, args, 4, 4);
            SplatDraw::Visible(args)
        } else {
            SplatDraw::Capacity(count)
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

fn upload_bytes(result: &Value) -> Result<u64, String> {
    result["counters"]["upload_bytes"].as_u64().ok_or("Missing input upload count".into())
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
