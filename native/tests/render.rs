use ink_gpu_program::{Backend, Engine};
use ink_studio_wgpu::{ContourSettings, GaussianRenderer, WorldOrder};
use serde_json::json;

#[test]
fn computes_and_draws_from_the_same_device_buffer() {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
    let adapter =
        pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .expect("native GPU adapter");
    let (device, queue) =
        pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default()))
            .expect("native GPU device");
    let format = wgpu::TextureFormat::Rgba8Unorm;
    let size = wgpu::Extent3d {
        width: 64,
        height: 64,
        depth_or_array_layers: 1,
    };
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("Gaussian integration fixture"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("Fixture image readback"),
        size: 64 * 64 * 4,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let rows = json!([
        {"position": [0, 0, -2], "covariance0": [16, 0, 0],
            "covariance1": [16, 0, 0], "reach": 3, "rgb": 255, "alpha": 0.8},
        {"position": [0, 0, -3], "covariance0": [16, 0, 0],
            "covariance1": [16, 0, 0], "reach": 3, "rgb": 65280, "alpha": 0.8}
    ]);
    let mut camera = json!({"eye": [0, 0, 0], "right": [1, 0, 0], "up": [0, 1, 0],
        "back": [0, 0, 1], "focal": 1, "near_clip": 0.1, "far_clip": 10, "variance": 0,
        "perspective": false});
    let mut renderer = GaussianRenderer::with_camera(
        &device,
        &queue,
        format,
        [64, 64],
        &rows,
        &camera,
        WorldOrder::Sort,
    )
    .expect("resident world projection");
    for (lit_x, dark_x) in [(32, 54), (54, 32)] {
        if lit_x == 54 {
            camera["eye"] = json!([-22, 0, 0]);
            let counters = renderer
                .update_camera(&device, &camera)
                .expect("resident camera update");
            assert!(counters["dispatches"].as_u64().unwrap() > 0);
        }
        let data = draw_fixture(&device, &queue, &texture, &readback, &renderer);
        assert!(data[32 * 256 + lit_x * 4] > 170);
        assert!(data[32 * 256 + lit_x * 4 + 1] < 60);
        assert_eq!(
            &data[32 * 256 + dark_x * 4..32 * 256 + dark_x * 4 + 4],
            &[0, 0, 0, 255]
        );
    }

    camera["eye"] = json!([500, 0, 0]);
    renderer.update_camera(&device, &camera).unwrap();
    let hidden = draw_fixture(&device, &queue, &texture, &readback, &renderer);
    assert!(hidden.chunks_exact(4).all(|pixel| pixel == [0, 0, 0, 255]));
    camera["eye"] = json!([0, 0, 0]);
    renderer.update_camera(&device, &camera).unwrap();
    let restored = draw_fixture(&device, &queue, &texture, &readback, &renderer);
    assert!(restored[32 * 256 + 32 * 4] > 170);

    let solid = json!([{"position": [0.25, 0.25, -2], "covariance0": [4, 0, 0],
        "covariance1": [4, 0, 0], "reach": 3, "rgb": 255, "alpha": 1}]);
    let contour = GaussianRenderer::with_contours(&device, &queue, format, [64, 64], &solid,
        &camera, WorldOrder::Sort, ContourSettings {
            colors: &[0x101820, 0xff0000], grade: None, dither: 0.0, occlusion: 0.0,
            occlusion_reach: 1.0, depth_near: 0.0, depth_span: 10.0, hard: true,
        }).expect("Colored Contours world projection");
    let data = draw_fixture(&device, &queue, &texture, &readback, &contour);
    assert_eq!(&data[..4], &[16, 24, 32, 255]);
    assert_eq!(&data[31 * 256 + 32 * 4..31 * 256 + 33 * 4], &[255, 0, 0, 255]);
    assert!(data.chunks_exact(4).any(|pixel| pixel[0] > 16 && pixel[0] < 255));
}

fn draw_fixture(device: &wgpu::Device, queue: &wgpu::Queue, texture: &wgpu::Texture,
    readback: &wgpu::Buffer, renderer: &GaussianRenderer) -> Vec<u8> {
    let size = wgpu::Extent3d { width: texture.width(), height: texture.height(), depth_or_array_layers: 1 };
    let mut encoder = device.create_command_encoder(&Default::default());
    renderer.draw(&mut encoder, &texture.create_view(&Default::default()));
    encoder.copy_texture_to_buffer(
        texture.as_image_copy(),
        wgpu::TexelCopyBufferInfo {
            buffer: readback,
            layout: wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(256),
                rows_per_image: Some(64),
            },
        },
        size,
    );
    queue.submit([encoder.finish()]);
    let (tx, rx) = std::sync::mpsc::channel();
    readback
        .slice(..)
        .map_async(wgpu::MapMode::Read, move |result| tx.send(result).unwrap());
    device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
    rx.recv().unwrap().unwrap();
    let data = readback.slice(..).get_mapped_range().unwrap();
    let pixels = data.to_vec();
    drop(data);
    readback.unmap();
    pixels
}

#[test]
fn uploads_only_changed_rig_transforms() {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default()))
        .expect("native GPU adapter");
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default()))
        .expect("native GPU device");
    let bone = json!({"axis_x": [1, 0, 0], "axis_y": [0, 1, 0], "axis_z": [0, 0, 1], "offset": [0, 0, 0]});
    let light = json!({"sun": [0, 1, 0], "ambient": 1, "diffuse": 0, "blink": 1});
    let rest = json!([{"center": [0, 0, -2], "covariance0": [1, 0, 0], "covariance1": [1, 0, 1],
        "normal": [0, 1, 0], "joints": [1, 1], "weight": 0, "shade": 0, "palette": [255, 0, 0, 0],
        "tones": 1, "eye": false, "alpha": 1}]);
    let bones = json!([bone, bone, bone]);
    let mut changed = bones.clone();
    changed[1]["offset"][0] = json!(4);
    let mut signed_zero = changed.clone();
    signed_zero[1]["offset"][1] = json!(-0.0);

    let camera = json!({"eye": [0, 0, 0], "right": [1, 0, 0], "up": [0, 1, 0], "back": [0, 0, 1],
        "focal": 1, "near_clip": 0.1, "far_clip": 10, "variance": 0, "perspective": false});
    let mut renderer = GaussianRenderer::with_camera(&device, &queue, wgpu::TextureFormat::Rgba8Unorm,
        [64, 64], &json!([]), &camera, WorldOrder::Skinned { rest: rest.clone(), bones: bones.clone(), light: light.clone() })
        .expect("skinned renderer");
    for (pose, bytes) in [(&bones, 4 + 3 * 48 + 24), (&changed, 48 + 24), (&signed_zero, 48 + 24), (&signed_zero, 24)] {
        assert_eq!(renderer.update_skin_camera(&device, &camera, pose, &light).unwrap(), bytes);
    }

    let mut engine = Engine::with_device(device, queue);
    let plan = json!({
        "inputs": {"bones": bones, "rest": rest, "light": light},
        "steps": [{"id": "posed", "call": "skin_world", "args": [{"input": "rest"}, {"input": "bones"}, {"input": "light"}]}],
        "outputs": ["posed"],
    });
    let session = engine.open(&plan, Backend::GpuRequired).unwrap()["session"].as_u64().unwrap();
    engine.write_changed(session, "bones", &bones).unwrap();
    engine.write_changed(session, "bones", &changed).unwrap();
    engine.step(session, 1).unwrap();
    let output = engine.read(session, &json!({"outputs": ["posed"]})).unwrap();
    assert_eq!(output["values"]["posed"][0]["position"], json!([4.0, 0.0, -2.0]));
    assert!(engine.write_ranges(session, "bones", &[(3, json!([bone]))]).is_err());
    assert_eq!(engine.write_changed(session, "bones", &changed).unwrap()["counters"]["upload_bytes"], 0);
    engine.write_ranges(session, "bones", &[(1, json!([bone]))]).unwrap();
    assert_eq!(engine.write_changed(session, "bones", &changed).unwrap()["counters"]["upload_bytes"], 4 + 3 * 48);
    engine.write(session, "bones", &bones).unwrap();
    assert_eq!(engine.write_changed(session, "bones", &changed).unwrap()["counters"]["upload_bytes"], 4 + 3 * 48);
    engine.step(session, 1).unwrap();
    let output = engine.read(session, &json!({"outputs": ["posed"]})).unwrap();
    assert_eq!(output["values"]["posed"][0]["position"], json!([4.0, 0.0, -2.0]));
}
