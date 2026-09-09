//! The signing key.
//!
//! Activation hands the phone a small signed statement rather than a yes or a
//! no, so the app can keep working while the server is unreachable without
//! that being the same thing as having no licence at all. The phone holds only
//! the public half and cannot mint one for itself.

use std::path::Path;

use base64::prelude::*;
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};

pub struct Keys {
    signing: SigningKey,
}

impl Keys {
    /// Loads the key, creating one the first time.
    pub fn load_or_create(path: &Path) -> std::io::Result<Self> {
        if let Ok(bytes) = std::fs::read(path) {
            if bytes.len() == 32 {
                let mut seed = [0u8; 32];
                seed.copy_from_slice(&bytes);
                return Ok(Self { signing: SigningKey::from_bytes(&seed) });
            }
        }

        let signing = SigningKey::generate(&mut rand::rngs::OsRng);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, signing.to_bytes())?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
        }

        Ok(Self { signing })
    }

    pub fn verifying(&self) -> VerifyingKey {
        self.signing.verifying_key()
    }

    /// The line to paste into the app so it can check tokens offline.
    pub fn public_base64(&self) -> String {
        BASE64_STANDARD.encode(self.verifying().to_bytes())
    }

    /// `<payload>.<signature>`, both base64url without padding.
    pub fn sign(&self, payload: &[u8]) -> String {
        let signature = self.signing.sign(payload);
        format!(
            "{}.{}",
            BASE64_URL_SAFE_NO_PAD.encode(payload),
            BASE64_URL_SAFE_NO_PAD.encode(signature.to_bytes())
        )
    }
}
