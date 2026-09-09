use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Everything the installer needs to remember between runs.
///
/// The Apple ID password is deliberately not in here — it lives in the
/// operating system's own keychain, and only if the user asks for the app to
/// be kept alive automatically.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Config {
    pub apple_id: Option<String>,
    pub team_id: Option<String>,
    pub device_udid: Option<String>,
    pub device_name: Option<String>,
    /// When the signature this phone is running was last renewed.
    pub last_refresh: Option<chrono::DateTime<chrono::Utc>>,
    /// Whether the user asked for automatic renewal.
    pub auto_refresh: bool,
}

impl Config {
    pub fn dir() -> PathBuf {
        directories::ProjectDirs::from("app", "Cloak", "CloakInstaller")
            .map(|d| d.config_dir().to_path_buf())
            .unwrap_or_else(|| PathBuf::from("."))
    }

    pub fn path() -> PathBuf {
        Self::dir().join("config.json")
    }

    pub fn load() -> Self {
        std::fs::read(Self::path())
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let _ = std::fs::create_dir_all(Self::dir());
        if let Ok(bytes) = serde_json::to_vec_pretty(self) {
            let _ = std::fs::write(Self::path(), bytes);
        }
    }

    /// A free signature is good for seven days. Renewing on day five leaves
    /// room for a laptop that spends a weekend shut.
    pub fn days_until_expiry(&self) -> Option<i64> {
        let last = self.last_refresh?;
        let age = chrono::Utc::now().signed_duration_since(last).num_days();
        Some(7 - age)
    }

    pub fn needs_refresh(&self) -> bool {
        match self.days_until_expiry() {
            Some(days) => days <= 2,
            None => false,
        }
    }
}

/// The Apple ID password, kept in the operating system's keychain rather than
/// anywhere Cloak controls.
pub struct StoredPassword;

impl StoredPassword {
    const SERVICE: &'static str = "Cloak Installer";

    pub fn save(apple_id: &str, password: &str) -> Result<(), String> {
        keyring::Entry::new(Self::SERVICE, apple_id)
            .and_then(|entry| entry.set_password(password))
            .map_err(|e| e.to_string())
    }

    pub fn load(apple_id: &str) -> Option<String> {
        keyring::Entry::new(Self::SERVICE, apple_id)
            .ok()
            .and_then(|entry| entry.get_password().ok())
    }

    pub fn forget(apple_id: &str) {
        if let Ok(entry) = keyring::Entry::new(Self::SERVICE, apple_id) {
            let _ = entry.delete_credential();
        }
    }
}
