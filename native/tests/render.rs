use ink_studio_wgpu::GaussianRenderer;
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
    let mut rows = json!([{"center": [0, 0], "xx": 16, "xy": 0, "yy": 16,
        "variance": 0, "reach": 3, "rgb": 255, "alpha": 0.8}]);
    let mut renderer = GaussianRenderer::new(&device, &queue, format, [64, 64], &rows)
        .expect("resident Gaussian projection");
    for (color, lit_x, dark_x) in [(0, 32, 54), (1, 54, 32)] {
        if color == 1 {
            rows[0]["center"] = json!([22, 0]);
            rows[0]["rgb"] = json!(65280);
            renderer.update(&device, &rows).expect("resident update");
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
        assert!(data[32 * 256 + lit_x * 4 + color] > 170);
        assert_eq!(
            &data[32 * 256 + dark_x * 4..32 * 256 + dark_x * 4 + 4],
            &[0, 0, 0, 255]
        );
        drop(data);
        readback.unmap();
    }
}
