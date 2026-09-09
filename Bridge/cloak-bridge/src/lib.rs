use std::ffi::{c_char, c_double, c_int, c_uchar, CStr, CString};
use std::net::IpAddr;
use std::ptr;
use std::sync::Mutex;
use std::time::Duration;

use idevice::pairing_file::PairingFile;
use idevice::provider::{RsdProvider, TcpProvider};
use idevice::services::core_device_proxy::CoreDeviceProxy;
use idevice::services::dvt::location_simulation::LocationSimulationClient;
use idevice::services::dvt::remote_server::RemoteServerClient;
use idevice::services::lockdown::LockdownClient;
use idevice::services::mobile_image_mounter::ImageMounter;
use idevice::services::rsd::RsdHandshake;
use idevice::RemoteXpcClient;
use idevice::IdeviceService;

pub mod rp;

const DVT_SERVICE: &str = "com.apple.instruments.dtservicehub";

use tokio::sync::{mpsc, oneshot};

pub const CLOAK_OK: c_int = 0;
pub const CLOAK_ERR_PAIRING: c_int = 1;
pub const CLOAK_ERR_CONNECT: c_int = 2;
pub const CLOAK_ERR_MOUNT: c_int = 3;
pub const CLOAK_ERR_SERVICE: c_int = 4;
pub const CLOAK_ERR_STATE: c_int = 5;
pub const CLOAK_ERR_BUFFER: c_int = 6;

type Reply = oneshot::Sender<Result<String, String>>;

enum Command {
    Probe(Reply),
    DeviceInfo(Reply),
    Mount {
        image: Vec<u8>,
        trust_cache: Vec<u8>,
        manifest: Vec<u8>,
        reply: Reply,
    },
    Open(Reply),
    Set(f64, f64, Reply),
    Clear(Reply),
    Shutdown,
}

pub struct Session {
    runtime: tokio::runtime::Runtime,
    sender: mpsc::Sender<Command>,
    last_error: Mutex<Option<CString>>,
}

fn provider(pairing: &PairingFile, addr: IpAddr) -> TcpProvider {
    TcpProvider {
        addr,
        scope_id: None,
        pairing_file: pairing.clone(),
        label: "Cloak".to_string(),
    }
}

#[derive(Clone, Copy)]
enum Handshake {
    Plain,
    QueryTypeFirst,
    TlsFirst,
    TlsFirstLegacy,
}

impl Handshake {
    fn label(self) -> &'static str {
        match self {
            Handshake::Plain => "plain",
            Handshake::QueryTypeFirst => "querytype",
            Handshake::TlsFirst => "tls-first",
            Handshake::TlsFirstLegacy => "tls-legacy",
        }
    }
}

async fn strategy(
    provider: &TcpProvider,
    pairing: &PairingFile,
    mode: Handshake,
) -> Result<String, String> {
    let mut lockdown = LockdownClient::connect(provider)
        .await
        .map_err(|error| format!("connect {error:?}"))?;

    let mut trace = String::new();

    match mode {
        Handshake::QueryTypeFirst => {
            let kind = lockdown
                .idevice
                .get_type()
                .await
                .map_err(|error| format!("querytype {error:?}"))?;
            trace.push_str(&format!("type={kind} "));
        }
        Handshake::TlsFirst | Handshake::TlsFirstLegacy => {
            let legacy = matches!(mode, Handshake::TlsFirstLegacy);
            lockdown
                .idevice
                .start_session(pairing, legacy)
                .await
                .map_err(|error| format!("tls upgrade {error:?}"))?;
            trace.push_str("tls=up ");
        }
        Handshake::Plain => {}
    }

    let version = lockdown
        .get_value(Some("ProductVersion"), None)
        .await
        .map_err(|error| format!("{trace}get_value {error:?}"))?;

    let version = version
        .as_string()
        .map(|text| text.to_string())
        .unwrap_or_else(|| "unknown".to_string());

    Ok(format!("{trace}ios={version} WORKS"))
}

async fn try_address(pairing: &PairingFile, addr: IpAddr) -> Result<(), String> {
    let provider = provider(pairing, addr);
    let mut notes: Vec<String> = Vec::new();

    let modes = [
        Handshake::TlsFirst,
        Handshake::TlsFirstLegacy,
        Handshake::QueryTypeFirst,
        Handshake::Plain,
    ];

    for mode in modes {
        let run = strategy(&provider, pairing, mode);
        match tokio::time::timeout(Duration::from_secs(8), run).await {
            Ok(Ok(_)) => return Ok(()),
            Ok(Err(reason)) => notes.push(format!("{}: {reason}", mode.label())),
            Err(_) => notes.push(format!("{}: timed out", mode.label())),
        }
    }

    Err(notes.join(" || "))
}

async fn resolve_address(pairing: &PairingFile, candidates: &[IpAddr]) -> Result<IpAddr, String> {
    let mut notes: Vec<String> = Vec::new();
    for addr in candidates {
        match try_address(pairing, *addr).await {
            Ok(()) => return Ok(*addr),
            Err(reason) => notes.push(format!("{addr} -> {reason}")),
        }
    }
    Err(format!(
        "lockdownd did not answer on any address. Tried {}: {}",
        candidates.len(),
        notes.join("; ")
    ))
}

async fn device_info(pairing: &PairingFile, addr: IpAddr) -> Result<String, String> {
    let provider = provider(pairing, addr);
    let mut lockdown = LockdownClient::connect(&provider)
        .await
        .map_err(|error| format!("lockdown: {error}"))?;
    lockdown
        .start_session(pairing)
        .await
        .map_err(|error| format!("session: {error}"))?;

    let values = lockdown
        .get_value(None, None)
        .await
        .map_err(|error| format!("values: {error}"))?;

    let dictionary = values
        .as_dictionary()
        .ok_or_else(|| "lockdown returned no dictionary".to_string())?;

    let text = |key: &str| -> String {
        dictionary
            .get(key)
            .and_then(|value| value.as_string())
            .unwrap_or_default()
            .to_string()
    };

    let chip_id = dictionary
        .get("UniqueChipID")
        .and_then(|value| value.as_unsigned_integer())
        .unwrap_or(0);

    let payload = serde_json::json!({
        "productVersion": text("ProductVersion"),
        "buildVersion": text("BuildVersion"),
        "productType": text("ProductType"),
        "deviceName": text("DeviceName"),
        "uniqueChipId": chip_id,
        "address": addr.to_string(),
    });

    Ok(payload.to_string())
}

async fn already_mounted(pairing: &PairingFile, addr: IpAddr) -> Result<bool, String> {
    let provider = provider(pairing, addr);
    let mut mounter = ImageMounter::connect(&provider)
        .await
        .map_err(|error| format!("mounter: {error}"))?;
    let devices = mounter
        .copy_devices()
        .await
        .map_err(|error| format!("copy_devices: {error}"))?;

    Ok(devices.iter().any(|entry| {
        entry
            .as_dictionary()
            .and_then(|dictionary| dictionary.get("DiskImageType"))
            .and_then(|value| value.as_string())
            .map(|value| value == "Personalized")
            .unwrap_or(false)
    }))
}

async fn mount(
    pairing: &PairingFile,
    addr: IpAddr,
    image: Vec<u8>,
    trust_cache: Vec<u8>,
    manifest: Vec<u8>,
) -> Result<String, String> {
    if already_mounted(pairing, addr).await? {
        return Ok("already mounted".to_string());
    }

    let info = device_info(pairing, addr).await?;
    let parsed: serde_json::Value =
        serde_json::from_str(&info).map_err(|error| format!("device info: {error}"))?;
    let chip_id = parsed
        .get("uniqueChipId")
        .and_then(|value| value.as_u64())
        .ok_or_else(|| "the device did not report a chip id".to_string())?;

    let provider = provider(pairing, addr);
    let mut mounter = ImageMounter::connect(&provider)
        .await
        .map_err(|error| format!("mounter: {error}"))?;

    mounter
        .mount_personalized(&provider, image, trust_cache, &manifest, None, chip_id)
        .await
        .map_err(|error| format!("mount: {error}"))?;

    Ok("mounted".to_string())
}

async fn worker(pairing: PairingFile, candidates: Vec<IpAddr>, mut receiver: mpsc::Receiver<Command>) {
    let mut resolved: Option<IpAddr> = None;

    while let Some(command) = receiver.recv().await {
        match command {
            Command::Shutdown => return,

            Command::Probe(reply) => {
                match resolve_address(&pairing, &candidates).await {
                    Ok(addr) => {
                        resolved = Some(addr);
                        let _ = reply.send(Ok(addr.to_string()));
                    }
                    Err(reason) => {
                        let _ = reply.send(Err(reason));
                    }
                }
            }

            Command::DeviceInfo(reply) => {
                let addr = match ensure(&pairing, &candidates, &mut resolved).await {
                    Ok(value) => value,
                    Err(reason) => {
                        let _ = reply.send(Err(reason));
                        continue;
                    }
                };
                let _ = reply.send(device_info(&pairing, addr).await);
            }

            Command::Mount {
                image,
                trust_cache,
                manifest,
                reply,
            } => {
                let addr = match ensure(&pairing, &candidates, &mut resolved).await {
                    Ok(value) => value,
                    Err(reason) => {
                        let _ = reply.send(Err(reason));
                        continue;
                    }
                };
                let _ = reply.send(mount(&pairing, addr, image, trust_cache, manifest).await);
            }

            Command::Set(_, _, reply) | Command::Clear(reply) => {
                let _ = reply.send(Err("the location service is not open".to_string()));
            }

            Command::Open(reply) => {
                let addr = match ensure(&pairing, &candidates, &mut resolved).await {
                    Ok(value) => value,
                    Err(reason) => {
                        let _ = reply.send(Err(reason));
                        continue;
                    }
                };
                if stream_locations(&pairing, addr, &mut receiver, reply).await {
                    return;
                }
            }
        }
    }
}

async fn ensure(
    pairing: &PairingFile,
    candidates: &[IpAddr],
    resolved: &mut Option<IpAddr>,
) -> Result<IpAddr, String> {
    if let Some(addr) = resolved {
        return Ok(*addr);
    }
    let addr = resolve_address(pairing, candidates).await?;
    *resolved = Some(addr);
    Ok(addr)
}

async fn stream_locations(
    pairing: &PairingFile,
    addr: IpAddr,
    receiver: &mut mpsc::Receiver<Command>,
    reply: Reply,
) -> bool {
    let provider = provider(pairing, addr);

    let proxy = match CoreDeviceProxy::connect(&provider).await {
        Ok(value) => value,
        Err(error) => {
            let _ = reply.send(Err(format!("core device proxy on {addr}: {error}")));
            return false;
        }
    };

    let rsd_port = proxy.tunnel_info().server_rsd_port;

    let adapter = match proxy.create_software_tunnel() {
        Ok(value) => value,
        Err(error) => {
            let _ = reply.send(Err(format!("tunnel: {error}")));
            return false;
        }
    };

    let mut handle = adapter.to_async_handle();

    let socket = match handle.connect_to_service_port(rsd_port).await {
        Ok(value) => value,
        Err(error) => {
            let _ = reply.send(Err(format!("rsd port {rsd_port}: {error}")));
            return false;
        }
    };

    let handshake = match RsdHandshake::new(socket).await {
        Ok(value) => value,
        Err(error) => {
            let _ = reply.send(Err(format!("rsd handshake: {error}")));
            return false;
        }
    };

    let dvt_port = match handshake.services.get(DVT_SERVICE) {
        Some(service) => service.port,
        None => {
            let mut names: Vec<&String> = handshake.services.keys().collect();
            names.sort();
            let listed = names
                .iter()
                .take(8)
                .map(|name| name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            let _ = reply.send(Err(format!(
                "{DVT_SERVICE} is not advertised, so the developer image is not mounted. {} services seen: {listed}",
                names.len()
            )));
            return false;
        }
    };

    let dvt_stream = match handle.connect_to_service_port(dvt_port).await {
        Ok(value) => value,
        Err(error) => {
            let _ = reply.send(Err(format!("dvt port {dvt_port}: {error}")));
            return false;
        }
    };

    let mut server = RemoteServerClient::new(dvt_stream);

    let mut location = match LocationSimulationClient::new(&mut server).await {
        Ok(value) => value,
        Err(error) => {
            let _ = reply.send(Err(format!("location service: {error}")));
            return false;
        }
    };

    let _ = reply.send(Ok("open".to_string()));

    while let Some(command) = receiver.recv().await {
        match command {
            Command::Set(latitude, longitude, responder) => {
                let result = location
                    .set(latitude, longitude)
                    .await
                    .map(|_| "set".to_string())
                    .map_err(|error| format!("set: {error}"));
                let failed = result.is_err();
                let _ = responder.send(result);
                if failed {
                    return false;
                }
            }
            Command::Clear(responder) => {
                let result = location
                    .clear()
                    .await
                    .map(|_| "cleared".to_string())
                    .map_err(|error| format!("clear: {error}"));
                let _ = responder.send(result);
            }
            Command::Open(responder) => {
                let _ = responder.send(Ok("already open".to_string()));
            }
            Command::Probe(responder) => {
                let _ = responder.send(Ok(addr.to_string()));
            }
            Command::DeviceInfo(responder) => {
                let _ = responder.send(device_info(pairing, addr).await);
            }
            Command::Mount { reply: responder, .. } => {
                let _ = responder.send(Ok("already mounted".to_string()));
            }
            Command::Shutdown => {
                let _ = location.clear().await;
                return true;
            }
        }
    }

    true
}

impl Session {
    fn record(&self, message: String) {
        if let Ok(value) = CString::new(message) {
            *self.last_error.lock().unwrap() = Some(value);
        }
    }

    fn dispatch<F>(&self, build: F) -> Result<String, String>
    where
        F: FnOnce(Reply) -> Command,
    {
        let (responder, receiver) = oneshot::channel();
        let command = build(responder);
        self.runtime.block_on(async {
            self.sender
                .send(command)
                .await
                .map_err(|_| "the device worker stopped".to_string())?;
            receiver
                .await
                .map_err(|_| "the device worker dropped the reply".to_string())?
        })
    }

    fn run<F>(&self, code: c_int, build: F) -> c_int
    where
        F: FnOnce(Reply) -> Command,
    {
        match self.dispatch(build) {
            Ok(_) => CLOAK_OK,
            Err(message) => {
                self.record(message);
                code
            }
        }
    }
}

async fn probe_rsd(addr: IpAddr, port: u16) -> Result<String, String> {
    let stream = tokio::time::timeout(
        Duration::from_secs(4),
        tokio::net::TcpStream::connect((addr, port)),
    )
    .await
    .map_err(|_| "connect timed out".to_string())?
    .map_err(|error| format!("connect {error:?}"))?;

    let mut client = tokio::time::timeout(Duration::from_secs(5), RemoteXpcClient::new(stream))
        .await
        .map_err(|_| "step1 xpc open timed out".to_string())?
        .map_err(|error| format!("step1 xpc open {error:?}"))?;

    tokio::time::timeout(Duration::from_secs(5), client.do_handshake())
        .await
        .map_err(|_| "step2 handshake timed out".to_string())?
        .map_err(|error| format!("step2 handshake {error:?}"))?;

    tokio::time::timeout(Duration::from_secs(5), client.send_device_handshake())
        .await
        .map_err(|_| "step3 device handshake timed out".to_string())?
        .map_err(|error| format!("step3 device handshake {error:?}"))?;

    let root = tokio::time::timeout(Duration::from_secs(6), client.recv_root())
        .await
        .map_err(|_| "step4 recv_root timed out".to_string())?
        .map_err(|error| format!("step4 recv_root {error:?}"))?;

    let Some(dictionary) = root.as_dictionary() else {
        return Ok(format!("{{\"stage\":\"root-not-dict\",\"root\":{:?}}}", format!("{root:?}").chars().take(300).collect::<String>()));
    };

    let mut keys: Vec<String> = dictionary.keys().cloned().collect();
    keys.sort();

    let Some(services) = dictionary.get("Services").and_then(|value| value.as_dictionary()) else {
        return Ok(serde_json::json!({
            "stage": "no-services",
            "rootKeys": keys,
        })
        .to_string());
    };

    let mut names: Vec<String> = services.keys().cloned().collect();
    names.sort();
    let dvt = names.iter().any(|name| name == DVT_SERVICE);

    Ok(serde_json::json!({
        "stage": "services",
        "serviceCount": names.len(),
        "hasDvt": dvt,
        "services": names.iter().take(40).collect::<Vec<_>>(),
    })
    .to_string())
}

#[no_mangle]
pub extern "C" fn cloak_probe_rsd(
    address: *const c_char,
    port: u16,
    out: *mut c_char,
    capacity: usize,
) -> c_int {
    if address.is_null() || out.is_null() {
        return CLOAK_ERR_STATE;
    }

    let Ok(text) = (unsafe { CStr::from_ptr(address) }).to_str() else {
        return CLOAK_ERR_STATE;
    };
    let Ok(addr) = text.parse::<IpAddr>() else {
        return CLOAK_ERR_STATE;
    };

    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
        return CLOAK_ERR_STATE;
    };

    let report = runtime.block_on(async {
        match probe_rsd(addr, port).await {
            Ok(value) => value,
            Err(reason) => serde_json::json!({ "stage": "failed", "reason": reason }).to_string(),
        }
    });

    let Ok(value) = CString::new(report) else {
        return CLOAK_ERR_BUFFER;
    };
    let raw = value.as_bytes_with_nul();
    if capacity < raw.len() {
        return CLOAK_ERR_BUFFER;
    }
    unsafe { ptr::copy_nonoverlapping(raw.as_ptr() as *const c_char, out, raw.len()) };
    CLOAK_OK
}

unsafe fn bytes<'a>(pointer: *const c_uchar, length: usize) -> Option<&'a [u8]> {
    if pointer.is_null() || length == 0 {
        None
    } else {
        Some(std::slice::from_raw_parts(pointer, length))
    }
}

#[no_mangle]
pub extern "C" fn cloak_session_new(
    pairing: *const c_uchar,
    length: usize,
    addresses: *const c_char,
) -> *mut Session {
    let Some(raw) = (unsafe { bytes(pairing, length) }) else {
        return ptr::null_mut();
    };
    let Ok(pairing_file) = PairingFile::from_bytes(raw) else {
        return ptr::null_mut();
    };

    let mut candidates: Vec<IpAddr> = Vec::new();
    if !addresses.is_null() {
        if let Ok(text) = unsafe { CStr::from_ptr(addresses) }.to_str() {
            for piece in text.split(',') {
                let trimmed = piece.trim();
                if trimmed.is_empty() {
                    continue;
                }
                if let Ok(addr) = trimmed.parse::<IpAddr>() {
                    if !candidates.contains(&addr) {
                        candidates.push(addr);
                    }
                }
            }
        }
    }
    if candidates.is_empty() {
        candidates.push(IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));
    }

    let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    else {
        return ptr::null_mut();
    };

    let (sender, receiver) = mpsc::channel(16);
    runtime.spawn(worker(pairing_file, candidates, receiver));

    Box::into_raw(Box::new(Session {
        runtime,
        sender,
        last_error: Mutex::new(None),
    }))
}

#[no_mangle]
pub extern "C" fn cloak_session_connect(session: *mut Session) -> c_int {
    let Some(session) = (unsafe { session.as_ref() }) else {
        return CLOAK_ERR_STATE;
    };
    session.run(CLOAK_ERR_CONNECT, Command::Probe)
}

#[no_mangle]
pub extern "C" fn cloak_session_device_info(
    session: *mut Session,
    out: *mut c_char,
    capacity: usize,
) -> c_int {
    let Some(session) = (unsafe { session.as_ref() }) else {
        return CLOAK_ERR_STATE;
    };
    match session.dispatch(Command::DeviceInfo) {
        Ok(json) => {
            let Ok(value) = CString::new(json) else {
                return CLOAK_ERR_BUFFER;
            };
            let raw = value.as_bytes_with_nul();
            if out.is_null() || capacity < raw.len() {
                return CLOAK_ERR_BUFFER;
            }
            unsafe { ptr::copy_nonoverlapping(raw.as_ptr() as *const c_char, out, raw.len()) };
            CLOAK_OK
        }
        Err(message) => {
            session.record(message);
            CLOAK_ERR_CONNECT
        }
    }
}

#[no_mangle]
pub extern "C" fn cloak_session_mount(
    session: *mut Session,
    image: *const c_uchar,
    image_length: usize,
    trust_cache: *const c_uchar,
    trust_cache_length: usize,
    manifest: *const c_uchar,
    manifest_length: usize,
) -> c_int {
    let Some(session) = (unsafe { session.as_ref() }) else {
        return CLOAK_ERR_STATE;
    };
    let (Some(image), Some(trust_cache), Some(manifest)) = (unsafe {
        (
            bytes(image, image_length),
            bytes(trust_cache, trust_cache_length),
            bytes(manifest, manifest_length),
        )
    }) else {
        session.record("the developer image, trust cache or manifest was empty".to_string());
        return CLOAK_ERR_MOUNT;
    };

    let image = image.to_vec();
    let trust_cache = trust_cache.to_vec();
    let manifest = manifest.to_vec();

    session.run(CLOAK_ERR_MOUNT, move |reply| Command::Mount {
        image,
        trust_cache,
        manifest,
        reply,
    })
}

#[no_mangle]
pub extern "C" fn cloak_session_open_service(session: *mut Session) -> c_int {
    let Some(session) = (unsafe { session.as_ref() }) else {
        return CLOAK_ERR_STATE;
    };
    session.run(CLOAK_ERR_SERVICE, Command::Open)
}

#[no_mangle]
pub extern "C" fn cloak_session_set_location(
    session: *mut Session,
    latitude: c_double,
    longitude: c_double,
) -> c_int {
    let Some(session) = (unsafe { session.as_ref() }) else {
        return CLOAK_ERR_STATE;
    };
    session.run(CLOAK_ERR_SERVICE, move |reply| {
        Command::Set(latitude, longitude, reply)
    })
}

#[no_mangle]
pub extern "C" fn cloak_session_clear_location(session: *mut Session) -> c_int {
    let Some(session) = (unsafe { session.as_ref() }) else {
        return CLOAK_ERR_STATE;
    };
    session.run(CLOAK_ERR_SERVICE, Command::Clear)
}

#[no_mangle]
pub extern "C" fn cloak_session_last_error(session: *mut Session) -> *const c_char {
    let Some(session) = (unsafe { session.as_ref() }) else {
        return ptr::null();
    };
    let guard = session.last_error.lock().unwrap();
    match guard.as_ref() {
        Some(value) => value.as_ptr(),
        None => ptr::null(),
    }
}

#[no_mangle]
pub extern "C" fn cloak_session_free(session: *mut Session) {
    if session.is_null() {
        return;
    }
    let session = unsafe { Box::from_raw(session) };
    let sender = session.sender.clone();
    session.runtime.block_on(async move {
        let _ = sender.send(Command::Shutdown).await;
    });
}
