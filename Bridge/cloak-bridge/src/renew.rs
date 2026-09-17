use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_uchar, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};

use idevice::pairing_file::PairingFile;
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{developer_session::DeveloperSession, devices::DevicesApi},
    sideload::{builder::MaxCertsBehavior, install::install_app, SideloaderBuilder, TeamSelection},
    util::storage::SideloadingStorage,
};
use rootcause::prelude::*;
use tokio::sync::oneshot;

use crate::signin;

pub const RENEW_OK: c_int = 0;
pub const RENEW_ERR: c_int = 1;
pub const RENEW_ERR_BUFFER: c_int = 2;

const MACHINE_KEY: &str = "cloak/machine";
const SERIAL_KEY: &str = "cloak/anisette_serial";
const URL_KEY: &str = "cloak/anisette_url";

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

pub struct FileStorage {
    path: PathBuf,
    cache: Mutex<HashMap<String, String>>,
}

impl FileStorage {
    pub fn open(dir: &str) -> Arc<Self> {
        let path = PathBuf::from(dir).join("signing-state.json");
        let cache = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<HashMap<String, String>>(&bytes).ok())
            .unwrap_or_default();
        Arc::new(Self { path, cache: Mutex::new(cache) })
    }

    fn flush(&self, map: &HashMap<String, String>) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(bytes) = serde_json::to_vec(map) {
            let tmp = self.path.with_extension("tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, &self.path);
            }
        }
    }

    fn clear_certificates(&self) {
        let mut map = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        map.retain(|key, _| key.contains("anisette") || key.starts_with("cloak/"));
        self.flush(&map);
    }

    fn has(&self, key: &str) -> bool {
        self.cache.lock().unwrap_or_else(|e| e.into_inner()).contains_key(key)
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

pub struct Shared(pub Arc<FileStorage>);

impl SideloadingStorage for Shared {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.0.store(key, value)
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        self.0.retrieve(key)
    }
}

/// The same store, with the sign-in helper's identity kept apart from every
/// other helper's.
///
/// The anisette blob is minted inside one specific server, which keeps the
/// other half of it. Handing helper B a blob that helper A produced yields a
/// one-time code that verifies against nothing, and Apple answers with a
/// refusal that reads like a wrong password. The desktop installer had exactly
/// this bug; the bridge kept it.
///
/// Certificates and the team stay shared, because those belong to the Apple ID
/// rather than to any server. Only the anisette keys are filed per helper.
pub struct PerHelper {
    inner: Arc<FileStorage>,
    helper: String,
}

impl PerHelper {
    pub fn new(inner: Arc<FileStorage>, helper: &str) -> Self {
        Self { inner, helper: helper.trim_end_matches('/').to_string() }
    }

    fn scoped(&self, key: &str) -> String {
        if key.contains("anisette") {
            format!("{key}@{}", self.helper)
        } else {
            key.to_string()
        }
    }
}

impl SideloadingStorage for PerHelper {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.inner.store(&self.scoped(key), value)
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        self.inner.retrieve(&self.scoped(key))
    }
}

#[derive(serde::Deserialize, Default)]
struct Handoff {
    key: Option<String>,
    der: Option<String>,
    machine: Option<String>,
    anisette_state: Option<String>,
    anisette_url: Option<String>,
    anisette_serial: Option<String>,
}

fn adopt_handoff(storage: &FileStorage, json: Option<&str>) {
    let Some(text) = json else { return };
    let Ok(handoff) = serde_json::from_str::<Handoff>(text) else { return };
    if let (Some(key), Some(der)) = (handoff.key.as_deref(), handoff.der.as_deref()) {
        if !storage.has(key) {
            let _ = storage.store(key, der);
        }
    }
    if let Some(machine) = handoff.machine.as_deref() {
        if !storage.has(MACHINE_KEY) {
            let _ = storage.store(MACHINE_KEY, machine);
        }
    }
    // The Mac's identity blob belongs to the helper the Mac used, and only to
    // that one. Filing it under that helper is what lets it be reused; filing
    // it loose is what got it sent to a different server and refused.
    if let Some(state) = handoff.anisette_state.as_deref() {
        if let Some(url) = handoff.anisette_url.as_deref() {
            let key = format!("anisette_state@{}", url.trim_end_matches('/'));
            if !storage.has(&key) {
                let _ = storage.store(&key, state);
            }
        }
    }
    if let Some(url) = handoff.anisette_url.as_deref() {
        if !storage.has(URL_KEY) {
            let _ = storage.store(URL_KEY, url);
        }
    }
    if let Some(serial) = handoff.anisette_serial.as_deref() {
        if !storage.has(SERIAL_KEY) {
            let _ = storage.store(SERIAL_KEY, serial);
        }
    }
}

struct Job {
    apple_id: String,
    password: String,
    app: PathBuf,
    state_dir: String,
    pairing: Option<PairingFile>,
    address: std::net::IpAddr,
    device_name: String,
    device_udid: String,
    handoff: Option<String>,
}

async fn run(session: Arc<RenewSession>, job: Job) {
    let outcome = renew(&session, &job).await;
    match outcome {
        Ok(expires) => set_state(&session, serde_json::json!({ "state": "done", "expires": expires })),
        Err(reason) => set_state(&session, serde_json::json!({ "state": "failed", "reason": reason })),
    }
    *session.running.lock().unwrap_or_else(|e| e.into_inner()) = false;
}

pub fn profile_expiry(app: &Path) -> Option<f64> {
    let data = std::fs::read(app.join("embedded.mobileprovision")).ok()?;
    let open = find(&data, b"<plist")?;
    let close = find(&data[open..], b"</plist>")? + open + b"</plist>".len();
    let value: plist::Value = plist::from_bytes(&data[open..close]).ok()?;
    let date = value.as_dictionary()?.get("ExpirationDate")?.as_date()?;
    let system: std::time::SystemTime = date.into();
    Some(system.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64())
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

async fn sign_in(
    session: &Arc<RenewSession>,
    job: &Job,
    storage: &Arc<FileStorage>,
) -> Result<AppleAccount, String> {
    working(session, "Finding a working sign-in helper", 0.05);

    let mut preferred = Vec::new();
    if let Ok(Some(url)) = storage.retrieve(signin::LAST_GOOD_KEY) {
        preferred.push(url);
    }
    if let Ok(Some(url)) = storage.retrieve(URL_KEY) {
        preferred.push(url);
    }
    let list = signin::candidates(&preferred).await;
    let serial = storage
        .retrieve(SERIAL_KEY)
        .ok()
        .flatten()
        .unwrap_or_else(|| "0".to_string());

    let mut apple_attempts = 0;
    let mut tried = 0;
    let mut last = String::new();

    // Probe every helper at once and keep the ones that answer, in the order
    // they were preferred. One at a time meant up to thirteen probes of six
    // seconds each before giving up, which on a phone reads as the whole
    // thing hanging and then refusing.
    let (live, probe_errors) = signin::live_helpers(&list).await;
    if live.is_empty() {
        let detail = probe_errors
            .iter()
            .take(3)
            .map(|(url, why)| format!("{url}: {why}"))
            .collect::<Vec<_>>()
            .join("; ");
        return Err(if detail.is_empty() {
            "No Apple sign-in helper answered. Check this phone's connection and try again.".to_string()
        } else {
            format!("No Apple sign-in helper answered. {detail}")
        });
    }

    for helper in live {
        if apple_attempts >= 3 || tried >= 8 {
            break;
        }
        tried += 1;
        working(session, "Signing in with your Apple ID", 0.08);

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

        let provider = RemoteV3AnisetteProvider::default()
            .map_err(|e| format!("Could not start the Apple sign-in helper: {e}"))?
            .set_url(&helper)
            .set_storage(Box::new(PerHelper::new(storage.clone(), &helper)))
            .set_serial_number(serial.clone());

        match AppleAccount::builder(&job.apple_id)
            .anisette_provider(signin::Identified::new(provider))
            .login(&job.password, two_factor)
            .await
        {
            Ok(account) => {
                let _ = storage.store(signin::LAST_GOOD_KEY, &helper);
                return Ok(account);
            }
            Err(error) => {
                let text = error.to_string();
                last = text.clone();
                if signin::helper_broke(&text, &helper) {
                    signin::forget_anisette(storage.as_ref());
                    continue;
                }
                if signin::throttled(&text) {
                    return Err("Apple wants a slower pace. Leave it alone for ten minutes and Cloak will try again on its own.".to_string());
                }
                if signin::helper_rejected(&text) {
                    apple_attempts += 1;
                    signin::forget_anisette(storage.as_ref());
                    continue;
                }
                return Err(friendly(&text));
            }
        }
    }

    if last.is_empty() {
        Err("No Apple sign-in helper answered. Check this phone's connection and try again.".to_string())
    } else {
        Err(format!("Apple would not accept any sign-in helper. Last answer: {}", friendly(&last)))
    }
}

async fn renew(session: &Arc<RenewSession>, job: &Job) -> Result<Option<f64>, String> {
    if !job.app.exists() {
        return Err("The working copy of Cloak to re-sign is missing.".to_string());
    }
    signin::ensure_crypto();

    // The Apple-facing half of a re-sign cannot be timed from a development
    // machine without signing in as the user, so the phone times itself. The
    // file lands in Documents, which file sharing makes visible in the Files
    // app, and carries phase names and durations only.
    let log_path = Path::new(&job.state_dir)
        .parent()
        .unwrap_or(Path::new(&job.state_dir))
        .join("cloak-signing-timings.log");
    isideload::util::timing::start(&log_path);
    // Declared first so it is dropped last and the total lands at the end of
    // the run, whichever way the run ends.
    let _whole = isideload::util::timing::Phase::start("TOTAL");

    let storage = FileStorage::open(&job.state_dir);
    adopt_handoff(&storage, job.handoff.as_deref());

    let mut account = {
        let _phase = isideload::util::timing::Phase::start("Apple sign-in");
        sign_in(session, job, &storage).await?
    };

    let machine = storage
        .retrieve(MACHINE_KEY)
        .ok()
        .flatten()
        .unwrap_or_else(|| format!("Cloak ({})", job.device_name));

    let mut attempt = 0u8;
    let signed = loop {
        attempt += 1;
        working(session, "Opening your developer account", 0.18);

        let developer = {
            let _phase = isideload::util::timing::Phase::start("Open developer session");
            tokio::time::timeout(
                std::time::Duration::from_secs(90),
                DeveloperSession::from_account(&mut account),
            )
            .await
            .map_err(|_| {
                "Apple stopped answering. Check the connection and try again.".to_string()
            })?
            .map_err(|e| format!("Apple would not open a developer session: {e}"))?
        };

        let mut sideloader = SideloaderBuilder::new(developer, job.apple_id.clone())
            .team_selection(TeamSelection::First)
            .max_certs_behavior(MaxCertsBehavior::Revoke)
            .storage(Box::new(Shared(storage.clone())))
            .machine_name(machine.clone())
            .build();

        working(session, "Checking your developer team", 0.24);
        let team = {
            let _phase = isideload::util::timing::Phase::start("Developer team");
            sideloader
                .get_team()
                .await
                .map_err(|e| format!("Apple would not say which developer team you are on: {e}"))?
        };

        {
            let _phase = isideload::util::timing::Phase::start("Register this device");
            sideloader
                .get_dev_session()
                .ensure_device_registered(&team, &job.device_name, &job.device_udid, None)
                .await
                .map_err(|e| friendly(&e.to_string()))?;
        }

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

        let _phase = isideload::util::timing::Phase::start("Sign the app");
        match sideloader
            .sign_app(job.app.clone(), Some(team.clone()), false, Some(progress))
            .await
        {
            Ok((path, _)) => break path,
            Err(error) => {
                let text = error.to_string();
                if attempt == 1 && looks_stale(&text) {
                    working(session, "Replacing an out of date certificate", 0.30);
                    storage.clear_certificates();
                    continue;
                }
                return Err(friendly(&text));
            }
        }
    };

    let expires = profile_expiry(&signed);
    set_state(
        session,
        serde_json::json!({ "state": "working", "phase": "Installing", "progress": 0.74, "installing": true, "expires": expires }),
    );

    let _install = isideload::util::timing::Phase::start("Install");
    match crate::rp::install_over_tunnel(signed.clone()).await {
        Ok(()) => return Ok(expires),
        Err(error) => {
            if job.pairing.is_none() {
                return Err(friendly(&error));
            }
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
            set_state(
                &session,
                serde_json::json!({ "state": "working", "phase": "Installing", "progress": 0.74 + fraction * 0.25, "installing": true, "expires": expires }),
            );
        }
    };
    install_app(&provider, &signed, install_progress)
        .await
        .map_err(|e| friendly(&e.to_string()))?;
    Ok(expires)
}

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

fn friendly(raw: &str) -> String {
    let lower = raw.to_lowercase();
    if signin::wrong_password(raw) {
        return "That Apple ID or password was not accepted. Enter your password again to retry."
            .to_string();
    }
    if lower.contains("maximum number of apps") || lower.contains("3 app ids") {
        return "This Apple ID has registered as many app IDs as Apple allows. They clear on their own after a week.".to_string();
    }
    if looks_stale(&lower) {
        return "Apple would not issue a signing certificate. Open developer.apple.com, delete the development certificates listed there, and try again.".to_string();
    }
    if lower.contains("tunnel") || lower.contains("afc") || lower.contains("installation") || lower.contains("lockdown") {
        return format!("Cloak signed itself but could not install the new copy. Turn LocalDevVPN on, open Cloak so it links, and try again. ({raw})");
    }
    raw.to_string()
}

fn text(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(pointer) }.to_str().ok().map(str::to_owned)
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
    handoff_json: *const c_char,
) -> c_int {
    let (Some(apple_id), Some(password), Some(app), Some(state_dir), Some(address), Some(name), Some(udid)) = (
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
        PairingFile::from_bytes(raw).ok()
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
        app: PathBuf::from(app),
        state_dir,
        pairing: pairing_file,
        address: addr,
        device_name: name,
        device_udid: udid,
        handoff: text(handoff_json),
    };

    let cloned = session.clone();
    session.runtime.spawn(async move {
        run(cloned, job).await;
    });

    RENEW_OK
}

#[no_mangle]
pub extern "C" fn cloak_renew_state(out: *mut c_char, capacity: usize) -> c_int {
    if out.is_null() {
        return RENEW_ERR;
    }
    let value = match SESSION.get() {
        Some(session) => session.state.lock().unwrap_or_else(|e| e.into_inner()).clone(),
        None => "{\"state\":\"idle\"}".to_string(),
    };
    let Ok(value) = CString::new(value) else {
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
    let sender = session.code.lock().unwrap_or_else(|e| e.into_inner()).take();
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
