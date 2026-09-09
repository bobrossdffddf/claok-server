//! The only two things that move.
//!
//! One hero motion per screen and nothing else, because a window with four
//! animations running at once reads as a screensaver rather than a tool.

use std::f32::consts::TAU;

use egui::{Color32, Mesh, Painter, Pos2, Rect, Shape, Stroke};

use crate::ui::skin;

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
            skin::ACCENT.gamma_multiply(0.20 * fraction),
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

/// A determinate ring, used only where the number is real.
pub fn ring(painter: &Painter, rect: Rect, progress: f32) {
    let centre = rect.center();
    let radius = rect.width().min(rect.height()) / 2.0 - 5.0;
    if radius < 8.0 {
        return;
    }

    painter.circle_stroke(centre, radius, Stroke::new(5.0, skin::LINE));

    let clamped = perceived(progress);
    if clamped > 0.001 {
        let steps = (110.0 * clamped).max(2.0) as usize;
        let points: Vec<Pos2> = (0..=steps)
            .map(|i| {
                let angle = -TAU / 4.0 + (i as f32 / steps as f32) * TAU * clamped;
                Pos2::new(centre.x + radius * angle.cos(), centre.y + radius * angle.sin())
            })
            .collect();
        painter.add(Shape::line(points, Stroke::new(5.0, skin::ACCENT)));
    }

    painter.text(
        centre,
        egui::Align2::CENTER_CENTER,
        format!("{}%", (clamped * 100.0).round() as i32),
        egui::FontId::new(17.0, crate::assets::medium()),
        skin::LABEL,
    );
}
