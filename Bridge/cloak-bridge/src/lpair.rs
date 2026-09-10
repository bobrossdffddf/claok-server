//! Pairing this phone with itself over lockdown.
//!
//! The old route asked Bonjour where iOS had put its `_remotepairing._tcp`
//! service, because that service listens on a port that changes every boot.
//! That made pairing depend on Wi-Fi being on, on Local Network permission,
//! on multicast not being filtered, and on iOS choosing to advertise at all.
//! Any one of those missing and there was nothing to connect to.
//!
//! Lockdown has none of those problems. It is the service every computer has
//! always used to pair with an iPhone, it is always listening, and it is
//! always on port 62078. Nothing has to be discovered. The reflector already
//! makes a connection the phone opens to itself arrive looking like it came
//! from another machine, which is the only reason iOS answers at all, and
//! that works with Wi-Fi off entirely.
//!
//! So: connect to the reflector on 62078, ask to pair, and iOS puts its own
//! "Trust This Computer?" alert on screen. One tap and a passcode, and the
//! pairing record comes back. No code to read off one screen and type into
//! another, and no Bonjour anywhere.

use std::ffi::{c_char, c_int, CStr, CString};
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use idevice::services::lockdown::LockdownClient;
use idevice::Idevice;

pub const LP_OK: c_int = 0;
pub const LP_ERR: c_int = 1;
pub const LP_ERR_BUFFER: c_int = 2;

struct LpSession {
    runtime: tokio::runtime::Runtime,
    state: Mutex<String>,
    running: Mutex<bool>,
}

static SESSION: OnceLock<Arc<LpSession>> = OnceLock::new();

fn session() -> Arc<LpSession> {
    SESSION
        .get_or_init(|| {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("runtime");
            Arc::new(LpSession {
                runtime,
                state: Mutex::new("{\"state\":\"idle\"}".to_string()),
                running: Mutex::new(false),
            })
        })
        .clone()
}

fn set_state(session: &LpSession, value: serde_json::Value) {
    *session.state.lock().unwrap_or_else(|e| e.into_inner()) = value.to_string();
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(ALPHABET[(n >> 18 & 63) as usize] as char);
        out.push(ALPHABET[(n >> 12 & 63) as usize] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6 & 63) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

struct Job {
    addresses: Vec<String>,
    host_id: String,
    system_buid: String,
    host_name: String,
}

async fn run(session: Arc<LpSession>, job: Job) {
    let mut notes: Vec<String> = Vec::new();

    for address in &job.addresses {
        set_state(
            &session,
            serde_json::json!({ "state": "connecting", "detail": address }),
        );

        match pair_with(&session, address, &job).await {
            Ok(record) => {
                set_state(
                    &session,
                    serde_json::json!({ "state": "paired", "record": base64(&record) }),
                );
                *session.running.lock().unwrap_or_else(|e| e.into_inner()) = false;
                return;
            }
            Err(reason) => notes.push(format!("{address}: {reason}")),
        }
    }

    set_state(
        &session,
        serde_json::json!({ "state": "failed", "reason": notes.join("\n") }),
    );
    *session.running.lock().unwrap_or_else(|e| e.into_inner()) = false;
}

async fn pair_with(session: &Arc<LpSession>, address: &str, job: &Job) -> Result<Vec<u8>, String> {
    let target = if address.contains(':') && !address.starts_with('[') {
        format!("[{address}]:{}", LockdownClient::LOCKDOWND_PORT)
    } else {
        format!("{address}:{}", LockdownClient::LOCKDOWND_PORT)
    };

    let stream = tokio::time::timeout(
        Duration::from_secs(6),
        tokio::net::TcpStream::connect(target.as_str()),
    )
    .await
    .map_err(|_| "timed out".to_string())?
    .map_err(|error| format!("{error}"))?;
    let _ = stream.set_nodelay(true);

    let mut lockdown = LockdownClient::new(Idevice::new(Box::new(stream), "Cloak"));

    // iOS puts the trust alert up the moment this is asked, and answers every
    // poll with "still waiting" until somebody taps it. The library loops on
    // that internally, so the only thing to do here is say so on screen and
    // give the person long enough to pick the phone up.
    set_state(
        session,
        serde_json::json!({ "state": "waiting-for-trust", "detail": address }),
    );

    let record = tokio::time::timeout(
        Duration::from_secs(180),
        lockdown.pair(
            job.host_id.clone(),
            job.system_buid.clone(),
            Some(job.host_name.as_str()),
        ),
    )
    .await
    .map_err(|_| "nobody answered the Trust prompt".to_string())?
    .map_err(|error| friendly(&error.to_string()))?;

    record
        .serialize()
        .map_err(|error| format!("the pairing record could not be read back: {error}"))
}

/// idevice reports what iOS said. iOS says it for developers.
fn friendly(raw: &str) -> String {
    let lower = raw.to_lowercase();
    if lower.contains("userdenied") || lower.contains("denied") {
        return "Trust was declined on the phone. Start again and tap Trust.".to_string();
    }
    if lower.contains("passwordprotected") || lower.contains("password") {
        return "Unlock the phone first, then try again. iOS will not pair while it is locked."
            .to_string();
    }
    if lower.contains("connection refused") || lower.contains("refused") {
        return "Nothing answered on this phone. The loopback tunnel is probably not running."
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
pub extern "C" fn cloak_lockdown_pair_start(
    addresses: *const c_char,
    host_id: *const c_char,
    system_buid: *const c_char,
    host_name: *const c_char,
) -> c_int {
    let (Some(addresses), Some(host_id), Some(system_buid), Some(host_name)) = (
        text(addresses),
        text(host_id),
        text(system_buid),
        text(host_name),
    ) else {
        return LP_ERR;
    };

    let list: Vec<String> = addresses
        .split(',')
        .map(|part| part.trim().to_string())
        .filter(|part| !part.is_empty())
        .collect();
    if list.is_empty() {
        return LP_ERR;
    }

    let session = session();
    {
        let mut running = session.running.lock().unwrap_or_else(|e| e.into_inner());
        if *running {
            return LP_ERR;
        }
        *running = true;
    }
    set_state(&session, serde_json::json!({ "state": "starting" }));

    let job = Job {
        addresses: list,
        host_id,
        system_buid,
        host_name,
    };

    let cloned = session.clone();
    session.runtime.spawn(async move {
        run(cloned, job).await;
    });

    LP_OK
}

#[no_mangle]
pub extern "C" fn cloak_lockdown_pair_state(out: *mut c_char, capacity: usize) -> c_int {
    let Some(session) = SESSION.get() else {
        return LP_ERR;
    };
    if out.is_null() {
        return LP_ERR;
    }
    let text = session.state.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let Ok(value) = CString::new(text) else {
        return LP_ERR_BUFFER;
    };
    let raw = value.as_bytes_with_nul();
    if capacity < raw.len() {
        return LP_ERR_BUFFER;
    }
    unsafe { ptr::copy_nonoverlapping(raw.as_ptr() as *const c_char, out, raw.len()) };
    LP_OK
}
