//! Renewing Cloak's signature from the phone itself.
//!
//! A free Apple ID signs an app for seven days. Until now the only cure was
//! plugging the phone into the computer that installed it, which is the one
//! thing this whole project exists to avoid. Everything needed to do it on the
//! phone is already here: the same signing library the desktop installer uses
//! builds for iOS, and the loopback reflector already lets the phone reach its
//! own lockdown service, which is where AFC and the installation proxy live.
//!
//! So the phone asks Apple for a certificate as itself, re-signs a fresh copy
//! of Cloak, and installs it over the reflector. No cable, no computer.
//!
//! Two-factor is the one part a person has to be present for, and only the
//! first time. The signing library stores the session it gets back, so later
//! renewals reuse it and run silently.

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_uchar, CStr, CString};
use std::path::PathBuf;
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};

use idevice::pairing_file::PairingFile;
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{developer_session::DeveloperSession, devices::DevicesApi},
    sideload::{
        builder::MaxCertsBehavior, install::install_app, SideloaderBuilder, TeamSelection,
    },
    util::storage::SideloadingStorage,
};
use rootcause::prelude::*;
use tokio::sync::oneshot;

pub const RENEW_OK: c_int = 0;
pub const RENEW_ERR: c_int = 1;
pub const RENEW_ERR_BUFFER: c_int = 2;

struct RenewSession {
    runtime: tokio::runtime::Runtime,
    state: Mutex<String>,
    code: Mutex<Option<oneshot::Sender<TwoFactorCallbackResponse>>>,
    running: Mutex<bool>,
}

static SESSION: OnceLock<Arc<RenewSession>> = OnceLock::new();

fn session() -> Arc<RenewSession> {
    SESSION
        .get_or_init(|| {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("runtime");
            Arc::new(RenewSession {
                runtime,
                state: Mutex::new("{\"state\":\"idle\"}".to_string()),
                code: Mutex::new(None),
                running: Mutex::new(false),
            })
        })
        .clone()
}

fn set_state(session: &RenewSession, value: serde_json::Value) {
    *session.state.lock().unwrap_or_else(|e| e.into_inner()) = value.to_string();
}

fn working(session: &RenewSession, phase: &str, progress: f64) {
    set_state(
        session,
        serde_json::json!({ "state": "working", "phase": phase, "progress": progress }),
    );
}

// MARK: - Storage

/// Where the signing library keeps the Apple session and the certificate.
///
/// Deliberately a plain file in the app's own container rather than the
/// keychain. The container is already private to this app, and the keychain
/// buys nothing here while costing an entitlement a free signature cannot
/// carry. The Apple ID password is not kept here; that is the app's business
/// and it goes in the keychain proper.
struct FileStorage {
    path: PathBuf,
    cache: Mutex<HashMap<String, String>>,
}

impl FileStorage {
    fn new(dir: &str) -> Self {
        let path = PathBuf::from(dir).join("signing-state.json");
        let cache = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<HashMap<String, String>>(&bytes).ok())
            .unwrap_or_default();
        Self {
            path,
            cache: Mutex::new(cache),
        }
    }

    fn flush(&self, map: &HashMap<String, String>) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(bytes) = serde_json::to_vec(map) {
            let _ = std::fs::write(&self.path, bytes);
        }
    }

    fn clear(&self) {
        let mut map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        map.clear();
        self.flush(&map);
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

// MARK: - The job

struct Job {
    apple_id: String,
    password: String,
    ipa: PathBuf,
    state_dir: String,
    pairing: Option<PairingFile>,
    address: std::net::IpAddr,
    device_name: String,
    device_udid: String,
}

async fn run(session: Arc<RenewSession>, job: Job) {
    let outcome = renew(&session, &job).await;
    match outcome {
        Ok(()) => set_state(&session, serde_json::json!({ "state": "done" })),
        Err(reason) => {
            set_state(&session, serde_json::json!({ "state": "failed", "reason": reason }))
        }
    }
    *session.running.lock().unwrap_or_else(|e| e.into_inner()) = false;
}

async fn renew(session: &Arc<RenewSession>, job: &Job) -> Result<(), String> {
    if !job.ipa.exists() {
        return Err("The working copy of Cloak to re-sign is missing.".to_string());
    }

    working(session, "Reaching Apple", 0.04);

    let anisette = RemoteV3AnisetteProvider::default()
        .map_err(|e| format!("Could not start the Apple sign-in helper: {e}"))?
        .set_serial_number("2".to_string());

    working(session, "Signing in with your Apple ID", 0.08);

    // Asked for only when Apple asks. After the first success the signing
    // library has a session it can reuse, so this never fires again until
    // Apple decides otherwise.
    let two_factor = {
        let session = session.clone();
        move |params: TwoFactorCallbackParams| {
            let session = session.clone();
            async move {
                let (tx, rx) = oneshot::channel();
                *session.code.lock().unwrap_or_else(|e| e.into_inner()) = Some(tx);
                set_state(
                    &session,
                    serde_json::json!({
                        "state": "needs-code",
                        "sms": params.sms,
                        "unknown": params.unknown,
                        "hint": params.last_error,
                    }),
                );
                match rx.await {
                    Ok(response) => Ok(response),
                    Err(_) => Ok(TwoFactorCallbackResponse::Abort),
                }
            }
        }
    };

    let mut account = AppleAccount::builder(&job.apple_id)
        .anisette_provider(anisette)
        .login(&job.password, two_factor)
        .await
        .map_err(|e| friendly(&e.to_string()))?;

    // Signing is attempted twice. A stale certificate, one this phone thinks
    // it owns and Apple has never heard of, is the common first failure and
    // there is nothing to tell the user about it: throw it away and ask again.
    let mut attempt = 0u8;
    let signed = loop {
        attempt += 1;

        working(session, "Opening your developer account", 0.18);

        let developer = tokio::time::timeout(
            std::time::Duration::from_secs(90),
            DeveloperSession::from_account(&mut account),
        )
        .await
        .map_err(|_| "Apple stopped answering. Check the connection and try again.".to_string())?
        .map_err(|e| format!("Apple would not open a developer session: {e}"))?;

        let mut sideloader = SideloaderBuilder::new(developer, job.apple_id.clone())
            .team_selection(TeamSelection::First)
            .max_certs_behavior(MaxCertsBehavior::Revoke)
            .storage(Box::new(FileStorage::new(&job.state_dir)))
            .machine_name(format!("Cloak on {}", job.device_name))
            .build();

        working(session, "Checking your developer team", 0.24);

        let team = sideloader
            .get_team()
            .await
            .map_err(|e| format!("Apple would not say which developer team you are on: {e}"))?;

        sideloader
            .get_dev_session()
            .ensure_device_registered(&team, &job.device_name, &job.device_udid, None)
            .await
            .map_err(|e| friendly(&e.to_string()))?;

        working(session, "Getting a signing certificate", 0.32);

        let progress = {
            let session = session.clone();
            move |fraction: f32| {
                let session = session.clone();
                async move {
                    working(&session, "Signing Cloak", 0.32 + (fraction as f64) * 0.4);
                }
            }
        };

        match sideloader
            .sign_app(job.ipa.clone(), Some(team.clone()), false, Some(progress))
            .await
        {
            Ok((path, _special)) => break path,
            Err(error) => {
                let text = error.to_string();
                if attempt == 1 && looks_stale(&text) {
                    working(session, "Replacing an out of date certificate", 0.30);
                    FileStorage::new(&job.state_dir).clear();
                    continue;
                }
                return Err(friendly(&text));
            }
        }
    };

    working(session, "Installing", 0.74);

    // iOS 27 refuses the phone's own lockdown port even through the reflector,
    // but it will install over the tunnel the phone opened to itself when it
    // paired without a computer. That tunnel is preferred when it is up; the
    // lockdown route below is what earlier versions use.
    match crate::rp::install_over_tunnel(signed.clone()).await {
        Ok(()) => return Ok(()),
        Err(error) => {
            if job.pairing.is_none() {
                return Err(friendly(&error));
            }
            working(session, "Trying the pairing record route", 0.75);
        }
    }

    let Some(pairing) = job.pairing.clone() else {
        return Err("No pairing available to install with.".to_string());
    };
    let provider = idevice::provider::TcpProvider {
        addr: job.address,
        scope_id: None,
        pairing_file: pairing,
        label: "Cloak".to_string(),
    };

    let install_progress = {
        let session = session.clone();
        move |percent: u64| {
            let fraction = (percent as f64 / 100.0).clamp(0.0, 1.0);
            working(&session, "Installing", 0.74 + fraction * 0.25);
        }
    };

    install_app(&provider, &signed, install_progress)
        .await
        .map_err(|e| friendly(&e.to_string()))?;

    Ok(())
}

/// Whether a signing failure is the kind a clean slate fixes.
fn looks_stale(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("7252")
        || lower.contains("7460")
        || lower.contains("no 'ios' certificate with serial number")
        || lower.contains("failed to retrieve certificate identity")
        || lower.contains("failed to revoke development certificate")
        || lower.contains("maximum number of certificates")
}

/// Apple's wording is for developers. This is not.
fn friendly(raw: &str) -> String {
    let lower = raw.to_lowercase();
    if lower.contains("-20101") || lower.contains("password") && lower.contains("incorrect") {
        return "That Apple ID or password was not accepted.".to_string();
    }
    if lower.contains("maximum number of apps") || lower.contains("3 app ids") {
        return "This Apple ID has registered as many app IDs as Apple allows. They clear on their own after a week."
            .to_string();
    }
    if looks_stale(&lower) {
        return "Apple would not issue a signing certificate. Open developer.apple.com, delete the development certificates listed there, and try again."
            .to_string();
    }
    if lower.contains("afc") || lower.contains("installation") || lower.contains("lockdown") {
        return "Cloak signed itself but could not install the new copy. Check the tunnel is running and try again."
            .to_string();
    }
    raw.to_string()
}

// MARK: - C interface

fn text(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

#[no_mangle]
pub extern "C" fn cloak_renew_start(
    apple_id: *const c_char,
    password: *const c_char,
    ipa_path: *const c_char,
    state_dir: *const c_char,
    pairing: *const c_uchar,
    pairing_len: usize,
    address: *const c_char,
    device_name: *const c_char,
    device_udid: *const c_char,
) -> c_int {
    let (Some(apple_id), Some(password), Some(ipa), Some(state_dir), Some(address), Some(name), Some(udid)) = (
        text(apple_id),
        text(password),
        text(ipa_path),
        text(state_dir),
        text(address),
        text(device_name),
        text(device_udid),
    ) else {
        return RENEW_ERR;
    };

    let pairing_file = if pairing.is_null() || pairing_len == 0 {
        None
    } else {
        let raw = unsafe { std::slice::from_raw_parts(pairing, pairing_len) };
        match PairingFile::from_bytes(raw) {
            Ok(file) => Some(file),
            Err(_) => return RENEW_ERR,
        }
    };

    let Ok(addr) = address.trim().parse::<std::net::IpAddr>() else {
        return RENEW_ERR;
    };

    let session = session();
    {
        let mut running = session.running.lock().unwrap_or_else(|e| e.into_inner());
        if *running {
            return RENEW_ERR;
        }
        *running = true;
    }
    working(&session, "Starting", 0.0);

    let job = Job {
        apple_id,
        password,
        ipa: PathBuf::from(ipa),
        state_dir,
        pairing: pairing_file,
        address: addr,
        device_name: name,
        device_udid: udid,
    };

    let cloned = session.clone();
    session.runtime.spawn(async move {
        run(cloned, job).await;
    });

    RENEW_OK
}

#[no_mangle]
pub extern "C" fn cloak_renew_state(out: *mut c_char, capacity: usize) -> c_int {
    let Some(session) = SESSION.get() else {
        return RENEW_ERR;
    };
    if out.is_null() {
        return RENEW_ERR;
    }
    let text = session.state.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let Ok(value) = CString::new(text) else {
        return RENEW_ERR_BUFFER;
    };
    let raw = value.as_bytes_with_nul();
    if capacity < raw.len() {
        return RENEW_ERR_BUFFER;
    }
    unsafe { ptr::copy_nonoverlapping(raw.as_ptr() as *const c_char, out, raw.len()) };
    RENEW_OK
}

#[no_mangle]
pub extern "C" fn cloak_renew_submit_code(code: *const c_char) -> c_int {
    let Some(session) = SESSION.get() else {
        return RENEW_ERR;
    };
    let Some(value) = text(code) else {
        return RENEW_ERR;
    };
    let sender = session
        .code
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take();
    match sender {
        Some(sender) => {
            let _ = sender.send(TwoFactorCallbackResponse::SubmitCode(value));
            working(session, "Checking the code", 0.12);
            RENEW_OK
        }
        None => RENEW_ERR,
    }
}

#[no_mangle]
pub extern "C" fn cloak_renew_cancel() -> c_int {
    let Some(session) = SESSION.get() else {
        return RENEW_ERR;
    };
    if let Some(sender) = session.code.lock().unwrap_or_else(|e| e.into_inner()).take() {
        let _ = sender.send(TwoFactorCallbackResponse::Abort);
    }
    RENEW_OK
}
