use base64::{Engine, engine::general_purpose::STANDARD};
use image::{ImageReader, RgbaImage, imageops};
use std::io::Cursor;

const SIZE: u32 = 256;

pub(super) fn prepare(data: &str, organization: bool) -> Result<String, &'static str> {
    let encoded = data.split_once(";base64,").ok_or("public_image_refused")?.1;
    if encoded.len() > 7 * 1024 * 1024 {
        return Err("public_response_too_large");
    }
    let bytes = STANDARD
        .decode(encoded)
        .map_err(|_| "public_image_refused")?;
    let original = decode(bytes)?;
    let mut canvas = if organization {
        let edge = (SIZE as f64 * std::f64::consts::FRAC_1_SQRT_2 * 0.70).floor() as u32;
        let logo = original
            .resize(edge, edge, imageops::FilterType::Lanczos3)
            .to_rgba8();
        let mut canvas = RgbaImage::new(SIZE, SIZE);
        imageops::overlay(
            &mut canvas,
            &logo,
            ((SIZE - logo.width()) / 2).into(),
            ((SIZE - logo.height()) / 2).into(),
        );
        canvas
    } else {
        original
            .resize_to_fill(SIZE, SIZE, imageops::FilterType::Lanczos3)
            .to_rgba8()
    };
    if !organization {
        let radius = SIZE as f64 / 2.0;
        for (x, y, pixel) in canvas.enumerate_pixels_mut() {
            let distance = (x as f64 + 0.5 - radius).hypot(y as f64 + 0.5 - radius);
            let coverage = (radius + 0.5 - distance).clamp(0.0, 1.0);
            pixel[3] = (pixel[3] as f64 * coverage).round() as u8;
        }
    }
    let mut output = Cursor::new(Vec::new());
    canvas
        .write_to(&mut output, image::ImageFormat::Png)
        .map_err(|_| "public_image_refused")?;
    Ok(format!(
        "data:image/png;base64,{}",
        STANDARD.encode(output.into_inner())
    ))
}

fn decode(bytes: Vec<u8>) -> Result<image::DynamicImage, &'static str> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|_| "public_image_refused")?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    reader.decode().map_err(|_| "public_image_refused")
}

/// A fetched picture re-encoded as PNG for the image model: decoded under the same limits as an
/// avatar, at least 256 and at most 1024 pixels on its longer edge, so only pixels leave Magpie.
#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
pub(in crate::inbox) fn reference(data: &str) -> Result<Vec<u8>, &'static str> {
    let encoded = data.split_once(";base64,").ok_or("public_image_refused")?.1;
    if encoded.len() > 7 * 1024 * 1024 {
        return Err("public_response_too_large");
    }
    let bytes = STANDARD
        .decode(encoded)
        .map_err(|_| "public_image_refused")?;
    let original = decode(bytes)?;
    let edge = original.width().max(original.height());
    if edge == 0 {
        return Err("public_image_refused");
    }
    let target = edge.clamp(256, 1024);
    let picture = if target == edge {
        original.to_rgba8()
    } else {
        let scale = f64::from(target) / f64::from(edge);
        let width = ((f64::from(original.width()) * scale).round() as u32).max(1);
        let height = ((f64::from(original.height()) * scale).round() as u32).max(1);
        original
            .resize_exact(width, height, imageops::FilterType::Lanczos3)
            .to_rgba8()
    };
    let mut output = Cursor::new(Vec::new());
    picture
        .write_to(&mut output, image::ImageFormat::Png)
        .map_err(|_| "public_image_refused")?;
    Ok(output.into_inner())
}

/// A painted picture kept for Magpie: the model's square image as a 512-pixel JPEG. It is opaque,
/// so the circle is cut when it is shown, through the photo branch of `prepare`.
#[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
pub(in crate::inbox) fn master(bytes: Vec<u8>) -> Result<Vec<u8>, &'static str> {
    const EDGE: u32 = 512;
    let painted = decode(bytes)?;
    let square = painted
        .resize_to_fill(EDGE, EDGE, imageops::FilterType::Lanczos3)
        .to_rgb8();
    let mut output = Cursor::new(Vec::new());
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut output, 90)
        .encode_image(&square)
        .map_err(|_| "public_image_refused")?;
    Ok(output.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encoded(image: RgbaImage) -> String {
        let mut output = Cursor::new(Vec::new());
        image
            .write_to(&mut output, image::ImageFormat::Png)
            .unwrap();
        format!(
            "data:image/png;base64,{}",
            STANDARD.encode(output.into_inner())
        )
    }

    fn decoded(data: &str) -> RgbaImage {
        image::load_from_memory(&STANDARD.decode(data.split_once(',').unwrap().1).unwrap())
            .unwrap()
            .to_rgba8()
    }

    #[test]
    fn photos_fill_circle_without_square_corners() {
        let photo = encoded(RgbaImage::from_pixel(
            400,
            200,
            image::Rgba([80, 120, 160, 255]),
        ));
        let result = decoded(&prepare(&photo, false).unwrap());
        assert_eq!(result.dimensions(), (SIZE, SIZE));
        assert_eq!(result.get_pixel(0, 0)[3], 0);
        assert!(result.get_pixel(128, 0)[3] > 240);
        assert_eq!(result.get_pixel(128, 128).0, [80, 120, 160, 255]);
    }

    #[test]
    fn saved_logos_have_transparent_clearance_and_preserve_aspect() {
        let logo = encoded(RgbaImage::from_pixel(
            400,
            200,
            image::Rgba([80, 120, 160, 255]),
        ));
        let result = decoded(&prepare(&logo, true).unwrap());
        let points: Vec<_> = result
            .enumerate_pixels()
            .filter(|(_, _, p)| p[3] > 0)
            .collect();
        let min_x = points.iter().map(|(x, _, _)| *x).min().unwrap();
        let max_x = points.iter().map(|(x, _, _)| *x).max().unwrap();
        let min_y = points.iter().map(|(_, y, _)| *y).min().unwrap();
        let max_y = points.iter().map(|(_, y, _)| *y).max().unwrap();
        assert!(min_x >= 64 && max_x < 192);
        assert_eq!(max_x - min_x + 1, 2 * (max_y - min_y + 1));
        assert_eq!(result.get_pixel(0, 128)[3], 0);
    }

    #[cfg(all(feature = "agent", unix, not(target_os = "ios")))]
    #[test]
    fn references_are_bounded_png_and_masters_fill_the_circle() {
        let small = encoded(RgbaImage::from_pixel(32, 16, image::Rgba([10, 20, 30, 255])));
        let png = reference(&small).unwrap();
        assert_eq!(image::guess_format(&png).unwrap(), image::ImageFormat::Png);
        assert_eq!(image::load_from_memory(&png).unwrap().width(), 256);
        let large = encoded(RgbaImage::from_pixel(2048, 1024, image::Rgba([10, 20, 30, 255])));
        let png = reference(&large).unwrap();
        let picture = image::load_from_memory(&png).unwrap();
        assert_eq!((picture.width(), picture.height()), (1024, 512));
        assert!(reference("data:image/png;base64,bm90IGFuIGltYWdl").is_err());
        let painted = {
            let mut output = Cursor::new(Vec::new());
            RgbaImage::from_pixel(1024, 1024, image::Rgba([240, 230, 210, 255]))
                .write_to(&mut output, image::ImageFormat::Png)
                .unwrap();
            output.into_inner()
        };
        let jpeg = master(painted).unwrap();
        assert_eq!(image::guess_format(&jpeg).unwrap(), image::ImageFormat::Jpeg);
        assert_eq!(image::load_from_memory(&jpeg).unwrap().width(), 512);
        let shown = decoded(&prepare(&format!("data:image/jpeg;base64,{}", STANDARD.encode(jpeg)), false).unwrap());
        assert_eq!(shown.get_pixel(0, 0)[3], 0);
        assert!(shown.get_pixel(128, 1)[3] > 200);
        assert!(shown.get_pixel(1, 128)[3] > 200);
        assert_eq!(shown.get_pixel(128, 128)[3], 255);
        assert!(master(b"not an image".to_vec()).is_err());
    }

    #[test]
    fn malformed_and_oversized_images_produce_no_renderable_output() {
        assert!(prepare("data:image/png;base64,bm90IGFuIGltYWdl", true).is_err());
        let oversized = encoded(RgbaImage::new(4097, 1));
        assert!(prepare(&oversized, false).is_err());
        assert!(prepare(&oversized, true).is_err());
    }
}
