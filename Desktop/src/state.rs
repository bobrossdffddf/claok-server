//! Where the installer keeps what it learns.
//!
//! Not the OS keychain. isideload stores several separate items — anisette
//! state, the signing certificate, its private key, the chosen team — and on
//! macOS every one of them is its own "allow access" prompt. Worse, an ad-hoc
//! signature changes on every build, so the keychain treats each build as a
//! different application and asks again from scratch. That is where the wall
//! of password prompts comes from.
//!
//! A file in the app's own support directory, readable only by this user,
//! prompts nobody. The Apple ID password is the one thing that still goes to
//! the keychain, because it is the one thing worth that protection, and only
//! when automatic renewal is switched on.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use isideload::util::storage::SideloadingStorage;
use rootcause::prelude::*;

pub struct FileStorage {
    path: PathBuf,
    cache: Mutex<HashMap<String, String>>,
    /// Which sign-in helper this state belongs to, if any.
    ///
    /// The identity the sign-in carries is not ours. It is minted inside one
    /// specific helper, which keeps the other half of it, and the blob saved
    /// here only means anything to that same server. Handing helper B a blob
    /// that helper A provisioned produces a one-time code Apple cannot verify,
    /// and Apple answers -22421, which reads as a broken account and is not
    /// one. So the blob is filed under the helper that made it.
    helper: Option<String>,
}

impl FileStorage {
    pub fn new() -> Self {
        let path = crate::config::Config::dir().join("signing-state.json");
        let cache = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<HashMap<String, String>>(&bytes).ok())
            .unwrap_or_default();
        Self { path, cache: Mutex::new(cache), helper: None }
    }

    /// The same store, with the sign-in helper's own state kept apart.
    ///
    /// The signing certificate and the team stay shared, because those belong
    /// to the Apple ID and not to any server. Only the anisette state is
    /// filed per helper, because only the anisette state is meaningless away
    /// from the machine that minted it.
    pub fn for_helper(url: &str) -> Self {
        let mut storage = Self::new();
        storage.helper = Some(url.trim_end_matches('/').to_string());
        storage.drop_unfiled_anisette();
        storage
    }

    /// Clears out identity blobs saved before they were filed by helper.
    ///
    /// One of those is what Apple refused with -22421. Nothing can use it now
    /// that it is not known which server minted it, so leaving it there only
    /// keeps the thing that caused the failure sitting on disk.
    fn drop_unfiled_anisette(&self) {
        let mut map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        let before = map.len();
        map.retain(|key, _| !(key.contains("anisette") && !key.contains('@')));
        if map.len() != before {
            tracing::info!("cleared anisette state that was not filed by helper");
            self.flush(&map);
        }
    }

    /// The key this store actually writes under.
    fn scoped(&self, key: &str) -> String {
        match &self.helper {
            Some(helper) if key.contains("anisette") => format!("{key}@{helper}"),
            _ => key.to_string(),
        }
    }

    /// The key the freshness stamp lives under, for whichever helper this is.
    fn stamp_key(&self) -> String {
        match &self.helper {
            Some(helper) => format!("anisette_saved_at@{helper}"),
            None => "anisette_saved_at".to_string(),
        }
    }

    fn now() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or_default()
    }

    /// Throws the helper's state away once it is old enough to have gone bad.
    ///
    /// Even the server that minted it will stop honouring one of these
    /// eventually, and when it does the sign-in fails at the password step
    /// with nothing that says so. Provisioning again costs one round trip, so
    /// it is not worth carrying an old one into a sign-in to save that.
    pub fn drop_stale_anisette(&self, max_age: std::time::Duration) {
        let stamp = self.stamp_key();
        let too_old = {
            let map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            match map.get(&stamp).and_then(|v| v.parse::<u64>().ok()) {
                Some(saved) => Self::now().saturating_sub(saved) > max_age.as_secs(),
                // Present but never stamped means it predates this, so it is
                // exactly the state worth being suspicious of.
                None => map.keys().any(|key| key == &self.scoped("anisette_state")),
            }
        };
        if too_old {
            tracing::info!("dropping stale anisette state for {:?}", self.helper);
            self.forget_anisette();
        }
    }

    fn flush(&self, map: &HashMap<String, String>) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(bytes) = serde_json::to_vec_pretty(map) {
            let _ = std::fs::write(&self.path, bytes);
        }

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&self.path, std::fs::Permissions::from_mode(0o600));
        }
    }

    /// Throws away only what the sign-in helper keeps, leaving the signing
    /// certificate alone. State Apple has rejected is worse than none, because
    /// keeping it means sending the same rejected thing again.
    pub fn forget_anisette(&self) {
        let mut map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        match &self.helper {
            // One helper's state only. Wiping every helper's on one refusal
            // would make the next helper provision from nothing as well, which
            // is a round trip spent proving something already known.
            Some(helper) => {
                let suffix = format!("@{helper}");
                map.retain(|key, _| !(key.contains("anisette") && key.ends_with(&suffix)));
            }
            None => map.retain(|key, _| !key.contains("anisette")),
        }
        self.flush(&map);
    }

    /// Throws away the signing certificate so the next run asks Apple for a
    /// fresh one. Used when a certificate has been revoked out from under us.
    pub fn clear(&self) {
        let mut map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        map.clear();
        self.flush(&map);
    }
}

impl Default for FileStorage {
    fn default() -> Self {
        Self::new()
    }
}

impl SideloadingStorage for FileStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        let scoped = self.scoped(key);
        let mut map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        if value.is_empty() {
            map.remove(&scoped);
        } else {
            map.insert(scoped, value.to_owned());
            if key.contains("anisette") {
                map.insert(self.stamp_key(), Self::now().to_string());
            }
        }
        self.flush(&map);
        Ok(())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        let scoped = self.scoped(key);
        let map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        Ok(map.get(&scoped).cloned())
    }
}
