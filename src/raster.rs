use image::{ImageFormat, ImageReader};
use std::cell::Cell;
use std::io::{self, BufRead, Cursor, Read, Seek, SeekFrom};

const MAX_DECODED_BYTES: u64 = 64 * 1024 * 1024;
const MAX_METADATA_BYTES: usize = 64 * 1024;

pub(crate) fn decoded_bytes(bytes: &[u8]) -> Option<u64> {
    let remaining = Cell::new(MAX_METADATA_BYTES);
    let format = image::guess_format(bytes).ok()?;
    if !matches!(
        format,
        ImageFormat::Png
            | ImageFormat::Jpeg
            | ImageFormat::Gif
            | ImageFormat::WebP
            | ImageFormat::Bmp
    ) {
        return None;
    }
    let headers = if format == ImageFormat::Jpeg {
        Some(
            Metadata {
                bytes,
                remaining: &remaining,
            }
            .jpeg_headers()?,
        )
    } else {
        None
    };
    let source = MetadataReader {
        cursor: Cursor::new(headers.as_deref().unwrap_or(bytes)),
        remaining: &remaining,
    };
    let mut reader = ImageReader::with_format(source, format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some((MAX_DECODED_BYTES / 8) as u32);
    limits.max_image_height = Some((MAX_DECODED_BYTES / 8) as u32);
    limits.max_alloc = Some(MAX_DECODED_BYTES);
    reader.limits(limits);
    let (width, height) = reader.into_dimensions().ok()?;
    let decoded = u64::from(width)
        .checked_mul(u64::from(height))?
        .checked_mul(8)?;
    if decoded == 0 || decoded > MAX_DECODED_BYTES {
        return None;
    }
    let mut metadata = Metadata {
        bytes,
        remaining: &remaining,
    };
    match format {
        ImageFormat::Gif => metadata.gif(width, height)?,
        ImageFormat::WebP => metadata.webp(width, height)?,
        _ => (),
    }
    Some(decoded)
}

struct MetadataReader<'a> {
    cursor: Cursor<&'a [u8]>,
    remaining: &'a Cell<usize>,
}

impl Read for MetadataReader<'_> {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        let limit = bytes.len().min(self.remaining.get());
        let read = self.cursor.read(&mut bytes[..limit])?;
        self.remaining.set(self.remaining.get() - read);
        Ok(read)
    }
}

impl BufRead for MetadataReader<'_> {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        let bytes = self.cursor.fill_buf()?;
        Ok(&bytes[..bytes.len().min(self.remaining.get())])
    }

    fn consume(&mut self, amount: usize) {
        let amount = amount.min(self.remaining.get());
        self.cursor.consume(amount);
        self.remaining.set(self.remaining.get() - amount);
    }
}

impl Seek for MetadataReader<'_> {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        self.cursor.seek(position)
    }
}

struct Metadata<'a> {
    bytes: &'a [u8],
    remaining: &'a Cell<usize>,
}

impl<'a> Metadata<'a> {
    fn read(&mut self, offset: usize, length: usize) -> Option<&'a [u8]> {
        self.remaining
            .set(self.remaining.get().checked_sub(length)?);
        self.bytes.get(offset..offset.checked_add(length)?)
    }

    fn skip(&self, offset: usize, length: usize) -> Option<usize> {
        let end = offset.checked_add(length)?;
        (end <= self.bytes.len()).then_some(end)
    }

    fn subblocks(&mut self, mut offset: usize) -> Option<usize> {
        loop {
            let length = usize::from(self.read(offset, 1)?[0]);
            offset = self.skip(offset + 1, length)?;
            if length == 0 {
                return Some(offset);
            }
        }
    }

    fn jpeg_headers(&mut self) -> Option<Vec<u8>> {
        let mut headers = self.read(0, 2)?.to_vec();
        let mut offset = 2;
        loop {
            if self.read(offset, 1)?[0] != 0xff {
                return None;
            }
            offset += 1;
            let mut marker = self.read(offset, 1)?[0];
            while marker == 0xff {
                offset += 1;
                marker = self.read(offset, 1)?[0];
            }
            if marker == 0 || marker == 1 || (0xd0..=0xd9).contains(&marker) {
                return None;
            }
            offset += 1;
            let length = self.read(offset, 2)?;
            let length = usize::from(u16::from_be_bytes([length[0], length[1]]));
            if length < 2 {
                return None;
            }
            let end = self.skip(offset, length)?;
            if (0xe0..=0xef).contains(&marker) || marker == 0xfe {
                offset = end;
                continue;
            }
            headers.extend([0xff, marker]);
            headers.extend(self.read(offset, length)?);
            if marker == 0xda {
                return Some(headers);
            }
            offset = end;
        }
    }

    fn gif(&mut self, width: u32, height: u32) -> Option<()> {
        let header = self.read(0, 13)?;
        let mut offset = self.skip(13, palette_bytes(header[10]))?;
        let mut frames = 0;
        loop {
            match self.read(offset, 1)?[0] {
                0x3b => return (frames > 0).then_some(()),
                0x21 => {
                    self.read(offset + 1, 1)?;
                    offset = self.subblocks(offset + 2)?;
                }
                0x2c => {
                    let frame = self.read(offset + 1, 9)?;
                    let left = little_endian_16(&frame[..2]);
                    let top = little_endian_16(&frame[2..4]);
                    let frame_width = little_endian_16(&frame[4..6]);
                    let frame_height = little_endian_16(&frame[6..8]);
                    fits(width, height, left, top, frame_width, frame_height)?;
                    offset = self.skip(offset + 10, palette_bytes(frame[8]))?;
                    if !(2..=8).contains(&self.read(offset, 1)?[0]) {
                        return None;
                    }
                    offset = self.subblocks(offset + 1)?;
                    frames += 1;
                }
                _ => return None,
            }
        }
    }

    fn webp(&mut self, width: u32, height: u32) -> Option<()> {
        let header = self.read(0, 12)?;
        let end = self.skip(8, little_endian_32(&header[4..8]) as usize)?;
        let mut offset = 12;
        let mut extended = false;
        let mut animated = false;
        let mut animation_header = false;
        let mut images = 0;
        while offset < end {
            let (kind, start, length, next) = self.chunk(offset, end)?;
            match kind {
                b"VP8X" => {
                    if offset != 12 || length != 10 {
                        return None;
                    }
                    let canvas = self.read(start, 10)?;
                    if little_endian_24(&canvas[4..7]) + 1 != width
                        || little_endian_24(&canvas[7..10]) + 1 != height
                    {
                        return None;
                    }
                    extended = true;
                    animated = canvas[0] & 2 != 0;
                }
                b"ANIM" => {
                    if !animated || animation_header || length != 6 {
                        return None;
                    }
                    self.read(start, 6)?;
                    animation_header = true;
                }
                b"ANMF" => {
                    if !animated || !animation_header || length < 16 {
                        return None;
                    }
                    let frame = self.read(start, 16)?;
                    let left = little_endian_24(&frame[..3]) * 2;
                    let top = little_endian_24(&frame[3..6]) * 2;
                    let frame_width = little_endian_24(&frame[6..9]) + 1;
                    let frame_height = little_endian_24(&frame[9..12]) + 1;
                    fits(width, height, left, top, frame_width, frame_height)?;
                    self.webp_frame(start + 16, start + length, frame_width, frame_height)?;
                    images += 1;
                }
                b"VP8 " | b"VP8L" => {
                    if animated || images != 0 {
                        return None;
                    }
                    self.webp_pixels(kind, start, length, width, height)?;
                    images += 1;
                }
                _ if !extended => return None,
                _ => (),
            }
            offset = next;
        }
        (offset == end && images > 0).then_some(())
    }

    fn chunk(&mut self, offset: usize, end: usize) -> Option<(&'a [u8], usize, usize, usize)> {
        let header = self.read(offset, 8)?;
        let length = little_endian_32(&header[4..8]) as usize;
        let start = offset.checked_add(8)?;
        let next = self.skip(start, length.checked_add(length & 1)?)?;
        (next <= end).then_some((&header[..4], start, length, next))
    }

    fn webp_frame(&mut self, mut offset: usize, end: usize, width: u32, height: u32) -> Option<()> {
        let mut found = false;
        while offset < end {
            let (kind, start, length, next) = self.chunk(offset, end)?;
            if kind == b"ALPH" && !found {
                offset = next;
                continue;
            }
            if found || !matches!(kind, b"VP8 " | b"VP8L") {
                return None;
            }
            self.webp_pixels(kind, start, length, width, height)?;
            found = true;
            offset = next;
        }
        (found && offset == end).then_some(())
    }

    fn webp_pixels(
        &mut self,
        kind: &[u8],
        offset: usize,
        length: usize,
        width: u32,
        height: u32,
    ) -> Option<()> {
        let (actual_width, actual_height) = if kind == b"VP8 " {
            if length < 10 {
                return None;
            }
            let header = self.read(offset, 10)?;
            if header[0] & 1 != 0 || header[3..6] != [0x9d, 0x01, 0x2a] {
                return None;
            }
            (
                little_endian_16(&header[6..8]) & 0x3fff,
                little_endian_16(&header[8..10]) & 0x3fff,
            )
        } else {
            if length < 5 {
                return None;
            }
            let header = self.read(offset, 5)?;
            let bits = little_endian_32(&header[1..5]);
            if header[0] != 0x2f || bits >> 29 != 0 {
                return None;
            }
            ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1)
        };
        (actual_width == width && actual_height == height).then_some(())
    }
}

fn palette_bytes(packed: u8) -> usize {
    if packed & 0x80 == 0 {
        0
    } else {
        3 * (2 << (packed & 7))
    }
}

fn fits(
    width: u32,
    height: u32,
    left: u32,
    top: u32,
    frame_width: u32,
    frame_height: u32,
) -> Option<()> {
    (frame_width > 0
        && frame_height > 0
        && left.checked_add(frame_width)? <= width
        && top.checked_add(frame_height)? <= height)
        .then_some(())
}

fn little_endian_16(bytes: &[u8]) -> u32 {
    u32::from(u16::from_le_bytes([bytes[0], bytes[1]]))
}

fn little_endian_24(bytes: &[u8]) -> u32 {
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], 0])
}

fn little_endian_32(bytes: &[u8]) -> u32 {
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine, engine::general_purpose::STANDARD};
    use serde::Deserialize;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Fixture {
        name: String,
        data: String,
        decoded_bytes: Option<u64>,
    }

    fn fixtures() -> Vec<Fixture> {
        serde_json::from_str(include_str!("../tests/fixtures/raster.json")).unwrap()
    }

    fn fixture(name: &str) -> Vec<u8> {
        STANDARD
            .decode(
                fixtures()
                    .into_iter()
                    .find(|fixture| fixture.name == name)
                    .unwrap()
                    .data,
            )
            .unwrap()
    }

    #[test]
    fn shared_metadata_fixtures() {
        for fixture in fixtures() {
            let bytes = STANDARD.decode(fixture.data).unwrap();
            assert_eq!(
                decoded_bytes(&bytes),
                fixture.decoded_bytes,
                "{}",
                fixture.name
            );
        }
    }

    #[test]
    fn accepted_small_fixtures_are_real_encoded_images() {
        for fixture in fixtures()
            .into_iter()
            .filter(|fixture| fixture.name.starts_with("small-"))
        {
            let bytes = STANDARD.decode(fixture.data).unwrap();
            let decoded = image::load_from_memory(&bytes).unwrap();
            assert_eq!(
                (decoded.width(), decoded.height()),
                (2, 3),
                "{}",
                fixture.name
            );
        }
    }

    #[test]
    fn compressed_payloads_do_not_exhaust_metadata_budget() {
        let mut jpeg = fixture("small-jpeg");
        jpeg.resize(128 * 1024, 0);
        assert_eq!(decoded_bytes(&jpeg), Some(48));

        let mut gif = fixture("small-gif");
        let blocks = [255].into_iter().chain([0; 255]).cycle().take(256 * 400);
        gif.splice(gif.len() - 2..gif.len() - 2, blocks);
        assert_eq!(decoded_bytes(&gif), Some(48));
        assert_eq!(image::load_from_memory(&gif).unwrap().width(), 2);

        let mut webp = fixture("small-webp-extended");
        let mut chunk = b"JUNK".to_vec();
        chunk.extend(100_000_u32.to_le_bytes());
        chunk.resize(100_008, 0);
        webp.splice(30..30, chunk);
        let size = (webp.len() as u32 - 8).to_le_bytes();
        webp[4..8].copy_from_slice(&size);
        assert_eq!(decoded_bytes(&webp), Some(48));
    }

    #[test]
    fn excessive_metadata_is_refused() {
        let mut gif = fixture("small-gif");
        gif.splice(25..25, [0x21, 0xfe, 0].into_iter().cycle().take(3 * 22_000));
        assert_eq!(decoded_bytes(&gif), None);
    }

    #[test]
    fn jpeg_application_payloads_are_skipped() {
        let small = fixture("small-jpeg");
        let mut bytes = small[..2].to_vec();
        for _ in 0..2 {
            bytes.extend([0xff, 0xe1]);
            bytes.extend(50_002_u16.to_be_bytes());
            bytes.resize(bytes.len() + 50_000, 0);
        }
        bytes.extend(&small[2..]);
        assert_eq!(image::load_from_memory(&bytes).unwrap().width(), 2);
        assert_eq!(decoded_bytes(&bytes), Some(48));
    }
}
