use std::ffi::{c_char, c_double, c_int, c_uchar, CStr, CString};
use std::net::IpAddr;
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use idevice::provider::RsdProvider;
use idevice::remote_pairing::{
    connect_tls_psk_tunnel_native, PairableHost, PairableHostInfo, RemotePairingClient,
    RpPairingFile, RpPairingSocket,
};
use idevice::services::dvt::location_simulation::LocationSimulationClient;
use idevice::services::dvt::remote_server::RemoteServerClient;
use idevice::services::mobile_image_mounter::ImageMounter;
use idevice::services::rsd::RsdHandshake;
use idevice::RsdService;
use tokio::sync::{mpsc, oneshot};

pub const RP_OK: c_int = 0;
pub const RP_ERR: c_int = 1;
pub const RP_ERR_BUFFER: c_int = 2;

const DVT_SERVICE: &str = "com.apple.instruments.dtservicehub";
const MOUNTER_SERVICE: &str = "com.apple.mobile.mobile_image_mounter.shim.remote";

/// Work the tunnel task performs once the link is up. Sent fire and forget so
/// nothing on the Swift side ever blocks on the network.
enum Command {
    Set(f64, f64),
    Clear,
    Mount {
        image: Vec<u8>,
        trust_cache: Vec<u8>,
        manifest: Vec<u8>,
        chip_id: u64,
    },
    Stop,
}

struct RpSession {
    runtime: tokio::runtime::Runtime,
    state: Mutex<String>,
    pin: Mutex<Option<oneshot::Sender<String>>>,
    commands: Mutex<Option<mpsc::UnboundedSender<Command>>>,
    /// Latest link report, merged into every state we publish so the UI keeps
    /// showing what the tunnel is doing while location updates stream through.
    link: Mutex<serde_json::Value>,
}

static SESSION: OnceLock<Arc<RpSession>> = OnceLock::new();

fn base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { TABLE[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[(n & 63) as usize] as char } else { '=' });
    }
    out
}

fn unbase64(input: &str) -> Option<Vec<u8>> {
    fn value(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a') as u32 + 26),
            b'0'..=b'9' => Some((c - b'0') as u32 + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let cleaned: Vec<u8> = input.bytes().filter(|c| !c.is_ascii_whitespace()).collect();
    let mut out = Vec::new();
    for chunk in cleaned.chunks(4) {
        if chunk.len() < 2 {
            return None;
        }
        let mut n = 0u32;
        let mut pad = 0;
        for (index, byte) in chunk.iter().enumerate() {
            if *byte == b'=' {
                pad += 1;
                n <<= 6;
            } else {
                n = (n << 6) | value(*byte)?;
            }
            let _ = index;
        }
        for _ in chunk.len()..4 {
            n <<= 6;
            pad += 1;
        }
        out.push((n >> 16) as u8);
        if pad < 2 {
            out.push((n >> 8) as u8);
        }
        if pad < 1 {
            out.push(n as u8);
        }
    }
    Some(out)
}

fn session() -> Arc<RpSession> {
    SESSION
        .get_or_init(|| {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("runtime");
            Arc::new(RpSession {
                runtime,
                state: Mutex::new("{\"state\":\"idle\"}".to_string()),
                pin: Mutex::new(None),
                commands: Mutex::new(None),
                link: Mutex::new(serde_json::json!({ "simulating": false })),
            })
        })
        .clone()
}

fn set_state(session: &RpSession, value: serde_json::Value) {
    *session.state.lock().unwrap() = value.to_string();
}

/// Everything a successful attempt hands back. The tunnel only lives as long as
/// these do, so they all have to travel together.
struct Link {
    #[allow(dead_code)]
    client: RemotePairingClient<RpPairingSocket<tokio::net::TcpStream>>,
    handle: idevice::tcp::handle::AdapterHandle,
    handshake: RsdHandshake,
    rsd_port: u16,
    stored: String,
    host: String,
}

/// `host:port` is ambiguous for IPv6, which is full of colons, so bracket it.
fn socket_target(host: &str, port: u16) -> String {
    if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

fn split_candidate(entry: &str, fallback: u16) -> (String, u16) {
    // A candidate is either "host" or "host|port". Carrying the port lets us
    // try several advertisements, which matters because more than one device on
    // the network answers and they do not agree on a port.
    match entry.rsplit_once('|') {
        Some((left, right)) => match right.parse::<u16>() {
            Ok(value) => (left.to_string(), value),
            Err(_) => (entry.to_string(), fallback),
        },
        None => (entry.to_string(), fallback),
    }
}

/// One full attempt against one address: connect, pair-verify, tunnel, RSD.
///
/// This is per candidate rather than per TCP connect on purpose. Other devices
/// on the network advertise `_remotepairing._tcp` too, and a Mac will happily
/// accept the socket and then reset it, because it has never heard of our key.
/// Falling through to the next address is what finds the phone itself.
async fn attempt(
    session: &Arc<RpSession>,
    host: &str,
    port: u16,
    existing: Option<Vec<u8>>,
) -> Result<Link, String> {
    set_state(
        session,
        serde_json::json!({ "state": "connecting", "detail": format!("{host}:{port}") }),
    );

    // A string host goes through getaddrinfo, so scoped IPv6 such as
    // fe80::1%en0 resolves correctly. IpAddr::parse would reject it.
    let stream = match tokio::time::timeout(
        Duration::from_secs(3),
        tokio::net::TcpStream::connect(socket_target(host, port).as_str()),
    )
    .await
    {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => return Err(format!("connect: {error}")),
        Err(_) => return Err("connect timed out".to_string()),
    };
    let _ = stream.set_nodelay(true);

    let socket = RpPairingSocket::new(stream);
    let mut client = RemotePairingClient::new(socket, "Cloak");

    let mut pairing_file = match existing.and_then(|bytes| RpPairingFile::from_bytes(&bytes).ok()) {
        Some(value) => value,
        None => RpPairingFile::generate("Cloak"),
    };

    set_state(session, serde_json::json!({ "state": "pairing", "detail": host }));

    // Done step by step rather than through connect(), so a failure says which
    // of the three actually broke. They fail for completely different reasons:
    // the handshake means the phone refused us outright, validate means it does
    // not recognise our identity, and pair means it refused a host-initiated
    // setup.
    client
        .attempt_pair_verify()
        .await
        .map_err(|error| format!("handshake: {error:?}"))?;

    if let Err(validate_error) = client.validate_pairing(&mut pairing_file).await {
        let pin_session = session.clone();
        client
            .pair(&mut pairing_file, || {
                let inner = pin_session.clone();
                async move {
                    let (tx, rx) = oneshot::channel();
                    *inner.pin.lock().unwrap() = Some(tx);
                    set_state(&inner, serde_json::json!({ "state": "needs-pin" }));
                    rx.await.unwrap_or_default()
                }
            })
            .await
            .map_err(|error| {
                format!("validate: {validate_error:?} then setup: {error:?}")
            })?;
    }

    let stored = base64(&pairing_file.to_bytes());
    set_state(
        session,
        serde_json::json!({ "state": "tunnelling", "pairing": stored, "detail": host }),
    );

    let tunnel_port = client
        .create_tcp_listener()
        .await
        .map_err(|error| format!("listener: {error:?}"))?;

    let tunnel_stream = tokio::net::TcpStream::connect(socket_target(host, tunnel_port).as_str())
        .await
        .map_err(|error| format!("tunnel connect: {error}"))?;

    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, client.encryption_key())
        .await
        .map_err(|error| format!("tls psk: {error:?}"))?;

    let rsd_port = tunnel.info.server_rsd_port;
    let mtu = tunnel.info.mtu as usize;

    let our_ip = tunnel
        .info
        .client_address
        .parse::<IpAddr>()
        .map_err(|error| format!("client address: {error}"))?;
    let their_ip = tunnel
        .info
        .server_address
        .parse::<IpAddr>()
        .map_err(|error| format!("server address: {error}"))?;

    let stream = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(stream), our_ip, their_ip);
    adapter.set_mss(mtu.saturating_sub(60));

    let mut handle = adapter.to_async_handle();

    let rsd_stream = handle
        .connect_to_service_port(rsd_port)
        .await
        .map_err(|error| format!("rsd port {rsd_port}: {error}"))?;

    let handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|error| format!("rsd handshake: {error}"))?;

    Ok(Link {
        client,
        handle,
        handshake,
        rsd_port,
        stored,
        host: host.to_string(),
    })
}

async fn run(session: Arc<RpSession>, hosts: Vec<String>, port: u16, existing: Option<Vec<u8>>) {
    let mut notes: Vec<String> = Vec::new();
    let mut link: Option<Link> = None;

    for entry in &hosts {
        let (host, host_port) = split_candidate(entry, port);
        match attempt(&session, &host, host_port, existing.clone()).await {
            Ok(value) => {
                link = Some(value);
                break;
            }
            Err(error) => notes.push(format!("{host}:{host_port} {error}")),
        }
    }

    let Some(link) = link else {
        set_state(
            &session,
            serde_json::json!({
                "state": "error",
                "reason": format!("no address answered as this phone. Tried: {}", notes.join(" | ")),
            }),
        );
        return;
    };

    let Link {
        client: _client,
        mut handle,
        handshake,
        rsd_port,
        stored,
        host,
    } = link;

    set_link(&session, serde_json::json!({ "simulating": false, "host": host }));

    let mut handshake = handshake;

    let (sender, mut receiver) = mpsc::unbounded_channel::<Command>();
    *session.commands.lock().unwrap() = Some(sender);

    publish_ready(&session, &handshake, &stored, rsd_port, None);

    // The tunnel only exists for as long as this task runs, so everything from
    // here down stays inside it.
    'outer: loop {
        let Some(command) = receiver.recv().await else {
            break;
        };

        match command {
            Command::Stop => break,

            Command::Clear => continue,

            Command::Mount {
                image,
                trust_cache,
                manifest,
                chip_id,
            } => {
                let resolved = if chip_id != 0 {
                    chip_id
                } else {
                    chip_id_from(&handshake).unwrap_or(0)
                };

                let note = if resolved == 0 {
                    Err("the device did not report a chip id, so the image cannot be personalized".to_string())
                } else {
                    do_mount(
                        &mut handle,
                        &mut handshake,
                        image,
                        trust_cache,
                        manifest,
                        resolved,
                    )
                    .await
                };

                match note {
                    Ok(()) => {
                        // Re-read the service list: dtservicehub only appears
                        // once the image is mounted.
                        match refresh(&mut handle, rsd_port).await {
                            Ok(fresh) => {
                                handshake = fresh;
                                publish_ready(&session, &handshake, &stored, rsd_port, Some("mounted".to_string()));
                            }
                            Err(error) => {
                                publish_ready(&session, &handshake, &stored, rsd_port, Some(format!("mounted, but re-reading services failed: {error}")));
                            }
                        }
                    }
                    Err(error) => {
                        publish_ready(&session, &handshake, &stored, rsd_port, Some(format!("mount failed: {error}")));
                    }
                }
            }

            Command::Set(latitude, longitude) => {
                let Some(service) = handshake.services.get(DVT_SERVICE) else {
                    publish_ready(
                        &session,
                        &handshake,
                        &stored,
                        rsd_port,
                        Some("the developer image is not mounted, so the location service is not there".to_string()),
                    );
                    continue;
                };
                let dvt_port = service.port;

                let dvt_stream = match handle.connect_to_service_port(dvt_port).await {
                    Ok(value) => value,
                    Err(error) => {
                        publish_ready(&session, &handshake, &stored, rsd_port, Some(format!("dvt port {dvt_port}: {error}")));
                        continue;
                    }
                };

                let mut server = RemoteServerClient::new(dvt_stream);
                let mut location = match LocationSimulationClient::new(&mut server).await {
                    Ok(value) => value,
                    Err(error) => {
                        publish_ready(&session, &handshake, &stored, rsd_port, Some(format!("location service: {error}")));
                        continue;
                    }
                };

                if let Err(error) = location.set(latitude, longitude).await {
                    publish_ready(&session, &handshake, &stored, rsd_port, Some(format!("set: {error}")));
                    continue;
                }

                set_link(&session, serde_json::json!({ "simulating": true, "note": serde_json::Value::Null }));
                publish_ready(&session, &handshake, &stored, rsd_port, None);

                // Hold the DVT channel open and stream every later fix through
                // it. Reopening per fix would make iOS drop the simulation.
                loop {
                    let Some(next) = receiver.recv().await else {
                        break 'outer;
                    };
                    match next {
                        Command::Set(lat, lon) => {
                            if let Err(error) = location.set(lat, lon).await {
                                set_link(&session, serde_json::json!({ "simulating": false }));
                                publish_ready(&session, &handshake, &stored, rsd_port, Some(format!("set: {error}")));
                                break;
                            }
                        }
                        Command::Clear => {
                            let _ = location.clear().await;
                            set_link(&session, serde_json::json!({ "simulating": false }));
                            publish_ready(&session, &handshake, &stored, rsd_port, None);
                            break;
                        }
                        Command::Stop => {
                            let _ = location.clear().await;
                            break 'outer;
                        }
                        Command::Mount { .. } => {
                            publish_ready(&session, &handshake, &stored, rsd_port, Some("stop simulating before mounting".to_string()));
                        }
                    }
                }
            }
        }
    }

    set_link(&session, serde_json::json!({ "simulating": false }));
    set_state(&session, serde_json::json!({ "state": "idle", "pairing": stored }));
}

async fn refresh(
    handle: &mut idevice::tcp::handle::AdapterHandle,
    rsd_port: u16,
) -> Result<RsdHandshake, String> {
    let stream = handle
        .connect_to_service_port(rsd_port)
        .await
        .map_err(|error| format!("rsd port {rsd_port}: {error}"))?;
    RsdHandshake::new(stream)
        .await
        .map_err(|error| format!("rsd handshake: {error}"))
}

async fn do_mount(
    handle: &mut idevice::tcp::handle::AdapterHandle,
    handshake: &mut RsdHandshake,
    image: Vec<u8>,
    trust_cache: Vec<u8>,
    manifest: Vec<u8>,
    chip_id: u64,
) -> Result<(), String> {
    let port = handshake
        .services
        .get(MOUNTER_SERVICE)
        .map(|service| service.port)
        .ok_or_else(|| format!("{MOUNTER_SERVICE} is not advertised over this tunnel"))?;

    let stream = handle
        .connect_to_service_port(port)
        .await
        .map_err(|error| format!("mounter port {port}: {error}"))?;

    let mut mounter = <ImageMounter as RsdService>::from_stream(stream)
        .await
        .map_err(|error| format!("mounter: {error}"))?;

    // Already there? Then there is nothing to do.
    if let Ok(devices) = mounter.copy_devices().await {
        let personalized = devices.iter().any(|device| {
            device
                .as_dictionary()
                .and_then(|d| d.get("MountType"))
                .and_then(|v| v.as_string())
                .map(|v| v == "Personalized")
                .unwrap_or(false)
        });
        if personalized {
            return Ok(());
        }
    }

    mounter
        .mount_personalized_rsd(handle, handshake, image, trust_cache, &manifest, None, chip_id)
        .await
        .map_err(|error| format!("{error}"))
}

fn publish_ready(
    session: &RpSession,
    handshake: &RsdHandshake,
    stored: &str,
    rsd_port: u16,
    note: Option<String>,
) {
    let mut names: Vec<String> = handshake.services.keys().cloned().collect();
    names.sort();
    let dvt = names.iter().any(|name| name == DVT_SERVICE);
    let mounter = names.iter().any(|name| name == MOUNTER_SERVICE);
    let link = session.link.lock().unwrap().clone();
    let chip = chip_id_from(handshake);

    set_state(
        session,
        serde_json::json!({
            "state": "ready",
            "pairing": stored,
            "serviceCount": names.len(),
            "hasDvt": dvt,
            "canMount": mounter,
            "rsdPort": rsd_port,
            "chipId": chip,
            "simulating": link.get("simulating").and_then(|v| v.as_bool()).unwrap_or(false),
            "note": note,
            "services": names.iter().take(40).collect::<Vec<_>>(),
        }),
    );
}

/// The RSD handshake carries the device properties, which is where the ECID
/// lives. Without it the personalized mount asks Apple's signing service to
/// sign for chip 0 and is refused.
fn chip_id_from(handshake: &RsdHandshake) -> Option<u64> {
    for key in ["UniqueChipID", "UniqueChipId", "ChipID", "ecid", "ECID"] {
        if let Some(value) = handshake.properties.get(key) {
            if let Some(number) = value.as_unsigned_integer() {
                if number != 0 {
                    return Some(number);
                }
            }
            if let Some(number) = value.as_signed_integer() {
                if number > 0 {
                    return Some(number as u64);
                }
            }
            if let Some(text) = value.as_string() {
                if let Ok(number) = text.parse::<u64>() {
                    if number != 0 {
                        return Some(number);
                    }
                }
            }
        }
    }
    None
}

fn set_link(session: &RpSession, value: serde_json::Value) {
    *session.link.lock().unwrap() = value;
}

#[no_mangle]
pub extern "C" fn cloak_rp_start(
    address: *const c_char,
    port: u16,
    pairing_base64: *const c_char,
) -> c_int {
    if address.is_null() {
        return RP_ERR;
    }
    let Ok(text) = (unsafe { CStr::from_ptr(address) }).to_str() else {
        return RP_ERR;
    };
    let hosts: Vec<String> = text
        .split(',')
        .map(|part| part.trim())
        .filter(|part| !part.is_empty())
        .map(|part| part.to_string())
        .collect();
    if hosts.is_empty() {
        return RP_ERR;
    }

    let existing = if pairing_base64.is_null() {
        None
    } else {
        (unsafe { CStr::from_ptr(pairing_base64) })
            .to_str()
            .ok()
            .filter(|value| !value.is_empty())
            .and_then(unbase64)
    };

    let session = session();

    let cloned = session.clone();
    session.runtime.spawn(async move {
        run(cloned, hosts, port, existing).await;
    });

    RP_OK
}

#[no_mangle]
pub extern "C" fn cloak_rp_state(out: *mut c_char, capacity: usize) -> c_int {
    let Some(session) = SESSION.get() else {
        return RP_ERR;
    };
    if out.is_null() {
        return RP_ERR;
    }
    let text = session.state.lock().unwrap().clone();
    let Ok(value) = CString::new(text) else {
        return RP_ERR_BUFFER;
    };
    let raw = value.as_bytes_with_nul();
    if capacity < raw.len() {
        return RP_ERR_BUFFER;
    }
    unsafe { ptr::copy_nonoverlapping(raw.as_ptr() as *const c_char, out, raw.len()) };
    RP_OK
}

#[no_mangle]
pub extern "C" fn cloak_rp_submit_pin(pin: *const c_char) -> c_int {
    let Some(session) = SESSION.get() else {
        return RP_ERR;
    };
    if pin.is_null() {
        return RP_ERR;
    }
    let Ok(text) = (unsafe { CStr::from_ptr(pin) }).to_str() else {
        return RP_ERR;
    };
    let Some(sender) = session.pin.lock().unwrap().take() else {
        return RP_ERR;
    };
    let _ = sender.send(text.to_string());
    RP_OK
}

fn send(command: Command) -> c_int {
    let Some(session) = SESSION.get() else {
        return RP_ERR;
    };
    let guard = session.commands.lock().unwrap();
    let Some(sender) = guard.as_ref() else {
        return RP_ERR;
    };
    if sender.send(command).is_err() {
        return RP_ERR;
    }
    RP_OK
}

/// Push one fix through the live tunnel. Fire and forget: the caller never
/// blocks, and any failure turns up in cloak_rp_state.
#[no_mangle]
pub extern "C" fn cloak_rp_set_location(latitude: c_double, longitude: c_double) -> c_int {
    send(Command::Set(latitude, longitude))
}

#[no_mangle]
pub extern "C" fn cloak_rp_clear_location() -> c_int {
    send(Command::Clear)
}

/// Mount the personalized developer image over the tunnel. Without it iOS does
/// not advertise the location service at all.
#[no_mangle]
pub extern "C" fn cloak_rp_mount(
    image: *const c_uchar,
    image_len: usize,
    trust_cache: *const c_uchar,
    trust_cache_len: usize,
    manifest: *const c_uchar,
    manifest_len: usize,
    chip_id: u64,
) -> c_int {
    if image.is_null() || trust_cache.is_null() || manifest.is_null() {
        return RP_ERR;
    }
    let image = unsafe { std::slice::from_raw_parts(image, image_len) }.to_vec();
    let trust_cache = unsafe { std::slice::from_raw_parts(trust_cache, trust_cache_len) }.to_vec();
    let manifest = unsafe { std::slice::from_raw_parts(manifest, manifest_len) }.to_vec();

    send(Command::Mount {
        image,
        trust_cache,
        manifest,
        chip_id,
    })
}

#[no_mangle]
pub extern "C" fn cloak_rp_stop() -> c_int {
    send(Command::Stop)
}

// ===================== Pairable host (device-initiated) =====================
//
// From iOS 27 the phone initiates pairing rather than accepting it. The host
// advertises `_remotepairing-pairable-host._tcp`, the phone connects to it, and
// the host generates the code the user types on the phone. Cloak plays the host
// here, which is what makes the whole thing work with no computer at all.

fn host_alt_irk(existing: Option<Vec<u8>>) -> [u8; 16] {
    let mut irk = [0u8; 16];
    if let Some(bytes) = existing {
        if bytes.len() == 16 {
            irk.copy_from_slice(&bytes);
            return irk;
        }
    }
    // Derived from the OS clock plus a hash so we do not pull in a rand
    // dependency here; the value only has to be stable and unguessable enough
    // to identify this host to the phone.
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut state = seed as u64 ^ 0x9E37_79B9_7F4A_7C15;
    for slot in irk.iter_mut() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        *slot = (state >> 24) as u8;
    }
    irk
}

async fn host_run(
    session: Arc<RpSession>,
    name: String,
    existing: Option<Vec<u8>>,
    existing_irk: Option<Vec<u8>>,
) {
    let listener = match tokio::net::TcpListener::bind(("0.0.0.0", 0)).await {
        Ok(value) => value,
        Err(error) => {
            set_state(&session, serde_json::json!({ "state": "error", "reason": format!("listen {error}") }));
            return;
        }
    };

    let port = match listener.local_addr() {
        Ok(addr) => addr.port(),
        Err(error) => {
            set_state(&session, serde_json::json!({ "state": "error", "reason": format!("port {error}") }));
            return;
        }
    };

    let mut pairing_file = match existing.and_then(|bytes| RpPairingFile::from_bytes(&bytes).ok()) {
        Some(value) => value,
        None => RpPairingFile::generate(&name),
    };

    let alt_irk = host_alt_irk(existing_irk);
    let identifier = pairing_file.identifier().to_string();

    let mut host_info = PairableHostInfo::generate(name.clone(), "Mac17,7");
    host_info.alt_irk = alt_irk;
    // Left empty these default to blank strings. Pairing still succeeds, but
    // the phone then has no identity to look us up by afterwards, which is
    // exactly what a later pair-verify needs.
    host_info.udid = identifier.clone();
    host_info.identifier = identifier.clone();
    let txt: serde_json::Map<String, serde_json::Value> = host_info
        .mdns_txt_records(&identifier)
        .into_iter()
        .map(|(key, value)| (key, serde_json::Value::String(value)))
        .collect();

    // Swift publishes the Bonjour record for this port and then waits here.
    set_state(
        &session,
        serde_json::json!({
            "state": "advertising",
            "port": port,
            "identifier": identifier,
            "altIrk": base64(&alt_irk),
            "txt": txt,
        }),
    );

    let (stream, peer) = match listener.accept().await {
        Ok(value) => value,
        Err(error) => {
            set_state(&session, serde_json::json!({ "state": "error", "reason": format!("accept {error}") }));
            return;
        }
    };
    let _ = stream.set_nodelay(true);

    set_state(
        &session,
        serde_json::json!({ "state": "host-connected", "detail": peer.ip().to_string() }),
    );

    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);

    let pin_session = session.clone();
    let result = host
        .accept(&mut pairing_file, |pin| {
            let inner = pin_session.clone();
            async move {
                set_state(&inner, serde_json::json!({ "state": "show-pin", "pin": pin }));
            }
        })
        .await;

    match result {
        Ok(_) => {
            set_state(
                &session,
                serde_json::json!({
                    "state": "paired",
                    "pairing": base64(&pairing_file.to_bytes()),
                    "altIrk": base64(&alt_irk),
                    "deviceAddress": peer.ip().to_string(),
                }),
            );
        }
        Err(error) => {
            set_state(&session, serde_json::json!({ "state": "error", "reason": format!("pair setup {error:?}") }));
        }
    }
}

/// Start advertising this app as a pairable host. Poll cloak_rp_state: it moves
/// through advertising -> host-connected -> show-pin -> paired.
#[no_mangle]
pub extern "C" fn cloak_rp_host_start(
    name: *const c_char,
    pairing_base64: *const c_char,
    alt_irk_base64: *const c_char,
) -> c_int {
    let name = if name.is_null() {
        "Cloak".to_string()
    } else {
        (unsafe { CStr::from_ptr(name) })
            .to_str()
            .unwrap_or("Cloak")
            .to_string()
    };

    let existing = read_optional_base64(pairing_base64);
    let existing_irk = read_optional_base64(alt_irk_base64);

    let session = session();
    let cloned = session.clone();
    session.runtime.spawn(async move {
        host_run(cloned, name, existing, existing_irk).await;
    });

    RP_OK
}

fn read_optional_base64(value: *const c_char) -> Option<Vec<u8>> {
    if value.is_null() {
        return None;
    }
    (unsafe { CStr::from_ptr(value) })
        .to_str()
        .ok()
        .filter(|text| !text.is_empty())
        .and_then(unbase64)
}
