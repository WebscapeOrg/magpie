//! Marmalade's avatar prompts, copied word for word from Marmalade 43bb5722: the house style block
//! (`Marmalade::HouseStyle::LIGNE_CLAIRE`), the "user-avatars" task template (version 1, the active
//! one), and the portrait and logo directives of `X::AvatarPainter`. Change them only together with
//! Marmalade, so the two apps' pictures keep matching.
//!
//! Magpie adds two things Marmalade does not need: one sentence asking for the subject to fit
//! inside a circle, and a monogram for a sender with no photo and no company.
//! Invariant: the only sender-derived text in a prompt is a domain that `avatars::email` accepted
//! (letters, digits, hyphens and dots) or one ASCII letter or digit. Names, subjects and message
//! text never reach a prompt.

const LIGNE_CLAIRE: &str = "Ligne-claire isometric composition, warm muted palette,
flat-colour fills, crisp 1pt black ink outlines, subtle pen-and-ink digital wash,
no gradients, no photo realism, masthead quality.

No banners, watermarks, captions, callouts, overlay text, or typography
on the image.";

const TASK: &str = "Create each requested author avatar in Marmalade\u{2019}s full ligne-claire house style. Preserve the supplied identity cues or logo shape, keep the subject clear at small size, and do not add banners, watermarks, captions, typography, or other overlay text.";

const PORTRAIT_FRAMING: &str = "Head-and-shoulders portrait framing on a soft cream background.";
const PORTRAIT_DIRECTIVE: &str = "Re-render the supplied photograph as a head-and-shoulders portrait. Preserve the subject's identifying features faithfully \u{2014} hair colour and style, beard or clean-shaven, glasses or no glasses, skin tone, build, distinctive accessories.";
const ORGANISATION_LOGO_DIRECTIVE: &str = "Re-render the supplied brand mark as a logo plate centred on a soft cream background. Preserve the logo's identifying features faithfully \u{2014} exact letterforms if there is a wordmark, glyph shape, colour palette, monogram structure. Do NOT replace the mark with a portrait or a face.";
const TEXT_LOGO_DIRECTIVE: &str = "Render a wordmark or emblem, never a person, a face or a portrait. If the brand's mark is not known with confidence, set the name in clean lettering rather than inventing a glyph.";
/// Magpie's addition: Magpie shows every sender picture in a circle.
const CIRCLE: &str = "The picture is shown inside a circle: keep the whole subject within the central circle and let the background fill the corners.";

/// `HouseStyle.for_reference_image`.
fn for_reference_image(directive: &str, framing: &str) -> String {
    [directive, framing, LIGNE_CLAIRE].join("\n\n")
}

/// `HouseStyle.for_text_to_image`.
fn for_text_to_image(subject: &str, framing: &str, directives: &[&str]) -> String {
    let opening = format!("An editorial illustration of {subject} drawn in isometric perspective.");
    let mut parts = vec![opening.as_str(), framing];
    parts.extend_from_slice(directives);
    parts.push(LIGNE_CLAIRE);
    parts.join("\n\n")
}

/// `AvatarPainter#prompt_for`: the task template, then the image prompt.
fn with_task(image_prompt: String) -> String {
    format!("{TASK}\n\n{image_prompt}")
}

/// A contact's photo redrawn as a portrait (`build_reference_prompt` with no biography).
pub(super) fn portrait() -> String {
    let framing = format!("{PORTRAIT_FRAMING}\n\nBackground: a neutral cream wash.\n\n{CIRCLE}");
    with_task(for_reference_image(PORTRAIT_DIRECTIVE, &framing))
}

/// A company's logo or favicon redrawn as a logo plate (`build_logo_prompt`).
pub(super) fn logo(domain: &str) -> String {
    let framing = format!("Subject: the {domain} brand mark.\n\n{CIRCLE}");
    with_task(for_reference_image(ORGANISATION_LOGO_DIRECTIVE, &framing))
}

/// A company whose logo could not be fetched (`build_text_logo_prompt`).
pub(super) fn text_logo(domain: &str) -> String {
    let subject = format!("the {domain} brand mark");
    let framing = format!("A logo plate centred on a soft cream background.\n\n{CIRCLE}");
    with_task(for_text_to_image(&subject, &framing, &[TEXT_LOGO_DIRECTIVE]))
}

/// A sender with no photo and no company: one letter drawn as a monogram, never a face.
pub(super) fn monogram(letter: char) -> String {
    let subject = format!("the capital letter {letter} as a monogram");
    let framing = format!("A monogram plate centred on a soft cream background.\n\n{CIRCLE}");
    let directive = format!(
        "Draw only the single character {letter} as an emblem, never a person, a face or a portrait, and no other letters or words."
    );
    with_task(for_text_to_image(&subject, &framing, &[&directive]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_keep_marmalades_words_and_order() {
        let portrait = portrait();
        assert!(portrait.starts_with(TASK));
        assert!(portrait.ends_with(LIGNE_CLAIRE));
        let directive = portrait.find(PORTRAIT_DIRECTIVE).unwrap();
        let framing = portrait.find(PORTRAIT_FRAMING).unwrap();
        assert!(directive < framing);
        assert!(portrait.contains("Background: a neutral cream wash."));
        let logo = logo("example.org");
        assert!(logo.contains(ORGANISATION_LOGO_DIRECTIVE));
        assert!(logo.contains("Subject: the example.org brand mark."));
        assert!(logo.ends_with(LIGNE_CLAIRE));
        let text = text_logo("example.org");
        assert!(text.contains("An editorial illustration of the example.org brand mark drawn in isometric perspective."));
        assert!(text.contains(TEXT_LOGO_DIRECTIVE));
        let monogram = monogram('D');
        assert!(monogram.contains("the capital letter D as a monogram"));
        assert!(monogram.contains("never a person, a face or a portrait"));
        for prompt in [portrait, logo, text, monogram] {
            assert!(prompt.contains(CIRCLE));
            assert_eq!(prompt.matches(LIGNE_CLAIRE).count(), 1);
        }
    }

    #[test]
    fn house_style_block_matches_marmalade_byte_for_byte() {
        assert_eq!(
            LIGNE_CLAIRE,
            "Ligne-claire isometric composition, warm muted palette,\nflat-colour fills, crisp 1pt black ink outlines, subtle pen-and-ink digital wash,\nno gradients, no photo realism, masthead quality.\n\nNo banners, watermarks, captions, callouts, overlay text, or typography\non the image."
        );
    }
}
