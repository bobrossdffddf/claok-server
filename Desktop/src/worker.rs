//! Everything slow happens here, on a tokio runtime of its own, so the window
//! never stops drawing.

use std::path::PathBuf;
use std::sync::Arc;

use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{developer_session::DeveloperSession, devices::DevicesApi},
    sideload::{builder::MaxCertsBehavior, install::install_app as install_signed, SideloaderBuilder, TeamSelection},
    util::device::IdeviceInfo,
};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::sync::Mutex;

use crate::config::{Config, StoredPassword};
use crate::device::{self, DeveloperMode, Phone};

#[derive(Debug, Clone)]
pub enum Command {
    Scan,
    RevealDeveloperMode { udid: String },
    EnableDeveloperMode { udid: String },
    Install { udid: String, apple_id: String, password: String, remember: bool },
    TwoFactor(TwoFactorCallbackResponse),
    OpenLocalDevVPN,
}

#[derive(Debug, Clone)]
pub enum Event {
    DriverMissing,
    /// Whether iOS accepted the signature without the user having to go and
    /// approve it by hand.
    Trusted(bool),
    Phones(Vec<Phone>),
    Status(String),
    Progress(f32),
    NeedTwoFactor(Box<TwoFactorCallbackParams>),
    DeveloperModeRevealed,
    Rebooting,
    Installed,
    Failed(String),
}

pub struct Channels {
    pub commands: UnboundedSender<Command>,
    pub events: UnboundedReceiver<Event>,
}

/// Starts the background runtime and hands back the two ends of the wire.
pub fn spawn(ipa: PathBuf) -> Channels {
    let (command_tx, command_rx) = tokio::sync::mpsc::unbounded_channel();
    let (event_tx, event_rx) = tokio::sync::mpsc::unbounded_channel();

    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("could not start the background runtime");
        runtime.block_on(run(command_rx, event_tx, ipa));
    });

    Channels { commands: command_tx, events: event_rx }
}

type Events = UnboundedSender<Event>;

async fn run(mut commands: UnboundedReceiver<Command>, events: Events, ipa: PathBuf) {
    // The two-factor code arrives from the window long after the login call
    // has gone to sleep waiting for it, so it needs a channel of its own.
    let (code_tx, code_rx) = tokio::sync::mpsc::unbounded_channel::<TwoFactorCallbackResponse>();
    let code_rx = Arc::new(Mutex::new(code_rx));

    while let Some(command) = commands.recv().await {
        match command {
            Command::TwoFactor(response) => {
                let _ = code_tx.send(response);
            }

            Command::Scan => {
                if !device::usbmuxd_available().await {
                    let _ = events.send(Event::DriverMissing);
                    continue;
                }
                match device::list_phones().await {
                    Ok(phones) => { let _ = events.send(Event::Phones(phones)); }
                    Err(message) => { let _ = events.send(Event::Failed(message)); }
                }
            }

            Command::RevealDeveloperMode { udid } => {
                let _ = events.send(Event::Status("Asking iOS to show the Developer Mode switch…".into()));
                match device::provider_for(&udid).await {
                    Ok(provider) => match device::reveal_developer_mode(&provider).await {
                        Ok(()) => { let _ = events.send(Event::DeveloperModeRevealed); }
                        Err(message) => { let _ = events.send(Event::Failed(message)); }
                    },
                    Err(message) => { let _ = events.send(Event::Failed(message)); }
                }
            }

            Command::EnableDeveloperMode { udid } => {
                let events = events.clone();
                tokio::spawn(async move { enable_developer_mode(&udid, &events).await });
            }

            Command::OpenLocalDevVPN => {
                let _ = open::that("https://apps.apple.com/app/id6755608044");
            }

            Command::Install { udid, apple_id, password, remember } => {
                // Run this off the loop. The install waits for a two-factor
                // code, and the only thing that can deliver one is this loop,
                // so awaiting it here means the two sit waiting for each other
                // forever with the status stuck on "signing in".
                let events = events.clone();
                let ipa = ipa.clone();
                let code_rx = code_rx.clone();
                tokio::spawn(async move {
                    let outcome = install(
                        &udid, &apple_id, &password, remember, &ipa, &events, code_rx,
                    ).await;
                    match outcome {
                        Ok(()) => { let _ = events.send(Event::Installed); }
                        Err(message) => { let _ = events.send(Event::Failed(message)); }
                    }
                });
            }
        }
    }
}

// MARK: - Developer Mode

async fn enable_developer_mode(udid: &str, events: &Events) {
    let provider = match device::provider_for(udid).await {
        Ok(p) => p,
        Err(message) => { let _ = events.send(Event::Failed(message)); return; }
    };

    let _ = events.send(Event::Status("Turning Developer Mode on…".into()));
    // Revealing first is harmless when it is already visible, and it is the
    // step that makes the switch exist at all on a phone Xcode has never seen.
    let _ = device::reveal_developer_mode(&provider).await;

    if let Err(message) = device::enable_developer_mode(&provider).await {
        let _ = events.send(Event::Failed(message));
        return;
    }

    let _ = events.send(Event::Rebooting);
    drop(provider);

    // The phone restarts and comes back asking for the passcode, then shows
    // "Turn on Developer Mode?". Answering that is action three.
    if !device::wait_for_return(udid, 180).await {
        let _ = events.send(Event::Failed(
            "The iPhone did not come back after restarting. Unlock it and plug it in again.".into(),
        ));
        return;
    }

    let _ = events.send(Event::Status("Confirming…".into()));
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;

    if let Ok(provider) = device::provider_for(udid).await {
        let _ = device::accept_developer_mode(&provider).await;
    }

    match device::list_phones().await {
        Ok(phones) => { let _ = events.send(Event::Phones(phones)); }
        Err(message) => { let _ = events.send(Event::Failed(message)); }
    }
}

// MARK: - Install

async fn install(
    udid: &str,
    apple_id: &str,
    password: &str,
    remember: bool,
    ipa: &PathBuf,
    events: &Events,
    code_rx: Arc<Mutex<UnboundedReceiver<TwoFactorCallbackResponse>>>,
) -> Result<(), String> {
    if !ipa.exists() {
        return Err(format!(
            "The Cloak app file is missing. It should sit next to this installer at {}.",
            ipa.display()
        ));
    }

    // Progress is reported by hand at every phase boundary. Leaning on the
    // signing library's own callback alone meant the bar sat at zero through
    // the two slowest parts of the job, sign-in and the certificate, which
    // reads as a hang rather than as work.
    let step = |fraction: f32, text: &str| {
        let _ = events.send(Event::Progress(fraction));
        let _ = events.send(Event::Status(text.to_string()));
    };

    step(0.04, "Reaching Apple");

    let anisette = RemoteV3AnisetteProvider::default()
        .map_err(|e| format!("Could not start the Apple sign-in helper: {e}"))?
        .set_serial_number("2".to_string());

    step(0.08, "Signing in with your Apple ID");

    let two_factor = {
        let events = events.clone();
        let code_rx = code_rx.clone();
        move |params: TwoFactorCallbackParams| {
            let events = events.clone();
            let code_rx = code_rx.clone();
            async move {
                let mut guard = code_rx.lock().await;
                while guard.try_recv().is_ok() {}
                let _ = events.send(Event::NeedTwoFactor(Box::new(params)));
                match guard.recv().await {
                    Some(response) => Ok(response),
                    None => Ok(TwoFactorCallbackResponse::Abort),
                }
            }
        }
    };

    // No time limit on the login as a whole, because a person may take minutes
    // to find the code on another device. The steps that involve no human do
    // get one.
    let mut account = AppleAccount::builder(apple_id)
        .anisette_provider(anisette)
        .login(password, two_factor)
        .await
        .map_err(|e| friendly_login_error(&e.to_string()))?;

    if remember {
        let _ = StoredPassword::save(apple_id, password);
    }

    let provider = device::provider_for(udid).await?;

    // Signing is attempted twice at most. The first failure is very often a
    // signing certificate this computer thinks it owns and Apple has never
    // heard of, which happens whenever a certificate is revoked from another
    // machine or from the developer site. There is nothing the user can do
    // about that and nothing to explain: throw the stale state away and ask
    // Apple for a fresh certificate.
    let mut attempt = 0u8;
    let (signed, team) = loop {
        attempt += 1;

        step(0.18, "Opening your developer account");

        let session = tokio::time::timeout(
            std::time::Duration::from_secs(90),
            DeveloperSession::from_account(&mut account),
        )
        .await
        .map_err(|_| "Apple stopped answering while opening your developer account. Check the connection and try again.".to_string())?
        .map_err(|e| format!("Apple would not open a developer session: {e}"))?;

        let mut sideloader = SideloaderBuilder::new(session, apple_id.to_string())
            .team_selection(TeamSelection::First)
            .max_certs_behavior(MaxCertsBehavior::Revoke)
            .storage(Box::new(crate::state::FileStorage::new()))
            .machine_name(machine_name())
            .build();

        step(0.24, "Registering this iPhone with Apple");

        let team = sideloader
            .get_team()
            .await
            .map_err(|e| format!("Apple would not say which developer team you are on: {e}"))?;

        let info = IdeviceInfo::from_device(&provider)
            .await
            .map_err(|e| format!("Could not read the iPhone's name: {e}"))?;

        sideloader
            .get_dev_session()
            .ensure_device_registered(&team, &info.name, &info.udid, None)
            .await
            .map_err(|e| friendly_install_error(&e.to_string()))?;

        step(0.32, "Getting a signing certificate");

        // sign_app spends most of its time hashing and rewriting the bundle,
        // so its own callback drives the middle third of the bar.
        let sign_progress = {
            let events = events.clone();
            move |fraction: f32| {
                let events = events.clone();
                async move {
                    let _ = events.send(Event::Progress(0.32 + fraction * 0.33));
                    if fraction > 0.15 {
                        let _ = events.send(Event::Status("Signing Cloak with your certificate".to_string()));
                    }
                }
            }
        };

        match sideloader
            .sign_app(ipa.clone(), Some(team.clone()), false, Some(sign_progress))
            .await
        {
            Ok((path, _special)) => break (path, team),
            Err(error) => {
                let text = error.to_string();
                if attempt == 1 && looks_stale(&text) {
                    let _ = events.send(Event::Status(
                        "Replacing an out of date certificate".to_string(),
                    ));
                    crate::state::FileStorage::new().clear();
                    continue;
                }
                return Err(friendly_install_error(&text));
            }
        }
    };

    step(0.66, "Copying Cloak to your iPhone");

    let copy_progress = {
        let events = events.clone();
        move |percent: u64| {
            let fraction = (percent as f32 / 100.0).clamp(0.0, 1.0);
            let _ = events.send(Event::Progress(0.66 + fraction * 0.29));
            if percent > 70 {
                let _ = events.send(Event::Status("Installing".to_string()));
            }
        }
    };

    install_signed(&provider, &signed, copy_progress)
        .await
        .map_err(|e| friendly_install_error(&e.to_string()))?;

    // Read this before the signed copy is thrown away.
    let profile_uuid = crate::handoff::profile_uuid(&signed);
    let _ = std::fs::remove_dir_all(&signed);

    step(0.92, "Telling iOS to trust it");

    // Without this the first launch is met with "Untrusted Developer" and a
    // hunt through Settings. iOS lets a connected computer answer that for
    // you, so it does. Older iOS does not offer the action, and then the app
    // has to say so rather than leaving the user stuck.
    let mut trusted = false;
    if let Some(uuid) = &profile_uuid {
        match crate::handoff::trust_signer(&provider, uuid).await {
            Ok(value) => trusted = value,
            Err(message) => tracing::warn!("could not trust the signer: {message}"),
        }
    }
    let _ = events.send(Event::Trusted(trusted));

    step(0.96, "Handing Cloak the keys");

    let bundle_id = format!("app.cloak.ios.{}", team.team_id);

    // Give the freshly installed app a moment to exist as far as the phone is
    // concerned, then hand it the pairing record so it needs no setup of its
    // own. Failing here is survivable: Cloak can still pair with itself.
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    if let Err(message) = crate::handoff::send_pairing_record(&provider, &bundle_id).await {
        tracing::warn!("pairing handoff skipped: {message}");
    }

    step(1.0, "Done");

    let mut config = Config::load();
    config.team_id = Some(team.team_id);
    config.apple_id = Some(apple_id.to_string());
    config.device_udid = Some(udid.to_string());
    config.last_refresh = Some(chrono::Utc::now());
    config.save();

    Ok(())
}

/// Whether a signing failure is the kind that a clean slate fixes.
///
/// Apple's 7252 is "there is no certificate with that serial on this team",
/// which means our copy of the identity is describing something that no longer
/// exists. Retrieving the identity failing at all is the same family.
fn looks_stale(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("7252")
        || lower.contains("no 'ios' certificate with serial number")
        || lower.contains("failed to retrieve certificate identity")
        || lower.contains("failed to revoke development certificate")
}

fn machine_name() -> String {
    let host = hostname();
    format!("Cloak ({host})")
}

fn hostname() -> String {
    #[cfg(windows)]
    { std::env::var("COMPUTERNAME").unwrap_or_else(|_| "this PC".into()) }
    #[cfg(not(windows))]
    {
        std::process::Command::new("hostname")
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "this Mac".into())
    }
}

// MARK: - Errors people can act on

fn friendly_login_error(raw: &str) -> String {
    let lower = raw.to_lowercase();
    if lower.contains("-20101") || lower.contains("incorrect") || lower.contains("password") {
        "That Apple ID and password did not match. Note that an app-specific password will not work here — use the real one.".into()
    } else if lower.contains("anisette") {
        "The Apple sign-in helper could not be reached. Check the internet connection and try again.".into()
    } else if lower.contains("locked") {
        "Apple has locked this account for security. Sign in at appleid.apple.com first, then come back.".into()
    } else {
        format!("Signing in failed.\n\n{raw}")
    }
}

fn friendly_install_error(raw: &str) -> String {
    let lower = raw.to_lowercase();
    if lower.contains("maximum number of certificates") || lower.contains("too many certificates") {
        return "Apple only lets a free account hold a couple of signing certificates at once, and yours are all in use by other tools. Sign in at developer.apple.com, go to Certificates, and delete one, then try again.".into();
    }
    if lower.contains("maximum") && lower.contains("app id") {
        "Apple only lets a free account register ten apps a week, and this account has used them all. Try again in a few days, or use a different Apple ID.".into()
    } else if lower.contains("developer mode") {
        "The iPhone still has Developer Mode off. Go back a step and turn it on.".into()
    } else if lower.contains("trust") {
        "The iPhone has not trusted this computer. Unlock it, tap Trust, then try again.".into()
    } else {
        format!("Installing failed.\n\n{raw}")
    }
}

/// Headless renewal, run by the scheduler every day. Does nothing unless the
/// signature is close to running out.
pub async fn refresh_now(ipa: PathBuf, force: bool) -> Result<(), String> {
    let config = Config::load();
    if !force && !config.needs_refresh() {
        return Ok(());
    }

    let apple_id = config.apple_id.ok_or("No Apple ID has been saved.")?;
    let udid = config.device_udid.ok_or("No iPhone has been saved.")?;
    let password = StoredPassword::load(&apple_id)
        .ok_or("The Apple ID password is not in the keychain, so Cloak cannot renew itself.")?;

    let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
    let (_code_tx, code_rx) = tokio::sync::mpsc::unbounded_channel();
    let code_rx = Arc::new(Mutex::new(code_rx));

    install(&udid, &apple_id, &password, false, &ipa, &tx, code_rx).await
}

/// Whether this phone still needs anything done to it.
pub fn developer_mode_ok(phone: &Phone) -> bool {
    matches!(phone.developer_mode, DeveloperMode::On | DeveloperMode::NotApplicable)
}
