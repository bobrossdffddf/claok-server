//! Type and icons.
//!
//! Inter stands in for San Francisco, which cannot be redistributed, and
//! carries the same neutral, slightly tight feel at UI sizes. Phosphor
//! supplies every glyph. Nothing here is drawn by hand.

use std::sync::Arc;

use egui::{FontData, FontDefinitions, FontFamily};

pub const ICONS: &str = "phosphor";

pub fn install(ctx: &egui::Context) {
    let mut fonts = FontDefinitions::default();

    fonts.font_data.insert(
        "inter".to_owned(),
        Arc::new(FontData::from_static(include_bytes!("../assets/Inter-Regular.ttf"))),
    );
    fonts.font_data.insert(
        "inter-medium".to_owned(),
        Arc::new(FontData::from_static(include_bytes!("../assets/Inter-Medium.ttf"))),
    );
    fonts.font_data.insert(
        "inter-semibold".to_owned(),
        Arc::new(FontData::from_static(include_bytes!("../assets/Inter-SemiBold.ttf"))),
    );
    fonts.font_data.insert(
        "inter-display".to_owned(),
        Arc::new(FontData::from_static(include_bytes!("../assets/InterDisplay-SemiBold.ttf"))),
    );
    fonts.font_data.insert(
        ICONS.to_owned(),
        Arc::new(FontData::from_static(include_bytes!("../assets/Phosphor.ttf"))),
    );
    fonts.font_data.insert(
        "phosphor-fill".to_owned(),
        Arc::new(FontData::from_static(include_bytes!("../assets/Phosphor-Fill.ttf"))),
    );

    fonts
        .families
        .entry(FontFamily::Proportional)
        .or_default()
        .insert(0, "inter".to_owned());

    fonts
        .families
        .insert(FontFamily::Name("medium".into()), vec!["inter-medium".to_owned(), "inter".to_owned()]);
    fonts
        .families
        .insert(FontFamily::Name("semibold".into()), vec!["inter-semibold".to_owned(), "inter".to_owned()]);
    fonts
        .families
        .insert(FontFamily::Name("display".into()), vec!["inter-display".to_owned(), "inter".to_owned()]);
    fonts
        .families
        .insert(FontFamily::Name(ICONS.into()), vec![ICONS.to_owned()]);
    fonts
        .families
        .insert(FontFamily::Name("icons-fill".into()), vec!["phosphor-fill".to_owned()]);

    ctx.set_fonts(fonts);
}

pub fn medium() -> FontFamily {
    FontFamily::Name("medium".into())
}

pub fn semibold() -> FontFamily {
    FontFamily::Name("semibold".into())
}

pub fn display() -> FontFamily {
    FontFamily::Name("display".into())
}

pub fn icons() -> FontFamily {
    FontFamily::Name(ICONS.into())
}

pub fn icons_filled() -> FontFamily {
    FontFamily::Name("icons-fill".into())
}

/// The glyphs used, by their Phosphor names.
pub mod icon {
    pub const IPHONE: &str = "\u{e1e2}";
    pub const PLUG: &str = "\u{e946}";
    pub const USB: &str = "\u{e956}";
    pub const WRENCH: &str = "\u{e5d4}";
    pub const KEY: &str = "\u{e2d6}";
    pub const LOCK_KEY: &str = "\u{e2fe}";
    pub const SHIELD_CHECK: &str = "\u{e40c}";
    pub const DOWNLOAD: &str = "\u{e20c}";
    pub const CHECK_CIRCLE: &str = "\u{e184}";
    pub const WARNING: &str = "\u{e4e0}";
    pub const WARNING_CIRCLE: &str = "\u{e4e2}";
    pub const REFRESH: &str = "\u{e094}";
    pub const MAP_PIN: &str = "\u{e316}";
    pub const CROSSHAIR: &str = "\u{e1d6}";
    pub const X_CIRCLE: &str = "\u{e4f8}";
    pub const CARET_RIGHT: &str = "\u{e13a}";
    pub const CARET_DOWN: &str = "\u{e136}";
    pub const INFO: &str = "\u{e2ce}";
    pub const APPLE: &str = "\u{e516}";
    pub const CLOCK: &str = "\u{e19a}";
    pub const ARROW_RIGHT: &str = "\u{e06c}";
    pub const GEAR: &str = "\u{e270}";
    pub const CELL_SIGNAL: &str = "\u{e142}";
    pub const PATH: &str = "\u{e39c}";
}
