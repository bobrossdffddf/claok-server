//! Talking to the iPhone over USB.

use idevice::{
    amfi::AmfiClient,
    lockdown::LockdownClient,
    provider::IdeviceProvider,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
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
pub async fn usbmuxd_available() -> bool {
    UsbmuxdConnection::default().await.is_ok()
}

pub async fn list_phones() -> Result<Vec<Phone>, String> {
    let mut usbmuxd = UsbmuxdConnection::default()
        .await
        .map_err(|e| format!("Could not reach the iPhone driver: {e}"))?;

    let devices = usbmuxd
        .get_devices()
        .await
        .map_err(|e| format!("Could not list iPhones: {e}"))?;

    let addr = UsbmuxdAddr::from_env_var().unwrap_or_default();

    let mut phones = Vec::new();
    for device in devices {
        let provider = device.to_provider(addr.clone(), LABEL);
        let phone = describe(&provider, &device.udid)
            .await
            .unwrap_or_else(|_| untrusted(&device.udid));
        tracing::info!(
            "found phone: name={:?} ios={:?} developer_mode={:?} trusted={}",
            phone.name,
            phone.ios_version,
            phone.developer_mode,
            phone.trusted,
        );
        phones.push(phone);
    }
    Ok(phones)
}

/// A connection handle for one phone, made fresh each time because usbmuxd
/// connections are cheap and long-lived ones go stale across a reboot.
pub async fn provider_for(udid: &str) -> Result<impl IdeviceProvider, String> {
    let mut usbmuxd = UsbmuxdConnection::default()
        .await
        .map_err(|e| format!("Could not reach the iPhone driver: {e}"))?;
    let devices = usbmuxd
        .get_devices()
        .await
        .map_err(|e| format!("Could not list iPhones: {e}"))?;
    let device = devices
        .into_iter()
        .find(|d| d.udid == udid)
        .ok_or_else(|| "That iPhone is not plugged in.".to_string())?;
    let addr = UsbmuxdAddr::from_env_var().unwrap_or_default();
    Ok(device.to_provider(addr, LABEL))
}

fn untrusted(udid: &str) -> Phone {
    Phone {
        udid: udid.to_string(),
        name: "iPhone".into(),
        ios_version: String::new(),
        developer_mode: DeveloperMode::Unknown,
        trusted: false,
    }
}

async fn describe(provider: &dyn IdeviceProvider, udid: &str) -> Result<Phone, String> {
    let mut lockdown = match LockdownClient::connect(provider).await {
        Ok(client) => client,
        Err(error) => {
            tracing::warn!("lockdown refused: {error}");
            return Ok(untrusted(udid));
        }
    };

    let pairing = match provider.get_pairing_file().await {
        Ok(pairing) => pairing,
        Err(error) => {
            tracing::info!("no pairing record yet, phone has not trusted us: {error}");
            return Ok(untrusted(udid));
        }
    };
    if let Err(error) = lockdown.start_session(&pairing).await {
        tracing::info!("lockdown session refused, phone has not trusted us: {error}");
        return Ok(untrusted(udid));
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
