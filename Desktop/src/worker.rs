//! Everything slow happens here, on a tokio runtime of its own, so the window
//! never stops drawing.

use std::path::PathBuf;
use std::sync::Arc;

use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        certificates::CertificatesApi, developer_session::DeveloperSession, devices::DevicesApi,
        teams::DeveloperTeam,
    },
    sideload::{builder::MaxCertsBehavior, install::install_app as install_signed, SideloaderBuilder, TeamSelection},
    util::device::IdeviceInfo,
};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::sync::Mutex;

use crate::config::{Config, StoredPassword};
use crate::device::{self, DeveloperMode, Phone};
use crate::handoff;

#[derive(Debug, Clone)]
pub enum Command {
    Scan,
    RevealDeveloperMode { udid: String },
    EnableDeveloperMode { udid: String },
    Install { udid: String, apple_id: String, password: String, remember: bool },
    TwoFactor(TwoFactorCallbackResponse),
    /// The six digit code the phone shows during remote pairing.
    PairingPin(String),
    OpenLocalDevVPN,
    /// Work out why a phone will not talk, and report it verbatim.
    Diagnose,
    /// Look again, ignoring anything remembered from the last look.
    Rescan,
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
    /// The phone has a pairing code on its screen; the window must ask for it.
    NeedPairingPin,
    DeveloperModeRevealed,
    /// iOS will not do it for us on this phone, so the person has to flip the
    /// switch themselves. Not a failure: the manual route works fine.
    DeveloperModeManual,
    Rebooting,
    Installed,
    Failed(String),
    /// The doctor's report, for the screen to show as-is.
    Diagnosis(String),
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

/// One look for phones. Kept in one place because it is now driven both by a
/// timer and by hand.
async fn scan(events: &Events) {
    if !device::usbmuxd_available().await {
        let _ = events.send(Event::DriverMissing);
        return;
    }
    match device::list_phones().await {
        Ok(phones) => {
            // Ask for the switch straight away rather than waiting for
            // somebody to press a button for it. iOS hides the Developer Mode
            // row until a developer tool asks, so telling people to go and
            // find it before asking is telling them to look at something that
            // is not there. Revealing an already visible switch does nothing.
            if reveal_where_needed(&phones).await {
                let _ = events.send(Event::DeveloperModeRevealed);
            }
            let _ = events.send(Event::Phones(phones));
        }
        Err(message) => { let _ = events.send(Event::Failed(message)); }
    }
}

async fn run(mut commands: UnboundedReceiver<Command>, events: Events, ipa: PathBuf) {
    // The two-factor code arrives from the window long after the login call
    // has gone to sleep waiting for it, so it needs a channel of its own.
    let (code_tx, code_rx) = tokio::sync::mpsc::unbounded_channel::<TwoFactorCallbackResponse>();
    let code_rx = Arc::new(Mutex::new(code_rx));
    let (pin_tx, pin_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let pin_rx = Arc::new(Mutex::new(pin_rx));

    while let Some(command) = commands.recv().await {
        match command {
            Command::TwoFactor(response) => {
                let _ = code_tx.send(response);
            }

            Command::PairingPin(pin) => {
                let _ = pin_tx.send(pin);
            }

            Command::Rescan => {
                device::forget_phones();
                scan(&events).await;
            }

            Command::Scan => scan(&events).await,

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

            Command::Diagnose => {
                let events = events.clone();
                tokio::spawn(async move {
                    let _ = events.send(Event::Status("Working out what is wrong".into()));
                    let report = device::doctor().await;
                    let _ = events.send(Event::Diagnosis(report));
                    let _ = events.send(Event::Status(String::new()));
                });
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
                let pin_rx = pin_rx.clone();
                tokio::spawn(async move {
                    let outcome = install(
                        &udid, &apple_id, &password, remember, &ipa, &events, code_rx, pin_rx,
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

/// Makes the Developer Mode switch appear on every plugged in phone that
/// needs it, and says whether any of them accepted.
///
/// A phone that has not been trusted cannot be asked, and a phone already
/// running with it on has nothing to reveal, so both are skipped quietly.
async fn reveal_where_needed(phones: &[device::Phone]) -> bool {
    let mut revealed = false;
    for phone in phones {
        if phone.via_apple_tooling {
            tracing::info!("skipping reveal on {}: this Mac only lets Apple's own tooling talk to it", phone.name);
            continue;
        }
        if !phone.trusted {
            tracing::info!("skipping reveal, {} could not be read ({:?})", phone.name, phone.problem);
            continue;
        }
        if developer_mode_ok(phone) {
            continue;
        }
        let Ok(provider) = device::provider_for(&phone.udid).await else { continue };
        if device::reveal_developer_mode(&provider).await.is_ok() {
            revealed = true;
        }
    }
    revealed
}

async fn enable_developer_mode(udid: &str, events: &Events) {
    let provider = match device::provider_for(udid).await {
        Ok(p) => p,
        Err(message) => { let _ = events.send(Event::Failed(message)); return; }
    };

    let _ = events.send(Event::Status("Turning Developer Mode on…".into()));
    // Revealing first is harmless when it is already visible, and it is the
    // step that makes the switch exist at all on a phone Xcode has never seen.
    let _ = device::reveal_developer_mode(&provider).await;

    match device::enable_developer_mode(&provider).await {
        Ok(()) => {}
        Err(device::DevModeRefusal::PasscodeSet) => {
            // The switch is showing by now, and turning it on by hand is a
            // supported route that works with a passcode set. Hand over
            // rather than asking anybody to take the lock off their phone.
            let _ = events.send(Event::DeveloperModeRevealed);
            let _ = events.send(Event::DeveloperModeManual);

            // Keep watching while they do it. The phone restarts partway
            // through, so this has to survive it going away and coming back,
            // and it means nobody has to press Check again.
            let events = events.clone();
            let udid = udid.to_string();
            tokio::spawn(async move {
                if device::wait_for_developer_mode(&udid, 600).await {
                    if let Ok(phones) = device::list_phones().await {
                        let _ = events.send(Event::Phones(phones));
                    }
                }
            });
            return;
        }
        Err(device::DevModeRefusal::Other(message)) => {
            let _ = events.send(Event::Failed(message));
            return;
        }
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

    let _ = events.send(Event::Status("Answering the prompt on the phone".into()));
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;

    let answered = match device::provider_for(udid).await {
        Ok(provider) => device::accept_developer_mode(&provider).await.is_ok(),
        Err(_) => false,
    };

    if !answered {
        // iOS would not let us answer for them, which happens when the phone
        // is still locked. It is one tap, so say which one.
        tracing::info!("could not answer the Developer Mode prompt, handing over");
        let _ = events.send(Event::DeveloperModeManual);
    }

    let _ = events.send(Event::Status("Checking the switch on the phone".into()));

    // Ask the phone rather than assuming. Until it says the switch is on,
    // nothing further in the install can work anyway.
    if !device::wait_for_developer_mode(udid, 300).await {
        tracing::warn!("Developer Mode still not on after the restart");
        let _ = events.send(Event::DeveloperModeManual);
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
    pin_rx: Arc<Mutex<UnboundedReceiver<String>>>,
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

    step(0.04, "Checking the connection");

    // Ask before anybody types a password. Sign-in is a run of requests over
    // the best part of a minute, and finding out at the end that the network
    // was never going to work reads as though the password was wrong.
    if let Err(detail) = apple_reachable().await {
        tracing::warn!("cannot reach Apple: {detail}");
        if detail.starts_with("FLAKY") {
            let through = tunnel_in_the_way()
                .map(|name| format!("\n\nEverything on this computer is going through {name} right now, which is where to look first."))
                .unwrap_or_default();
            return Err(format!(
                "The connection to Apple is dropping requests.\n\nCloak asked Apple the same harmless question three times before touching your password, and some of them never came back. Signing in is a dozen requests in a row, so it would fail part way through and look like Apple refusing the account.{through}\n\nFix the connection first, then sign in. Sharing your phone's internet connection is the quickest way to rule it out.\n\nDetail: {detail}"
            ));
        }
        return Err(unreachable_message_for(&detail));
    }

    step(0.06, "Finding a working sign-in helper");

    // The helper that produces the identity Apple demands is a public server,
    // and each one holds a trust key it provisions with. When Apple invalidates
    // one of those keys, every app pointed at that server stops working at the
    // same moment, for everybody, including somebody signing in for the first
    // time. It looks exactly like a broken account and is nothing of the sort.
    //
    // So this works down the list rather than betting the whole install on one.
    let config = Config::load();
    let helpers = crate::anisette::healthy_candidates(&config).await;
    if helpers.is_empty() {
        return Err(crate::anisette::none_available(&crate::anisette::candidates(&config)));
    }

    step(0.08, "Signing in with your Apple ID");

    // Normally None, and that is the working state: the helper's own machine
    // description goes up with the identity data it minted, which is the only
    // combination Apple accepts. A value here is a replacement somebody typed
    // in on purpose.
    let identity = crate::anisette::client_info(&config);
    match &identity {
        Some(value) => tracing::info!("overriding the machine Apple is told about: {value}"),
        None => tracing::info!("letting each sign-in helper describe its own machine"),
    }

    // Four at most. Each one that refuses to provision is a different server
    // and not another go at the same thing, so this is not the repeated
    // attempts Apple locks accounts out for. A refusal that is about the
    // account stops the loop dead on the first one.
    let mut last_error = String::new();
    let mut account = None;

    // Two counts, because they are not the same thing. A helper that falls over
    // while minting the identity never reached Apple and costs nothing, so
    // those are worth working through. An answer from Apple itself is an
    // attempt Apple is counting, and only a handful of those are ever safe.
    let mut apple_attempts = 0;

    // Dropped connections are counted apart again. They are free against the
    // account and they often clear by themselves, so they are worth a couple
    // of goes, but not an unbounded number on a line that is simply down.
    let mut transport_failures = 0;

    // Identities Apple would not verify. Each one is a fresh provisioning
    // against a different helper rather than another go at the same thing, so
    // these are worth working through, but not forever.
    let mut stale_identities = 0;

    for (index, helper) in helpers.iter().enumerate() {
        if apple_attempts >= 3 {
            tracing::warn!("stopping after {apple_attempts} attempts that reached Apple");
            break;
        }
        if index > 0 {
            let _ = events.send(Event::Status(
                "That sign-in helper is not working. Trying another".to_string(),
            ));
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
        tracing::info!("trying sign-in helper {helper}");

        // Set the moment Apple asks for the code, so the reassurance ticker
        // below stops talking over the code prompt.
        let asked = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));

        let two_factor = {
            let events = events.clone();
            let code_rx = code_rx.clone();
            let asked = asked.clone();
            move |params: TwoFactorCallbackParams| {
                let events = events.clone();
                let code_rx = code_rx.clone();
                asked.store(true, std::sync::atomic::Ordering::Relaxed);
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

        // The identity blob is filed under this helper and nobody else, and an
        // old one is dropped before it can be sent. Sending a blob one server
        // minted to a different server is what Apple answers -22421 to.
        let store = crate::state::FileStorage::for_helper(helper);
        store.drop_stale_anisette(std::time::Duration::from_secs(12 * 60 * 60));

        let provider = RemoteV3AnisetteProvider::default()
            .map_err(|e| format!("Could not start the Apple sign-in helper: {e}"))?
            .set_url(helper)
            .set_storage(Box::new(crate::state::FileStorage::for_helper(helper)))
            .set_serial_number(
                config
                    .anisette_serial
                    .clone()
                    .unwrap_or_else(|| "0".to_string()),
            );

        let anisette = crate::anisette::Identified::new(provider, identity.clone());

        // Signing in is a dozen requests in a row and Apple is slow to answer
        // some of them, so this stretch can run the better part of a minute
        // with nothing to show for it. A screen that has said the same four
        // words for fifty seconds reads as a hang, so say what is happening.
        let heartbeat = {
            let events = events.clone();
            let asked = asked.clone();
            tokio::spawn(async move {
                for note in [
                    (8, "Proving this Mac to Apple"),
                    (20, "Waiting on Apple. This part is slow"),
                    (40, "Still waiting on Apple. It has not failed"),
                    (70, "Apple is taking longer than usual to answer"),
                ] {
                    tokio::time::sleep(std::time::Duration::from_secs(note.0)).await;
                    if asked.load(std::sync::atomic::Ordering::Relaxed) {
                        return;
                    }
                    if events.send(Event::Status(note.1.to_string())).is_err() {
                        return;
                    }
                }
            })
        };
        let _heartbeat = crate::worker::StopOnDrop(heartbeat);

        // No time limit on the login as a whole, because a person may take
        // minutes to find the code on another device.
        match AppleAccount::builder(apple_id)
            .anisette_provider(anisette)
            .login(password, two_factor)
            .await
        {
            Ok(signed_in) => {
                let mut saved = Config::load();
                if saved.anisette_last_good.as_deref() != Some(helper.as_str()) {
                    saved.anisette_last_good = Some(helper.clone());
                    saved.save();
                }
                account = Some(signed_in);
                break;
            }
            Err(error) => {
                let text = error.to_string();
                last_error = text.clone();

                // The helper fell over on its own. Nothing was asked of Apple,
                // so this is not remembered against the server either: these
                // are volunteer boxes and a bad minute is not a dead server.
                if crate::anisette::helper_broke(&text, helper) {
                    tracing::warn!("{helper} failed to produce an identity, moving on");
                    store.forget_anisette();
                    continue;
                }

                // Apple would not verify the one-time code the identity
                // produced. The password was never looked at, so this costs
                // the account nothing. Throw that identity away and go to the
                // next helper, which now provisions from scratch because its
                // state is kept separately.
                if crate::anisette::stale_session(&text) {
                    apple_attempts += 1;
                    stale_identities += 1;
                    tracing::warn!("{helper} produced an identity Apple would not verify");
                    store.forget_anisette();
                    if stale_identities <= 2 && index + 1 < helpers.len() {
                        let _ = events.send(Event::Status(
                            "Apple would not accept that identity. Making a fresh one".to_string(),
                        ));
                        continue;
                    }
                    return Err(crate::anisette::stale_session_message());
                }

                // A throttle is about how fast requests are arriving, not about
                // this helper, so trying another one is the worst thing to do:
                // it is another burst and it deepens the throttle. The pacing
                // and backoff inside the signing library have already waited
                // this out several times over by the time it reaches here, so
                // stop and let things go quiet.
                if crate::anisette::identity_throttled(&text) {
                    tracing::error!("Apple is still throttling after backing off");
                    return Err(crate::anisette::slow_down());
                }

                // Apple answered, and what it refused was the identity this
                // helper produced. That is worth a different helper, and it is
                // remembered so the next run does not start here again.
                if crate::anisette::helper_was_rejected(&text) {
                    apple_attempts += 1;
                    tracing::warn!("Apple would not accept the identity from {helper}, moving on");
                    crate::anisette::remember_rejected(helper);
                    store.forget_anisette();
                    continue;
                }

                // A failure that never reached Apple is not an attempt Apple
                // is counting, and it is not this helper's fault either. It is
                // also the one kind that often comes right on its own, because
                // a route that drops one request in five will carry the next.
                // So it gets another go on a different helper before it is
                // reported, which costs the account nothing.
                if looks_like_transport(&text) {
                    transport_failures += 1;
                    if transport_failures <= 2 && index + 1 < helpers.len() {
                        tracing::warn!("the request never completed ({text}); trying again");
                        let _ = events.send(Event::Status(
                            "The connection dropped that request. Trying again".to_string(),
                        ));
                        store.forget_anisette();
                        continue;
                    }
                    tracing::error!("the request to Apple never completed: {text}");
                    return Err(friendly_login_error(&text));
                }

                apple_attempts += 1;

                // Anything else is about the account or the network, and trying
                // another server would only spend an attempt Apple is counting.
                tracing::error!("sign-in failed on helper {helper}: {text}");
                if looks_rate_limited(&text) {
                    store.forget_anisette();
                }
                // A saved password Apple has just rejected is worse than none,
                // because it would be offered again silently on the next run.
                if wrong_password(&text) {
                    StoredPassword::forget(apple_id);
                }
                return Err(friendly_login_error(&text));
            }
        }
    }

    let Some(mut account) = account else {
        tracing::error!("every helper refused: {last_error}");
        // Ran out of helpers while the connection was the thing failing. That
        // is not Apple refusing anything and must not be reported as if it is.
        if transport_failures > 0 && looks_like_transport(&last_error) {
            return Err(friendly_login_error(&last_error));
        }
        return Err(crate::anisette::all_helpers_rejected());
    };

    if remember {
        let _ = StoredPassword::save(apple_id, password);
    }

    // On macOS 26 and later this can fail outright while the phone is
    // perfectly healthy, because Apple's device daemon refuses to carry
    // anything that is not its own. Signing needs no device at all, so a
    // missing provider is not fatal: the install goes through Apple's tool
    // instead, at the end.
    let provider = match device::provider_for(udid).await {
        Ok(provider) => Some(provider),
        Err(reason) => {
            if device::apple_view(udid).is_some_and(|view| view.paired) {
                tracing::warn!("no provider ({reason}); going through Apple's tooling instead");
                let _ = events.send(Event::Status(
                    "This Mac will not let anything but Apple talk to the phone. Using Apple's own tool instead".to_string(),
                ));
                None
            } else {
                return Err(reason);
            }
        }
    };

    // The pairing record goes inside the app, before it is signed.
    //
    // This is what makes Cloak work on every iOS version rather than only on
    // 27. Below that, a phone cannot pair with itself, so the record this
    // computer already holds is the only way the app can talk to the phone's
    // own developer services. Pushing it across afterwards over AFC is what
    // used to happen, and iOS refused it every single time with a permission
    // error, which left every install below iOS 27 quietly broken.
    // The remote pairing record, the one that survives iOS 26.4 and later.
    // The phone shows a code, the person types it in the window, and the
    // record travels inside the app next to the lockdown one. iOS 27 refuses
    // this direction of pairing, so it is skipped there and the app pairs
    // outward on its own.
    let remote_record: Option<String> = {
        let apple = device::apple_view(udid);
        let major = match &provider {
            Some(provider) => device::ios_major(provider).await.unwrap_or(0),
            None => apple
                .as_ref()
                .and_then(|view| view.ios_version.split('.').next().and_then(|p| p.parse().ok()))
                .unwrap_or(0),
        };
        let name = match &provider {
            Some(provider) => device::device_name(provider).await.unwrap_or_else(|| "iPhone".to_string()),
            None => apple.as_ref().map(|view| view.name.clone()).unwrap_or_else(|| "iPhone".to_string()),
        };
        if major >= 27 {
            None
        } else {
            step(0.20, "Pairing the new way (a code will appear on the phone)");
            match remote_pair(&name, events, pin_rx.clone()).await {
                Ok(record) => {
                    tracing::info!("remote pairing record obtained");
                    let _ = events.send(Event::Status("Paired the new way. Continuing.".into()));
                    Some(record)
                }
                Err(reason) => {
                    tracing::warn!("remote pairing skipped: {reason}");
                    let _ = events.send(Event::Status(format!("Could not pair the new way ({reason}). Continuing with the classic record.")));
                    tokio::time::sleep(std::time::Duration::from_secs(4)).await;
                    None
                }
            }
        }
    };

    // The signing identity travels too, so a refresh done on the phone uses
    // this computer's certificate under this computer's machine name instead
    // of asking Apple for a second one. A free account only gets one, and a
    // second request revokes the first, which is how "it worked yesterday"
    // turns into an app that will not open.
    let signing_identity: Option<String> = {
        let storage = crate::state::FileStorage::new();
        match isideload::sideload::cert_identity::CertificateIdentity::ensure_private_key(apple_id, &storage).await {
            Ok((key_name, der)) => {
                use base64::Engine;
                let saved = Config::load();
                let anisette_state = isideload::util::storage::SideloadingStorage::retrieve(&storage, "anisette_state").ok().flatten();
                Some(serde_json::json!({
                    "key": key_name,
                    "der": base64::engine::general_purpose::STANDARD.encode(der),
                    "machine": machine_name(),
                    "anisette_state": anisette_state,
                    "anisette_url": saved.anisette_last_good,
                    "anisette_serial": saved.anisette_serial.unwrap_or_else(|| "0".to_string()),
                }).to_string())
            }
            Err(error) => {
                tracing::warn!("signing identity not bundled: {error}");
                None
            }
        }
    };

    let mut record_bundled = false;
    let pairing_bytes = match &provider {
        Some(provider) => handoff::pairing_record(provider).await,
        // usbmuxd still hands over the record even where it refuses to carry
        // a connection, so this is worth asking for on its own.
        None => match device::muxd_provider_for(udid).await {
            Ok(muxd) => handoff::pairing_record(&muxd).await,
            Err(reason) => Err(reason),
        },
    };
    let ipa = match pairing_bytes {
        Ok(record) => {
            let bundled = std::env::temp_dir().join("Cloak-paired.ipa");
            match handoff::bundle_pairing_record(ipa, &record, remote_record.as_deref(), signing_identity.as_deref(), &bundled) {
                Ok(()) => {
                    tracing::info!("pairing record bundled into the app");
                    record_bundled = true;
                    bundled
                }
                Err(reason) => {
                    // Not fatal on iOS 27, which can pair by itself, so carry
                    // on rather than refusing to install at all.
                    tracing::warn!("could not bundle the pairing record: {reason}");
                    ipa.clone()
                }
            }
        }
        Err(reason) => {
            tracing::warn!("no pairing record to hand over: {reason}");
            if remote_record.is_some() || signing_identity.is_some() {
                let bundled = std::env::temp_dir().join("Cloak-paired.ipa");
                match handoff::bundle_pairing_record(ipa, &[], remote_record.as_deref(), signing_identity.as_deref(), &bundled) {
                    Ok(()) => { record_bundled = true; bundled }
                    Err(reason) => { tracing::warn!("could not bundle the remote pairing: {reason}"); ipa.clone() }
                }
            } else {
                ipa.clone()
            }
        }
    };
    let ipa = &ipa;

    // Signing is attempted twice at most. The first failure is very often a
    // signing certificate this computer thinks it owns and Apple has never
    // heard of, which happens whenever a certificate is revoked from another
    // machine or from the developer site. There is nothing the user can do
    // about that and nothing to explain: throw the stale state away and ask
    // Apple for a fresh certificate.
    let mut attempt = 0u8;
    let mut cleared: Option<usize> = None;
    let (signed, team) = loop {
        attempt += 1;

        step(0.18, "Opening your developer account");

        let session = open_developer_session(&mut account, &events).await?;

        let mut sideloader = SideloaderBuilder::new(session, apple_id.to_string())
            .team_selection(TeamSelection::First)
            .max_certs_behavior(MaxCertsBehavior::Revoke)
            .storage(Box::new(crate::state::FileStorage::new()))
            .machine_name(machine_name())
            .build();

        step(0.24, "Registering this iPhone with Apple");

        // Same rule as the step above: a dropped request is worth another go,
        // an answer from Apple is final.
        let team = {
            let mut got = None;
            let mut last = String::new();
            for attempt in 1..=3u32 {
                if attempt > 1 {
                    let _ = events.send(Event::Status(
                        "The connection dropped that request. Trying again".to_string(),
                    ));
                    tokio::time::sleep(std::time::Duration::from_secs(2 * attempt as u64)).await;
                }
                match tokio::time::timeout(
                    std::time::Duration::from_secs(45),
                    sideloader.get_team(),
                )
                .await
                {
                    Ok(Ok(team)) => {
                        got = Some(team);
                        break;
                    }
                    Ok(Err(error)) => {
                        let text = error.to_string();
                        if !looks_like_transport(&text) {
                            return Err(format!(
                                "Apple would not say which developer team you are on: {text}"
                            ));
                        }
                        last = text;
                    }
                    Err(_) => last = "the request to Apple timed out".to_string(),
                }
                tracing::warn!("team lookup attempt {attempt} did not complete: {last}");
            }
            match got {
                Some(team) => team,
                None => return Err(friendly_login_error(&last)),
            }
        };

        // On a second go, clear Apple's side out before trying again. The
        // signing library asks for the certificate list once and then revokes
        // from that copy, so anything deleted in the meantime gets revoked
        // twice and the second attempt is fatal. This re-asks every time.
        if attempt > 1 {
            let _ = events.send(Event::Status("Tidying up old certificates".to_string()));
            let count = make_room(sideloader.get_dev_session(), &team, &machine_name()).await;
            tracing::info!("cleared {count} certificate(s)");
            cleared = Some(count);
        }

        let (device_name, device_udid) = match &provider {
            Some(provider) => {
                let info = IdeviceInfo::from_device(provider)
                    .await
                    .map_err(|e| format!("Could not read the iPhone's name: {e}"))?;
                (info.name, info.udid)
            }
            None => (
                device::apple_view(udid).map(|view| view.name).unwrap_or_else(|| "iPhone".to_string()),
                udid.to_string(),
            ),
        };

        sideloader
            .get_dev_session()
            .ensure_device_registered(&team, &device_name, &device_udid, None)
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
                tracing::error!("signing failed on attempt {attempt}: {text}");
                if looks_stale(&text) {
                    return Err(certificate_dead_end(cleared));
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

    match &provider {
        Some(provider) => install_signed(provider, &signed, copy_progress)
            .await
            .map_err(|e| friendly_install_error(&e.to_string()))?,
        None => {
            let _ = events.send(Event::Status("Installing through Apple's own tool".to_string()));
            let talk = events.clone();
            device::install_with_apple_tooling(udid, &signed, |note| {
                let _ = talk.send(Event::Status(note.to_string()));
            })
            .await?;
            let _ = events.send(Event::Progress(0.95));
        }
    }

    // Read these before the signed copy is thrown away.
    let profile_uuid = crate::handoff::profile_uuid(&signed);
    let profile_bytes = std::fs::read(signed.join("embedded.mobileprovision")).ok();
    let _ = std::fs::remove_dir_all(&signed);

    step(0.92, "Telling iOS to trust it");

    // Without this the first launch is met with "Untrusted Developer" and a
    // hunt through Settings. iOS lets a connected computer answer that for
    // you, so it does.
    //
    // Two things learned on iOS 27. The install returns before the phone has
    // registered the app's provisioning profile (it was doing that lazily on
    // first launch), and asking it to trust a profile it has not registered
    // is answered with a bare {success: false}. So the profile is registered
    // through misagent first, the way AltStore does, and the trust request is
    // retried for a few seconds while the install settles.
    let mut trusted = false;
    if let Some(provider) = &provider {
        if let Some(bytes) = profile_bytes {
            match crate::handoff::register_profile(provider, bytes).await {
                Ok(()) => tracing::info!("provisioning profile registered with the phone"),
                Err(message) => tracing::warn!("could not register the profile: {message}"),
            }
        }
        if let Some(uuid) = &profile_uuid {
            for attempt in 1..=5u32 {
                match crate::handoff::trust_signer(provider, uuid).await {
                    Ok(true) => { trusted = true; break; }
                    Ok(false) => tracing::warn!("trust attempt {attempt}: the phone said no"),
                    Err(message) => tracing::warn!("trust attempt {attempt}: {message}"),
                }
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        }
    }
    let _ = events.send(Event::Trusted(trusted));

    step(0.96, "Handing Cloak the keys");

    let bundle_id = format!("app.cloak.ios.{}", team.team_id);

    // The record travelled inside the app, so there is nothing left to hand
    // over. The AFC push only runs when bundling failed; iOS refuses it on
    // most versions, but it is the only remaining route in that case.
    if let Some(provider) = &provider {
        if !record_bundled {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            if let Err(message) = crate::handoff::send_pairing_record(provider, &bundle_id).await {
                tracing::warn!("pairing handoff skipped: {message}");
            }
        }

        step(0.98, "Leaving a copy for on-phone refresh");
        if let Err(message) = crate::handoff::send_app_copy(provider, &bundle_id, ipa).await {
            tracing::warn!("could not leave an app copy for on-phone refresh: {message}");
        }
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

/// Revokes signing certificates until Apple has room for a new one.
///
/// Apple caps how many a developer account may hold, and hitting the cap is
/// the normal state of affairs for anybody who has run more than one of these
/// tools. The signing library handles that by listing the certificates once
/// and then revoking from its copy, which breaks the moment one of them has
/// already gone: revoking a certificate that is not there returns error 7252
/// and takes the whole install down with it.
///
/// This asks Apple again before every revoke and treats a refusal as "already
/// gone", which is what it means. Certificates this installer made itself go
/// first, so somebody's Xcode setup survives where possible.
async fn make_room(session: &mut DeveloperSession, team: &DeveloperTeam, ours: &str) -> usize {
    let mut removed = 0usize;
    let mut first_pass = true;
    let mut tried: std::collections::HashSet<String> = std::collections::HashSet::new();

    for _ in 0..12 {
        let certs = match session.list_ios_certs(team).await {
            Ok(certs) => certs,
            Err(error) => {
                tracing::warn!("could not list certificates: {error}");
                break;
            }
        };

        if first_pass {
            first_pass = false;
            tracing::info!("Apple lists {} development certificate(s):", certs.len());
            for cert in &certs {
                let kind = cert
                    .certificate_type
                    .as_ref()
                    .and_then(|t| t.name.clone())
                    .unwrap_or_else(|| "unknown type".to_string());
                let platform = cert
                    .certificate_platform
                    .clone()
                    .or_else(|| {
                        cert.certificate_type
                            .as_ref()
                            .and_then(|t| t.platform.clone())
                    })
                    .unwrap_or_else(|| "unstated".to_string());
                tracing::info!(
                    "  serial={} platform={} type={} machine={:?} status={:?}/{:?} name={:?}",
                    cert.serial_number.clone().unwrap_or_else(|| "none".to_string()),
                    platform,
                    kind,
                    cert.machine_name,
                    cert.status,
                    cert.status_code,
                    cert.name,
                );
            }
        }

        let untried: Vec<_> = certs
            .iter()
            .filter(|cert| {
                cert.serial_number
                    .as_ref()
                    .is_some_and(|serial| !tried.contains(serial))
            })
            .collect();

        if untried.is_empty() {
            break;
        }

        // Ours first, then whatever else is in the way.
        let chosen = untried
            .iter()
            .find(|cert| cert.machine_name.as_deref() == Some(ours))
            .copied()
            .or_else(|| untried.first().copied());

        let Some(cert) = chosen else { break };
        let Some(serial) = cert.serial_number.clone() else { break };
        tried.insert(serial.clone());

        match session.revoke_development_cert(team, &serial, None).await {
            Ok(()) => {
                removed += 1;
                tracing::info!("revoked certificate {serial}");
            }
            Err(error) => {
                // Almost always 7252: it was already gone. Nothing to do and
                // nothing worth telling the user about.
                tracing::info!("certificate {serial} was already gone ({error})");
            }
        }
    }

    removed
}

/// The signing certificate slots are full and Apple will not let us clear them.
///
/// Apple allows a small, fixed number of development certificates per account.
/// The installer clears its own out of the way automatically, but a certificate
/// Apple lists yet refuses to revoke (usually one Xcode made under a different
/// certificate type) can only be removed by hand.
fn certificate_dead_end(cleared: Option<usize>) -> String {
    let opening = match cleared {
        Some(0) => "Apple would not let go of any of the signing certificates on your account.",
        Some(count) => {
            return format!(
                "Cleared {count} old signing certificate(s), but Apple still refused to issue a \
                 new one.\n\nOpen developer.apple.com/account/resources/certificates/list, \
                 delete the development certificates listed there, then run this installer \
                 again.\n\nThe full log is in Library/Logs/Cloak/installer.log inside your \
                 home folder."
            );
        }
        None => "Apple would not issue a signing certificate.",
    };

    format!(
        "{opening}\n\nYour account has run out of signing certificate slots. Open \
         developer.apple.com/account/resources/certificates/list, sign in, delete the \
         development certificates listed there, then run this installer again.\n\nThe full \
         log is in Library/Logs/Cloak/installer.log inside your home folder."
    )
}

/// Whether a signing failure is the kind that a clean slate fixes.
///
/// Apple's 7252 is "there is no certificate with that serial on this team",
/// which means our copy of the identity is describing something that no longer
/// exists. Retrieving the identity failing at all is the same family.
fn looks_stale(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("7252")
        || lower.contains("7460")
        || lower.contains("no 'ios' certificate with serial number")
        || lower.contains("failed to retrieve certificate identity")
        || lower.contains("failed to revoke development certificate")
        || lower.contains("maximum number of certificates")
        || lower.contains("reached max attempts to request certificate")
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

/// Whether Apple answers at all from this network.
///
/// A plain TCP connect, because it is the cheapest thing that catches the whole
/// family of causes: no DNS, no route, a filtered network, a captive portal
/// that has not been signed into.
async fn apple_reachable() -> Result<(), String> {
    // All at once. These are independent questions about the same route, and
    // asking them one after another turned a four second check into half a
    // minute on a slow line, which reads as the installer having hung.
    let doors = ["gsa.apple.com:443", "developerservices2.apple.com:443"];
    let knocks: Vec<_> = doors
        .iter()
        .map(|host| {
            let host = host.to_string();
            tokio::spawn(async move {
                let outcome = tokio::time::timeout(
                    std::time::Duration::from_secs(5),
                    tokio::net::TcpStream::connect(&host),
                )
                .await;
                match outcome {
                    Ok(Ok(_)) => Ok(()),
                    Ok(Err(error)) => Err(format!("{host}: {error}")),
                    Err(_) => Err(format!("{host}: timed out")),
                }
            })
        })
        .collect();

    // One failure is enough to stop, but only after both have been asked, so
    // the error names whichever actually broke rather than whichever was first.
    let mut answers = Vec::new();
    for knock in knocks {
        answers.push(knock.await.unwrap_or_else(|e| Err(format!("check failed: {e}"))));
    }
    if let Some(failure) = answers.into_iter().find_map(Result::err) {
        if name_lookup_failed(&failure) && apple_answers_by_address().await {
            return Err(BROKEN_RESOLVER.to_string());
        }
        return Err(failure);
    }

    // A TCP connect proves almost nothing: it succeeds straight through a
    // filter that opens the traffic and re-signs it, and the sign-in then
    // fails much later with something that reads like Apple's fault. So do
    // real HTTPS requests, with the same TLS stack the sign-in uses.
    let client = reqwest::Client::builder()
        .user_agent("Cloak Installer")
        .timeout(std::time::Duration::from_secs(6))
        .build()
        .map_err(|e| format!("could not build a client: {e}"))?;

    // Three of them, not one. A route that drops one request in five passes a
    // single check and then fails the sign-in, which is a run of a dozen
    // requests back to back. Run together they cost one request's worth of
    // time and still catch the flakiness.
    let tries: Vec<_> = (1..=3)
        .map(|attempt| {
            let client = client.clone();
            tokio::spawn(async move {
                match client.get("https://gsa.apple.com/grandslam/GsService2").send().await {
                    // Any answer at all is a good answer: 401 is what Apple
                    // says to an unauthenticated GET, and it proves the whole
                    // path works.
                    Ok(_) => None,
                    Err(error) => Some(format!("try {attempt}: {error}")),
                }
            })
        })
        .collect();
    let mut failures: Vec<String> = Vec::new();
    for handle in tries {
        if let Ok(Some(failure)) = handle.await {
            failures.push(failure);
        }
    }

    if failures.is_empty() {
        return Ok(());
    }

    if failures.len() == 3 {
        return Err(format!("https to gsa.apple.com: {}", failures.join("; ")));
    }

    // Some worked, some did not. That is the worst kind, because it looks
    // like everything is fine right up until it is not.
    Err(format!(
        "FLAKY: {} of 3 requests to Apple failed. {}",
        failures.len(),
        failures.join("; ")
    ))
}

/// Marker for the one network fault that is this computer rather than the line.
const BROKEN_RESOLVER: &str = "broken-name-lookup";

fn name_lookup_failed(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("failed to lookup address")
        || lower.contains("nodename nor servname")
        || lower.contains("name or service not known")
        || lower.contains("dns")
}

/// Whether Apple answers when the name lookup is skipped entirely.
///
/// If a fixed Apple address answers on 443 while the name will not resolve,
/// then the connection is fine and the name lookup on this computer is broken.
/// That happens after VPN software is removed untidily, and it is invisible
/// from the browser's point of view because it fails identically to being
/// offline, so it is worth saying out loud rather than blaming the network.
async fn apple_answers_by_address() -> bool {
    // Apple's own range. Any of these answering is enough to prove the point.
    for address in ["17.32.194.34:443", "17.253.144.10:443"] {
        let reached = tokio::time::timeout(
            std::time::Duration::from_secs(6),
            tokio::net::TcpStream::connect(address),
        )
        .await;
        if matches!(reached, Ok(Ok(_))) {
            return true;
        }
    }
    false
}

fn unreachable_message_for(failure: &str) -> String {
    if failure == BROKEN_RESOLVER {
        return "This computer cannot look up web addresses, so nothing can reach Apple.\n\nThe connection itself is fine. Cloak reached Apple by numeric address a moment ago. What is broken is the part of macOS that turns a name like apple.com into an address, and while it is broken every app on this Mac is affected, not just Cloak.\n\nRestart the Mac. That fixes it. It is usually left behind by VPN software that was removed or quit untidily.".to_string();
    }
    unreachable_message()
}

fn unreachable_message() -> String {
    let mut message = String::from(
        "Cloak cannot reach Apple from this network.\n\nSigning in has to talk to apple.com, and something between this computer and Apple is blocking or dropping it. Work, school and guest networks very often do.",
    );
    if let Some(name) = tunnel_in_the_way() {
        message.push_str(&format!(
            "\n\nEverything on this computer is currently going through {name}, so that is the most likely cause. Turn it off and try again.",
        ));
    } else {
        message.push_str(
            "\n\nTry again on a home network, or share your phone's internet connection and use that.",
        );
    }
    message
}

/// The name of the VPN carrying this computer's traffic, if one is.
///
/// Apple limits sign-ins hard by internet address, and a VPN puts thousands of
/// strangers behind one. A shared address is normally already over the limit,
/// so Apple refuses the sign-in before it looks at anything, and waiting never
/// helps because the address never goes quiet. It is indistinguishable from a
/// lockout from the inside and it is the single most common reason this fails.
#[cfg(target_os = "macos")]
fn tunnel_in_the_way() -> Option<String> {
    let route = std::process::Command::new("route")
        .args(["-n", "get", "default"])
        .output()
        .ok()?;
    let route = String::from_utf8_lossy(&route.stdout);
    let interface = route
        .lines()
        .find_map(|line| line.trim().strip_prefix("interface:"))?
        .trim();

    let tunnelled = interface.starts_with("utun")
        || interface.starts_with("ppp")
        || interface.starts_with("ipsec")
        || interface.starts_with("tun");
    if !tunnelled {
        return None;
    }

    // The interface says a tunnel, not which one. scutil names the connected
    // services, and a name is far more use to somebody than "utun26".
    let listed = std::process::Command::new("scutil")
        .args(["--nc", "list"])
        .output()
        .ok();
    if let Some(listed) = listed {
        let text = String::from_utf8_lossy(&listed.stdout);
        for line in text.lines() {
            if !line.contains("(Connected)") {
                continue;
            }
            if let Some(start) = line.find('"') {
                if let Some(end) = line[start + 1..].find('"') {
                    let name = &line[start + 1..start + 1 + end];
                    if !name.is_empty() && !name.eq_ignore_ascii_case("Tailscale") {
                        return Some(name.to_string());
                    }
                }
            }
        }
    }

    // Tailscale does not appear in scutil at all: it owns a utun of its own
    // and nothing lists it as a network service. Everything on the machine
    // going through an exit node looks exactly like this, and it was the
    // blind spot that made a blocked network read as Apple's refusal.
    if let Some(name) = tailscale_exit_node() {
        return Some(name);
    }

    Some("a VPN".to_string())
}

#[cfg(not(target_os = "macos"))]
fn tunnel_in_the_way() -> Option<String> {
    None
}

/// Tailscale, and the exit node it is sending everything through if there is
/// one. An exit node is the case that matters: all traffic leaves through
/// somebody else's machine, and when that machine is having a bad day every
/// request from here fails in a way that looks like the far end's fault.
#[cfg(target_os = "macos")]
fn tailscale_exit_node() -> Option<String> {
    for binary in [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ] {
        if !std::path::Path::new(binary).exists() {
            continue;
        }
        let Ok(output) = std::process::Command::new(binary).args(["status", "--json"]).output() else {
            continue;
        };
        let Ok(parsed) = serde_json::from_slice::<serde_json::Value>(&output.stdout) else {
            continue;
        };
        if parsed.get("BackendState").and_then(|v| v.as_str()) != Some("Running") {
            return None;
        }
        // The active exit node is the peer flagged as one.
        if let Some(peers) = parsed.get("Peer").and_then(|v| v.as_object()) {
            for peer in peers.values() {
                if peer.get("ExitNode").and_then(|v| v.as_bool()) == Some(true) {
                    let name = peer
                        .get("HostName")
                        .and_then(|v| v.as_str())
                        .unwrap_or("another machine");
                    return Some(format!("Tailscale, through the exit node {name}"));
                }
            }
        }
        return Some("Tailscale".to_string());
    }
    None
}

#[cfg(target_os = "macos")]
fn tailscale_running() -> bool {
    tailscale_exit_node().is_some()
}

#[cfg(not(target_os = "macos"))]
fn tailscale_running() -> bool {
    false
}

/// Whether Apple rejected the request because the sign-in helper gave it
/// something it did not like.
///
/// A 503 from grandslam on a request that was otherwise well formed is the
/// signature of an anisette server handing out identity data Apple has stopped
/// accepting. It reads as an outage but it is per-helper, so another one very
/// often works immediately.
fn looks_like_bad_helper(text: &str) -> bool {
    let lower = text.to_lowercase();

    // A request that never got an answer says nothing about what Apple thinks
    // of anybody's identity. This has to be ruled out first, because the
    // module that talks to Apple is called grandslam and its name is in the
    // source path of every error it ever produces, network ones included.
    if looks_like_transport(&lower) {
        return false;
    }

    let apple_had_a_verdict = (lower.contains("grandslam") || lower.contains("gsservice2"))
        && (lower.contains("503") || lower.contains("temporarily unavailable"));

    apple_had_a_verdict
        || lower.contains("-45003")
        || lower.contains("invalid trust key")
        || lower.contains("failed to provision")
        || lower.contains("provisioning failed")
}

/// The request never completed. Nothing here is a verdict from Apple: it is
/// DNS, TLS, a dropped connection or a timeout, and the fix is on this side.
fn looks_like_transport(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("error sending request")
        || lower.contains("failed to send")
        || lower.contains("connection reset")
        || lower.contains("connection closed")
        || lower.contains("connection refused")
        || lower.contains("network is unreachable")
        || lower.contains("no route to host")
        || lower.contains("operation timed out")
        || lower.contains("timed out")
        || lower.contains("dns error")
        || lower.contains("could not resolve")
        || looks_intercepted(&lower)
}

/// Something is sitting between this computer and the internet, opening the
/// traffic and re-signing it with its own certificate. School and office
/// filters do this. curl trusts it because its certificate is in the system
/// store; the signing library does not, and refuses the connection.
fn looks_intercepted(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("certificate is not trusted")
        || lower.contains("invalid peer certificate")
        || lower.contains("-67843")
        || lower.contains("unknown issuer")
        || lower.contains("self signed")
        || lower.contains("self-signed")
}

/// Whether a sign-in failure was the network rather than the account.
///
/// These all mean the same thing to somebody sitting in front of it, which is
/// that nothing they typed was wrong and trying again may simply work.
fn looks_transient(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("error sending request")
        || lower.contains("url bag")
        || lower.contains("503")
        || lower.contains("502")
        || lower.contains("504")
        || lower.contains("temporarily unavailable")
        || lower.contains("timed out")
        || lower.contains("timeout")
        || lower.contains("connection reset")
        || lower.contains("connection closed")
        || lower.contains("dns")
}

/// Whether Apple is refusing because it has seen too many attempts.
///
/// The lockout is measured in hours, so getting this wrong and retrying is
/// expensive. Anything that smells like it is treated as one.
fn looks_rate_limited(text: &str) -> bool {
    let lower = text.to_lowercase();
    // -22406 does NOT belong here. It is Apple saying the password is wrong,
    // and treating it as a lockout told people to go away and wait two hours
    // when what they needed to do was retype their password.
    lower.contains("429")
        || lower.contains("rate limit")
        || lower.contains("too many")
        || lower.contains("try again later")
}

/// Apple judged the password and it did not match.
fn wrong_password(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("-22406")
        || lower.contains("-20101")
        || lower.contains("enter the correct password")
}

fn friendly_login_error(raw: &str) -> String {
    let lower = raw.to_lowercase();
    // First, because it is the one answer that means Apple looked at the
    // account and reached a verdict. Everything below it is about getting as
    // far as being asked.
    if wrong_password(&lower) {
        return "Apple says that password is not right for this Apple ID.\n\nEverything else worked: Apple accepted the computer, accepted the Apple ID, and checked the password, so this is the password itself and nothing else.\n\nTwo things catch people out. An app-specific password will not work here, it has to be the real one. And if two-factor is on, the password still goes in this box and the six digit code is asked for separately afterwards.\n\nIf it is definitely right, sign in at appleid.apple.com once in a browser and then try here again.".to_string();
    }
    if looks_intercepted(&lower) {
        return format!(
            "Something on this network is opening encrypted traffic and re-signing it, and Apple's sign-in will not accept that.\n\nThis is what a school, office or guest network filter does. Cloak saw a certificate that was not Apple's on the way to Apple.{}\n\nUse a different network, or share your phone's internet connection and try again from there.",
            match tunnel_in_the_way() {
                Some(name) => format!(" Everything on this computer is currently going through {name}, so try turning that off first."),
                None => String::new(),
            }
        );
    }
    if looks_like_transport(&lower) {
        return format!(
            "{}\n\nApple never answered: the connection itself failed, so nothing was judged and nothing is wrong with the Apple ID.\n\nWhat went wrong underneath: {}",
            unreachable_message(),
            raw.lines().find(|line| line.contains("error sending request") || line.contains("certificate")).unwrap_or(raw).trim()
        );
    }
    if looks_rate_limited(&lower) {
        if let Some(name) = tunnel_in_the_way() {
            return format!(
                "Apple is refusing sign-ins from this computer's internet address, and {name} is why.\n\nEverything on this computer is going through it right now, which means Apple sees the same address as everybody else using it. Apple limits sign-ins per address, that shared one is already over the limit, and it never goes quiet enough to recover. Waiting will not fix this.\n\nTurn {name} off and sign in again. It can go back on afterwards."
            );
        }
        return "Apple has temporarily stopped accepting sign-ins from this computer.\n\nIt limits how quickly sign-ins can arrive from one internet connection, and every further attempt keeps it refusing.\n\nLeave it completely alone for ten minutes, then try once. If that does not work, share your phone's internet connection and try once from there.".to_string();
    }
    if looks_like_bad_helper(&lower) {
        return "Apple turned this sign-in away, and not because of the password.\n\nApple periodically stops accepting the identity that sideloading tools present, and when it does every one of them breaks at the same moment. Other apps that install without the App Store will be failing right now too.\n\nThis usually clears within a day. If somebody has published a fix, the details go in the two boxes under \"Sign-in helper\" on the sign-in screen, and no new version of Cloak is needed.\n\nDo not keep retrying: Apple locks an account out for two hours after repeated attempts.".to_string();
    }
    if lower.contains("incorrect") {
        "That Apple ID and password did not match. Note that an app-specific password will not work here, use the real one.".into()
    } else if lower.contains("locked") {
        "Apple has locked this account for security. Sign in at appleid.apple.com first, then come back.".into()
    } else if looks_transient(&lower) {
        // Three goes have already been had by the time this is reached.
        format!(
            "{}\n\nCloak tried three times and the connection failed every time.",
            unreachable_message()
        )
    } else if lower.contains("anisette") {
        "The Apple sign-in helper could not be reached. Check the internet connection and try again.".into()
    } else if lower.contains("password") {
        "That Apple ID and password did not match. Note that an app-specific password will not work here — use the real one.".into()
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

#[cfg(test)]
mod classification {
    use super::*;

    /// The real failure from Bob's Mac after the helper sweep was reordered.
    /// An identity minted by one helper was sent to another, and Apple
    /// answered this at the password step without ever judging the password.
    const STALE_IDENTITY: &str = "Failed to log in to Apple ID vendor/isideload/src/auth/apple_account.rs:289 GrandSlam error during proof login request vendor/isideload/src/auth/apple_account.rs:1058 Auth error -22421: This action could not be completed. Try again. vendor/isideload/src/auth/grandslam.rs:350";

    #[test]
    fn an_unverifiable_identity_is_recognised() {
        assert!(crate::anisette::stale_session(STALE_IDENTITY));
    }

    #[test]
    fn an_unverifiable_identity_is_not_a_refused_helper() {
        // It used to fall through to here, which blacklisted a helper that
        // was working and reported an outage that was not happening.
        assert!(!crate::anisette::helper_was_rejected(STALE_IDENTITY));
    }

    #[test]
    fn an_unverifiable_identity_is_not_a_dropped_connection() {
        assert!(!looks_like_transport(STALE_IDENTITY));
    }

    #[test]
    fn an_unverifiable_identity_is_not_a_wrong_password() {
        assert!(!wrong_password(STALE_IDENTITY));
    }

    #[test]
    fn a_dropped_connection_is_not_an_unverifiable_identity() {
        assert!(!crate::anisette::stale_session(NETWORK_FAILURE));
    }

    /// The real failure from Bob's Mac, verbatim. It was reported as Apple
    /// refusing the identity because the word "grandslam" is in the source
    /// path of every error that module produces.
    const NETWORK_FAILURE: &str = " ● Failed to send proof login request ● Failed to send grandslam request ├ vendor/isideload/src/auth/grandslam.rs:203 ● error sending request for url (https://gsa.apple.com/grandslam/GsService2) ╰ vendor/isideload/src/auth/grandslam.rs:203";

    #[test]
    fn a_dead_connection_is_not_apple_refusing_anything() {
        assert!(looks_like_transport(NETWORK_FAILURE));
        assert!(!looks_like_bad_helper(NETWORK_FAILURE));
        let message = friendly_login_error(NETWORK_FAILURE);
        assert!(!message.contains("Apple turned this sign-in away"));
        assert!(message.contains("cannot reach Apple"));
    }

    #[test]
    fn an_intercepted_connection_says_so() {
        let text = "invalid peer certificate: Other(OtherError(\"F7CF1ATB21000078 certificate is not trusted: -67843\"))";
        assert!(looks_intercepted(text));
        assert!(!looks_like_bad_helper(text));
        assert!(friendly_login_error(text).contains("re-signing"));
    }

    #[test]
    fn a_real_refusal_still_reads_as_one() {
        let text = "grandslam request failed: 503 Service Temporarily Unavailable";
        assert!(looks_like_bad_helper(text));
        assert!(friendly_login_error(text).contains("Apple turned this sign-in away"));

        let trust = "Anisette provisioning failed: -45003 invalid trust key";
        assert!(looks_like_bad_helper(trust));
    }

    #[test]
    fn a_wrong_password_still_wins() {
        let text = "-20101 the password is incorrect";
        assert!(friendly_login_error(text).contains("password is not right"));
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

    // Headless: nobody can type a pairing code, so the remote pairing step
    // gets a channel that answers empty at once and is skipped.
    let (_pin_tx, pin_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    drop(_pin_tx);
    let pin_rx = Arc::new(Mutex::new(pin_rx));
    install(&udid, &apple_id, &password, false, &ipa, &tx, code_rx, pin_rx).await
}

/// Whether this phone still needs anything done to it.
pub fn developer_mode_ok(phone: &Phone) -> bool {
    matches!(phone.developer_mode, DeveloperMode::On | DeveloperMode::NotApplicable)
}


/// Runs remote pairing against the phone from this computer, asking the
/// window for the code the phone shows.
async fn remote_pair(
    device_name: &str,
    events: &Events,
    pin_rx: Arc<Mutex<UnboundedReceiver<String>>>,
) -> Result<String, String> {
    let name = device_name.to_string();
    let found = tokio::task::spawn_blocking(move || crate::rppair::browse(std::time::Duration::from_secs(12)))
        .await
        .map_err(|e| format!("browse task: {e}"))??;
    if found.is_empty() {
        return Err("no phone is advertising remote pairing on this computer's networks (is the phone on the same Wi-Fi as this computer?)".to_string());
    }

    let events = events.clone();
    let ask = || {
        let events = events.clone();
        let pin_rx = pin_rx.clone();
        async move {
            let _ = events.send(Event::NeedPairingPin);
            // Drain anything stale, then wait for the fresh one.
            let mut guard = pin_rx.lock().await;
            while let Ok(_) = guard.try_recv() {}
            guard.recv().await.unwrap_or_default()
        }
    };

    let mut last = String::new();
    for target in crate::rppair::ordered(&found, &name) {
        let _ = events.send(Event::Status(format!("Pairing with {}", target.name.trim_end_matches(&format!(".{}", "_remotepairing._tcp.local.")))));
        match tokio::time::timeout(std::time::Duration::from_secs(180), crate::rppair::pair(target, &ask)).await {
            Ok(Ok(record)) => return Ok(record),
            Ok(Err(reason)) => last = format!("{}: {reason}", target.name),
            Err(_) => last = format!("{}: pairing timed out", target.name),
        }
        tracing::warn!("remote pairing with {} failed: {last}", target.name);
    }
    Err(last)
}


/// A background task that is cancelled when it goes out of scope.
///
/// Every exit from the sign-in loop is a `continue`, a `break` or a `return`,
/// and a status ticker that outlived one of those would talk over whatever
/// came next.
pub struct StopOnDrop(pub tokio::task::JoinHandle<()>);

impl Drop for StopOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}


/// Opens the developer session, riding out a connection that drops requests.
///
/// This is the step straight after the password, and it is a fresh request to
/// the same endpoint the sign-in just used. On a line that drops one request
/// in five it lands on the bad one often enough to be the normal outcome, and
/// failing here threw away a sign-in that had completely succeeded, which is
/// the most expensive possible moment to give up.
///
/// Only a dropped connection is retried. An answer from Apple is an answer.
async fn open_developer_session(
    account: &mut AppleAccount,
    events: &Events,
) -> Result<DeveloperSession, String> {
    let mut last = String::new();

    for attempt in 1..=4u32 {
        if attempt > 1 {
            let _ = events.send(Event::Status(
                "The connection dropped that request. Trying again".to_string(),
            ));
            tokio::time::sleep(std::time::Duration::from_secs(2 * attempt as u64)).await;
        }

        match tokio::time::timeout(
            std::time::Duration::from_secs(45),
            DeveloperSession::from_account(account),
        )
        .await
        {
            Ok(Ok(session)) => return Ok(session),
            Ok(Err(error)) => {
                let text = error.to_string();
                // Apple answered and said no. Another go changes nothing.
                if !looks_like_transport(&text) {
                    return Err(format!("Apple would not open a developer session: {text}"));
                }
                last = text;
            }
            Err(_) => last = "the request to Apple timed out".to_string(),
        }
        tracing::warn!("developer session attempt {attempt} did not complete: {last}");
    }

    tracing::error!("developer session never completed: {last}");
    Err(friendly_login_error(&last))
}

