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
}

impl FileStorage {
    pub fn new() -> Self {
        let path = crate::config::Config::dir().join("signing-state.json");
        let cache = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<HashMap<String, String>>(&bytes).ok())
            .unwrap_or_default();
        Self { path, cache: Mutex::new(cache) }
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
        let mut map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        if value.is_empty() {
            map.remove(key);
        } else {
            map.insert(key.to_owned(), value.to_owned());
        }
        self.flush(&map);
        Ok(())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        let map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        Ok(map.get(key).cloned())
    }
}
