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
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|_| "public_image_refused")?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    let original = reader.decode().map_err(|_| "public_image_refused")?;
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

    #[test]
    fn malformed_and_oversized_images_produce_no_renderable_output() {
        assert!(prepare("data:image/png;base64,bm90IGFuIGltYWdl", true).is_err());
        let oversized = encoded(RgbaImage::new(4097, 1));
        assert!(prepare(&oversized, false).is_err());
        assert!(prepare(&oversized, true).is_err());
    }
}
