use std::time::Duration;

use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::util::storage::SideloadingStorage;
use rootcause::prelude::*;

pub const KNOWN: &[&str] = &[
    "https://ani.sidestore.io",
    "https://ani.sidestore.app",
    "https://ani.sidestore.zip",
    "https://ani.846969.xyz",
    "https://ani.npeg.us",
    "https://anisette.wedotstud.io",
    "https://ani.neoarz.com",
    "https://ani.idevicehacked.com",
    "https://ani.xu30.top",
    "https://ani.owoellen.rocks",
    "https://ani.jaydenha.uk",
    "https://ani3server.fly.dev",
    "https://ani.stikstore.app",
];

const DIRECTORY: &str = "https://servers.sidestore.io/servers.json";
pub const LAST_GOOD_KEY: &str = "cloak/anisette_last_good";

pub fn ensure_crypto() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

fn client() -> Option<reqwest::Client> {
    ensure_crypto();
    reqwest::Client::builder().user_agent("Cloak").build().ok()
}

pub async fn candidates(preferred: &[String]) -> Vec<String> {
    let mut list: Vec<String> = Vec::new();
    let push = |value: &str, list: &mut Vec<String>| {
        let trimmed = value.trim().trim_end_matches('/').to_string();
        if trimmed.starts_with("https://") && !list.contains(&trimmed) {
            list.push(trimmed);
        }
    };
    for value in preferred {
        push(value, &mut list);
    }
    for value in KNOWN {
        push(value, &mut list);
    }
    if let Some(http) = client() {
        #[derive(serde::Deserialize)]
        struct Directory {
            servers: Vec<Entry>,
        }
        #[derive(serde::Deserialize)]
        struct Entry {
            address: String,
        }
        if let Ok(response) = http.get(DIRECTORY).timeout(Duration::from_secs(6)).send().await {
            if let Ok(directory) = response.json::<Directory>().await {
                for entry in directory.servers {
                    push(&entry.address, &mut list);
                }
            }
        }
    }
    list
}

/// Whether a helper answers, and when it does not, why.
///
/// The reason is carried out rather than thrown away. "None of the helpers
/// are answering" told nobody anything: a certificate that will not verify, a
/// network the phone cannot route and a server that is genuinely down all
/// looked identical, and re-signing on the phone has been failing with that
/// one sentence for days.
pub async fn probe(url: &str) -> Result<(), String> {
    let Some(http) = client() else { return Ok(()) };
    let probe = http
        .post(format!("{url}/v3/get_headers"))
        .header("Content-Type", "application/json")
        .body(r#"{"identifier":"AAAAAAAAAAAAAAAAAAAAAA=="}"#)
        .timeout(Duration::from_secs(6))
        .send()
        .await;
    let first = match probe {
        Ok(response) if response.status().is_success() => return Ok(()),
        Ok(response) => format!("answered {}", response.status().as_u16()),
        Err(error) => describe(&error),
    };
    match http.get(format!("{url}/")).timeout(Duration::from_secs(6)).send().await {
        Ok(response) if response.status().is_success() => {
            let body = response.text().await.unwrap_or_default();
            if body.contains("X-Apple-I-MD-M") {
                Ok(())
            } else {
                Err(format!("{first}, and the page it serves is not an anisette helper"))
            }
        }
        Ok(response) => Err(format!("{first}, and its home page answered {}", response.status().as_u16())),
        Err(error) => Err(format!("{first}, then {}", describe(&error))),
    }
}

/// A transport error in words a person can act on.
fn describe(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        return "timed out".to_string();
    }
    if error.is_connect() {
        let text = error.to_string().to_lowercase();
        if text.contains("certificate") || text.contains("tls") || text.contains("handshake") {
            return format!("could not verify its certificate ({error})");
        }
        return format!("could not connect ({error})");
    }
    error.to_string()
}

pub async fn healthy(url: &str) -> bool {
    probe(url).await.is_ok()
}

/// Probes every candidate at once and returns the ones that answered, in the
/// order they were offered, along with why each of the others did not.
///
/// A dead helper takes the full six-second probe timeout to fail, and there is
/// usually one or two of them in the list. Waiting for every probe to finish
/// therefore put a fixed six-second wall in front of every sign-in even when a
/// working helper had answered in a quarter of a second. So once a helper
/// answers, only a short settle window is spent gathering the rest, and the
/// stragglers are dropped rather than waited on. When nothing answers at all
/// the full set of failures is still collected, for the diagnostic message.
pub async fn live_helpers(list: &[String]) -> (Vec<String>, Vec<(String, String)>) {
    // tokio rather than a futures combinator: this crate does not depend on
    // the futures crate, and adding one for a join would be the tail wagging
    // the dog. Results arrive over a channel so the fast answers can be taken
    // without waiting on the slow ones.
    let count = list.iter().take(16).count();
    if count == 0 {
        return (Vec::new(), Vec::new());
    }
    let (tx, mut rx) = tokio::sync::mpsc::channel(count);
    for url in list.iter().take(16) {
        let url = url.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            let outcome = probe(&url).await;
            let _ = tx.send((url, outcome)).await;
        });
    }
    drop(tx);

    // Stop waiting for stragglers this long after the first helper answers, and
    // never wait past the hard cap for a first answer that never comes.
    const SETTLE: Duration = Duration::from_millis(1200);
    const HARD_CAP: Duration = Duration::from_secs(7);

    let started = tokio::time::Instant::now();
    let mut settle_deadline: Option<tokio::time::Instant> = None;
    let mut live: Vec<String> = Vec::new();
    let mut failures = Vec::new();
    let mut received = 0usize;

    while received < count {
        let now = tokio::time::Instant::now();
        let deadline = settle_deadline
            .map(|settle| settle.min(started + HARD_CAP))
            .unwrap_or(started + HARD_CAP);
        if now >= deadline {
            break;
        }
        match tokio::time::timeout(deadline - now, rx.recv()).await {
            Ok(Some((url, Ok(())))) => {
                live.push(url);
                received += 1;
                if settle_deadline.is_none() {
                    settle_deadline = Some(tokio::time::Instant::now() + SETTLE);
                }
            }
            Ok(Some((url, Err(why)))) => {
                failures.push((url, why));
                received += 1;
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }

    // The login loop tries these in order and the first one it is handed should
    // be the preferred (last good) helper, so restore the order they were
    // offered in rather than the order they happened to answer in.
    live.sort_by_key(|url| {
        list.iter().position(|candidate| candidate == url).unwrap_or(usize::MAX)
    });
    (live, failures)
}

pub fn helper_broke(text: &str, url: &str) -> bool {
    if text.contains(url) {
        return true;
    }
    let lower = text.to_lowercase();
    lower.contains("/v3/get_headers")
        || lower.contains("/v3/client_info")
        || lower.contains("provisioning timed out")
        || lower.contains("timed out")
        || lower.contains("timeout")
}

pub fn helper_rejected(text: &str) -> bool {
    let lower = text.to_lowercase();
    if lower.contains("timed out") || lower.contains("timeout") {
        return false;
    }
    let provisioning = lower.contains("-45003")
        || lower.contains("invalid trust key")
        || lower.contains("provisioning failed")
        || lower.contains("end provisioning error")
        || lower.contains("failed to provision");
    let identity = lower.contains("grandslam")
        && (lower.contains("503") || lower.contains("service temporarily unavailable"));
    provisioning || identity
}

pub fn throttled(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("429") || lower.contains("too many requests")
}

pub fn wrong_password(text: &str) -> bool {
    let lower = text.to_lowercase();
    // -20101 and -22406 are both Apple credential refusals: -20101 is the plain
    // "wrong password", -22406 is "Enter the correct password for this Apple
    // Account", raised when the SRP proof does not verify. Neither is a helper
    // fault, so both read as a rejected credential rather than a raw error code.
    lower.contains("-20101")
        || lower.contains("-22406")
        || (lower.contains("password") && lower.contains("incorrect"))
}

pub fn without_xcode(value: &str) -> String {
    let Some(start) = value.find(" (com.apple.dt.Xcode") else {
        return value.to_string();
    };
    let Some(offset) = value[start..].find(')') else {
        return value.to_string();
    };
    let mut out = String::with_capacity(value.len());
    out.push_str(&value[..start]);
    out.push_str(&value[start + offset + 1..]);
    out
}

pub struct Identified {
    inner: RemoteV3AnisetteProvider,
}

impl Identified {
    pub fn new(inner: RemoteV3AnisetteProvider) -> Self {
        Self { inner }
    }
}

#[async_trait::async_trait]
impl isideload::anisette::AnisetteProvider for Identified {
    async fn get_anisette_data(&self) -> Result<isideload::anisette::AnisetteData, Report> {
        self.inner.get_anisette_data().await
    }

    async fn get_client_info(&self) -> Result<isideload::anisette::AnisetteClientInfo, Report> {
        let mut info = self.inner.get_client_info().await?;
        info.client_info = without_xcode(&info.client_info);
        Ok(info)
    }

    async fn provision(
        &mut self,
        gs: std::sync::Arc<isideload::auth::grandslam::GrandSlam>,
    ) -> Result<(), Report> {
        self.inner.provision(gs).await
    }

    fn needs_provisioning(&self) -> Result<bool, Report> {
        self.inner.needs_provisioning()
    }
}

pub fn forget_anisette(storage: &dyn SideloadingStorage) {
    let _ = storage.store("anisette_state", "");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_xcode() {
        assert_eq!(
            without_xcode("<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"),
            "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1>"
        );
    }

    #[test]
    fn classifies() {
        assert!(helper_rejected("grandslam answered 503"));
        assert!(!helper_rejected("request timed out"));
        assert!(throttled("HTTP 429 Too Many Requests"));
        assert!(wrong_password("-20101"));
        assert!(wrong_password(
            "Auth error -22406: Enter the correct password for this Apple Account"
        ));
    }
}
