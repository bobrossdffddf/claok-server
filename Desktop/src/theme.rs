//! Every colour and every measurement the window uses, in one place.
//!
//! The values are the phone app's own, lifted from `App/Theme.swift` so the
//! thing that installs Cloak and the thing it installs look like they were
//! made by the same people. Dark, because Cloak is dark, and because the
//! installer is the first screen anybody sees of it.
//!
//! Nothing below is allowed to be written as a literal anywhere else.

/// The palette. Names match the iOS side where the iOS side has a name for it.
pub mod skin {
    use egui::Color32;

    /// The window itself. `Palette.ground`.
    pub const BG: Color32 = Color32::from_rgb(12, 16, 21);
    /// The one card. `Palette.surface`.
    pub const SURFACE: Color32 = Color32::from_rgb(22, 28, 35);
    /// A group inside the card. `Palette.raised`.
    pub const RAISED: Color32 = Color32::from_rgb(32, 40, 48);
    /// Hover, and anything sitting on top of a group. `Palette.floating`.
    pub const FLOATING: Color32 = Color32::from_rgb(41, 50, 59);
    /// Text fields and progress tracks: a well cut into the group rather than
    /// another layer stacked on it.
    pub const FIELD: Color32 = Color32::from_rgb(18, 23, 30);
    /// White at ten percent, which is the only border in the app.
    pub const LINE: Color32 = Color32::from_rgba_premultiplied(26, 26, 26, 26);

    /// Kept under its old name because the card is what `PANEL` used to mean.
    pub const PANEL: Color32 = SURFACE;

    pub const LABEL: Color32 = Color32::from_rgb(238, 243, 247);
    /// `Palette.dim`.
    pub const SECOND: Color32 = Color32::from_rgb(169, 179, 189);
    /// `Palette.faint`. Measured to clear 4.5:1 on every surface above.
    pub const TERTIARY: Color32 = Color32::from_rgb(144, 156, 170);

    /// `Palette.accent`.
    pub const ACCENT: Color32 = Color32::from_rgb(59, 224, 200);
    /// `Palette.accentDeep`, for the bottom of the accent fill.
    pub const ACCENT_DEEP: Color32 = Color32::from_rgb(22, 163, 146);
    /// Accent laid over `RAISED` at about fourteen percent, pre-mixed so it
    /// can be used as a solid fill without alpha blending surprises.
    pub const ACCENT_SOFT: Color32 = Color32::from_rgb(28, 62, 66);
    /// Text sitting on an accent fill. Teal is a light colour; white on it is
    /// unreadable and is the single most common way a dark theme goes wrong.
    pub const ON_ACCENT: Color32 = Color32::from_rgb(6, 18, 17);

    /// `Palette.ok`.
    pub const GREEN: Color32 = Color32::from_rgb(79, 224, 150);
    pub const GREEN_SOFT: Color32 = Color32::from_rgb(22, 47, 39);
    /// `Palette.warn`.
    pub const ORANGE: Color32 = Color32::from_rgb(251, 179, 83);
    pub const ORANGE_SOFT: Color32 = Color32::from_rgb(44, 36, 24);
    /// `Palette.danger`.
    pub const RED: Color32 = Color32::from_rgb(255, 107, 111);
    pub const RED_SOFT: Color32 = Color32::from_rgb(52, 28, 31);

    /// The top of the window's gradient, a shade lighter than `BG`.
    pub const BACKDROP_TOP: Color32 = Color32::from_rgb(16, 21, 27);
}

/// The measurements. A 4pt rhythm and four radii, concentric: a 10pt control
/// inside 16pt of padding sits in a 14pt group, and a 14pt group inside a
/// 20pt card.
pub mod metric {
    /// The card never grows past this, however wide the window is dragged.
    pub const CARD_WIDTH: f32 = 720.0;
    /// The card never shrinks past this either; below it the window scrolls.
    pub const CARD_MIN: f32 = 520.0;

    pub const CARD_PAD: i8 = 20;
    pub const GROUP_PAD: i8 = 15;

    pub const CARD_RADIUS: u8 = 20;
    pub const GROUP_RADIUS: u8 = 14;
    pub const CHIP_RADIUS: u8 = 10;
    pub const FIELD_RADIUS: u8 = 10;

    pub const BUTTON_H: f32 = 40.0;
    pub const FIELD_H: f32 = 38.0;

    /// The 4pt rhythm. Nothing in the window is allowed to invent a gap.
    pub const HAIR: f32 = 4.0;
    pub const TIGHT: f32 = 8.0;
    pub const SNUG: f32 = 12.0;
    pub const REGULAR: f32 = 16.0;
    pub const LOOSE: f32 = 24.0;

    /// Between one labelled section and the next.
    pub const SECTION_GAP: f32 = 10.0;
}
