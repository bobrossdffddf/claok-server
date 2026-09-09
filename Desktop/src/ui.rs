//! The window.
//!
//! Shaped like a Mac setup assistant: a quiet sidebar naming the steps, a
//! single decision on the right, and one primary action in the bottom corner.
//! Light, because that is what a legitimate installer looks like and a dark
//! one asking for an Apple ID password looks like something else.
//!
//! Type is Inter, standing in for San Francisco. Every glyph is Phosphor.
//! Nothing is drawn by hand except the two things that have to move.

use egui::{
    Align, Color32, CornerRadius, FontFamily, FontId, Layout, Margin, Rect, RichText, Sense,
    Stroke, TextStyle, Vec2,
};
use isideload::auth::apple_account::{TwoFactorCallbackParams, TwoFactorCallbackResponse};

use crate::agent::{self, Schedule};
use crate::assets::{self, icon};
use crate::config::Config;
use crate::device::{DeveloperMode, Phone};
use crate::viz;
use crate::worker::{self, Channels, Command, Event};

pub mod skin {
    use egui::Color32;

    pub const BG: Color32 = Color32::from_rgb(245, 245, 247);
    pub const PANEL: Color32 = Color32::from_rgb(255, 255, 255);
    pub const LINE: Color32 = Color32::from_rgb(227, 227, 232);
    pub const LABEL: Color32 = Color32::from_rgb(29, 29, 31);
    pub const SECOND: Color32 = Color32::from_rgb(110, 110, 115);
    pub const TERTIARY: Color32 = Color32::from_rgb(161, 161, 166);
    pub const ACCENT: Color32 = Color32::from_rgb(14, 147, 132);
    pub const ACCENT_SOFT: Color32 = Color32::from_rgb(230, 246, 244);
    pub const GREEN: Color32 = Color32::from_rgb(30, 158, 82);
    pub const ORANGE: Color32 = Color32::from_rgb(194, 112, 10);
    pub const RED: Color32 = Color32::from_rgb(214, 48, 58);
    pub const RED_SOFT: Color32 = Color32::from_rgb(253, 237, 238);
}

#[derive(PartialEq, Clone, Copy)]
enum Step {
    Welcome,
    Looking,
    NoDriver,
    PickPhone,
    Found,
    DeveloperMode,
    Rebooting,
    WhyAppleID,
    SignIn,
    Working,
    TrustApp,
    Done,
}

impl Step {
    fn stage(self) -> usize {
        match self {
            Step::Welcome | Step::Looking | Step::NoDriver | Step::PickPhone | Step::Found => 0,
            Step::DeveloperMode | Step::Rebooting => 1,
            Step::WhyAppleID | Step::SignIn => 2,
            Step::Working => 3,
            Step::TrustApp | Step::Done => 4,
        }
    }
}

const STAGES: [(&str, &str); 5] = [
    (icon::IPHONE, "Your iPhone"),
    (icon::WRENCH, "Developer Mode"),
    (icon::KEY, "Apple ID"),
    (icon::DOWNLOAD, "Install"),
    (icon::CHECK_CIRCLE, "Finish"),
];

pub struct Installer {
    channels: Channels,
    step: Step,
    phones: Vec<Phone>,
    chosen: Option<Phone>,
    apple_id: String,
    password: String,
    remember: bool,
    status: String,
    progress: f32,
    failure: Option<String>,
    two_factor: Option<TwoFactorCallbackParams>,
    code: String,
    config: Config,
    revealed: bool,
    trusted: bool,
    last_scan: std::time::Instant,
    started_at: Option<std::time::Instant>,
}

impl Installer {
    pub fn new(channels: Channels, cc: &eframe::CreationContext<'_>) -> Self {
        assets::install(&cc.egui_ctx);
        style(&cc.egui_ctx);
        let config = Config::load();
        let _ = channels.commands.send(Command::Scan);
        Self {
            channels,
            step: Step::Welcome,
            phones: Vec::new(),
            chosen: None,
            apple_id: config.apple_id.clone().unwrap_or_default(),
            password: String::new(),
            remember: true,
            status: "Looking for your iPhone".into(),
            progress: 0.0,
            failure: None,
            two_factor: None,
            code: String::new(),
            config,
            revealed: false,
            trusted: false,
            last_scan: std::time::Instant::now(),
            started_at: None,
        }
    }

    fn send(&self, command: Command) {
        let _ = self.channels.commands.send(command);
    }

    fn drain(&mut self, ctx: &egui::Context) {
        while let Ok(event) = self.channels.events.try_recv() {
            match event {
                Event::DriverMissing => {
                    if self.step != Step::Welcome {
                        self.step = Step::NoDriver;
                    }
                }
                Event::Phones(phones) => {
                    self.phones = phones;
                    if let Some(current) = &self.chosen {
                        self.chosen = self.phones.iter().find(|p| p.udid == current.udid).cloned();
                    }
                    match self.step {
                        Step::Looking | Step::NoDriver | Step::PickPhone | Step::Rebooting => {
                            self.advance_from_phones()
                        }
                        Step::DeveloperMode => {
                            if self.chosen.as_ref().is_some_and(worker::developer_mode_ok) {
                                self.step = Step::WhyAppleID;
                            }
                        }
                        _ => {}
                    }
                }
                Event::Status(text) => self.status = text,
                Event::Progress(fraction) => self.progress = fraction,
                Event::NeedTwoFactor(params) => {
                    self.two_factor = Some(*params);
                    self.code.clear();
                }
                Event::DeveloperModeRevealed => self.revealed = true,
                Event::Trusted(ok) => self.trusted = ok,
                Event::Rebooting => self.step = Step::Rebooting,
                Event::Installed => {
                    self.password.clear();
                    self.config = Config::load();
                    // iOS answered the trust prompt itself on anything recent
                    // enough. When it did not, that is a real step the user
                    // has to do and it gets a screen of its own.
                    self.step = if self.trusted { Step::Done } else { Step::TrustApp };
                }
                Event::Failed(message) => {
                    self.failure = Some(message);
                    self.two_factor = None;
                    if self.step == Step::Working {
                        self.step = Step::SignIn;
                    }
                }
            }
            ctx.request_repaint();
        }

        let idle = matches!(
            self.step,
            Step::Looking | Step::NoDriver | Step::PickPhone | Step::Rebooting
        );
        if idle && self.last_scan.elapsed() > std::time::Duration::from_secs(2) {
            self.last_scan = std::time::Instant::now();
            self.send(Command::Scan);
        }
    }

    fn advance_from_phones(&mut self) {
        match self.phones.len() {
            0 => {
                if self.step != Step::NoDriver {
                    self.step = Step::Looking
                }
            }
            1 => {
                self.chosen = self.phones.first().cloned();
                self.step = Step::Found;
            }
            _ => self.step = Step::PickPhone,
        }
    }
}

impl eframe::App for Installer {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        let c = skin::BG;
        [c.r() as f32 / 255.0, c.g() as f32 / 255.0, c.b() as f32 / 255.0, 1.0]
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.drain(ctx);

        // Only spend frames while something is genuinely moving. A fan
        // spinning up during an install is itself a trust event.
        if matches!(self.step, Step::Looking | Step::Rebooting | Step::Working) {
            ctx.request_repaint_after(std::time::Duration::from_millis(33));
        }

        egui::SidePanel::left("stages")
            .exact_width(226.0)
            .resizable(false)
            .frame(
                egui::Frame::new()
                    .fill(skin::PANEL)
                    .inner_margin(Margin::symmetric(16, 22)),
            )
            .show(ctx, |ui| self.sidebar(ui));

        egui::TopBottomPanel::bottom("actions")
            .frame(
                egui::Frame::new()
                    .fill(skin::BG)
                    .inner_margin(Margin { left: 32, right: 32, top: 14, bottom: 20 }),
            )
            .show_separator_line(false)
            .show(ctx, |ui| self.actions(ui));

        egui::CentralPanel::default()
            .frame(
                egui::Frame::new()
                    .fill(skin::BG)
                    .inner_margin(Margin { left: 32, right: 32, top: 30, bottom: 4 }),
            )
            .show(ctx, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| self.content(ui));
            });

        if self.two_factor.is_some() {
            self.two_factor_window(ctx);
        }
    }
}

impl Installer {
    // MARK: - Sidebar

    fn sidebar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            glyph(ui, icon::MAP_PIN, 20.0, skin::ACCENT);
            ui.add_space(2.0);
            ui.vertical(|ui| {
                ui.add_space(1.0);
                ui.label(RichText::new("Cloak").font(FontId::new(16.0, assets::semibold())).color(skin::LABEL));
                ui.label(RichText::new("Installer").size(11.5).color(skin::TERTIARY));
            });
        });

        ui.add_space(26.0);

        let stage = self.step.stage();
        for (index, (symbol, name)) in STAGES.iter().enumerate() {
            self.stage_row(ui, index, stage, symbol, name);
        }

        ui.with_layout(Layout::bottom_up(Align::Min), |ui| {
            ui.add_space(2.0);
            ui.label(
                RichText::new("Your password goes to Apple and nowhere else.")
                    .size(10.5)
                    .color(skin::TERTIARY),
            );
            ui.add_space(4.0);
            ui.label(
                RichText::new(format!("Version {}", env!("CARGO_PKG_VERSION")))
                    .size(10.5)
                    .color(skin::TERTIARY),
            );
        });
    }

    fn stage_row(&self, ui: &mut egui::Ui, index: usize, stage: usize, symbol: &str, name: &str) {
        let done = index < stage;
        let current = index == stage;

        let fill = if current { skin::ACCENT_SOFT } else { Color32::TRANSPARENT };
        egui::Frame::new()
            .fill(fill)
            .corner_radius(CornerRadius::same(7))
            .inner_margin(Margin::symmetric(9, 8))
            .show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.horizontal(|ui| {
                    let tint = if done {
                        skin::GREEN
                    } else if current {
                        skin::ACCENT
                    } else {
                        skin::TERTIARY
                    };
                    glyph(ui, if done { icon::CHECK_CIRCLE } else { symbol }, 16.0, tint);
                    ui.add_space(4.0);
                    ui.label(
                        RichText::new(name)
                            .font(FontId::new(
                                13.5,
                                if current { assets::medium() } else { FontFamily::Proportional },
                            ))
                            .color(if current || done { skin::LABEL } else { skin::SECOND }),
                    );
                });
            });
        ui.add_space(2.0);
    }

    // MARK: - Content

    fn content(&mut self, ui: &mut egui::Ui) {
        if let Some(message) = self.failure.clone() {
            notice(ui, skin::RED, skin::RED_SOFT, icon::WARNING_CIRCLE, "That did not work", &message);
            ui.add_space(20.0);
        }

        match self.step {
            Step::Welcome => self.welcome(ui),
            Step::Looking => self.looking(ui),
            Step::NoDriver => self.no_driver(ui),
            Step::PickPhone => self.pick_phone(ui),
            Step::Found => self.found(ui),
            Step::DeveloperMode => self.developer_mode(ui),
            Step::Rebooting => self.rebooting(ui),
            Step::WhyAppleID => self.why_apple_id(ui),
            Step::SignIn => self.sign_in(ui),
            Step::Working => self.working(ui),
            Step::TrustApp => self.trust_app(ui),
            Step::Done => self.done(ui),
        }
    }

    fn welcome(&mut self, ui: &mut egui::Ui) {
        title(ui, "Put your phone anywhere");
        lede(ui, "Cloak changes the location your iPhone reports to every app on it, using the location simulator Apple already ships inside iOS. This puts it on your phone. Here is the whole of it.");
        ui.add_space(22.0);

        list_item(ui, icon::PLUG, "Plug your iPhone in", "Over the cable, once. Everything after this happens on the phone alone.");
        list_item(ui, icon::WRENCH, "Turn on Developer Mode", "This does it for you, including making the switch appear in Settings. iOS hides it until a computer asks.");
        list_item(ui, icon::KEY, "Sign in with your Apple ID", "Apple has to vouch for the app before iOS will run it. The next screen explains why, before you type anything.");
        list_item(ui, icon::DOWNLOAD, "Add one free App Store app", "LocalDevVPN. Apple will not let a free account sign the part that would replace it.");

        ui.add_space(6.0);
        footnote(ui, "Nothing is bought, nothing is enrolled, and no payment method is touched. A free Apple ID is enough.");
    }

    fn looking(&mut self, ui: &mut egui::Ui) {
        title(ui, "Plug in your iPhone");
        lede(ui, "Use the cable that came with it. Unlock the phone, and if it asks whether to trust this computer, say Trust.");
        ui.add_space(24.0);

        card(ui, |ui| {
            ui.horizontal(|ui| {
                let (rect, _) = ui.allocate_exact_size(Vec2::splat(64.0), Sense::hover());
                let t = ui.input(|i| i.time) as f32;
                viz::radar(ui.painter(), rect, t);
                ui.add_space(10.0);
                ui.vertical(|ui| {
                    ui.add_space(14.0);
                    ui.label(RichText::new("Watching for it").font(FontId::new(15.0, assets::medium())).color(skin::LABEL));
                    ui.label(RichText::new("Nothing found yet").size(13.0).color(skin::SECOND));
                });
            });
        });
    }

    fn no_driver(&mut self, ui: &mut egui::Ui) {
        title(ui, "One thing to install first");
        if cfg!(windows) {
            lede(ui, "Windows has no iPhone driver of its own. Apple's comes bundled with iTunes, and that is the only reason you need it. This never opens iTunes and never syncs anything.");
            ui.add_space(20.0);
            notice(ui, skin::ORANGE, Color32::from_rgb(255, 247, 235), icon::INFO,
                "Use Apple's download, not the Microsoft Store",
                "The Store version does not always register the device service. Install it, come back here, and press Check again.");
        } else {
            lede(ui, "macOS could not reach its own iPhone service, which is unusual. Restarting the Mac normally settles it.");
        }
    }

    fn pick_phone(&mut self, ui: &mut egui::Ui) {
        title(ui, "Which iPhone?");
        lede(ui, "More than one is plugged in.");
        ui.add_space(20.0);

        let phones = self.phones.clone();
        for phone in phones {
            if phone_row(ui, &phone, false) {
                let ok = worker::developer_mode_ok(&phone);
                self.chosen = Some(phone);
                self.step = if ok { Step::WhyAppleID } else { Step::DeveloperMode };
            }
        }
    }

    fn developer_mode(&mut self, ui: &mut egui::Ui) {
        title(ui, "Turn on Developer Mode");
        lede(ui, "iOS will not run an app signed by an ordinary person until this is on, and it hides the switch entirely until a computer asks for it. That is why people follow instructions saying to find Developer Mode in Settings and there is no such row.");
        ui.add_space(20.0);

        if let Some(phone) = self.chosen.clone() {
            phone_row(ui, &phone, true);
            ui.add_space(16.0);
        }

        if self.revealed {
            notice(ui, skin::GREEN, Color32::from_rgb(236, 249, 241), icon::CHECK_CIRCLE,
                "The switch is there now",
                "On the phone: Settings, then Privacy & Security, then Developer Mode.");
            ui.add_space(16.0);
        }

        footnote(ui, "Turning it on restarts the phone, which is normal and loses nothing. If iOS refuses because a passcode is set, turn the passcode off for this one step and put it straight back.");
    }

    fn rebooting(&mut self, ui: &mut egui::Ui) {
        title(ui, "Your iPhone is restarting");
        lede(ui, "When it comes back, unlock it. It will ask whether to turn Developer Mode on, and you say yes.");
        ui.add_space(24.0);

        card(ui, |ui| {
            ui.horizontal(|ui| {
                let (rect, _) = ui.allocate_exact_size(Vec2::splat(64.0), Sense::hover());
                let t = ui.input(|i| i.time) as f32;
                viz::radar(ui.painter(), rect, t);
                ui.add_space(10.0);
                ui.vertical(|ui| {
                    ui.add_space(18.0);
                    ui.label(RichText::new(self.status.clone()).font(FontId::new(15.0, assets::medium())).color(skin::LABEL));
                    ui.label(RichText::new("Waiting for it to come back").size(13.0).color(skin::SECOND));
                });
            });
        });
    }

    /// The screen that has to exist. Asking for an Apple ID password inside a
    /// downloaded app is exactly what a phishing page does, and "trust me" is
    /// exactly what a phishing page says.
    fn why_apple_id(&mut self, ui: &mut egui::Ui) {
        title(ui, "Why this needs your Apple ID");
        lede(ui, "iOS only runs an app if Apple has vouched for it, on this exact phone. There is no way around that and no way to do it on your behalf. So this asks Apple, as you, for two things.");
        ui.add_space(20.0);

        list_item(ui, icon::SHIELD_CHECK, "A signing certificate", "The same one Xcode requests when a developer runs their own app on their own phone.");
        list_item(ui, icon::IPHONE, "Permission for this iPhone", "Apple records that this specific device may run apps you signed.");

        ui.add_space(10.0);
        rule(ui);
        ui.add_space(18.0);

        headline(ui, "What it does not do");
        ui.add_space(12.0);

        assurance(ui, "Your password goes to Apple and nowhere else", "Straight to gsa.apple.com over TLS. There is no Cloak server for it to reach, because there is no Cloak server.");
        assurance(ui, "It is not written down", "Unless you switch on automatic renewal at the end, and then it goes into your operating system's keychain, the same place your browser keeps yours.");
        assurance(ui, "Nothing is bought or enrolled", "A free Apple ID works. The paid developer program is not involved and no payment method is touched.");
        assurance(ui, "Your data is not touched", "No photos, no iCloud, no Find My, no messages. The only things that change on your account are one certificate and one registered device.");

        ui.add_space(8.0);
        notice(ui, skin::ACCENT, skin::ACCENT_SOFT, icon::INFO,
            "Still uneasy?",
            "Make a second Apple ID, which takes about two minutes, and use that instead. Everything here works exactly the same with it.");
    }

    fn sign_in(&mut self, ui: &mut egui::Ui) {
        title(ui, "Sign in with your Apple ID");
        lede(ui, "This goes to Apple directly. You will get a six digit code on your other devices, the same as signing in anywhere else.");
        ui.add_space(22.0);

        card(ui, |ui| {
            field(ui, "Apple ID", |ui| {
                ui.add(
                    egui::TextEdit::singleline(&mut self.apple_id)
                        .desired_width(f32::INFINITY)
                        .margin(Margin::symmetric(10, 9))
                        .hint_text("you@example.com"),
                );
            });
            ui.add_space(14.0);
            field(ui, "Password", |ui| {
                ui.add(
                    egui::TextEdit::singleline(&mut self.password)
                        .password(true)
                        .desired_width(f32::INFINITY)
                        .margin(Margin::symmetric(10, 9)),
                );
            });
            ui.add_space(8.0);
            footnote(ui, "Your real password, not an app-specific one. App-specific passwords do not work for this.");
        });

        ui.add_space(18.0);

        card(ui, |ui| {
            ui.horizontal(|ui| {
                ui.checkbox(&mut self.remember, "");
                ui.vertical(|ui| {
                    ui.label(RichText::new("Keep Cloak working after a week").font(FontId::new(14.0, assets::medium())).color(skin::LABEL));
                    ui.add_space(2.0);
                    ui.label(
                        RichText::new("Apple's free signature expires every seven days. With this on, the password goes into your keychain and this computer renews Cloak quietly. With it off, nothing is stored and you run this again each week.")
                            .size(12.5)
                            .color(skin::SECOND),
                    );
                });
            });
        });
    }

    fn working(&mut self, ui: &mut egui::Ui) {
        title(ui, "Installing");
        ui.add_space(18.0);

        card(ui, |ui| {
            ui.horizontal(|ui| {
                let (rect, _) = ui.allocate_exact_size(Vec2::splat(78.0), Sense::hover());
                viz::ring(ui.painter(), rect, self.progress);
                ui.add_space(14.0);
                ui.vertical(|ui| {
                    ui.add_space(20.0);
                    ui.label(RichText::new(self.status.clone()).font(FontId::new(16.0, assets::medium())).color(skin::LABEL));
                    ui.add_space(2.0);
                    ui.label(RichText::new(self.elapsed_text()).size(12.5).color(skin::SECOND));
                });
            });

            ui.add_space(16.0);
            rule(ui);
            ui.add_space(14.0);

            let phases: [(f32, &str); 6] = [
                (0.08, "Signing in with Apple"),
                (0.18, "Opening your developer account"),
                (0.24, "Registering this iPhone"),
                (0.32, "Getting a signing certificate"),
                (0.66, "Signing Cloak"),
                (0.96, "Copying it across"),
            ];
            for (at, name) in phases {
                phase_row(ui, self.progress, at, name);
            }
        });

        ui.add_space(14.0);
        footnote(ui, "The first run takes a minute or two. Signing hashes every file in the app, which is the slow part, and it only happens once. If a code was sent to your other devices, the box for it is waiting in front of this window.");
    }

    /// A phone that has been found, before anything is done to it. One screen
    /// that only says "this is the phone I am about to work on" costs a click
    /// and removes the worst feeling in an installer, which is watching
    /// something happen to a device you have not agreed on yet.
    fn found(&mut self, ui: &mut egui::Ui) {
        title(ui, "Found your iPhone");
        lede(ui, "This is the phone Cloak will be installed on. Nothing has been changed yet.");
        ui.add_space(22.0);

        if let Some(phone) = self.chosen.clone() {
            phone_row(ui, &phone, true);
        }

        ui.add_space(16.0);

        let needs_developer_mode = !self.chosen.as_ref().is_some_and(worker::developer_mode_ok);
        if needs_developer_mode {
            notice(ui, skin::ORANGE, Color32::from_rgb(255, 247, 235), icon::WRENCH,
                "Developer Mode is off",
                "That is normal and expected. The next screen turns it on for you, which takes one restart of the phone.");
        } else {
            notice(ui, skin::GREEN, Color32::from_rgb(236, 249, 241), icon::CHECK_CIRCLE,
                "Developer Mode is already on",
                "Nothing to do there. Straight on to signing in.");
        }

        ui.add_space(16.0);
        footnote(ui, "If this is the wrong phone, unplug it and plug in the one you want.");
    }

    /// Only shown when iOS would not answer the trust prompt itself, which
    /// means an older iOS or a device that refused. Then it is a genuine
    /// manual step and deserves its own screen with the exact path spelled
    /// out, because the row in Settings is not obviously the right one.
    fn trust_app(&mut self, ui: &mut egui::Ui) {
        title(ui, "One tap on the phone");
        lede(ui, "iOS will not open an app signed by an ordinary Apple ID until you say, on the phone itself, that you meant to install it. On newer iOS this installer answers that for you. Yours wants to hear it from you.");
        ui.add_space(22.0);

        step_line(ui, 1, "Open Settings on the iPhone");
        step_line(ui, 2, "Tap General");
        step_line(ui, 3, "Tap VPN & Device Management");
        step_line(ui, 4, "Tap your Apple ID under Developer App");
        step_line(ui, 5, "Tap Trust, then Trust again");

        ui.add_space(14.0);
        footnote(ui, "If Cloak opens and immediately closes, this is why. It is a one-time thing per Apple ID, not per install.");
    }

    fn done(&mut self, ui: &mut egui::Ui) {
        title(ui, "All set");
        lede(ui, "Open Cloak on your phone. It already has the key this computer handed it, so there is no code to type and no pairing to sit through. It will walk you through the last piece, one free App Store app, and then everything happens on the phone alone.");
        ui.add_space(20.0);

        if self.trusted {
            notice(ui, skin::GREEN, Color32::from_rgb(236, 249, 241), icon::SHIELD_CHECK,
                "Already trusted",
                "iOS accepted the signature, so Cloak opens straight away with no warning about an untrusted developer.");
            ui.add_space(16.0);
        }

        let scheduled = agent::status() == Schedule::Installed;
        if scheduled {
            notice(ui, skin::GREEN, Color32::from_rgb(236, 249, 241), icon::REFRESH,
                "Automatic renewal is on",
                "Apple's signature lasts seven days. This computer renews it every few days as long as your phone has been plugged in recently. Your places, routes and recordings survive a renewal.");
        } else {
            notice(ui, skin::ORANGE, Color32::from_rgb(255, 247, 235), icon::CLOCK,
                "Apple's signature runs out in seven days",
                "Cloak stops opening when it does. Turning on automatic renewal lets this computer take care of it quietly.");
        }

        if let Some(days) = self.config.days_until_expiry() {
            ui.add_space(14.0);
            footnote(ui, &format!("Signature good for about {days} more days."));
        }
    }

    // MARK: - Actions

    fn actions(&mut self, ui: &mut egui::Ui) {
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| match self.step {
            Step::Welcome => {
                if primary(ui, "Begin").clicked() {
                    self.step = Step::Looking;
                    self.send(Command::Scan);
                }
            }
            Step::Looking => {
                ui.add_enabled_ui(false, |ui| { let _ = primary(ui, "Continue"); });
                if secondary(ui, "Check again").clicked() { self.send(Command::Scan); }
            }
            Step::NoDriver => {
                if cfg!(windows) {
                    if primary(ui, "Get iTunes from Apple").clicked() {
                        let _ = open::that("https://www.apple.com/itunes/download/win64");
                    }
                }
                if secondary(ui, "Check again").clicked() { self.send(Command::Scan); }
            }
            Step::PickPhone => {}
            Step::Found => {
                let needs = !self.chosen.as_ref().is_some_and(worker::developer_mode_ok);
                if primary(ui, "Continue").clicked() {
                    self.step = if needs { Step::DeveloperMode } else { Step::WhyAppleID };
                }
                if secondary(ui, "Use a different iPhone").clicked() {
                    self.chosen = None;
                    self.step = Step::Looking;
                    self.send(Command::Scan);
                }
            }
            Step::DeveloperMode => {
                let udid = self.chosen.as_ref().map(|p| p.udid.clone()).unwrap_or_default();
                if primary(ui, "Turn it on for me").clicked() {
                    self.failure = None;
                    self.send(Command::EnableDeveloperMode { udid: udid.clone() });
                }
                if secondary(ui, "It is already on").clicked() { self.step = Step::WhyAppleID; }
                if secondary(ui, "Just reveal the switch").clicked() {
                    self.failure = None;
                    self.send(Command::RevealDeveloperMode { udid });
                }
            }
            Step::Rebooting => {
                ui.add_enabled_ui(false, |ui| { let _ = primary(ui, "Waiting"); });
            }
            Step::WhyAppleID => {
                if primary(ui, "Continue").clicked() { self.step = Step::SignIn; }
            }
            Step::SignIn => {
                let ready = !self.apple_id.trim().is_empty() && !self.password.is_empty();
                ui.add_enabled_ui(ready, |ui| {
                    if primary(ui, "Install Cloak").clicked() {
                        self.failure = None;
                        self.progress = 0.0;
                        self.status = "Reaching Apple".into();
                        self.started_at = Some(std::time::Instant::now());
                        self.step = Step::Working;
                        self.send(Command::Install {
                            udid: self.chosen.as_ref().map(|p| p.udid.clone()).unwrap_or_default(),
                            apple_id: self.apple_id.trim().to_string(),
                            password: self.password.clone(),
                            remember: self.remember,
                        });
                    }
                });
                if secondary(ui, "Why do you need this?").clicked() { self.step = Step::WhyAppleID; }
            }
            Step::Working => {
                ui.add_enabled_ui(false, |ui| { let _ = primary(ui, "Installing"); });
            }
            Step::TrustApp => {
                if primary(ui, "I have done that").clicked() { self.step = Step::Done; }
            }
            Step::Done => {
                let scheduled = agent::status() == Schedule::Installed;
                if scheduled {
                    if secondary(ui, "Turn renewal off").clicked() { let _ = agent::remove(); }
                } else if primary(ui, "Turn on automatic renewal").clicked() {
                    if let Err(message) = agent::install() { self.failure = Some(message); }
                }
            }
        });
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

    // MARK: - Two-factor

    fn two_factor_window(&mut self, ctx: &egui::Context) {
        let params = self.two_factor.clone().unwrap();
        let mut open = true;

        egui::Window::new("Apple sent you a code")
            .collapsible(false)
            .resizable(false)
            .anchor(egui::Align2::CENTER_CENTER, Vec2::ZERO)
            .open(&mut open)
            .frame(
                egui::Frame::new()
                    .fill(skin::PANEL)
                    .corner_radius(CornerRadius::same(12))
                    .stroke(Stroke::new(1.0, skin::LINE))
                    .inner_margin(Margin::same(22))
                    .shadow(egui::epaint::Shadow {
                        offset: [0, 8],
                        blur: 28,
                        spread: 0,
                        color: Color32::from_black_alpha(38),
                    }),
            )
            .show(ctx, |ui| {
                ui.set_min_width(320.0);
                ui.label(
                    RichText::new(if params.sms {
                        "Check your text messages for the six digit code."
                    } else {
                        "Check your other Apple devices for the six digit code."
                    })
                    .size(13.5)
                    .color(skin::SECOND),
                );
                if let Some(last) = &params.last_error {
                    ui.add_space(8.0);
                    ui.label(RichText::new(last).size(13.0).color(skin::RED));
                }
                ui.add_space(14.0);
                let response = ui.add(
                    egui::TextEdit::singleline(&mut self.code)
                        .hint_text("000000")
                        .margin(Margin::symmetric(10, 11))
                        .horizontal_align(Align::Center)
                        .font(FontId::new(22.0, FontFamily::Monospace))
                        .desired_width(f32::INFINITY),
                );
                let entered = response.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));

                ui.add_space(14.0);
                let ready = self.code.trim().len() >= 6;
                ui.add_enabled_ui(ready, |ui| {
                    if primary(ui, "Continue").clicked() || (entered && ready) {
                        self.send(Command::TwoFactor(TwoFactorCallbackResponse::SubmitCode(
                            self.code.trim().to_string(),
                        )));
                        self.two_factor = None;
                    }
                });

                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    if secondary(ui, "Send it again").clicked() {
                        self.send(Command::TwoFactor(TwoFactorCallbackResponse::ResendCode));
                    }
                    if !params.numbers.is_empty() && secondary(ui, "Text it to me").clicked() {
                        let id = params.numbers[0].id;
                        self.send(Command::TwoFactor(TwoFactorCallbackResponse::SendSms(id)));
                    }
                });
            });

        if !open {
            self.send(Command::TwoFactor(TwoFactorCallbackResponse::Abort));
            self.two_factor = None;
        }
    }
}

// MARK: - Style

fn style(ctx: &egui::Context) {
    let mut style = (*ctx.style()).clone();
    style.spacing.item_spacing = Vec2::new(8.0, 8.0);
    style.spacing.button_padding = Vec2::new(16.0, 9.0);
    style.spacing.interact_size.y = 32.0;

    let mut visuals = egui::Visuals::light();
    visuals.panel_fill = skin::BG;
    visuals.window_fill = skin::PANEL;
    visuals.extreme_bg_color = Color32::WHITE;
    visuals.override_text_color = Some(skin::LABEL);
    visuals.selection.bg_fill = skin::ACCENT.gamma_multiply(0.28);
    visuals.widgets.noninteractive.bg_fill = skin::PANEL;
    visuals.widgets.noninteractive.bg_stroke = Stroke::new(1.0, skin::LINE);
    visuals.widgets.inactive.bg_fill = Color32::WHITE;
    visuals.widgets.inactive.weak_bg_fill = Color32::WHITE;
    visuals.widgets.inactive.bg_stroke = Stroke::new(1.0, skin::LINE);
    visuals.widgets.hovered.bg_fill = Color32::from_rgb(248, 248, 250);
    visuals.widgets.hovered.weak_bg_fill = Color32::from_rgb(248, 248, 250);
    visuals.widgets.hovered.bg_stroke = Stroke::new(1.0, skin::TERTIARY);
    visuals.widgets.active.bg_fill = Color32::from_rgb(240, 240, 244);
    visuals.widgets.active.weak_bg_fill = Color32::from_rgb(240, 240, 244);
    visuals.window_stroke = Stroke::new(1.0, skin::LINE);
    style.visuals = visuals;

    style.text_styles.insert(TextStyle::Body, FontId::new(14.0, FontFamily::Proportional));
    style.text_styles.insert(TextStyle::Button, FontId::new(14.0, assets::medium()));
    style.text_styles.insert(TextStyle::Small, FontId::new(11.5, FontFamily::Proportional));

    ctx.set_style(style);
}

// MARK: - Pieces

fn glyph(ui: &mut egui::Ui, symbol: &str, size: f32, tint: Color32) {
    ui.label(RichText::new(symbol).font(FontId::new(size, assets::icons())).color(tint));
}

fn title(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).font(FontId::new(26.0, assets::display())).color(skin::LABEL));
    ui.add_space(10.0);
}

fn headline(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).font(FontId::new(15.5, assets::semibold())).color(skin::LABEL));
}

fn lede(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).size(14.0).color(skin::SECOND).line_height(Some(21.0)));
}

fn footnote(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).size(12.0).color(skin::TERTIARY).line_height(Some(17.0)));
}

fn rule(ui: &mut egui::Ui) {
    let (rect, _) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 1.0), Sense::hover());
    ui.painter()
        .line_segment([rect.left_center(), rect.right_center()], Stroke::new(1.0, skin::LINE));
}

fn card(ui: &mut egui::Ui, body: impl FnOnce(&mut egui::Ui)) {
    egui::Frame::new()
        .fill(skin::PANEL)
        .corner_radius(CornerRadius::same(10))
        .stroke(Stroke::new(1.0, skin::LINE))
        .inner_margin(Margin::same(18))
        .show(ui, |ui| {
            ui.set_width(ui.available_width() - 36.0);
            body(ui)
        });
}

fn notice(ui: &mut egui::Ui, tint: Color32, fill: Color32, symbol: &str, title: &str, body: &str) {
    egui::Frame::new()
        .fill(fill)
        .corner_radius(CornerRadius::same(10))
        .inner_margin(Margin::same(16))
        .show(ui, |ui| {
            ui.set_width(ui.available_width() - 32.0);
            ui.horizontal_top(|ui| {
                glyph(ui, symbol, 18.0, tint);
                ui.add_space(6.0);
                ui.vertical(|ui| {
                    ui.label(RichText::new(title).font(FontId::new(14.0, assets::medium())).color(skin::LABEL));
                    ui.add_space(3.0);
                    ui.label(RichText::new(body).size(13.0).color(skin::SECOND).line_height(Some(18.5)));
                });
            });
        });
}

fn list_item(ui: &mut egui::Ui, symbol: &str, title: &str, detail: &str) {
    ui.horizontal_top(|ui| {
        egui::Frame::new()
            .fill(skin::ACCENT_SOFT)
            .corner_radius(CornerRadius::same(8))
            .inner_margin(Margin::same(8))
            .show(ui, |ui| glyph(ui, symbol, 17.0, skin::ACCENT));
        ui.add_space(6.0);
        ui.vertical(|ui| {
            ui.add_space(2.0);
            ui.label(RichText::new(title).font(FontId::new(14.5, assets::medium())).color(skin::LABEL));
            ui.add_space(2.0);
            ui.label(RichText::new(detail).size(13.0).color(skin::SECOND).line_height(Some(18.5)));
        });
    });
    ui.add_space(14.0);
}

fn assurance(ui: &mut egui::Ui, title: &str, detail: &str) {
    ui.horizontal_top(|ui| {
        glyph(ui, icon::CHECK_CIRCLE, 16.0, skin::GREEN);
        ui.add_space(5.0);
        ui.vertical(|ui| {
            ui.label(RichText::new(title).font(FontId::new(13.8, assets::medium())).color(skin::LABEL));
            ui.add_space(1.0);
            ui.label(RichText::new(detail).size(12.8).color(skin::SECOND).line_height(Some(18.0)));
        });
    });
    ui.add_space(12.0);
}

fn field(ui: &mut egui::Ui, label: &str, body: impl FnOnce(&mut egui::Ui)) {
    ui.label(RichText::new(label).size(12.0).color(skin::SECOND));
    ui.add_space(5.0);
    body(ui);
}

/// One connected phone, named down to the tail of its serial. Specificity is
/// what separates something that actually talked to the device from something
/// that guessed.
fn phone_row(ui: &mut egui::Ui, phone: &Phone, quiet: bool) -> bool {
    let mut clicked = false;
    let tail: String = phone.udid.chars().rev().take(6).collect::<Vec<_>>().iter().rev().collect();

    egui::Frame::new()
        .fill(skin::PANEL)
        .corner_radius(CornerRadius::same(10))
        .stroke(Stroke::new(1.0, skin::LINE))
        .inner_margin(Margin::same(16))
        .show(ui, |ui| {
            ui.set_width(ui.available_width() - 32.0);
            ui.horizontal(|ui| {
                glyph(ui, icon::IPHONE, 24.0, skin::ACCENT);
                ui.add_space(8.0);
                ui.vertical(|ui| {
                    ui.label(RichText::new(&phone.name).font(FontId::new(14.5, assets::medium())).color(skin::LABEL));
                    ui.add_space(2.0);
                    ui.label(
                        RichText::new(format!("iOS {}  ·  USB  ·  …{}", phone.ios_version, tail))
                            .size(12.5)
                            .color(skin::SECOND),
                    );
                });
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if quiet {
                        let (label, tint) = match phone.developer_mode {
                            DeveloperMode::On => ("Developer Mode on", skin::GREEN),
                            DeveloperMode::NotApplicable => ("Not needed on this iOS", skin::GREEN),
                            DeveloperMode::Off => ("Developer Mode off", skin::ORANGE),
                            DeveloperMode::Unknown => ("Could not read the setting", skin::TERTIARY),
                        };
                        ui.label(RichText::new(label).size(12.5).color(tint));
                    } else if secondary(ui, "Use this one").clicked() {
                        clicked = true;
                    }
                });
            });
        });
    ui.add_space(10.0);
    clicked
}

fn step_line(ui: &mut egui::Ui, number: usize, text: &str) {
    ui.horizontal(|ui| {
        let (rect, _) = ui.allocate_exact_size(Vec2::splat(24.0), Sense::hover());
        ui.painter().circle_filled(rect.center(), 11.0, skin::ACCENT_SOFT);
        ui.painter().text(
            rect.center(),
            egui::Align2::CENTER_CENTER,
            number.to_string(),
            FontId::new(12.0, assets::medium()),
            skin::ACCENT,
        );
        ui.add_space(4.0);
        ui.label(RichText::new(text).size(14.0).color(skin::LABEL));
    });
    ui.add_space(10.0);
}

fn phase_row(ui: &mut egui::Ui, progress: f32, at: f32, name: &str) {
    let done = progress > at + 0.005;
    let current = !done && progress >= at - 0.06;

    ui.horizontal(|ui| {
        if done {
            glyph(ui, icon::CHECK_CIRCLE, 15.0, skin::GREEN);
        } else if current {
            let (rect, _) = ui.allocate_exact_size(Vec2::splat(17.0), Sense::hover());
            let t = ui.input(|i| i.time) as f32;
            let pulse = 4.0 + (t * 3.4).sin() * 1.4;
            ui.painter().circle_filled(rect.center(), pulse, skin::ACCENT);
        } else {
            let (rect, _) = ui.allocate_exact_size(Vec2::splat(17.0), Sense::hover());
            ui.painter()
                .circle_stroke(rect.center(), 4.5, Stroke::new(1.4, skin::LINE));
        }
        ui.add_space(3.0);
        ui.label(
            RichText::new(name)
                .size(13.2)
                .font(FontId::new(
                    13.2,
                    if current { assets::medium() } else { FontFamily::Proportional },
                ))
                .color(if done || current { skin::LABEL } else { skin::TERTIARY }),
        );
    });
    ui.add_space(7.0);
}

fn primary(ui: &mut egui::Ui, text: &str) -> egui::Response {
    let enabled = ui.is_enabled();
    let fill = if enabled { skin::ACCENT } else { Color32::from_rgb(200, 205, 208) };
    ui.add(
        egui::Button::new(
            RichText::new(text)
                .font(FontId::new(14.0, assets::medium()))
                .color(Color32::WHITE),
        )
        .fill(fill)
        .stroke(Stroke::NONE)
        .corner_radius(CornerRadius::same(8))
        .min_size(Vec2::new(130.0, 34.0)),
    )
}

fn secondary(ui: &mut egui::Ui, text: &str) -> egui::Response {
    ui.add(
        egui::Button::new(RichText::new(text).font(FontId::new(14.0, assets::medium())).color(skin::LABEL))
            .fill(Color32::WHITE)
            .stroke(Stroke::new(1.0, skin::LINE))
            .corner_radius(CornerRadius::same(8))
            .min_size(Vec2::new(0.0, 34.0)),
    )
}
