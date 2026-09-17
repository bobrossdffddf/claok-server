//! Talking to the iPhone over USB.

use idevice::{
    amfi::AmfiClient,
    lockdown::LockdownClient,
    provider::{IdeviceProvider, TcpProvider},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
    IdeviceService,
};

const LABEL: &str = "Cloak Installer";

#[derive(Debug, Clone, PartialEq)]
pub struct Phone {
    pub udid: String,
    pub name: String,
    pub ios_version: String,
    pub developer_mode: DeveloperMode,
    /// Whether this phone has tapped Trust on this computer.
    ///
    /// Nothing works without it, including reading which iOS it runs and
    /// asking it to show the Developer Mode switch, so a phone that has not
    /// been trusted looks identical to one that is simply not ready. Saying
    /// which it is turns a dead end into one tap.
    pub trusted: bool,
    /// How usbmuxd says this phone is attached.
    pub link: Link,
    /// True when nothing of ours can reach the phone but Apple's own tooling
    /// can, which is the state every door being shut on macOS 26+ produces.
    pub via_apple_tooling: bool,
    /// Why it could not be read, when it could not be read. This exists
    /// because every failure used to be reported as "not trusted", which sent
    /// people to tap Trust over and over at a phone that had already trusted
    /// this computer and was failing for an entirely different reason.
    pub problem: Option<Problem>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Link {
    Usb,
    /// Listed only over Wi-Fi sync. usbmuxd advertises these exactly like a
    /// cabled phone, and lockdownd refuses them unless Wi-Fi sync is on and
    /// the phone is awake on the same network, so a Wi-Fi ghost of a phone
    /// sitting in a drawer looks identical to a cabled phone refusing to talk.
    Network,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Problem {
    /// The phone has never been trusted, or the trust was revoked.
    NotTrusted,
    /// Listed over Wi-Fi only, so there is nothing to install through.
    WifiOnly,
    /// lockdownd would not take the connection at all. Being locked, having
    /// just been plugged in, or being a stale usbmuxd entry all do this.
    Refused(String),
    /// It answered but would not say what it is.
    Unreadable(String),
}

impl Problem {
    /// What to tell somebody, in the words that describe their actual
    /// situation rather than the first guess.
    pub fn headline(&self) -> &'static str {
        match self {
            Problem::NotTrusted => "Unlock the iPhone and tap Trust",
            Problem::WifiOnly => "Plug the iPhone in with a cable",
            Problem::Refused(_) => "The iPhone is not answering yet",
            Problem::Unreadable(_) => "The iPhone answered but would not identify itself",
        }
    }

    pub fn detail(&self) -> String {
        match self {
            Problem::NotTrusted => "It has not trusted this computer yet, so nothing can be read from it or changed on it. Unlock the screen, tap Trust This Computer, type the passcode, then unplug it and plug it back in.".to_string(),
            Problem::WifiOnly => "This iPhone is only showing up over Wi-Fi sync, which cannot install anything. Connect it with a cable and unlock it. If it is already plugged in, try the other end of the cable or another port: a charge-only cable looks exactly like this.".to_string(),
            Problem::Refused(detail) => format!("It is attached, but iOS refused the connection. This is not the Trust prompt, and tapping Trust again will not change it.\n\nIn order of likelihood:\n\n1. USB Restricted Mode. In Settings > Face ID & Passcode, scroll to Allow Access When Locked and turn Accessories on. With it off and the phone locked for an hour, iOS charges but refuses all data.\n\n2. The phone is locked. Unlock it and leave it unlocked while this runs.\n\n3. The cable or the port. One that enumerates and then drops mid-handshake does exactly this. Try the other end, another port, and a cable you know carries data.\n\nWhat iOS said: {detail}"),
            Problem::Unreadable(detail) => format!("It accepted the connection but would not answer basic questions about itself. Unlock it and try again.\n\nWhat iOS said: {detail}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeveloperMode {
    /// Nothing to do — either it is on, or this iOS is old enough not to have
    /// the concept at all.
    On,
    Off,
    NotApplicable,
    Unknown,
}

impl Phone {
    /// iOS 16 is where Developer Mode arrived. Before that the toggle does not
    /// exist and nothing needs turning on.
    pub fn major_version(&self) -> u32 {
        self.ios_version
            .split('.')
            .next()
            .and_then(|part| part.parse().ok())
            .unwrap_or(0)
    }
}

/// Whether anything is listening where usbmuxd should be.
///
/// On macOS that is Apple's own daemon and it is always there. On Windows it
/// is Apple Mobile Device Support, which arrives with iTunes or the Apple
/// Devices app, and its absence is the single most common reason a Windows
/// install goes nowhere.
/// Opens a connection to the iPhone driver, honouring USBMUXD_SOCKET_ADDRESS.
///
/// idevice's stock default-connection helper hardwires the `/var/run/usbmuxd`
/// socket and never looks at the environment. That is wrong on Linux and
/// ChromeOS, where there is no system usbmuxd and the CLI starts a private,
/// user-owned one on a socket under `$XDG_RUNTIME_DIR`, pointing idevice at it
/// through `USBMUXD_SOCKET_ADDRESS` (see usbmux.rs). Only `from_env_var()`
/// reads that variable, so every usbmuxd connection this module makes must go
/// through here, or the private daemon is invisible and the no-root path never
/// works.
///
/// With the variable unset this is the old behaviour byte for byte: on macOS
/// and Windows `from_env_var()` falls back to the same default as before
/// (the /var/run socket, or TCP 127.0.0.1:27015 on Windows).
async fn muxd_connection() -> Result<UsbmuxdConnection, idevice::IdeviceError> {
    UsbmuxdAddr::from_env_var().unwrap_or_default().connect(0).await
}

pub async fn usbmuxd_available() -> bool {
    muxd_connection().await.is_ok()
}

/// The last answer for each phone, so a scan on a timer costs nothing when
/// nothing has changed. Short lived on purpose: unplugging must still show up
/// promptly.
static PHONE_CACHE: std::sync::Mutex<Option<(std::time::Instant, Vec<Phone>)>> =
    std::sync::Mutex::new(None);

fn cached_phones() -> Option<Vec<Phone>> {
    let guard = PHONE_CACHE.lock().ok()?;
    let (at, phones) = guard.as_ref()?;
    if at.elapsed() < std::time::Duration::from_secs(20) {
        Some(phones.clone())
    } else {
        None
    }
}

fn remember_phones(phones: &[Phone]) {
    if let Ok(mut guard) = PHONE_CACHE.lock() {
        *guard = Some((std::time::Instant::now(), phones.to_vec()));
    }
}

/// Throw the cache away, for when the person has asked for a fresh look.
pub fn forget_phones() {
    if let Ok(mut guard) = PHONE_CACHE.lock() {
        *guard = None;
    }
}

pub async fn list_phones() -> Result<Vec<Phone>, String> {
    let mut usbmuxd = muxd_connection()
        .await
        .map_err(|e| format!("Could not reach the iPhone driver: {e}"))?;

    let devices = usbmuxd
        .get_devices()
        .await
        .map_err(|e| format!("Could not list iPhones: {e}"))?;

    // Nothing plugged in is the one answer that must never come from a cache.
    if devices.is_empty() {
        remember_phones(&[]);
        return Ok(Vec::new());
    }

    // Everything else can be, because working it out takes seconds and the
    // answer does not change between two ticks of a timer.
    if let Some(cached) = cached_phones() {
        if cached.len() == devices.len()
            && cached.iter().all(|phone| devices.iter().any(|d| d.udid == phone.udid))
        {
            return Ok(cached);
        }
    }

    let addr = UsbmuxdAddr::from_env_var().unwrap_or_default();

    // usbmuxd lists a Wi-Fi synced phone exactly like a cabled one. Cabled
    // entries come first and a phone listed both ways is only kept once, as
    // the cabled one, because that is the entry anything can be installed
    // through.
    let mut ordered: Vec<_> = devices.into_iter().collect();
    ordered.sort_by_key(|device| match device.connection_type {
        Connection::Usb => 0,
        _ => 1,
    });

    let mut phones: Vec<Phone> = Vec::new();
    for device in ordered {
        if phones.iter().any(|existing| existing.udid == device.udid) {
            continue;
        }
        let link = match device.connection_type {
            Connection::Usb => Link::Usb,
            _ => Link::Network,
        };

        if link == Link::Network {
            tracing::info!("{} is listed over Wi-Fi only", device.udid);
            phones.push(unreadable(&device.udid, link, Problem::WifiOnly));
            continue;
        }

        // Asked at the same time as our own doors, not after them. On macOS 26
        // and later this is the only route that ever answers, and waiting for
        // two of ours to be refused first is where the ten second wait before
        // the phone appeared was coming from. It costs a subprocess, runs
        // while the driver is being tried, and is thrown away unused whenever
        // the driver works.
        let apple = {
            let udid = device.udid.clone();
            tokio::task::spawn_blocking(move || apple_view(&udid))
        };

        let provider = device.to_provider(addr.clone(), LABEL);
        let phone = match describe(&provider, &device.udid, link).await {
            Ok(phone) => phone,
            Err(Problem::Refused(reason)) => {
                let seen = apple.await.ok().flatten();

                // Apple's own tool can see it and it is paired. There is
                // nothing left to find out, so do not spend eight seconds and
                // two subprocesses on the cable's network link to find it out
                // again more slowly.
                if let Some(view) = seen.filter(|view| view.paired) {
                    tracing::info!(
                        "driver refused {} ({reason}); Apple's tool has it, using that",
                        device.udid
                    );
                    from_apple_view(&device.udid, link, view)
                } else {
                    // The driver would not carry us and Apple cannot see it
                    // either. Now the cable's own network link is worth the
                    // wait, because it is the only thing left to ask.
                    tracing::info!(
                        "driver refused {} ({reason}); trying the cable directly",
                        device.udid
                    );
                    match direct_provider_for(&device.udid).await {
                        Ok(direct) => match describe(&direct, &device.udid, link).await {
                            Ok(phone) => phone,
                            Err(problem) => through_apple(&device.udid, link, problem),
                        },
                        Err(_) => through_apple(&device.udid, link, Problem::Refused(reason)),
                    }
                }
            }
            Err(problem) => unreadable(&device.udid, link, problem),
        };
        tracing::info!(
            "found phone: name={:?} ios={:?} developer_mode={:?} trusted={} link={:?} problem={:?}",
            phone.name,
            phone.ios_version,
            phone.developer_mode,
            phone.trusted,
            phone.link,
            phone.problem,
        );
        phones.push(phone);
    }
    remember_phones(&phones);
    Ok(phones)
}

/// A connection handle for one phone through the iPhone driver, made fresh
/// each time because usbmuxd connections are cheap and long-lived ones go
/// stale across a reboot.
pub async fn muxd_provider_for(udid: &str) -> Result<idevice::provider::UsbmuxdProvider, String> {
    let mut usbmuxd = muxd_connection()
        .await
        .map_err(|e| format!("Could not reach the iPhone driver: {e}"))?;
    let devices = usbmuxd
        .get_devices()
        .await
        .map_err(|e| format!("Could not list iPhones: {e}"))?;

    // The cabled entry, when there is one. Picking the Wi-Fi entry of a phone
    // that is also plugged in is a silent dead end: every service refuses.
    let mut matching: Vec<_> = devices.into_iter().filter(|d| d.udid == udid).collect();
    matching.sort_by_key(|device| match device.connection_type {
        Connection::Usb => 0,
        _ => 1,
    });
    let device = matching
        .into_iter()
        .next()
        .ok_or_else(|| "That iPhone is not plugged in.".to_string())?;

    if !matches!(device.connection_type, Connection::Usb) {
        return Err("That iPhone is only reachable over Wi-Fi sync, which cannot install anything. Plug it in with a cable.".to_string());
    }

    let addr = UsbmuxdAddr::from_env_var().unwrap_or_default();
    Ok(device.to_provider(addr, LABEL))
}

/// What every caller wants: a way in, by whichever route works.
pub async fn provider_for(udid: &str) -> Result<Door, String> {
    open_door(udid).await
}

/// Every door of ours is shut. If Apple's own tool can see the phone, this is
/// a working phone behind a macOS that will not let anyone else talk to it,
/// and the install can still go ahead through that tool.
fn through_apple(udid: &str, link: Link, problem: Problem) -> Phone {
    match apple_view(udid) {
        Some(view) if view.paired => from_apple_view(udid, link, view),
        _ => unreadable(udid, link, problem),
    }
}

/// A phone as Apple's own tool sees it.
fn from_apple_view(udid: &str, link: Link, view: AppleView) -> Phone {
    tracing::info!(
        "using Apple's tooling for {udid}: iOS {} developer mode {}",
        view.ios_version,
        view.developer_mode
    );
    Phone {
        udid: udid.to_string(),
        name: view.name,
        ios_version: view.ios_version,
        developer_mode: if view.developer_mode { DeveloperMode::On } else { DeveloperMode::Off },
        trusted: true,
        link,
        via_apple_tooling: true,
        problem: None,
    }
}

fn unreadable(udid: &str, link: Link, problem: Problem) -> Phone {
    Phone {
        udid: udid.to_string(),
        name: "iPhone".into(),
        ios_version: String::new(),
        developer_mode: DeveloperMode::Unknown,
        trusted: false,
        link,
        via_apple_tooling: false,
        problem: Some(problem),
    }
}

async fn describe(provider: &dyn IdeviceProvider, udid: &str, link: Link) -> Result<Phone, Problem> {
    // A phone that has just been plugged in, or has just been unlocked,
    // refuses the first connection or two. Retrying for a couple of seconds is
    // the difference between "not trusted" and simply working.
    let mut lockdown = None;
    let mut last = String::new();
    for attempt in 0..2 {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        }
        match LockdownClient::connect(provider).await {
            Ok(client) => {
                lockdown = Some(client);
                break;
            }
            Err(error) => {
                last = error.to_string();
                tracing::warn!("lockdown refused (attempt {}): {error}", attempt + 1);
            }
        }
    }
    let Some(mut lockdown) = lockdown else {
        return Err(Problem::Refused(last));
    };

    // Only now is trust the question. A missing pairing record is the honest
    // "tap Trust" case; everything above it is not.
    let pairing = match provider.get_pairing_file().await {
        Ok(pairing) => pairing,
        Err(error) => {
            tracing::info!("no pairing record: {error}");
            return Err(Problem::NotTrusted);
        }
    };
    if let Err(error) = lockdown.start_session(&pairing).await {
        tracing::info!("lockdown session refused: {error}");
        return Err(Problem::NotTrusted);
    }

    let name = lockdown
        .get_value(Some("DeviceName"), None)
        .await
        .ok()
        .and_then(|v| v.as_string().map(str::to_owned))
        .unwrap_or_else(|| "iPhone".into());

    let ios_version = lockdown
        .get_value(Some("ProductVersion"), None)
        .await
        .ok()
        .and_then(|v| v.as_string().map(str::to_owned))
        .unwrap_or_default();

    let major: u32 = ios_version
        .split('.')
        .next()
        .and_then(|p| p.parse().ok())
        .unwrap_or(0);

    let developer_mode = if major > 0 && major < 16 {
        DeveloperMode::NotApplicable
    } else {
        match lockdown
            .get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi"))
            .await
        {
            Ok(value) => match value.as_boolean() {
                Some(true) => DeveloperMode::On,
                Some(false) => DeveloperMode::Off,
                None => DeveloperMode::Unknown,
            },
            Err(_) => DeveloperMode::Unknown,
        }
    };

    Ok(Phone {
        udid: udid.to_string(),
        name,
        ios_version,
        developer_mode,
        trusted: true,
        link,
        via_apple_tooling: false,
        problem: None,
    })
}

/// Makes the Developer Mode switch visible in Settings.
///
/// iOS hides it until a developer tool has connected at least once, which is
/// exactly the wall people hit when they try to follow instructions that say
/// "go to Privacy & Security and turn on Developer Mode" and find no such row.
pub async fn reveal_developer_mode(provider: &dyn IdeviceProvider) -> Result<(), String> {
    let mut amfi = AmfiClient::connect(provider).await.map_err(|e| {
        tracing::warn!("amfi connect failed while revealing: {e}");
        format!("Could not reach the security service on the iPhone: {e}")
    })?;
    let result = amfi
        .reveal_developer_mode_option_in_ui()
        .await
        .map_err(|e| format!("The iPhone refused to show the Developer Mode switch: {e}"));
    match &result {
        Ok(()) => tracing::info!("asked the iPhone to show the Developer Mode switch"),
        Err(message) => tracing::warn!("reveal failed: {message}"),
    }
    result
}

/// Why iOS would not turn Developer Mode on for us.
pub enum DevModeRefusal {
    /// iOS refuses the remote request on a phone with a passcode, and only
    /// the remote request. Turning the switch on by hand works normally: the
    /// passcode is part of Apple's own documented steps, typed after the
    /// restart to confirm.
    PasscodeSet,
    Other(String),
}

/// Turns Developer Mode on. The phone reboots as a result.
pub async fn enable_developer_mode(provider: &dyn IdeviceProvider) -> Result<(), DevModeRefusal> {
    let mut amfi = AmfiClient::connect(provider).await.map_err(|e| {
        tracing::warn!("amfi connect failed while enabling: {e}");
        DevModeRefusal::Other(format!(
            "Could not reach the security service on the iPhone: {e}"
        ))
    })?;

    tracing::info!("asking the iPhone to turn Developer Mode on");
    amfi.enable_developer_mode().await.map_err(|e| {
        let text = e.to_string();
        if text.to_lowercase().contains("passcode") {
            tracing::info!("iOS refused the remote enable because a passcode is set");
            DevModeRefusal::PasscodeSet
        } else {
            tracing::warn!("enable failed: {e}");
            DevModeRefusal::Other(format!("The iPhone refused to turn Developer Mode on: {e}"))
        }
    })
}

/// Answers the "Turn on Developer Mode?" prompt that appears after the reboot.
pub async fn accept_developer_mode(provider: &dyn IdeviceProvider) -> Result<(), String> {
    let mut amfi = AmfiClient::connect(provider)
        .await
        .map_err(|e| format!("Could not reach the security service on the iPhone: {e}"))?;
    tracing::info!("confirming Developer Mode after the restart");
    amfi.accept_developer_mode()
        .await
        .map_err(|e| format!("The iPhone would not confirm Developer Mode: {e}"))
}

/// Waits until the phone actually reports Developer Mode as on.
///
/// Answering the post-restart prompt is not the same as the switch being on,
/// and moving the installer along before it is leaves somebody looking at a
/// screen that says the opposite of what their phone says. This asks the
/// phone rather than assuming.
pub async fn wait_for_developer_mode(udid: &str, seconds: u64) -> bool {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(seconds);
    while std::time::Instant::now() < deadline {
        if let Ok(phones) = list_phones().await {
            if let Some(phone) = phones.iter().find(|p| p.udid == udid) {
                if matches!(
                    phone.developer_mode,
                    DeveloperMode::On | DeveloperMode::NotApplicable
                ) {
                    return true;
                }
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
    false
}

/// Waits for a phone to come back after a reboot.
pub async fn wait_for_return(udid: &str, seconds: u64) -> bool {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(seconds);
    while std::time::Instant::now() < deadline {
        if let Ok(phones) = list_phones().await {
            if phones.iter().any(|p| p.udid == udid) {
                return true;
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
    false
}

/// One lockdown value as a string, over a fresh session.
async fn lockdown_string(provider: &dyn IdeviceProvider, key: &str) -> Option<String> {
    let mut lockdown = LockdownClient::connect(provider).await.ok()?;
    let pairing = provider.get_pairing_file().await.ok()?;
    lockdown.start_session(&pairing).await.ok()?;
    lockdown
        .get_value(Some(key), None)
        .await
        .ok()
        .and_then(|v| v.as_string().map(str::to_owned))
}

pub async fn device_name(provider: &dyn IdeviceProvider) -> Option<String> {
    lockdown_string(provider, "DeviceName").await
}

pub async fn ios_major(provider: &dyn IdeviceProvider) -> Option<u32> {
    let version = lockdown_string(provider, "ProductVersion").await?;
    version.split('.').next()?.parse().ok()
}

// MARK: - Doctor

/// Everything we can learn about why a phone will not talk, printed in one go.
///
/// This exists because a refused lockdown connection has at least five causes
/// that look identical from the outside, and guessing between them by swapping
/// cables and re-tapping Trust costs hours. Each line below is a measurement,
/// and the verdict at the end is derived only from measurements.
pub async fn doctor() -> String {
    use std::fmt::Write;
    let mut out = String::new();
    let _ = writeln!(out, "Cloak doctor\n");

    // 1. Is anything on the USB bus at all? macOS answers this without any
    //    pairing, trust or cooperation from the phone.
    let physical = std::process::Command::new("/usr/sbin/ioreg")
        .args(["-p", "IOUSB", "-l", "-w", "0"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_lowercase())
        .unwrap_or_default();
    let usb_iphone = physical.contains("iphone");
    let _ = writeln!(out, "USB bus: {}", if usb_iphone { "an iPhone is attached" } else { "NO iPhone attached" });

    // 2. What does the iPhone driver say?
    let driver_up = usbmuxd_available().await;
    let _ = writeln!(out, "iPhone driver: {}", if driver_up { "running" } else { "NOT reachable" });
    if !driver_up {
        let _ = writeln!(out, "\nVerdict: the iPhone driver is not running. {}", crate::usbmux::advice());
        return out;
    }

    let phones = list_phones().await;
    match &phones {
        Err(error) => {
            let _ = writeln!(out, "Listing phones failed: {error}");
        }
        Ok(list) if list.is_empty() => {
            let _ = writeln!(out, "Phones listed: none");
        }
        Ok(list) => {
            let _ = writeln!(out, "Phones listed: {}", list.len());
            for phone in list {
                let _ = writeln!(
                    out,
                    "  {} | link {:?} | iOS {} | developer mode {:?} | {}",
                    phone.udid,
                    phone.link,
                    if phone.ios_version.is_empty() { "unknown".into() } else { phone.ios_version.clone() },
                    phone.developer_mode,
                    match &phone.problem {
                        None => "reachable".to_string(),
                        Some(p) => format!("{p:?}"),
                    }
                );
            }
        }
    }

    let mut direct_worked = false;
    let mut rsd_worked = false;

    // 3. For each cabled phone, try the two doors in turn and report which
    //    one opens. CoreDeviceProxy is the route Xcode itself uses on iOS 17
    //    and later, and it can work when lockdown's own port does not.
    if let Ok(list) = &phones {
        for phone in list.iter().filter(|p| p.link == Link::Usb) {
            let _ = writeln!(out, "\nDoors on {}:", phone.udid);
            match provider_for(&phone.udid).await {
                Err(error) => { let _ = writeln!(out, "  no provider: {error}"); }
                Ok(provider) => {
                    match LockdownClient::connect(&provider).await {
                        Ok(_) => { let _ = writeln!(out, "  lockdown (port 62078): OPEN"); }
                        Err(error) => { let _ = writeln!(out, "  lockdown (port 62078): refused - {error}"); }
                    }
                    match provider.get_pairing_file().await {
                        Ok(_) => { let _ = writeln!(out, "  pairing record: present"); }
                        Err(error) => { let _ = writeln!(out, "  pairing record: missing - {error}"); }
                    }
                    match idevice::services::core_device_proxy::CoreDeviceProxy::connect(&provider).await {
                        Ok(proxy) => {
                            let _ = writeln!(out, "  CoreDevice tunnel: OPEN (RSD port {})", proxy.tunnel_info().server_rsd_port);
                        }
                        Err(error) => { let _ = writeln!(out, "  CoreDevice tunnel: refused - {error}"); }
                    }
                }
            }

            // The way round a driver that will not proxy: the cable's own
            // network link.
            let _ = writeln!(out, "\nStraight down the cable (no driver involved):");
            let peers = usb_network_peers();
            if peers.is_empty() {
                let _ = writeln!(out, "  no phone found on any interface");
            }
            for (address, scope) in &peers {
                let _ = writeln!(out, "  candidate {address} (scope {scope})");
            }
            for phone in list.iter().filter(|p| p.link == Link::Usb) {
                match direct_provider_for(&phone.udid).await {
                    Ok(_) => {
                        let _ = writeln!(out, "  {} : REACHED, lockdown answered and identified itself", phone.udid);
                        direct_worked = true;
                    }
                    Err(error) => { let _ = writeln!(out, "  {} : lockdown - {error}", phone.udid); }
                }
            }

            // Lockdown is dead on iOS 26.4 and later for anything that is not
            // Apple's. Remote Service Discovery is what is left.
            let _ = writeln!(out, "\nRemote Service Discovery (the iOS 26.4+ door):");
            for (address, scope) in usb_network_peers() {
                match probe_rsd(&address, scope).await {
                    Ok(services) => {
                        let _ = writeln!(out, "  {address} (scope {scope}): OPEN, {} services", services.len());
                        for name in services.iter().take(14) {
                            let _ = writeln!(out, "      {name}");
                        }
                        rsd_worked = true;
                        break;
                    }
                    Err(error) => { let _ = writeln!(out, "  {address} (scope {scope}): {error}"); }
                }
            }
        }
    }

    // 4. What Apple's own tool thinks, which tells us whether the phone is
    //    trusted at all, independently of anything Cloak does.
    if let Ok(output) = std::process::Command::new("/usr/bin/xcrun")
        .args(["devicectl", "list", "devices"])
        .output()
    {
        let text = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = text.lines().filter(|l| l.contains("physical")).collect();
        let _ = writeln!(out, "\nApple's own view:");
        if lines.is_empty() {
            let _ = writeln!(out, "  no physical devices known to macOS");
        }
        for line in lines {
            let _ = writeln!(out, "  {}", line.trim());
        }
    }

    // 5. The verdict, from the measurements above only.
    let _ = writeln!(out, "\nVerdict:");
    let cabled = phones.as_ref().map(|l| l.iter().any(|p| p.link == Link::Usb)).unwrap_or(false);
    let wifi_only = phones.as_ref().map(|l| l.iter().any(|p| p.link == Link::Network)).unwrap_or(false);

    if !usb_iphone && !cabled {
        let _ = writeln!(out, "  No iPhone is attached by cable. Anything Cloak shows about a phone right now is left over from an earlier scan.");
        if wifi_only {
            let _ = writeln!(out, "  Your Mac can see the phone over Wi-Fi, which is why it looks connected, but nothing can be installed that way.");
        }
        let _ = writeln!(out, "  Plug it in with a cable that carries data. A charge-only cable enumerates nothing at all, which is exactly what this looks like.");
    } else if cabled {
        let refused = phones.as_ref().map(|l| l.iter().any(|p| matches!(p.problem, Some(Problem::Refused(_))))).unwrap_or(false);
        let untrusted = phones.as_ref().map(|l| l.iter().any(|p| matches!(p.problem, Some(Problem::NotTrusted)))).unwrap_or(false);
        if untrusted {
            let _ = writeln!(out, "  The phone is attached and answering, but there is no pairing record. This one really is the Trust prompt: unlock the phone, tap Trust, type the passcode.");
        } else if refused {
            if direct_worked {
                let _ = writeln!(out, "  The iPhone driver refuses to carry connections for anything that is not Apple's own software, which is a macOS problem and not yours.");
                let _ = writeln!(out, "  The phone itself is answering perfectly over the cable's network link, so Cloak will use that instead and there is nothing for you to fix.");
                return out;
            }
            if rsd_worked {
                let _ = writeln!(out, "  The iPhone driver refuses to carry connections for anything that is not Apple's own software, and iOS 26.4 and later no longer answer the old lockdown route for a third party either.");
                let _ = writeln!(out, "  The phone is answering Remote Service Discovery over the cable, which is the route Xcode itself uses, so that is the one to install through. Nothing here is wrong with your phone, your cable or your Trust prompt.");
                return out;
            }
            let _ = writeln!(out, "  The phone is attached but iOS refused the connection. In order of likelihood:");
            let _ = writeln!(out, "    1. USB Restricted Mode. Settings > Face ID & Passcode > Allow Access When Locked > Accessories. With it off and the phone locked for an hour, iOS enumerates for charging and refuses all data.");
            let _ = writeln!(out, "    2. The phone is locked. Unlock it and leave it unlocked while this runs.");
            let _ = writeln!(out, "    3. A failing cable or port: it enumerates, then drops mid-handshake.");
            let _ = writeln!(out, "  This is not the Trust prompt. Tapping Trust again will not change it.");
        } else {
            let _ = writeln!(out, "  The phone is attached and answering. Nothing is wrong at this layer.");
        }
    }
    out
}

// MARK: - Straight down the cable, without usbmuxd

/// The phone, reached over the network link the cable already provides.
///
/// macOS 27 refuses to proxy connections for anything that is not Apple's own
/// software: usbmuxd enumerates the phone, hands over the pairing record, and
/// then answers every single `Connect` with "device refused connection". That
/// is not the phone, and no amount of trusting, unlocking or re-cabling
/// touches it, which is exactly why it looked unfixable.
///
/// A connected iPhone is also an ethernet device. macOS brings it up as an
/// `anri` interface with a link-local IPv6 address at each end, and every
/// service the phone offers is listening there: lockdown on 62078, remote
/// pairing on 49152, RSD on 58783. Measured on iOS 27.0 over a cable, with
/// usbmuxd refusing all three at the same moment.
///
/// So when the driver refuses, go around it.
pub fn usb_network_peers() -> Vec<(String, u32)> {
    // Discovery pings every interface and waits on mDNS, so it costs seconds.
    // It is asked for repeatedly during one run, and the answer does not
    // change from second to second, so it is worked out once and kept briefly.
    static CACHE: std::sync::Mutex<Option<(std::time::Instant, Vec<(String, u32)>)>> =
        std::sync::Mutex::new(None);
    if let Ok(guard) = CACHE.lock() {
        if let Some((at, cached)) = guard.as_ref() {
            if at.elapsed() < std::time::Duration::from_secs(30) && !cached.is_empty() {
                return cached.clone();
            }
        }
    }

    let found = discover_peers();
    if let Ok(mut guard) = CACHE.lock() {
        *guard = Some((std::time::Instant::now(), found.clone()));
    }
    found
}

fn discover_peers() -> Vec<(String, u32)> {
    let mut found: Vec<(String, u32)> = Vec::new();


    // An iPhone shows up as anri*; older macOS used en* for the same job, and
    // Linux calls it enp*/usb*. Nudge each one so neighbour discovery has
    // something in its cache, then read the cache.
    let interfaces = own_interfaces();
    // A cabled iPhone comes up as anri (or usb on Linux). Pinging every
    // ethernet and Wi-Fi interface as well costs a couple of seconds each and
    // finds nothing, so those are only swept when there is no anri at all.
    let direct: Vec<String> = interfaces
        .iter()
        .filter(|name| name.starts_with("anri") || name.starts_with("usb"))
        .cloned()
        .collect();
    let to_nudge = if direct.is_empty() { interfaces.clone() } else { direct };
    for name in &to_nudge {
        nudge(name);
    }
    // Neighbour discovery is not instant.
    std::thread::sleep(std::time::Duration::from_millis(400));

    let table = neighbours();
    tracing::info!("neighbour table has {} entries across {:?}", table.len(), interfaces);

    let mine = own_addresses();
    tracing::info!("this machine's v6 addresses: {mine:?}");
    for (address, interface) in table {
        if !interfaces.iter().any(|candidate| candidate == &interface) {
            continue;
        }
        // Ours is in the table too; skip anything this machine owns. The
        // comparison is on the address with any scope stripped, because
        // getifaddrs on macOS hides the scope id inside the address bytes and
        // the two spellings never match as strings.
        if mine.iter().any(|owned| same_address(owned, &address)) {
            tracing::info!("skipping {address} on {interface}: that is us");
            continue;
        }
        let index = interface_index(&interface);
        tracing::info!("candidate {address} on {interface} (index {index})");
        if index != 0 && !found.iter().any(|(a, s)| a == &address && *s == index) {
            found.push((address, index));
        }
    }

    // Then whatever is advertising itself, for the case where the neighbour
    // entry has expired. An advertisement does not say which link it arrived
    // on, so each address is paired with every candidate interface and the
    // wrong ones simply fail to answer. Deduplicated on the pair, so a correct
    // entry from the table above is never shadowed by a guessed scope.
    for (address, scope) in advertised_peers() {
        if !found.iter().any(|(a, s)| a == &address && *s == scope) {
            found.push((address, scope));
        }
    }

    // Same reasoning: the link the phone is really on, first.
    let preferred: Vec<u32> = ordered_interfaces().iter().map(|name| interface_index(name)).collect();
    found.sort_by_key(|(_, scope)| preferred.iter().position(|index| index == scope).unwrap_or(usize::MAX));
    tracing::info!("peer candidates: {found:?}");
    found
}

/// Every phone advertising Remote Service Discovery, which on a cabled iPhone
/// is advertised over the USB link. Returns scoped link-local addresses.
fn advertised_peers() -> Vec<(String, u32)> {
    use mdns_sd::{ServiceDaemon, ServiceEvent};

    let mut found: Vec<(String, u32)> = Vec::new();
    let Ok(daemon) = ServiceDaemon::new() else { return found };

    let mut receivers = Vec::new();
    for service in ["_remoted._tcp.local.", "_apple-mobdev2._tcp.local."] {
        if let Ok(receiver) = daemon.browse(service) {
            receivers.push(receiver);
        }
    }

    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(2500);
    while std::time::Instant::now() < deadline {
        for receiver in &receivers {
            while let Ok(event) = receiver.recv_timeout(std::time::Duration::from_millis(120)) {
                if let ServiceEvent::ServiceResolved(info) = event {
                    for address in info.get_addresses() {
                        let std::net::IpAddr::V6(v6) = address else { continue };
                        let text = v6.to_string();
                        // Which interface it arrived on decides the scope.
                        for interface in own_interfaces() {
                            let index = interface_index(&interface);
                            if index == 0 { continue; }
                            if !found.iter().any(|(existing, scope)| existing == &text && *scope == index) {
                                found.push((text.clone(), index));
                            }
                        }
                    }
                    tracing::info!("advertised device service: {} at {:?}", info.get_fullname(), info.get_addresses());
                }
            }
        }
        if !found.is_empty() { break; }
    }
    let _ = daemon.shutdown();
    found
}

/// Interfaces worth looking at: the ones a cabled iPhone appears on.
fn own_interfaces() -> Vec<String> {
    let mut names = ordered_interfaces();
    names.dedup();
    names
}

/// The same list, with the interface a cabled iPhone actually appears on
/// first. Trying an address on the wrong link costs a connection timeout
/// each, so the order here is most of the speed of the whole route.
fn ordered_interfaces() -> Vec<String> {
    let mut names = raw_interfaces();
    names.sort_by_key(|name| if name.starts_with("anri") { 0 } else if name.starts_with("usb") { 1 } else { 2 });
    names
}

#[cfg(not(unix))]
fn raw_interfaces() -> Vec<String> {
    Vec::new()
}

#[cfg(unix)]
fn raw_interfaces() -> Vec<String> {
    let mut names = Vec::new();
    unsafe {
        let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut head) != 0 {
            return names;
        }
        let mut cursor = head;
        while !cursor.is_null() {
            let entry = &*cursor;
            if !entry.ifa_name.is_null() {
                let name = std::ffi::CStr::from_ptr(entry.ifa_name).to_string_lossy().to_string();
                let interesting = name.starts_with("anri")
                    || name.starts_with("en")
                    || name.starts_with("usb")
                    || name.starts_with("enp");
                if interesting && !names.contains(&name) {
                    names.push(name);
                }
            }
            cursor = entry.ifa_next;
        }
        libc::freeifaddrs(head);
    }
    names
}

#[cfg(not(unix))]
fn own_addresses() -> Vec<String> {
    Vec::new()
}

#[cfg(unix)]
fn own_addresses() -> Vec<String> {
    let mut addresses = Vec::new();
    unsafe {
        let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut head) != 0 {
            return addresses;
        }
        let mut cursor = head;
        while !cursor.is_null() {
            let entry = &*cursor;
            if !entry.ifa_addr.is_null() && (*entry.ifa_addr).sa_family as i32 == libc::AF_INET6 {
                let sock = entry.ifa_addr as *const libc::sockaddr_in6;
                let bytes = (*sock).sin6_addr.s6_addr;
                let address = std::net::Ipv6Addr::from(bytes).to_string();
                addresses.push(address);
            }
            cursor = entry.ifa_next;
        }
        libc::freeifaddrs(head);
    }
    addresses
}

/// Whether two IPv6 addresses are the same host, ignoring how the scope was
/// spelled. macOS reports a link-local from getifaddrs with the interface
/// index buried in the third and fourth bytes, so `fe80::1` on interface 46
/// comes back as `fe80:2e::1` and never matches the text form.
fn same_address(a: &str, b: &str) -> bool {
    fn normalise(value: &str) -> Option<[u16; 8]> {
        let bare = value.split('%').next().unwrap_or(value);
        let mut parts = bare.parse::<std::net::Ipv6Addr>().ok()?.segments();
        if parts[0] & 0xffc0 == 0xfe80 {
            parts[1] = 0;
        }
        Some(parts)
    }
    match (normalise(a), normalise(b)) {
        (Some(left), Some(right)) => left == right,
        _ => a == b,
    }
}

#[cfg(not(unix))]
fn interface_index(_name: &str) -> u32 {
    0
}

#[cfg(unix)]
fn interface_index(name: &str) -> u32 {
    let Ok(c_name) = std::ffi::CString::new(name) else { return 0 };
    unsafe { libc::if_nametoindex(c_name.as_ptr()) }
}

/// Send something to the all-nodes multicast address so the neighbour table
/// has the phone in it. No privileges needed; the packet going nowhere is fine.
///
/// The scope id is put into the socket address by hand rather than written as
/// "ff02::1%anri0" and handed to a name lookup, because getaddrinfo refuses a
/// scope on a multicast address and the whole discovery then finds nothing.
fn nudge(interface: &str) {
    let index = interface_index(interface);
    if index == 0 {
        return;
    }
    let all_nodes = std::net::Ipv6Addr::new(0xff02, 0, 0, 0, 0, 0, 0, 1);
    let target = std::net::SocketAddr::V6(std::net::SocketAddrV6::new(all_nodes, 9, 0, index));
    if let Ok(socket) = std::net::UdpSocket::bind("[::]:0") {
        for _ in 0..2 {
            let _ = socket.send_to(&[0u8; 1], target);
        }
    }

    // Belt and braces: an actual ICMPv6 echo to the same address fills the
    // table even where a stray UDP datagram does not.
    #[cfg(target_os = "macos")]
    {
        // No -i: an interval under a second is refused for anyone who is not
        // root, and ping6 then exits without sending a single packet, which is
        // exactly how this looked like "the phone is not on any interface".
        let output = std::process::Command::new("/sbin/ping6")
            .args(["-c", "2", "-I", interface, &format!("ff02::1%{interface}")])
            .output();
        if let Ok(output) = output {
            let replies = String::from_utf8_lossy(&output.stdout)
                .lines()
                .filter(|line| line.contains("bytes from"))
                .count();
            tracing::info!("nudged {interface}: {replies} replies");
        }
    }
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("ping")
            .args(["-6", "-c", "2", "-W", "1", "-I", interface, "ff02::1"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
}

/// Everything the neighbour table knows, as (address with scope, interface).
#[cfg(target_os = "macos")]
fn neighbours() -> Vec<(String, String)> {
    parse_ndp(
        &std::process::Command::new("/usr/sbin/ndp")
            .args(["-an"])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default(),
    )
}

#[cfg(target_os = "macos")]
fn parse_ndp(text: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let Some(address) = parts.next() else { continue };
        let Some(_mac) = parts.next() else { continue };
        let Some(interface) = parts.next() else { continue };
        if !address.starts_with("fe80::") {
            continue;
        }
        let bare = address.split('%').next().unwrap_or(address).to_string();
        out.push((bare, interface.to_string()));
    }
    out
}

#[cfg(target_os = "linux")]
fn neighbours() -> Vec<(String, String)> {
    let text = std::process::Command::new("ip")
        .args(["-6", "neigh"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();
    let mut out = Vec::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let Some(address) = parts.next() else { continue };
        if !address.starts_with("fe80::") {
            continue;
        }
        let mut interface = String::new();
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if let Some(position) = tokens.iter().position(|t| *t == "dev") {
            if let Some(name) = tokens.get(position + 1) {
                interface = name.to_string();
            }
        }
        out.push((address.to_string(), interface));
    }
    out
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn neighbours() -> Vec<(String, String)> {
    Vec::new()
}

/// A provider that goes straight to the phone over the cable's network link,
/// verified to be the phone we actually want by asking it who it is.
/// When the direct route last failed for a phone. Retrying it every few
/// seconds costs discovery plus a connection timeout and never changes its
/// mind within a minute, so it is left alone for a while after a failure.
static DIRECT_HOPELESS: std::sync::Mutex<Option<(String, std::time::Instant)>> =
    std::sync::Mutex::new(None);

fn direct_recently_failed(udid: &str) -> bool {
    match DIRECT_HOPELESS.lock() {
        Ok(guard) => guard
            .as_ref()
            .is_some_and(|(who, when)| who == udid && when.elapsed() < std::time::Duration::from_secs(120)),
        Err(_) => false,
    }
}

fn remember_direct_failure(udid: &str) {
    if let Ok(mut guard) = DIRECT_HOPELESS.lock() {
        *guard = Some((udid.to_string(), std::time::Instant::now()));
    }
}

pub async fn direct_provider_for(udid: &str) -> Result<TcpProvider, String> {
    if direct_recently_failed(udid) {
        return Err("The cable's own network link did not answer a moment ago.".to_string());
    }
    // The pairing record still comes from usbmuxd: reading it is allowed even
    // where connecting is not.
    let pairing = match muxd_provider_for(udid).await {
        Ok(provider) => provider
            .get_pairing_file()
            .await
            .map_err(|e| format!("no pairing record for this phone: {e}"))?,
        Err(error) => return Err(error),
    };

    let peers = usb_network_peers();
    if peers.is_empty() {
        remember_direct_failure(udid);
        return Err("The phone is not on any network interface this computer can see.".to_string());
    }

    // A scope that worked once works again; a scope that failed is not worth
    // eight seconds every time.
    static GOOD_SCOPE: std::sync::Mutex<Option<(String, u32)>> = std::sync::Mutex::new(None);
    let known = GOOD_SCOPE.lock().ok().and_then(|guard| guard.clone());

    let mut peers = peers;
    if let Some(good) = &known {
        peers.retain(|peer| peer == good);
        if peers.is_empty() {
            peers.push(good.clone());
        }
    }

    let mut last = String::new();
    for (address, scope) in peers {
        let Ok(parsed) = address.parse::<std::net::IpAddr>() else { continue };
        let provider = TcpProvider {
            addr: parsed,
            scope_id: Some(scope),
            pairing_file: pairing.clone(),
            label: LABEL.to_string(),
        };
        let attempt = tokio::time::timeout(std::time::Duration::from_secs(8), confirm(&provider, udid)).await;
        let attempt = match attempt {
            Ok(result) => result,
            Err(_) => Err("timed out".to_string()),
        };
        match attempt {
            Ok(()) => {
                tracing::info!("reaching {udid} directly at {address} (scope {scope})");
                if let Ok(mut guard) = GOOD_SCOPE.lock() {
                    *guard = Some((address.clone(), scope));
                }
                return Ok(provider);
            }
            Err(error) => {
                last = format!("{address}: {error}");
                tracing::info!("{address} is not the phone we want: {error}");
            }
        }
    }
    remember_direct_failure(udid);
    Err(format!("No interface answered as this iPhone. Last: {last}"))
}

/// Asks whatever is at the other end who it is, and insists on the right answer.
async fn confirm(provider: &TcpProvider, udid: &str) -> Result<(), String> {
    let mut lockdown = LockdownClient::connect(provider)
        .await
        .map_err(|e| format!("lockdown: {e}"))?;
    let pairing = provider
        .get_pairing_file()
        .await
        .map_err(|e| format!("pairing: {e}"))?;
    lockdown
        .start_session(&pairing)
        .await
        .map_err(|e| format!("session: {e}"))?;
    let reported = lockdown
        .get_value(Some("UniqueDeviceID"), None)
        .await
        .map_err(|e| format!("identity: {e}"))?
        .as_string()
        .map(str::to_owned)
        .unwrap_or_default();
    if reported.eq_ignore_ascii_case(udid) {
        Ok(())
    } else {
        Err(format!("that is {reported}"))
    }
}

// MARK: - One provider, whichever door opened

/// Either way in, behind one type, so nothing downstream has to know or care
/// which door was used.
#[derive(Debug)]
pub enum Door {
    /// Through the iPhone driver, which is how it has always worked.
    Driver(idevice::provider::UsbmuxdProvider),
    /// Straight down the cable's network link, for machines whose driver
    /// refuses to carry anything that is not Apple's.
    Direct(TcpProvider),
}

impl IdeviceProvider for Door {
    fn connect(
        &self,
        port: u16,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<idevice::Idevice, idevice::IdeviceError>> + Send>> {
        match self {
            Door::Driver(provider) => provider.connect(port),
            Door::Direct(provider) => provider.connect(port),
        }
    }

    fn label(&self) -> &str {
        match self {
            Door::Driver(provider) => provider.label(),
            Door::Direct(provider) => provider.label(),
        }
    }

    fn get_pairing_file(
        &self,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<idevice::pairing_file::PairingFile, idevice::IdeviceError>> + Send>> {
        match self {
            Door::Driver(provider) => provider.get_pairing_file(),
            Door::Direct(provider) => provider.get_pairing_file(),
        }
    }
}

/// The way in for this phone: the driver if it will carry us, the cable's own
/// network link if it will not.
///
/// Tries the driver first because it is the route every other tool uses and
/// the one most likely to keep working. Falls through on a refusal rather than
/// on any error, so a genuinely untrusted phone still reports as untrusted
/// instead of being chased down a second road for no reason.
pub async fn open_door(udid: &str) -> Result<Door, String> {
    let through_driver = muxd_provider_for(udid).await;
    if let Ok(provider) = through_driver {
        match LockdownClient::connect(&provider).await {
            Ok(_) => return Ok(Door::Driver(provider)),
            Err(error) => {
                tracing::info!("the driver would not carry us ({error}); trying the cable directly");
            }
        }
    }

    match direct_provider_for(udid).await {
        Ok(provider) => Ok(Door::Direct(provider)),
        Err(error) => Err(error),
    }
}


/// Opens Remote Service Discovery on the cable's network link and reports what
/// the phone is offering. This is the handshake Xcode does, and on iOS 26.4
/// and later it is the only one the phone still answers for a third party.
pub async fn probe_rsd(address: &str, scope: u32) -> Result<Vec<String>, String> {
    let Ok(parsed) = address.parse::<std::net::Ipv6Addr>() else {
        return Err("not an address".to_string());
    };
    let target = std::net::SocketAddr::V6(std::net::SocketAddrV6::new(parsed, 58783, 0, scope));
    let stream = tokio::time::timeout(
        std::time::Duration::from_secs(4),
        tokio::net::TcpStream::connect(target),
    )
    .await
    .map_err(|_| "timed out".to_string())?
    .map_err(|e| format!("connect: {e}"))?;

    let handshake = tokio::time::timeout(
        std::time::Duration::from_secs(8),
        idevice::services::rsd::RsdHandshake::new(Box::new(stream)),
    )
    .await
    .map_err(|_| "handshake timed out".to_string())?
    .map_err(|e| format!("handshake: {e}"))?;

    let mut names: Vec<String> = handshake.services.keys().cloned().collect();
    names.sort();
    Ok(names)
}

// MARK: - Apple's own tooling, as a last way in

/// What `devicectl` knows about a phone.
///
/// On macOS 26 and later Apple's device daemon takes the phone for itself:
/// usbmuxd enumerates it and then refuses every connection, lockdown accepts
/// the socket and kills the session, and Remote Service Discovery resets the
/// stream. Measured on macOS 27 with iOS 27, all three at the same moment,
/// with a good cable and a phone that had already trusted the Mac.
///
/// What still works is the tool Apple ships with Xcode, which is talking to
/// the phone perfectly well the whole time. So when every door of our own is
/// shut, knock on that one.
#[derive(Debug, Clone)]
pub struct AppleView {
    pub name: String,
    pub ios_version: String,
    pub developer_mode: bool,
    pub paired: bool,
    /// Apple's word for whether its own tunnel to the phone is up. Without it
    /// every install fails with 4016 no matter how healthy everything else is.
    pub tunnel: String,
}

impl AppleView {
    /// Whether Apple's tool could actually act on the phone right now.
    ///
    /// Paired is not the same as reachable. A phone that was unplugged, went
    /// to sleep, or locked keeps its pairing and loses its tunnel, and that is
    /// the state an install fails in.
    pub fn ready(&self) -> bool {
        // Older tooling does not report this at all. Absence is not a fault.
        if self.tunnel.is_empty() {
            return self.paired;
        }
        self.paired && self.tunnel.eq_ignore_ascii_case("connected")
    }
}

pub fn devicectl_present() -> bool {
    std::path::Path::new("/usr/bin/xcrun").exists()
}

/// Everything Apple's tool will say about this phone, or nothing if it cannot
/// see it either.
pub fn apple_view(udid: &str) -> Option<AppleView> {
    if !devicectl_present() {
        return None;
    }
    let output = std::path::PathBuf::from(std::env::temp_dir()).join(format!("cloak-{udid}.json"));
    let status = std::process::Command::new("/usr/bin/xcrun")
        .args([
            "devicectl", "device", "info", "details",
            "--device", udid,
            "--json-output", &output.to_string_lossy(),
            "--quiet",
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .ok()?;
    if !status.success() {
        return None;
    }

    let text = std::fs::read_to_string(&output).ok()?;
    let _ = std::fs::remove_file(&output);
    let parsed: serde_json::Value = serde_json::from_str(&text).ok()?;
    let result = parsed.get("result")?;
    let properties = result.get("deviceProperties")?;
    let connection = result.get("connectionProperties");

    Some(AppleView {
        name: properties
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("iPhone")
            .to_string(),
        ios_version: properties
            .get("osVersionNumber")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        developer_mode: properties
            .get("developerModeStatus")
            .and_then(|v| v.as_str())
            .map(|value| value.eq_ignore_ascii_case("enabled"))
            .unwrap_or(false),
        paired: connection
            .and_then(|c| c.get("pairingState"))
            .and_then(|v| v.as_str())
            .map(|value| value.eq_ignore_ascii_case("paired"))
            .unwrap_or(false),
        tunnel: connection
            .and_then(|c| c.get("tunnelState"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
    })
}

/// Waits for Apple's tool to be able to act on the phone.
///
/// The install fails with CoreDeviceError 4016 and an empty
/// `CurrentlyAssertableStates` when the phone is paired but Apple's tunnel to
/// it is down, which is the ordinary state for a second or two after the cable
/// goes in, for as long as the phone is locked, and for a while after it wakes.
/// Nothing about it is permanent and nothing about the message says so, so it
/// is worth waiting through rather than reporting.
pub async fn wait_until_ready(
    udid: &str,
    mut say: impl FnMut(&str),
) -> Result<(), String> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(90);
    let mut told_to_unlock = false;
    let mut last = String::new();

    loop {
        // Listing is what makes Apple's daemon re-enumerate and bring the
        // tunnel back up, so this is a nudge and not only a question.
        let _ = tokio::process::Command::new("/usr/bin/xcrun")
            .args(["devicectl", "list", "devices", "--quiet"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await;

        let udid = udid.to_string();
        let view = tokio::task::spawn_blocking(move || apple_view(&udid))
            .await
            .ok()
            .flatten();

        match &view {
            Some(view) if view.ready() => return Ok(()),
            Some(view) => {
                last = format!("paired={}, tunnel={}", view.paired, view.tunnel);
                if !told_to_unlock {
                    told_to_unlock = true;
                    say("Unlock the iPhone and leave it on the Home Screen");
                }
            }
            None => {
                last = "Apple's tool cannot see the phone".to_string();
                if !told_to_unlock {
                    told_to_unlock = true;
                    say("Waiting for the iPhone. Unlock it and leave it plugged in");
                }
            }
        }

        if std::time::Instant::now() >= deadline {
            return Err(format!(
                "The iPhone is connected but not ready to be installed to.\n\nApple's own \
                 device connection to it is down, which is what the install refuses on. It \
                 is not the Apple ID, the signing, or the app.\n\nUnlock the phone and \
                 leave it on the Home Screen, then unplug the cable and plug it back in. If \
                 it still will not come up, restart the phone.\n\nDetail: {last}"
            ));
        }

        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}

/// Installs a signed .app through Apple's own tool.
pub async fn install_with_apple_tooling(
    udid: &str,
    app: &std::path::Path,
    mut say: impl FnMut(&str),
) -> Result<(), String> {
    // Never straight in. The phone spends a good part of any session paired
    // but not reachable, and starting the install then wastes the whole
    // signing run on an error that reads like a refusal.
    wait_until_ready(udid, &mut say).await?;

    tracing::info!("installing {} through devicectl", app.display());

    // Twice at most. The tunnel can go down between the check and the install
    // — that is the whole nature of it — and a second go after waiting it out
    // again is free, where making somebody sign in from the start is not.
    let mut last = String::new();
    for attempt in 1..=2 {
        let output = tokio::process::Command::new("/usr/bin/xcrun")
            .args([
                "devicectl", "device", "install", "app",
                "--device", udid,
                &app.to_string_lossy(),
            ])
            .output()
            .await
            .map_err(|e| format!("Could not run Apple's device tool: {e}"))?;

        if output.status.success() {
            tracing::info!("devicectl install finished");
            return Ok(());
        }

        last = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        tracing::error!("devicectl install failed (try {attempt}): {last}");

        if attempt == 1 && not_ready_yet(&last) {
            say("The iPhone dropped off for a moment. Waiting for it");
            wait_until_ready(udid, &mut say).await?;
            continue;
        }
        break;
    }

    Err(friendly_devicectl(&last))
}

/// Whether the failure is the phone not being reachable rather than a refusal.
fn not_ready_yet(raw: &str) -> bool {
    let lower = raw.to_lowercase();
    lower.contains("4016")
        || lower.contains("usage assertion")
        || lower.contains("currentlyassertablestates")
}

fn friendly_devicectl(raw: &str) -> String {
    let lower = raw.to_lowercase();
    if lower.contains("developer mode") {
        return "The iPhone still has Developer Mode off. Turn it on in Settings, Privacy & Security, Developer Mode, then try again.".to_string();
    }
    if lower.contains("not paired") || lower.contains("pairing") {
        return "Your Mac and this iPhone are not paired. Unlock the phone, tap Trust, then try again.".to_string();
    }
    if not_ready_yet(raw) {
        return "The iPhone is not ready to be installed to.\n\nIt is plugged in and paired, \
                but Apple's own connection to it is down, and that is what the install \
                refuses on. Nothing is wrong with the Apple ID or with the app.\n\nUnlock \
                the phone, leave it on the Home Screen, then unplug the cable and plug it \
                back in. Cloak will pick it up on its own."
            .to_string();
    }
    if lower.contains("could not find") || lower.contains("no devices") {
        return "Apple's device tool cannot see the iPhone. Unplug it and plug it back in.".to_string();
    }
    format!("Apple's device tool refused the install.\n\n{}", raw.trim())
}
