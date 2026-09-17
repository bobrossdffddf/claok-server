//! The window.
//!
//! One screen. Three labelled sections that are all on it from the first
//! frame: the Apple ID, the iPhone, and the install. Nothing gets a page of
//! its own, because every page in a wizard is somewhere a person can be stuck
//! without being able to see what is holding them up. A code prompt, a
//! Developer Mode switch, a phone that has been unplugged: each one appears
//! inside the section it belongs to and goes away again by itself.
//!
//! Dark, and the phone app's own palette, so the installer and the thing it
//! installs look like they were made by the same people.
//!
//! Type is Inter, standing in for San Francisco. Every glyph is Phosphor.
//! Nothing is drawn by hand except the things that have to move.

use egui::{
    Align, Color32, CornerRadius, FontFamily, FontId, Layout, Margin, Pos2, RichText, Sense,
    Stroke, TextStyle, Vec2,
};
use isideload::auth::apple_account::{TwoFactorCallbackParams, TwoFactorCallbackResponse};

use crate::agent::{self, Schedule};
use crate::assets::{self, icon};
use crate::config::Config;
use crate::device::{DeveloperMode, Phone};
use crate::theme::{metric, skin};
use crate::viz;
use crate::worker::{self, Channels, Command, Event};

/// Where the install itself has got to. Everything else on screen is a fact
/// about the account or the phone and is drawn inline, not as a step.
#[derive(PartialEq, Clone, Copy)]
enum Phase {
    Setup,
    Installing,
    /// On the phone, but this iOS wants the signature approved by hand.
    Trust,
    Done,
}

pub struct Installer {
    channels: Channels,
    phase: Phase,

    phones: Vec<Phone>,
    chosen: Option<Phone>,

    apple_id: String,
    password: String,
    remember: bool,

    status: String,
    /// The real figure from the worker.
    progress: f32,
    /// The figure on screen, which chases the real one so the bar glides
    /// rather than jumping a third of its length in one frame.
    shown: f32,

    /// An install that failed. Belongs to the Install section.
    failure: Option<String>,
    /// Anything that went wrong reading or changing the phone. Belongs to the
    /// iPhone section, and never takes the screen over.
    device_failure: Option<String>,

    two_factor: Option<TwoFactorCallbackParams>,
    needs_pairing_pin: bool,
    pin: String,
    code: String,

    config: Config,
    /// An Apple sign-in helper set by hand. Empty means let Cloak choose.
    anisette_url: String,
    client_info: String,
    show_advanced: bool,
    show_assurances: bool,

    /// usbmuxd is not answering, so nothing will be found until that is fixed.
    driver_missing: bool,
    revealed: bool,
    /// iOS would not flip the switch for us, so the section turns into four
    /// taps to do on the phone instead of an error.
    manual_dev_mode: bool,
    /// Somebody chose to press on without Developer Mode.
    skipped_dev_mode: bool,
    rebooting: bool,
    trusted: bool,

    /// The last diagnosis, when somebody has asked for one.
    report: Option<String>,

    /// True while a scan is out. Without this the timer starts another one
    /// before the last has answered, and they queue up faster than they drain.
    scanning: bool,
    /// How many scans in a row have come back with nothing. One empty answer
    /// is usually the phone settling, not the phone leaving.
    empty_scans: u8,
    last_scan: std::time::Instant,
    /// A device failure gets one silent second try before anybody is told
    /// about it, because most of them are a phone that was mid-handshake.
    retry_at: Option<std::time::Instant>,
    auto_retried: bool,

    started_at: Option<std::time::Instant>,
    /// One-shot flags for things that happen on the first frame only.
    sized: bool,
    focused: bool,
    /// Set by Enter in the password field, read by the Install section.
    submit: bool,
    /// The code box takes the cursor once when it appears, not every frame.
    code_focused: bool,
    /// Bring the Install section into view once, after something changed it.
    scroll_to_install: bool,
    /// True between asking iOS to do something to the phone and hearing back.
    /// A failure that answers a button press is shown at once; a failure from
    /// the background scan is retried quietly first.
    awaiting_phone: bool,
}

impl Installer {
    pub fn new(channels: Channels, cc: &eframe::CreationContext<'_>) -> Self {
        assets::install(&cc.egui_ctx);
        style(&cc.egui_ctx);
        let config = Config::load();
        let _ = channels.commands.send(Command::Scan);
        Self {
            channels,
            phase: Phase::Setup,
            phones: Vec::new(),
            chosen: None,
            apple_id: config.apple_id.clone().unwrap_or_default(),
            password: String::new(),
            remember: true,
            status: String::new(),
            progress: 0.0,
            shown: 0.0,
            failure: None,
            device_failure: None,
            two_factor: None,
            needs_pairing_pin: false,
            pin: String::new(),
            code: String::new(),
            anisette_url: config.anisette_url.clone().unwrap_or_default(),
            client_info: config.client_info.clone().unwrap_or_default(),
            config,
            show_advanced: false,
            show_assurances: false,
            driver_missing: false,
            revealed: false,
            manual_dev_mode: false,
            skipped_dev_mode: false,
            rebooting: false,
            trusted: false,
            report: None,
            scanning: true,
            empty_scans: 0,
            last_scan: std::time::Instant::now(),
            retry_at: None,
            auto_retried: false,
            started_at: None,
            sized: false,
            focused: false,
            submit: false,
            code_focused: false,
            scroll_to_install: false,
            awaiting_phone: false,
        }
    }

    fn send(&self, command: Command) {
        let _ = self.channels.commands.send(command);
    }

    fn installing(&self) -> bool {
        self.phase == Phase::Installing
    }

    fn developer_mode_ready(&self) -> bool {
        self.chosen.as_ref().is_some_and(worker::developer_mode_ok) || self.skipped_dev_mode
    }

    // MARK: - Events

    fn drain(&mut self, ctx: &egui::Context) {
        while let Ok(event) = self.channels.events.try_recv() {
            match event {
                Event::DriverMissing => {
                    self.scanning = false;
                    self.driver_missing = true;
                    self.phones.clear();
                    self.chosen = None;
                }
                Event::Phones(phones) => {
                    self.scanning = false;
                    self.driver_missing = false;
                    self.auto_retried = false;
                    self.device_failure = None;
                    self.empty_scans =
                        if phones.is_empty() { self.empty_scans.saturating_add(1) } else { 0 };

                    let had_one = self.chosen.is_some();
                    let vanished = had_one
                        && !phones
                            .iter()
                            .any(|p| Some(&p.udid) == self.chosen.as_ref().map(|c| &c.udid));

                    // One empty answer is usually the phone settling after
                    // being plugged in, or the reboot it was just asked for,
                    // so do not tear the section down for it.
                    if vanished && self.empty_scans < 2 && phones.is_empty() {
                        ctx.request_repaint();
                        continue;
                    }

                    self.phones = phones;
                    if let Some(current) = &self.chosen {
                        self.chosen =
                            self.phones.iter().find(|p| p.udid == current.udid).cloned();
                    }
                    // Exactly one phone needs no decision from anybody.
                    if self.chosen.is_none() && self.phones.len() == 1 {
                        self.chosen = self.phones.first().cloned();
                    }
                    if self.chosen.as_ref().is_some_and(worker::developer_mode_ok) {
                        self.manual_dev_mode = false;
                        self.rebooting = false;
                    }
                }
                Event::Status(text) => self.status = text,
                Event::Diagnosis(text) => self.report = Some(text),
                Event::Progress(fraction) => self.progress = fraction,
                Event::NeedTwoFactor(params) => {
                    self.two_factor = Some(*params);
                    self.code.clear();
                    self.code_focused = false;
                }
                Event::NeedPairingPin => {
                    self.needs_pairing_pin = true;
                    self.pin.clear();
                }
                Event::DeveloperModeRevealed => {
                    self.revealed = true;
                    self.awaiting_phone = false;
                }
                Event::DeveloperModeManual => {
                    self.device_failure = None;
                    self.revealed = true;
                    self.manual_dev_mode = true;
                    self.awaiting_phone = false;
                }
                Event::Trusted(ok) => self.trusted = ok,
                Event::Rebooting => {
                    self.rebooting = true;
                    self.device_failure = None;
                    self.awaiting_phone = false;
                }
                Event::Installed => {
                    self.password.clear();
                    self.progress = 1.0;
                    self.config = Config::load();
                    // Renewal on by default. The signature lasts seven days
                    // and nobody remembers to come back and press a button in
                    // a week; the password is already in the keychain when
                    // "remember" was ticked, which is the default. The
                    // finished state still offers to turn it off.
                    if self.remember && agent::status() != Schedule::Installed {
                        if let Err(message) = agent::install() {
                            tracing::warn!("could not schedule renewal: {message}");
                        }
                    }
                    // iOS answered the trust prompt itself on anything recent
                    // enough. When it did not, that is a real thing the person
                    // has to do and it gets said plainly.
                    self.phase = if self.trusted { Phase::Done } else { Phase::Trust };
                    self.scroll_to_install = true;
                }
                Event::Failed(message) => {
                    if self.installing() {
                        self.failure = Some(message);
                        self.two_factor = None;
                        self.needs_pairing_pin = false;
                        self.phase = Phase::Setup;
                        self.scroll_to_install = true;
                    } else {
                        // A failure that answers a button press is that
                        // button's answer and is shown at once. One that came
                        // from the background scan gets a quiet second go
                        // first, because a phone still waking up fails exactly
                        // like a phone that is never going to answer.
                        if self.awaiting_phone {
                            self.awaiting_phone = false;
                            self.device_failure = Some(message);
                        } else if self.auto_retried {
                            self.device_failure = Some(message);
                        } else {
                            self.auto_retried = true;
                            self.retry_at = Some(std::time::Instant::now());
                        }
                    }
                }
            }
            ctx.request_repaint();
        }

        // The quiet retry, once, a beat after the failure.
        if let Some(at) = self.retry_at {
            if at.elapsed() > std::time::Duration::from_millis(1200) {
                self.retry_at = None;
                self.scanning = true;
                self.send(Command::Rescan);
            }
        }

        // The phone list looks after itself. Plugging a phone in, unlocking
        // it, tapping Trust, or pulling the cable out all show up within a
        // couple of seconds with nothing pressed. The only thing that stops
        // the timer is an install in flight, which is using the cable.
        if !self.installing()
            && !self.scanning
            && self.last_scan.elapsed() > std::time::Duration::from_millis(2000)
        {
            self.last_scan = std::time::Instant::now();
            self.scanning = true;
            self.send(Command::Scan);
        }
    }

    /// What is still missing, in the order it has to be fixed.
    fn blocker(&self) -> Option<&'static str> {
        if self.chosen.is_none() {
            return Some("Connect an iPhone with USB to install.");
        }
        if !self.developer_mode_ready() {
            return Some("Turn on Developer Mode to install.");
        }
        if self.apple_id.trim().is_empty() || self.password.is_empty() {
            return Some("Sign in with your Apple ID to install.");
        }
        None
    }

    fn helper_text(&self) -> String {
        match self.phase {
            Phase::Installing => {
                "Installing. Leave the iPhone plugged in and unlocked.".to_string()
            }
            Phase::Trust => "Almost there. One tap on the phone finishes it.".to_string(),
            Phase::Done => "Cloak is on your iPhone. You can close this window.".to_string(),
            Phase::Setup => match self.blocker() {
                Some(text) => text.to_string(),
                None => "Everything is ready. Press Install Cloak.".to_string(),
            },
        }
    }

    fn elapsed_text(&self) -> String {
        match self.started_at {
            Some(at) => {
                let seconds = at.elapsed().as_secs();
                if seconds < 60 {
                    format!("{seconds} seconds so far")
                } else {
                    format!("{} min {} sec so far", seconds / 60, seconds % 60)
                }
            }
            None => "Working".into(),
        }
    }

    fn start_install(&mut self) {
        self.failure = None;
        self.report = None;
        self.progress = 0.0;
        self.shown = 0.0;
        self.status = "Reaching Apple".into();
        self.started_at = Some(std::time::Instant::now());
        self.phase = Phase::Installing;
        self.scroll_to_install = true;
        self.send(Command::Install {
            udid: self.chosen.as_ref().map(|p| p.udid.clone()).unwrap_or_default(),
            apple_id: self.apple_id.trim().to_string(),
            password: self.password.clone(),
            remember: self.remember,
        });
    }
}

impl eframe::App for Installer {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        let c = skin::BG;
        [c.r() as f32 / 255.0, c.g() as f32 / 255.0, c.b() as f32 / 255.0, 1.0]
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.drain(ctx);

        // One screen rather than five means it wants a taller window than a
        // page at a time did. Asked for once, on the first frame.
        if !self.sized {
            self.sized = true;
            let monitor = ctx
                .input(|i| i.viewport().monitor_size)
                .unwrap_or(Vec2::new(1440.0, 900.0));
            let height = (monitor.y - 120.0).clamp(560.0, 870.0);
            let width = 840.0_f32.min((monitor.x - 80.0).max(780.0));
            ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(Vec2::new(width, height)));
            ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(Pos2::new(
                ((monitor.x - width) / 2.0).max(0.0),
                ((monitor.y - height) / 2.0).max(32.0),
            )));
        }

        // The bar glides instead of stepping. The figure behind it is
        // untouched; only what is drawn is eased.
        self.shown += (self.progress - self.shown) * 0.12;
        if (self.progress - self.shown).abs() < 0.001 {
            self.shown = self.progress;
        }

        // Fast while something is genuinely moving, slow otherwise, but never
        // stopped: the phone list is on a timer and a window that only repaints
        // when the mouse moves would never notice a cable being pulled out.
        let moving = self.installing() || self.rebooting || self.chosen.is_none();
        ctx.request_repaint_after(std::time::Duration::from_millis(if moving { 33 } else { 250 }));

        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(skin::BG).inner_margin(Margin::ZERO))
            .show(ctx, |ui| {
                viz::backdrop(ui.painter(), ui.max_rect());
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        ui.add_space(metric::SNUG);
                        let card = (ui.available_width() - 2.0 * metric::LOOSE)
                            .clamp(metric::CARD_MIN, metric::CARD_WIDTH);
                        let pad = ((ui.available_width() - card) / 2.0).max(0.0);
                        ui.horizontal(|ui| {
                            ui.add_space(pad);
                            ui.vertical(|ui| {
                                ui.set_width(card);
                                self.card(ui, card);
                                ui.add_space(metric::SNUG);
                                ui.vertical_centered(|ui| {
                                    ui.label(
                                        RichText::new(self.helper_text())
                                            .size(12.0)
                                            .color(skin::TERTIARY),
                                    );
                                });
                            });
                        });
                        ui.add_space(metric::SNUG);
                    });
            });
    }
}

// MARK: - The card

impl Installer {
    fn card(&mut self, ui: &mut egui::Ui, w: f32) {
        egui::Frame::new()
            .fill(skin::SURFACE)
            .corner_radius(CornerRadius::same(metric::CARD_RADIUS))
            .stroke(Stroke::new(1.0, skin::LINE))
            .inner_margin(Margin::same(metric::CARD_PAD))
            .shadow(egui::epaint::Shadow {
                offset: [0, 12],
                blur: 38,
                spread: 0,
                color: Color32::from_black_alpha(110),
            })
            .show(ui, |ui| {
                let inner = w - 2.0 * metric::CARD_PAD as f32;
                ui.set_width(inner);

                self.header(ui, inner);
                ui.add_space(metric::SNUG);

                self.apple_id_section(ui, inner);
                ui.add_space(metric::SECTION_GAP);

                self.phone_section(ui, inner);
                ui.add_space(metric::SECTION_GAP);

                self.install_section(ui, inner);

                if self.scroll_to_install {
                    self.scroll_to_install = false;
                    ui.scroll_to_cursor(Some(Align::Max));
                }
            });
    }

    fn header(&mut self, ui: &mut egui::Ui, w: f32) {
        ui.horizontal(|ui| {
            egui::Frame::new()
                .fill(skin::ACCENT_SOFT)
                .corner_radius(CornerRadius::same(metric::CHIP_RADIUS))
                .inner_margin(Margin::same(8))
                .show(ui, |ui| glyph(ui, icon::MAP_PIN, 18.0, skin::ACCENT));
            ui.add_space(metric::HAIR);
            ui.vertical(|ui| {
                ui.label(
                    RichText::new("Cloak Installer")
                        .font(FontId::new(19.0, assets::display()))
                        .color(skin::LABEL),
                );
                ui.add_space(1.0);
                ui.label(
                    RichText::new(format!("Version {}", env!("CARGO_PKG_VERSION")))
                        .size(11.0)
                        .color(skin::TERTIARY),
                );
            });
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if round_button(ui, icon::GEAR, self.show_advanced)
                    .on_hover_text("Sign-in helper and what Apple is told")
                    .clicked()
                {
                    self.show_advanced = !self.show_advanced;
                }
            });
        });

        ui.add_space(metric::SNUG);
        rule(ui, w);

        if self.show_advanced {
            ui.add_space(metric::REGULAR);
            self.advanced(ui, w);
        }
    }

    /// Hidden until asked for, because nobody should have to know what an
    /// anisette server is. But when they are all down, and they do all go
    /// down together, this is the difference between waiting for a new build
    /// and pasting in an address that works.
    fn advanced(&mut self, ui: &mut egui::Ui, w: f32) {
        group(ui, w, |ui, inner| {
            ui.label(
                RichText::new("Apple will not accept a sign-in without an identity that only a Mac can produce, so Cloak borrows one from a public helper server. It picks a working one by itself. If sign-in keeps failing when nothing else is wrong, they are probably all having a bad day, and a different address can go here.")
                    .size(12.0)
                    .color(skin::SECOND)
                    .line_height(Some(17.5)),
            );
            ui.add_space(metric::TIGHT);
            let response = ui.add(
                egui::TextEdit::singleline(&mut self.anisette_url)
                    .desired_width(inner)
                    .margin(Margin::symmetric(12, 9))
                    .hint_text("Leave empty to choose automatically"),
            );
            if response.changed() {
                let trimmed = self.anisette_url.trim().to_string();
                self.config.anisette_url =
                    if trimmed.is_empty() { None } else { Some(trimmed) };
                self.config.save();
            }

            ui.add_space(metric::SNUG);
            ui.label(
                RichText::new("Apple is also told what kind of machine is asking. On a Mac, Cloak answers with this machine's real model, macOS build and Xcode version, which is both true and unlike anybody else's. Leave this empty unless somebody has published something specific to use instead.")
                    .size(12.0)
                    .color(skin::SECOND)
                    .line_height(Some(17.5)),
            );
            if let Some(current) = crate::anisette::client_info(&self.config) {
                ui.add_space(metric::HAIR + 2.0);
                ui.label(
                    RichText::new(format!("Currently sending: {current}"))
                        .size(11.0)
                        .color(skin::TERTIARY),
                );
            }
            ui.add_space(metric::TIGHT);
            let identity = ui.add(
                egui::TextEdit::singleline(&mut self.client_info)
                    .desired_width(inner)
                    .margin(Margin::symmetric(12, 9))
                    .hint_text("Leave empty unless told otherwise"),
            );
            if identity.changed() {
                let trimmed = self.client_info.trim().to_string();
                self.config.client_info =
                    if trimmed.is_empty() { None } else { Some(trimmed) };
                self.config.save();
            }

            ui.add_space(metric::SNUG);
            footnote(ui, "Apple locks an account out for about two hours after repeated sign-in attempts, so Cloak only ever tries once. Change something here before trying again rather than pressing the button twice.");
        });
    }

    // MARK: - Apple ID

    fn apple_id_section(&mut self, ui: &mut egui::Ui, w: f32) {
        if caption(
            ui,
            "Apple ID",
            Some("A second, empty Apple ID works just as well."),
            true,
        ) {
            self.show_assurances = !self.show_assurances;
        }

        group(ui, w, |ui, inner| {
            if self.phase != Phase::Setup {
                // Nothing here is editable once the install has started, so
                // the fields fold away to the one fact that still matters and
                // the room goes to the progress bar instead.
                ui.horizontal(|ui| {
                    glyph(ui, icon::APPLE, 15.0, skin::SECOND);
                    ui.add_space(metric::HAIR + 1.0);
                    ui.label(
                        RichText::new(if self.apple_id.trim().is_empty() {
                            "Signing in".to_string()
                        } else {
                            self.apple_id.trim().to_string()
                        })
                        .font(FontId::new(13.0, assets::medium()))
                        .color(skin::LABEL),
                    );
                });
                if let Some(params) = self.two_factor.clone() {
                    ui.add_space(metric::TIGHT);
                    rule(ui, inner);
                    ui.add_space(metric::TIGHT + 2.0);
                    self.two_factor_inline(ui, inner, &params);
                } else if self.installing() {
                    ui.add_space(metric::TIGHT);
                    state_line(ui, skin::ACCENT, None, &self.status.clone(), true);
                }
                return;
            }

            let id_field = ui.add(
                egui::TextEdit::singleline(&mut self.apple_id)
                    .desired_width(inner)
                    .margin(Margin::symmetric(12, 9))
                    .hint_text("you@example.com"),
            );
            ui.add_space(metric::TIGHT);
            let password_field = ui.add(
                egui::TextEdit::singleline(&mut self.password)
                    .password(true)
                    .desired_width(inner)
                    .margin(Margin::symmetric(12, 9))
                    .hint_text("Password"),
            );
            if password_field.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                self.submit = true;
            }

            // The cursor starts where the typing starts. One less click on
            // every single run.
            if !self.focused {
                self.focused = true;
                if self.apple_id.trim().is_empty() {
                    id_field.request_focus();
                } else {
                    password_field.request_focus();
                }
            }

            ui.add_space(metric::TIGHT);
            check(
                ui,
                &mut self.remember,
                "Keep this working after a week",
                Some("Puts the password in this computer's keychain and renews Cloak every few days."),
            );

            ui.add_space(metric::TIGHT + 2.0);
            footnote(ui, "Your real password, not an app-specific one. It goes to Apple over TLS and nowhere else.");

            if self.show_assurances {
                ui.add_space(metric::SNUG);
                rule(ui, inner);
                ui.add_space(metric::SNUG);
                assurances(ui);
            }
        });
    }

    fn two_factor_inline(
        &mut self,
        ui: &mut egui::Ui,
        w: f32,
        params: &TwoFactorCallbackParams,
    ) {
        ui.horizontal(|ui| {
            glyph(ui, icon::LOCK_KEY, 15.0, skin::ACCENT);
            ui.add_space(metric::HAIR);
            ui.label(
                RichText::new("Apple sent a six digit code")
                    .font(FontId::new(13.5, assets::medium()))
                    .color(skin::LABEL),
            );
        });
        ui.add_space(metric::HAIR + 1.0);
        ui.label(
            RichText::new(if params.sms {
                "Check your text messages for it."
            } else {
                "Check your other Apple devices. Nothing arrived? Have it texted instead."
            })
            .size(12.5)
            .color(skin::SECOND)
            .line_height(Some(17.5)),
        );
        if let Some(last) = &params.last_error {
            ui.add_space(metric::HAIR + 2.0);
            ui.label(RichText::new(last).size(12.5).color(skin::RED));
        }

        ui.add_space(metric::SNUG);
        let code_width = (w * 0.42).max(150.0);
        let mut entered = false;
        ui.horizontal(|ui| {
            let response = ui.add(
                egui::TextEdit::singleline(&mut self.code)
                    .hint_text("000000")
                    .margin(Margin::symmetric(10, 9))
                    .horizontal_align(Align::Center)
                    .font(FontId::new(19.0, FontFamily::Monospace))
                    .desired_width(code_width),
            );
            if !self.code_focused {
                self.code_focused = true;
                response.request_focus();
            }
            if response.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                entered = true;
            }
            ui.add_space(metric::TIGHT);
            let ready = self.code.trim().len() >= 6;
            ui.add_enabled_ui(ready, |ui| {
                if primary(ui, "Continue", ui.available_width().min(150.0)).clicked() {
                    entered = true;
                }
            });
        });

        if entered && self.code.trim().len() >= 6 {
            self.send(Command::TwoFactor(TwoFactorCallbackResponse::SubmitCode(
                self.code.trim().to_string(),
            )));
            self.two_factor = None;
        }

        ui.add_space(metric::TIGHT);
        ui.horizontal(|ui| {
            if quiet_link(ui, icon::REFRESH, "Send it again").clicked() {
                self.send(Command::TwoFactor(TwoFactorCallbackResponse::ResendCode));
            }
            ui.add_space(metric::SNUG);
            // Offered even when the list of numbers came back empty. Apple
            // refuses to hand that list over on plenty of accounts, but
            // sending to the first number on the account does not need the
            // list, only the number's position.
            if quiet_link(ui, icon::CELL_SIGNAL, "Text it to me").clicked() {
                let id = params.numbers.first().map(|n| n.id).unwrap_or(1);
                self.send(Command::TwoFactor(TwoFactorCallbackResponse::SendSms(id)));
            }
            ui.add_space(metric::SNUG);
            if quiet_link(ui, icon::X_CIRCLE, "Cancel").clicked() {
                self.send(Command::TwoFactor(TwoFactorCallbackResponse::Abort));
                self.two_factor = None;
            }
        });
    }

    // MARK: - iPhone

    fn phone_section(&mut self, ui: &mut egui::Ui, w: f32) {
        caption(ui, "iPhone", None, false);

        group(ui, w, |ui, inner| {
            if self.needs_pairing_pin {
                self.pairing_pin_inline(ui, inner);
                ui.add_space(metric::SNUG);
                rule(ui, inner);
                ui.add_space(metric::SNUG);
            }

            if self.driver_missing {
                self.driver_state(ui, inner);
            } else if self.rebooting {
                self.rebooting_state(ui, inner);
            } else if let Some(phone) = self.chosen.clone() {
                phone_row(ui, inner, &phone, false);
                self.phone_state(ui, inner, &phone);
            } else if self.phones.len() > 1 {
                ui.label(
                    RichText::new("More than one iPhone is plugged in. Pick the one to install on.")
                        .size(13.0)
                        .color(skin::SECOND),
                );
                ui.add_space(metric::TIGHT);
                let phones = self.phones.clone();
                for phone in phones {
                    if phone_row(ui, inner, &phone, true) {
                        self.chosen = Some(phone);
                    }
                }
            } else {
                self.looking_state(ui, inner);
            }

            if let Some(message) = self.device_failure.clone() {
                ui.add_space(metric::SNUG);
                state_line(ui, skin::RED, Some(icon::WARNING_CIRCLE), &message, false);
            }

            if let Some(report) = self.report.clone() {
                ui.add_space(metric::SNUG);
                egui::Frame::new()
                    .fill(skin::FIELD)
                    .corner_radius(CornerRadius::same(metric::FIELD_RADIUS))
                    .inner_margin(Margin::same(12))
                    .show(ui, |ui| {
                        ui.set_width(inner - 24.0);
                        egui::ScrollArea::vertical()
                            .max_height(150.0)
                            .id_salt("diagnosis")
                            .show(ui, |ui| {
                                ui.label(
                                    RichText::new(report)
                                        .size(11.5)
                                        .family(FontFamily::Monospace)
                                        .color(skin::SECOND),
                                );
                            });
                    });
                ui.add_space(metric::TIGHT);
                if quiet_link(ui, icon::X_CIRCLE, "Hide this").clicked() {
                    self.report = None;
                }
            }

            if self.installing() {
                return;
            }

            // The manual fallback, always in the same place. The list looks
            // after itself, so this is here for impatience rather than need.
            ui.add_space(metric::TIGHT + 2.0);
            rule(ui, inner);
            ui.add_space(metric::TIGHT + 2.0);
            ui.vertical_centered(|ui| {
                ui.horizontal(|ui| {
                    if quiet_link(ui, icon::REFRESH, "Refresh list").clicked() {
                        self.report = None;
                        self.device_failure = None;
                        self.auto_retried = false;
                        self.scanning = true;
                        self.send(Command::Rescan);
                    }
                    if self.chosen.is_some() && self.phones.len() > 1 {
                        ui.add_space(metric::SNUG);
                        ui.label(RichText::new("\u{00b7}").size(12.0).color(skin::TERTIARY));
                        ui.add_space(metric::SNUG);
                        if quiet_link(ui, icon::IPHONE, "Use a different iPhone").clicked() {
                            self.chosen = None;
                            self.skipped_dev_mode = false;
                            self.manual_dev_mode = false;
                        }
                    }
                    let stuck = self.chosen.is_none()
                        || self.device_failure.is_some()
                        || self.chosen.as_ref().is_some_and(|p| p.problem.is_some());
                    if stuck {
                        ui.add_space(metric::SNUG);
                        ui.label(RichText::new("\u{00b7}").size(12.0).color(skin::TERTIARY));
                        ui.add_space(metric::SNUG);
                        if quiet_link(ui, icon::CROSSHAIR, "Why can it not see my phone?").clicked()
                        {
                            self.send(Command::Diagnose);
                        }
                    }
                });
            });
        });
    }

    fn looking_state(&mut self, ui: &mut egui::Ui, _w: f32) {
        ui.horizontal(|ui| {
            let (rect, _) = ui.allocate_exact_size(Vec2::splat(36.0), Sense::hover());
            let t = ui.input(|i| i.time) as f32;
            viz::radar(ui.painter(), rect, t);
            ui.add_space(metric::SNUG);
            ui.vertical(|ui| {
                ui.add_space(2.0);
                ui.label(
                    RichText::new("No iPhone found")
                        .font(FontId::new(14.0, assets::medium()))
                        .color(skin::LABEL),
                );
                ui.add_space(2.0);
                ui.label(
                    RichText::new("Connect it with USB, unlock it, and tap Trust if it asks. This list refreshes itself.")
                        .size(12.5)
                        .color(skin::SECOND)
                        .line_height(Some(17.5)),
                );
            });
        });
    }

    fn driver_state(&mut self, ui: &mut egui::Ui, w: f32) {
        if cfg!(windows) {
            note(
                ui,
                w,
                skin::ORANGE,
                skin::ORANGE_SOFT,
                icon::WARNING,
                "Windows needs Apple's iPhone driver",
                "It comes bundled with iTunes, and that is the only reason you need it. This never opens iTunes and never syncs anything. Use Apple's own download rather than the Microsoft Store version, which does not always register the device service.",
            );
            ui.add_space(metric::SNUG);
            if action(ui, "Get iTunes from Apple", w).clicked() {
                let _ = open::that("https://www.apple.com/itunes/download/win64");
            }
        } else {
            note(
                ui,
                w,
                skin::ORANGE,
                skin::ORANGE_SOFT,
                icon::WARNING,
                "macOS is not answering about iPhones",
                "The system service that talks to iPhones did not respond, which is unusual. Restarting the Mac normally settles it.",
            );
        }
    }

    fn rebooting_state(&mut self, ui: &mut egui::Ui, w: f32) {
        ui.horizontal(|ui| {
            let (rect, _) = ui.allocate_exact_size(Vec2::splat(36.0), Sense::hover());
            let t = ui.input(|i| i.time) as f32;
            viz::radar(ui.painter(), rect, t);
            ui.add_space(metric::SNUG);
            ui.vertical(|ui| {
                ui.add_space(2.0);
                ui.label(
                    RichText::new("Your iPhone is restarting")
                        .font(FontId::new(14.0, assets::medium()))
                        .color(skin::LABEL),
                );
                ui.add_space(2.0);
                ui.label(
                    RichText::new("About a minute. Leave it plugged in. This carries on by itself the moment it comes back.")
                        .size(12.5)
                        .color(skin::SECOND)
                        .line_height(Some(17.5)),
                );
            });
        });
        ui.add_space(metric::SNUG);
        steps(ui, w, &[
            "Unlock the phone with your passcode.",
            "A message asks whether to turn Developer Mode on. Tap Turn On.",
            "Enter the passcode again if it asks.",
        ]);
    }

    /// Everything that can be true of the phone that has been picked.
    fn phone_state(&mut self, ui: &mut egui::Ui, w: f32, phone: &Phone) {
        if let Some(problem) = phone.problem.clone() {
            ui.add_space(metric::SNUG);
            note(
                ui,
                w,
                skin::ORANGE,
                skin::ORANGE_SOFT,
                icon::WARNING,
                problem.headline(),
                &problem.detail(),
            );
            return;
        }

        if worker::developer_mode_ok(phone) {
            // The badge on the row says it. Once is enough.
            return;
        }

        let udid = phone.udid.clone();

        if self.manual_dev_mode {
            ui.add_space(metric::SNUG);
            note(
                ui,
                w,
                skin::ACCENT,
                skin::ACCENT_SOFT,
                icon::IPHONE,
                "This one has to be done on the phone",
                "iOS only refuses to be switched over remotely when a passcode is set. Doing it by hand takes four taps and the passcode stays exactly as it is.",
            );
            ui.add_space(metric::SNUG);
            steps(ui, w, &[
                "Open Settings, then Privacy & Security.",
                "Under Security, turn on Developer Mode.",
                "Tap Restart when it asks.",
                "When it comes back, unlock it, tap Enable and type the passcode.",
            ]);
            ui.add_space(metric::TIGHT);
            footnote(ui, "If Developer Mode is not in that list, close Settings completely and open it again: Settings will not redraw a page it is already showing. This section is watching the phone and moves on by itself the moment the switch is on.");
            ui.add_space(metric::SNUG);
            ui.horizontal(|ui| {
                if quiet_link(ui, icon::REFRESH, "Check now").clicked() {
                    self.device_failure = None;
                    self.auto_retried = false;
                    self.scanning = true;
                    self.send(Command::Rescan);
                }
                ui.add_space(metric::SNUG);
                if quiet_link(ui, icon::CARET_RIGHT, "Skip this for now").clicked() {
                    self.skipped_dev_mode = true;
                }
            });
            return;
        }

        ui.add_space(metric::TIGHT + 2.0);
        state_line(
            ui,
            skin::ORANGE,
            Some(icon::WRENCH),
            "Developer Mode is off, which is normal. iOS hides the switch until a computer asks, and Cloak has asked. Turning it on restarts the phone once and loses nothing.",
            false,
        );
        ui.add_space(metric::TIGHT + 2.0);
        if action(ui, "Turn on Developer Mode", w).clicked() {
            self.device_failure = None;
            self.awaiting_phone = true;
            self.send(Command::EnableDeveloperMode { udid: udid.clone() });
        }
        ui.add_space(metric::TIGHT);
        ui.horizontal(|ui| {
            if quiet_link(ui, icon::IPHONE, "I will do it on the phone myself").clicked() {
                self.device_failure = None;
                self.manual_dev_mode = true;
                self.awaiting_phone = true;
                self.send(Command::RevealDeveloperMode { udid: udid.clone() });
            }
            ui.add_space(metric::SNUG);
            if quiet_link(ui, icon::CARET_RIGHT, "Skip this for now").clicked() {
                self.skipped_dev_mode = true;
            }
        });
    }

    fn pairing_pin_inline(&mut self, ui: &mut egui::Ui, w: f32) {
        ui.horizontal(|ui| {
            glyph(ui, icon::IPHONE, 15.0, skin::ACCENT);
            ui.add_space(metric::HAIR);
            ui.label(
                RichText::new("Your iPhone is showing a code")
                    .font(FontId::new(13.5, assets::medium()))
                    .color(skin::LABEL),
            );
        });
        ui.add_space(metric::HAIR + 1.0);
        ui.label(
            RichText::new("It is asking whether to pair with \u{201c}Cloak\u{201d} and showing six digits. Type them here.")
                .size(12.5)
                .color(skin::SECOND)
                .line_height(Some(17.5)),
        );
        ui.add_space(metric::SNUG);

        let mut entered = false;
        ui.horizontal(|ui| {
            let response = ui.add(
                egui::TextEdit::singleline(&mut self.pin)
                    .hint_text("000000")
                    .margin(Margin::symmetric(10, 9))
                    .horizontal_align(Align::Center)
                    .font(FontId::new(19.0, FontFamily::Monospace))
                    .desired_width((w * 0.42).max(150.0)),
            );
            if response.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                entered = true;
            }
            ui.add_space(metric::TIGHT);
            let ready = self.pin.trim().len() >= 6;
            ui.add_enabled_ui(ready, |ui| {
                if primary(ui, "Pair", ui.available_width().min(150.0)).clicked() {
                    entered = true;
                }
            });
        });
        if entered && self.pin.trim().len() >= 6 {
            self.send(Command::PairingPin(self.pin.trim().to_string()));
            self.needs_pairing_pin = false;
        }
        ui.add_space(metric::TIGHT);
        if quiet_link(ui, icon::X_CIRCLE, "Skip pairing").clicked() {
            self.send(Command::PairingPin(String::new()));
            self.needs_pairing_pin = false;
        }
    }

    // MARK: - Install

    fn install_section(&mut self, ui: &mut egui::Ui, w: f32) {
        caption(ui, "Install", None, false);

        group(ui, w, |ui, inner| match self.phase {
            Phase::Setup => self.install_idle(ui, inner),
            Phase::Installing => self.install_running(ui, inner),
            Phase::Trust => self.install_trust(ui, inner),
            Phase::Done => self.install_done(ui, inner),
        });
    }

    fn install_idle(&mut self, ui: &mut egui::Ui, w: f32) {
        if let Some(message) = self.failure.clone() {
            note(
                ui,
                w,
                skin::RED,
                skin::RED_SOFT,
                icon::WARNING_CIRCLE,
                "That did not work",
                &message,
            );
            ui.add_space(metric::SNUG);
        }

        let ready = self.blocker().is_none();
        let label = if self.failure.is_some() { "Try again" } else { "Install Cloak" };
        ui.add_enabled_ui(ready, |ui| {
            if primary(ui, label, w).clicked() {
                self.submit = true;
            }
        });

        if self.submit {
            self.submit = false;
            if ready {
                self.start_install();
                return;
            }
        }

        if self.failure.is_none() {
            ui.add_space(metric::TIGHT);
            footnote(ui, "One or two minutes. Signing every file in the app is the slow part, and it only happens once.");
        }
    }

    fn install_running(&mut self, ui: &mut egui::Ui, w: f32) {
        let t = ui.input(|i| i.time) as f32;
        let (rect, _) = ui.allocate_exact_size(Vec2::new(w, 8.0), Sense::hover());
        viz::bar(ui.painter(), rect, self.shown, t);

        ui.add_space(metric::SNUG + 2.0);
        ui.horizontal(|ui| {
            ui.label(
                RichText::new(if self.status.is_empty() {
                    "Working".to_string()
                } else {
                    self.status.clone()
                })
                .font(FontId::new(14.0, assets::medium()))
                .color(skin::LABEL),
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                ui.label(
                    RichText::new(format!(
                        "{}%",
                        (viz::perceived(self.shown) * 100.0).round() as i32
                    ))
                    .font(FontId::new(13.0, assets::medium()))
                    .color(skin::ACCENT),
                );
            });
        });
        ui.add_space(metric::HAIR);
        footnote(ui, &self.elapsed_text());
    }

    fn install_trust(&mut self, ui: &mut egui::Ui, w: f32) {
        note(
            ui,
            w,
            skin::GREEN,
            skin::GREEN_SOFT,
            icon::CHECK_CIRCLE,
            "Cloak is on your iPhone",
            "One tap left, on the phone itself. iOS will not open an app signed by an ordinary Apple ID until you say you meant to install it. On newer iOS this installer answers that for you; yours wants to hear it from you.",
        );
        ui.add_space(metric::SNUG);
        steps(ui, w, &[
            "Open Settings on the iPhone.",
            "Tap General.",
            "Tap VPN & Device Management.",
            "Tap your Apple ID under Developer App.",
            "Tap Trust, then Trust again.",
        ]);
        ui.add_space(metric::TIGHT);
        footnote(ui, "If Cloak opens and immediately closes, this is why. It is a one-time thing per Apple ID, not per install.");
        ui.add_space(metric::SNUG);
        if primary(ui, "I have done that", w).clicked() {
            self.phase = Phase::Done;
        }
    }

    fn install_done(&mut self, ui: &mut egui::Ui, w: f32) {
        note(
            ui,
            w,
            skin::GREEN,
            skin::GREEN_SOFT,
            icon::SHIELD_CHECK,
            "All set",
            "Open Cloak on your phone. It already has the key this computer handed it, so there is no code to type and no pairing to sit through. It will walk you through the last piece, one free App Store app, and then everything happens on the phone alone.",
        );

        if self.trusted {
            ui.add_space(metric::TIGHT + 2.0);
            state_line(
                ui,
                skin::GREEN,
                Some(icon::SHIELD_CHECK),
                "iOS accepted the signature by itself, so Cloak opens straight away with no warning about an untrusted developer.",
                false,
            );
        }

        let scheduled = agent::status() == Schedule::Installed;
        ui.add_space(metric::SNUG);
        if scheduled {
            state_line(
                ui,
                skin::GREEN,
                Some(icon::REFRESH),
                "Automatic renewal is on. Apple's signature lasts seven days and this computer renews it quietly as long as your phone has been plugged in recently. Your places, routes and recordings survive a renewal.",
                false,
            );
            ui.add_space(metric::SNUG);
            ui.horizontal(|ui| {
                if quiet_link(ui, icon::DOWNLOAD, "Get LocalDevVPN").clicked() {
                    self.send(Command::OpenLocalDevVPN);
                }
                ui.add_space(metric::SNUG);
                if quiet_link(ui, icon::CLOCK, "Turn renewal off").clicked() {
                    let _ = agent::remove();
                }
            });
        } else {
            state_line(
                ui,
                skin::ORANGE,
                Some(icon::CLOCK),
                "Apple's signature runs out in seven days and Cloak stops opening when it does. Automatic renewal lets this computer take care of that quietly.",
                false,
            );
            ui.add_space(metric::SNUG);
            if primary(ui, "Turn on automatic renewal", w).clicked() {
                if let Err(message) = agent::install() {
                    self.failure = Some(message);
                }
            }
            ui.add_space(metric::TIGHT);
            if quiet_link(ui, icon::DOWNLOAD, "Get LocalDevVPN").clicked() {
                self.send(Command::OpenLocalDevVPN);
            }
        }

        if let Some(days) = self.config.days_until_expiry() {
            ui.add_space(metric::SNUG);
            footnote(ui, &format!("Signature good for about {days} more days."));
        }
    }
}

// MARK: - Style

fn style(ctx: &egui::Context) {
    let mut style = (*ctx.style()).clone();
    style.spacing.item_spacing = Vec2::new(8.0, 6.0);
    style.spacing.button_padding = Vec2::new(14.0, 8.0);
    style.spacing.interact_size.y = metric::FIELD_H;

    let mut visuals = egui::Visuals::dark();
    visuals.panel_fill = skin::BG;
    visuals.window_fill = skin::SURFACE;
    visuals.faint_bg_color = skin::RAISED;
    // Text fields are wells cut into the group rather than another layer.
    visuals.extreme_bg_color = skin::FIELD;
    visuals.override_text_color = Some(skin::LABEL);
    visuals.selection.bg_fill = skin::ACCENT.gamma_multiply(0.30);
    visuals.selection.stroke = Stroke::new(1.0, skin::ACCENT);
    visuals.hyperlink_color = skin::ACCENT;

    visuals.widgets.noninteractive.bg_fill = skin::SURFACE;
    visuals.widgets.noninteractive.weak_bg_fill = skin::SURFACE;
    visuals.widgets.noninteractive.bg_stroke = Stroke::new(1.0, skin::LINE);
    visuals.widgets.noninteractive.fg_stroke = Stroke::new(1.0, skin::SECOND);

    visuals.widgets.inactive.bg_fill = skin::FIELD;
    visuals.widgets.inactive.weak_bg_fill = skin::FIELD;
    visuals.widgets.inactive.bg_stroke = Stroke::new(1.0, skin::LINE);
    visuals.widgets.inactive.fg_stroke = Stroke::new(1.0, skin::LABEL);

    visuals.widgets.hovered.bg_fill = skin::FLOATING;
    visuals.widgets.hovered.weak_bg_fill = skin::FLOATING;
    visuals.widgets.hovered.bg_stroke = Stroke::new(1.0, skin::ACCENT.gamma_multiply(0.55));
    visuals.widgets.hovered.fg_stroke = Stroke::new(1.0, skin::LABEL);

    visuals.widgets.active.bg_fill = skin::FLOATING;
    visuals.widgets.active.weak_bg_fill = skin::FLOATING;
    visuals.widgets.active.bg_stroke = Stroke::new(1.0, skin::ACCENT);
    visuals.widgets.active.fg_stroke = Stroke::new(1.0, skin::LABEL);

    visuals.widgets.open.bg_fill = skin::FLOATING;
    visuals.widgets.open.weak_bg_fill = skin::FLOATING;
    visuals.widgets.open.bg_stroke = Stroke::new(1.0, skin::LINE);

    for widget in [
        &mut visuals.widgets.noninteractive,
        &mut visuals.widgets.inactive,
        &mut visuals.widgets.hovered,
        &mut visuals.widgets.active,
        &mut visuals.widgets.open,
    ] {
        widget.corner_radius = CornerRadius::same(metric::FIELD_RADIUS);
    }

    visuals.window_stroke = Stroke::new(1.0, skin::LINE);
    style.visuals = visuals;

    style.text_styles.insert(TextStyle::Body, FontId::new(13.5, FontFamily::Proportional));
    style.text_styles.insert(TextStyle::Button, FontId::new(13.5, assets::medium()));
    style.text_styles.insert(TextStyle::Small, FontId::new(11.5, FontFamily::Proportional));

    ctx.set_style(style);
}

// MARK: - Pieces

fn glyph(ui: &mut egui::Ui, symbol: &str, size: f32, tint: Color32) {
    ui.label(RichText::new(symbol).font(FontId::new(size, assets::icons())).color(tint));
}

fn footnote(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).size(11.5).color(skin::TERTIARY).line_height(Some(16.5)));
}

fn rule(ui: &mut egui::Ui, w: f32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::new(w, 1.0), Sense::hover());
    ui.painter()
        .line_segment([rect.left_center(), rect.right_center()], Stroke::new(1.0, skin::LINE));
}

/// A section label. Small, uppercase, quiet, with room on the same line for an
/// aside and for the one thing in the window that explains itself.
fn caption(ui: &mut egui::Ui, text: &str, aside: Option<&str>, info: bool) -> bool {
    let mut clicked = false;
    ui.horizontal(|ui| {
        ui.label(
            RichText::new(text.to_uppercase())
                .font(FontId::new(10.5, assets::semibold()))
                .color(skin::TERTIARY),
        );
        if let Some(aside) = aside {
            ui.add_space(metric::TIGHT);
            ui.label(RichText::new(aside).size(11.5).color(skin::TERTIARY));
        }
        if info {
            ui.add_space(2.0);
            let response = ui.add(
                egui::Label::new(
                    RichText::new(icon::INFO)
                        .font(FontId::new(13.0, assets::icons()))
                        .color(skin::SECOND),
                )
                .sense(Sense::click()),
            );
            if response.clicked() {
                clicked = true;
            }
            response.on_hover_text("What this does to your account, and what it does not");
        }
    });
    ui.add_space(metric::HAIR + 1.0);
    clicked
}

/// The darker rounded block a section's contents live in.
fn group(ui: &mut egui::Ui, w: f32, body: impl FnOnce(&mut egui::Ui, f32)) {
    egui::Frame::new()
        .fill(skin::RAISED)
        .corner_radius(CornerRadius::same(metric::GROUP_RADIUS))
        .stroke(Stroke::new(1.0, skin::LINE))
        .inner_margin(Margin::same(metric::GROUP_PAD))
        .show(ui, |ui| {
            let inner = w - 2.0 * metric::GROUP_PAD as f32;
            ui.set_width(inner);
            body(ui, inner);
        });
}

/// One line of state, with an optional glyph. Used for everything that is a
/// sentence rather than a block.
fn state_line(ui: &mut egui::Ui, tint: Color32, symbol: Option<&str>, text: &str, busy: bool) {
    ui.horizontal_top(|ui| {
        if busy {
            let (rect, _) = ui.allocate_exact_size(Vec2::new(24.0, 17.0), Sense::hover());
            let t = ui.input(|i| i.time) as f32;
            viz::dots(ui.painter(), rect, t);
            ui.add_space(2.0);
        } else if let Some(symbol) = symbol {
            glyph(ui, symbol, 15.0, tint);
            ui.add_space(metric::HAIR + 1.0);
        }
        // A horizontal row hands its children unlimited width, so the text has
        // to be put back inside a vertical one or it runs off the card.
        ui.vertical(|ui| {
            ui.label(
                RichText::new(text)
                    .size(12.5)
                    .color(if busy { skin::LABEL } else { skin::SECOND })
                    .line_height(Some(17.5)),
            );
        });
    });
}

/// A tinted block for something that needs a headline as well as a sentence.
fn note(
    ui: &mut egui::Ui,
    w: f32,
    tint: Color32,
    fill: Color32,
    symbol: &str,
    title: &str,
    body: &str,
) {
    egui::Frame::new()
        .fill(fill)
        .corner_radius(CornerRadius::same(metric::FIELD_RADIUS))
        .inner_margin(Margin::same(14))
        .show(ui, |ui| {
            ui.set_width(w - 28.0);
            ui.horizontal_top(|ui| {
                glyph(ui, symbol, 16.0, tint);
                ui.add_space(metric::TIGHT - 2.0);
                ui.vertical(|ui| {
                    ui.label(
                        RichText::new(title)
                            .font(FontId::new(13.5, assets::medium()))
                            .color(skin::LABEL),
                    );
                    ui.add_space(3.0);
                    ui.label(
                        RichText::new(body)
                            .size(12.5)
                            .color(skin::SECOND)
                            .line_height(Some(17.5)),
                    );
                });
            });
        });
}

fn steps(ui: &mut egui::Ui, w: f32, lines: &[&str]) {
    egui::Frame::new()
        .fill(skin::FIELD)
        .corner_radius(CornerRadius::same(metric::FIELD_RADIUS))
        .inner_margin(Margin::same(14))
        .show(ui, |ui| {
            ui.set_width(w - 28.0);
            for (index, line) in lines.iter().enumerate() {
                ui.horizontal_top(|ui| {
                    let (rect, _) = ui.allocate_exact_size(Vec2::splat(20.0), Sense::hover());
                    ui.painter().circle_filled(rect.center(), 9.0, skin::ACCENT_SOFT);
                    ui.painter().text(
                        rect.center(),
                        egui::Align2::CENTER_CENTER,
                        (index + 1).to_string(),
                        FontId::new(11.0, assets::medium()),
                        skin::ACCENT,
                    );
                    ui.add_space(metric::TIGHT - 2.0);
                    ui.label(
                        RichText::new(*line)
                            .size(12.5)
                            .color(skin::LABEL)
                            .line_height(Some(17.5)),
                    );
                });
                if index + 1 < lines.len() {
                    ui.add_space(metric::TIGHT);
                }
            }
        });
}

/// The screen that has to exist somewhere. Asking for an Apple ID password
/// inside a downloaded app is exactly what a phishing page does, and "trust
/// me" is exactly what a phishing page says. Folded behind the info icon so
/// it is one click away rather than a page everybody has to walk through.
fn assurances(ui: &mut egui::Ui) {
    ui.label(
        RichText::new("iOS only runs an app if Apple has vouched for it, on this exact phone. So Cloak asks Apple, as you, for a signing certificate and for permission for this one iPhone. That is all it asks for.")
            .size(12.5)
            .color(skin::SECOND)
            .line_height(Some(17.5)),
    );
    ui.add_space(metric::SNUG);
    for (title, detail) in [
        ("Your password goes to Apple and nowhere else", "Straight to gsa.apple.com over TLS. There is no Cloak server for it to reach, because there is no Cloak server."),
        ("It is not written down", "Unless the box above is ticked, and then it goes into this computer's keychain, the same place your browser keeps yours."),
        ("Nothing is bought or enrolled", "A free Apple ID works. The paid developer program is not involved and no payment method is touched."),
        ("Your data is not touched", "No photos, no iCloud, no Find My, no messages. The only things that change on your account are one certificate and one registered device."),
    ] {
        ui.horizontal_top(|ui| {
            glyph(ui, icon::CHECK_CIRCLE, 14.0, skin::GREEN);
            ui.add_space(metric::HAIR + 1.0);
            ui.vertical(|ui| {
                ui.label(
                    RichText::new(title)
                        .font(FontId::new(12.8, assets::medium()))
                        .color(skin::LABEL),
                );
                ui.add_space(1.0);
                ui.label(
                    RichText::new(detail)
                        .size(12.0)
                        .color(skin::SECOND)
                        .line_height(Some(17.0)),
                );
            });
        });
        ui.add_space(metric::TIGHT + 2.0);
    }
    footnote(ui, "Still uneasy? Make a second Apple ID, which takes about two minutes, and use that instead. Everything here works exactly the same with it.");
}

/// One connected phone, named down to the tail of its serial. Specificity is
/// what separates something that actually talked to the device from something
/// that guessed.
fn phone_row(ui: &mut egui::Ui, w: f32, phone: &Phone, choosable: bool) -> bool {
    let mut clicked = false;
    let tail: String = phone.udid.chars().rev().take(6).collect::<Vec<_>>().iter().rev().collect();

    egui::Frame::new()
        .fill(skin::FIELD)
        .corner_radius(CornerRadius::same(metric::FIELD_RADIUS))
        .inner_margin(Margin::same(12))
        .show(ui, |ui| {
            ui.set_width(w - 24.0);
            ui.horizontal(|ui| {
                glyph(ui, icon::IPHONE, 22.0, skin::ACCENT);
                ui.add_space(metric::TIGHT);
                ui.vertical(|ui| {
                    ui.label(
                        RichText::new(&phone.name)
                            .font(FontId::new(13.8, assets::medium()))
                            .color(skin::LABEL),
                    );
                    ui.add_space(2.0);
                    ui.label(
                        RichText::new(format!(
                            "{}  \u{00b7}  {}  \u{00b7}  \u{2026}{}",
                            if phone.ios_version.is_empty() {
                                "iOS unknown".to_string()
                            } else {
                                format!("iOS {}", phone.ios_version)
                            },
                            match phone.link {
                                crate::device::Link::Usb => "USB",
                                crate::device::Link::Network => "Wi-Fi only",
                            },
                            tail
                        ))
                        .size(11.5)
                        .color(skin::TERTIARY),
                    );
                });
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if choosable {
                        if secondary(ui, "Use this one").clicked() {
                            clicked = true;
                        }
                    } else {
                        let (label, tint) = match phone.developer_mode {
                            DeveloperMode::On => ("Developer Mode on", skin::GREEN),
                            DeveloperMode::NotApplicable => ("Not needed on this iOS", skin::GREEN),
                            DeveloperMode::Off => ("Developer Mode off", skin::ORANGE),
                            DeveloperMode::Unknown if phone.problem.is_some() => {
                                match phone.problem.as_ref() {
                                    Some(crate::device::Problem::NotTrusted) => {
                                        ("Not trusted yet", skin::ORANGE)
                                    }
                                    Some(crate::device::Problem::WifiOnly) => {
                                        ("Wi-Fi only, needs a cable", skin::ORANGE)
                                    }
                                    Some(crate::device::Problem::Refused(_)) => {
                                        ("Not answering yet", skin::ORANGE)
                                    }
                                    _ => ("Could not read it", skin::ORANGE),
                                }
                            }
                            DeveloperMode::Unknown => ("Could not read the setting", skin::TERTIARY),
                        };
                        ui.label(RichText::new(label).size(11.5).color(tint));
                    }
                });
            });
        });
    if choosable {
        ui.add_space(metric::TIGHT);
    }
    clicked
}

/// A checkbox drawn by hand, because egui's own is a light-mode square and
/// this window is not a light-mode window.
fn check(ui: &mut egui::Ui, on: &mut bool, title: &str, detail: Option<&str>) {
    ui.horizontal_top(|ui| {
        let (rect, response) = ui.allocate_exact_size(Vec2::splat(18.0), Sense::click());
        if response.clicked() {
            *on = !*on;
        }
        let painter = ui.painter();
        if *on {
            painter.rect_filled(rect, CornerRadius::same(5), skin::ACCENT);
            let c = rect.center();
            painter.line_segment(
                [Pos2::new(c.x - 4.0, c.y + 0.2), Pos2::new(c.x - 1.2, c.y + 3.2)],
                Stroke::new(2.0, skin::ON_ACCENT),
            );
            painter.line_segment(
                [Pos2::new(c.x - 1.2, c.y + 3.2), Pos2::new(c.x + 4.2, c.y - 3.2)],
                Stroke::new(2.0, skin::ON_ACCENT),
            );
        } else {
            painter.rect_filled(rect, CornerRadius::same(5), skin::FIELD);
            painter.rect_stroke(
                rect,
                CornerRadius::same(5),
                Stroke::new(
                    1.0,
                    if response.hovered() { skin::ACCENT } else { skin::LINE },
                ),
                egui::StrokeKind::Inside,
            );
        }
        ui.add_space(metric::TIGHT);
        ui.vertical(|ui| {
            let label = ui.add(
                egui::Label::new(
                    RichText::new(title)
                        .font(FontId::new(13.0, assets::medium()))
                        .color(skin::LABEL),
                )
                .sense(Sense::click()),
            );
            if label.clicked() {
                *on = !*on;
            }
            if let Some(detail) = detail {
                ui.add_space(2.0);
                ui.label(
                    RichText::new(detail)
                        .size(11.5)
                        .color(skin::TERTIARY)
                        .line_height(Some(16.5)),
                );
            }
        });
    });
}

/// The one accent-filled button on the screen. Dimmed rather than hidden when
/// it will not do anything yet, because a control that vanishes teaches
/// nobody what they are missing.
fn primary(ui: &mut egui::Ui, text: &str, width: f32) -> egui::Response {
    let enabled = ui.is_enabled();
    let fill = if enabled { skin::ACCENT } else { skin::ACCENT_SOFT };
    let ink = if enabled { skin::ON_ACCENT } else { skin::SECOND };
    ui.add(
        egui::Button::new(
            RichText::new(text).font(FontId::new(14.0, assets::semibold())).color(ink),
        )
        .fill(fill)
        .stroke(Stroke::NONE)
        .corner_radius(CornerRadius::same(metric::FIELD_RADIUS))
        .min_size(Vec2::new(width, metric::BUTTON_H)),
    )
}

/// An action that is not the one primary action: outlined in the accent
/// rather than filled with it, so a screen never has two things shouting.
fn action(ui: &mut egui::Ui, text: &str, width: f32) -> egui::Response {
    let enabled = ui.is_enabled();
    ui.add(
        egui::Button::new(
            RichText::new(text)
                .font(FontId::new(13.5, assets::medium()))
                .color(if enabled { skin::ACCENT } else { skin::TERTIARY }),
        )
        .fill(skin::ACCENT_SOFT)
        .stroke(Stroke::new(1.0, skin::ACCENT.gamma_multiply(0.45)))
        .corner_radius(CornerRadius::same(metric::FIELD_RADIUS))
        .min_size(Vec2::new(width, 36.0)),
    )
}

fn secondary(ui: &mut egui::Ui, text: &str) -> egui::Response {
    ui.add(
        egui::Button::new(
            RichText::new(text)
                .font(FontId::new(12.5, assets::medium()))
                .color(skin::LABEL),
        )
        .fill(skin::FLOATING)
        .stroke(Stroke::new(1.0, skin::LINE))
        .corner_radius(CornerRadius::same(metric::CHIP_RADIUS))
        .min_size(Vec2::new(0.0, 30.0)),
    )
}

/// A glyph and a word, clickable, with no chrome at all. Everything that is
/// not the one primary action is one of these.
fn quiet_link(ui: &mut egui::Ui, symbol: &str, text: &str) -> egui::Response {
    let response = ui
        .horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 4.0;
            let a = ui.add(
                egui::Label::new(
                    RichText::new(symbol)
                        .font(FontId::new(13.0, assets::icons()))
                        .color(skin::SECOND),
                )
                .sense(Sense::click()),
            );
            let b = ui.add(
                egui::Label::new(
                    RichText::new(text)
                        .font(FontId::new(12.5, assets::medium()))
                        .color(skin::SECOND),
                )
                .sense(Sense::click()),
            );
            a.union(b)
        })
        .inner;
    if response.hovered() {
        ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
    }
    response
}

/// The one round control, top right of the card.
fn round_button(ui: &mut egui::Ui, symbol: &str, on: bool) -> egui::Response {
    let (rect, response) = ui.allocate_exact_size(Vec2::splat(30.0), Sense::click());
    let fill = if on {
        skin::ACCENT_SOFT
    } else if response.hovered() {
        skin::FLOATING
    } else {
        skin::RAISED
    };
    ui.painter().circle_filled(rect.center(), 15.0, fill);
    ui.painter().text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        symbol,
        FontId::new(15.0, assets::icons()),
        if on { skin::ACCENT } else { skin::SECOND },
    );
    if response.hovered() {
        ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
    }
    response
}
