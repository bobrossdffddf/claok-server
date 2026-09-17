//! The only things that move.
//!
//! One hero motion per state and nothing else, because a window with four
//! animations running at once reads as a screensaver rather than a tool.

use std::f32::consts::TAU;

use egui::{Color32, CornerRadius, Mesh, Painter, Pos2, Rect, Shape, Stroke, Vec2};

use crate::theme::skin;

/// Progress bars are judged by how they end, so the number shown accelerates
/// towards the finish. The underlying figure is unchanged: this only shapes the
/// approach, and it still arrives exactly when the work does.
pub fn perceived(progress: f32) -> f32 {
    let x = progress.clamp(0.0, 1.0);
    let shaped = x + (1.0 - x) * 0.03;
    shaped * shaped
}

fn noise(seed: u32) -> f32 {
    let mut x = seed.wrapping_mul(747_796_405).wrapping_add(2_891_336_453);
    x = ((x >> ((x >> 28) + 4)) ^ x).wrapping_mul(277_803_737);
    ((x >> 22) ^ x) as f32 / u32::MAX as f32
}

/// The window's own background: the phone app's `Palette.backdrop`, a very
/// shallow vertical gradient rather than one flat fill, so the card has
/// something to sit on.
pub fn backdrop(painter: &Painter, rect: Rect) {
    let mut mesh = Mesh::default();
    mesh.colored_vertex(rect.left_top(), skin::BACKDROP_TOP);
    mesh.colored_vertex(rect.right_top(), skin::BACKDROP_TOP);
    mesh.colored_vertex(rect.right_bottom(), skin::BG);
    mesh.colored_vertex(rect.left_bottom(), skin::BG);
    mesh.add_triangle(0, 1, 2);
    mesh.add_triangle(0, 2, 3);
    painter.add(Shape::mesh(mesh));
}

/// For waiting on something outside the program. A radar turns at a constant
/// rate, which makes this the one place linear motion is correct, and the fixed
/// period gives an open-ended wait a pulse to count.
pub fn radar(painter: &Painter, rect: Rect, t: f32) {
    let centre = rect.center();
    let radius = rect.width().min(rect.height()) / 2.0 - 2.0;
    if radius < 6.0 {
        return;
    }

    for step in 1..=3 {
        painter.circle_stroke(
            centre,
            radius * step as f32 / 3.0,
            Stroke::new(1.0, skin::LINE),
        );
    }

    let angle = (t / 4.0) * TAU;
    let spread = TAU / 7.0;

    let mut mesh = Mesh::default();
    mesh.colored_vertex(centre, Color32::TRANSPARENT);
    let steps = 40;
    for index in 0..=steps {
        let fraction = index as f32 / steps as f32;
        let a = angle - spread + spread * fraction;
        mesh.colored_vertex(
            Pos2::new(centre.x + radius * a.cos(), centre.y + radius * a.sin()),
            skin::ACCENT.gamma_multiply(0.26 * fraction),
        );
    }
    for index in 1..steps {
        mesh.add_triangle(0, index as u32, index as u32 + 1);
    }
    painter.add(Shape::mesh(mesh));

    painter.line_segment(
        [centre, Pos2::new(centre.x + radius * angle.cos(), centre.y + radius * angle.sin())],
        Stroke::new(1.4, skin::ACCENT.gamma_multiply(0.7)),
    );

    for index in 0..3u32 {
        let blip_angle = noise(index * 7 + 3) * TAU;
        let blip_radius = radius * (0.32 + noise(index * 13 + 5) * 0.55);
        let point = Pos2::new(
            centre.x + blip_radius * blip_angle.cos(),
            centre.y + blip_radius * blip_angle.sin(),
        );

        let mut delta = (angle % TAU) - blip_angle;
        while delta < 0.0 {
            delta += TAU;
        }
        let since = delta / TAU * 4.0;
        let fade = (-since / 1.5).exp();
        if fade > 0.03 {
            painter.circle_filled(point, 2.0, skin::ACCENT.gamma_multiply(fade));
        }
    }

    painter.circle_filled(centre, 3.0, skin::ACCENT);
}

/// The one progress bar.
///
/// A travelling highlight rides the filled part, so a stage that genuinely
/// takes forty seconds without moving the number still looks alive. That is
/// the whole difference between "working" and "hung" to somebody watching.
pub fn bar(painter: &Painter, rect: Rect, progress: f32, t: f32) {
    let radius = CornerRadius::same((rect.height() / 2.0) as u8);
    painter.rect_filled(rect, radius, skin::FIELD);

    let filled = perceived(progress).clamp(0.0, 1.0);
    let width = (rect.width() * filled).max(if filled > 0.0 { rect.height() } else { 0.0 });
    if width <= 0.5 {
        return;
    }

    let done = Rect::from_min_size(rect.min, Vec2::new(width, rect.height()));
    painter.rect_filled(done, radius, skin::ACCENT_DEEP);

    // The highlight is a short accent band sliding left to right inside the
    // part that is already done, drawn as a mesh so it fades at both ends
    // instead of appearing as a hard rectangle.
    let band = (rect.width() * 0.22).min(width);
    let travel = (t * 0.55).fract() * (width + band) - band;
    let left = travel.max(done.min.x - rect.min.x + 0.0).max(0.0);
    let right = (travel + band).min(width);
    if right > left {
        let mut mesh = Mesh::default();
        let x0 = rect.min.x + left;
        let x1 = rect.min.x + right;
        let mid = (x0 + x1) / 2.0;
        let edge = skin::ACCENT_DEEP;
        let peak = skin::ACCENT;
        mesh.colored_vertex(Pos2::new(x0, rect.min.y), edge);
        mesh.colored_vertex(Pos2::new(x0, rect.max.y), edge);
        mesh.colored_vertex(Pos2::new(mid, rect.min.y), peak);
        mesh.colored_vertex(Pos2::new(mid, rect.max.y), peak);
        mesh.colored_vertex(Pos2::new(x1, rect.min.y), edge);
        mesh.colored_vertex(Pos2::new(x1, rect.max.y), edge);
        mesh.add_triangle(0, 1, 2);
        mesh.add_triangle(1, 3, 2);
        mesh.add_triangle(2, 3, 4);
        mesh.add_triangle(3, 5, 4);
        painter.add(Shape::mesh(mesh));
    }

    // The leading edge stays the full accent so the bar always has a bright
    // head, whatever the highlight is doing.
    let head = Rect::from_min_size(
        Pos2::new(rect.min.x + width - rect.height().min(width), rect.min.y),
        Vec2::new(rect.height().min(width), rect.height()),
    );
    painter.rect_filled(head, radius, skin::ACCENT);
}

/// Three dots for a wait too short to deserve a radar.
pub fn dots(painter: &Painter, rect: Rect, t: f32) {
    let centre = rect.center();
    for index in 0..3i32 {
        let phase = t * 2.6 - index as f32 * 0.5;
        let lift = (phase.sin() * 0.5 + 0.5).powf(1.6);
        painter.circle_filled(
            Pos2::new(centre.x + (index - 1) as f32 * 7.0, centre.y),
            2.3 + lift * 0.9,
            skin::ACCENT.gamma_multiply(0.35 + lift * 0.65),
        );
    }
}
