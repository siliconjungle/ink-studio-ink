use cw_zlib::{HashVariant, OutputSchedule};

pub(super) struct Raster<'a> {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub pixels: &'a [u32],
    pub colors: &'a [u32],
    pub coverage: &'a [u32],
}

fn filtered_rows(raster: &Raster<'_>) -> Vec<u8> {
    let width = raster.width as usize;
    let mut bytes =
        Vec::with_capacity((width * raster.channels as usize + 1) * raster.height as usize);
    for row in raster.pixels.chunks_exact(width) {
        bytes.push(0);
        if raster.channels == 1 {
            bytes.extend(row.iter().map(|&value| value as u8));
        } else {
            bytes.extend(row.iter().flat_map(|&value| value.to_be_bytes()));
        }
    }
    bytes
}

fn deflate(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let capacity = bytes.len() + bytes.len() / 8 + 64;
    // Studio's original Node encoder and Chrome use Chromium's match hashing.
    cw_zlib::compress(
        bytes,
        6,
        15,
        8,
        0,
        HashVariant::Chromium,
        &OutputSchedule::node(capacity),
    )
    .map_err(|error| format!("PNG compression failed ({error:?})"))
}

fn chunk(out: &mut Vec<u8>, tag: &[u8; 4], bytes: &[u8]) {
    out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    let start = out.len();
    out.extend_from_slice(tag);
    out.extend_from_slice(bytes);
    out.extend_from_slice(&crc32fast::hash(&out[start..]).to_be_bytes());
}

pub(super) fn encode(raster: Raster<'_>, metadata: &[u8]) -> Result<Vec<u8>, String> {
    let data = deflate(&filtered_rows(&raster))?;
    let ink = deflate(metadata)?;
    let mut out = Vec::with_capacity(
        data.len() + ink.len() + raster.colors.len() * 3 + raster.coverage.len() + 93,
    );
    out.extend_from_slice(b"\x89PNG\r\n\x1a\n");
    let mut header = [0; 13];
    header[..4].copy_from_slice(&raster.width.to_be_bytes());
    header[4..8].copy_from_slice(&raster.height.to_be_bytes());
    header[8] = 8;
    header[9] = if raster.channels == 1 { 3 } else { 6 };
    chunk(&mut out, b"IHDR", &header);
    if raster.channels == 1 {
        let table: Vec<_> = raster
            .colors
            .iter()
            .flat_map(|&value| {
                let [_, r, g, b] = value.to_be_bytes();
                [r, g, b]
            })
            .collect();
        chunk(&mut out, b"PLTE", &table);
        if !raster.coverage.is_empty() {
            let alpha: Vec<_> = raster.coverage.iter().map(|&alpha| alpha as u8).collect();
            chunk(&mut out, b"tRNS", &alpha);
        }
    }
    chunk(&mut out, b"inKD", &ink);
    chunk(&mut out, b"IDAT", &data);
    chunk(&mut out, b"IEND", &[]);
    Ok(out)
}
