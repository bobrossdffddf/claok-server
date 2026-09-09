//! Checking a token that came back to us.
//!
//! The phone verifies tokens offline so it can work without a signal. When it
//! asks for something that actually matters, the server checks the same token
//! again itself, and this time it can also see whether the licence has been
//! withdrawn since.

use base64::prelude::*;
use ed25519_dalek::{Signature, Verifier};
use serde::Deserialize;

use crate::store::{now, Store};
use crate::Keys;

#[derive(Debug, Deserialize)]
pub struct Claims {
    pub lic: String,
    pub dev: String,
    #[serde(default)]
    pub plan: String,
    pub exp: i64,
}

pub enum Refusal {
    Malformed,
    Expired,
    Withdrawn,
    WrongDevice,
}

impl Refusal {
    pub fn message(&self) -> &'static str {
        match self {
            Refusal::Malformed => "That is not a licence this server issued.",
            Refusal::Expired => "That licence check has run out. Open Cloak while online.",
            Refusal::Withdrawn => "That licence has been withdrawn.",
            Refusal::WrongDevice => "That licence belongs to a different device.",
        }
    }
}

/// Verifies a bearer token and confirms the licence behind it is still good.
pub fn check(keys: &Keys, store: &Store, token: &str) -> Result<Claims, Refusal> {
    let (payload_part, signature_part) = token.split_once('.').ok_or(Refusal::Malformed)?;

    let payload = BASE64_URL_SAFE_NO_PAD
        .decode(payload_part)
        .map_err(|_| Refusal::Malformed)?;
    let signature_bytes = BASE64_URL_SAFE_NO_PAD
        .decode(signature_part)
        .map_err(|_| Refusal::Malformed)?;
    let signature = Signature::from_slice(&signature_bytes).map_err(|_| Refusal::Malformed)?;

    keys.verifying()
        .verify(&payload, &signature)
        .map_err(|_| Refusal::Malformed)?;

    let claims: Claims = serde_json::from_slice(&payload).map_err(|_| Refusal::Malformed)?;

    if claims.exp < now() {
        return Err(Refusal::Expired);
    }

    // The signature only proves we issued it. Whether it still counts is a
    // question for the database, which is the whole reason to check again
    // here rather than trusting what the phone already decided.
    let license = store
        .license(&claims.lic)
        .map_err(|_| Refusal::Malformed)?
        .ok_or(Refusal::Withdrawn)?;

    if license.revoked {
        return Err(Refusal::Withdrawn);
    }
    if let Some(expiry) = license.expires_at {
        if expiry < now() {
            return Err(Refusal::Withdrawn);
        }
    }

    match store.activation(&claims.lic).map_err(|_| Refusal::Malformed)? {
        Some(active) if active.device_id == claims.dev => {
            let _ = store.touch(&claims.lic);
            Ok(claims)
        }
        Some(_) => Err(Refusal::WrongDevice),
        None => Err(Refusal::Withdrawn),
    }
}
