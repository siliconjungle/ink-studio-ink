use ink_studio_wgpu::{GaussianRenderer, WorldOrder};
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
        let mut encoder = device.create_command_encoder(&Default::default());
        renderer.draw(&mut encoder, &texture.create_view(&Default::default()));
        encoder.copy_texture_to_buffer(
            texture.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
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
        assert!(data[32 * 256 + lit_x * 4] > 170);
        assert!(data[32 * 256 + lit_x * 4 + 1] < 60);
        assert_eq!(
            &data[32 * 256 + dark_x * 4..32 * 256 + dark_x * 4 + 4],
            &[0, 0, 0, 255]
        );
        drop(data);
        readback.unmap();
    }
}
