//! Pairing the phone the new way, from the computer.
//!
//! From iOS 26.4 the phone refuses the classic lockdown pairing record for
//! anything that arrives over the network, which is how Cloak talks to the
//! phone from the phone. What still works is Apple's remote pairing, the
//! protocol Xcode uses for wireless debugging: the computer connects to the
//! phone's `_remotepairing._tcp` service, the phone shows a six digit code,
//! the person types it here, and both sides keep a record. SideStore's
//! computer tool does exactly this for the same reason.
//!
//! The record is written into the app before it is signed, so on first launch
//! Cloak already has a pairing it can use through its own loopback tunnel, with
//! no discovery, no Local Network permission and no code on the phone.

use std::net::IpAddr;
use std::time::{Duration, Instant};

use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket};
use mdns_sd::{ServiceDaemon, ServiceEvent};

pub const RP_FILE: &str = "cloak-rppairing.txt";
const SERVICE: &str = "_remotepairing._tcp.local.";

#[derive(Debug, Clone)]
pub struct Found {
    pub name: String,
    pub addresses: Vec<IpAddr>,
    pub port: u16,
}

/// Every phone advertising remote pairing on the networks this computer is
/// on, including the USB link iOS brings up on its own.
pub fn browse(wait: Duration) -> Result<Vec<Found>, String> {
    let daemon = ServiceDaemon::new().map_err(|e| format!("mDNS could not start: {e}"))?;
    let receiver = daemon
        .browse(SERVICE)
        .map_err(|e| format!("mDNS browse failed: {e}"))?;

    let started = Instant::now();
    let mut found: Vec<Found> = Vec::new();
    tracing::info!("browsing {SERVICE} for up to {}s", wait.as_secs());
    while started.elapsed() < wait {
        match receiver.recv_timeout(Duration::from_millis(400)) {
            Ok(ServiceEvent::ServiceResolved(info)) => {
                let mut addresses: Vec<IpAddr> = info.get_addresses().iter().cloned().collect();
                // IPv4 first: it is what the loopback reflector on the phone
                // speaks, and it avoids scoped IPv6 trouble entirely.
                addresses.sort_by_key(|a| a.is_ipv6());
                let entry = Found {
                    name: info.get_fullname().to_string(),
                    addresses,
                    port: info.get_port(),
                };
                if !found.iter().any(|f| f.name == entry.name) {
                    tracing::info!("remote pairing service: {} at {:?} port {}", entry.name, entry.addresses, entry.port);
                    found.push(entry);
                }
            }
            Ok(_) => {}
            Err(_) => {}
        }
        if !found.is_empty() && started.elapsed() > Duration::from_secs(5) {
            break;
        }
    }
    let _ = daemon.shutdown();
    Ok(found)
}

/// Pairs with one advertised phone. `ask_pin` is called when the phone puts
/// its code on screen and must return what the person typed.
pub async fn pair<F, Fut>(target: &Found, ask_pin: F) -> Result<String, String>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = String>,
{
    let mut last = String::from("no address answered");
    for socket_addr in dial_targets(target) {
        let stream = match tokio::time::timeout(
            Duration::from_secs(3),
            tokio::net::TcpStream::connect(socket_addr),
        )
        .await
        {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => {
                last = format!("{socket_addr}: {error}");
                continue;
            }
            Err(_) => {
                last = format!("{socket_addr}: timed out");
                continue;
            }
        };
        let _ = stream.set_nodelay(true);
        tracing::info!("remote pairing: connected to {socket_addr}");
        let address = socket_addr.ip();

        let socket = RpPairingSocket::new(stream);
        let mut client = RemotePairingClient::new(socket, "Cloak");
        let mut file = RpPairingFile::generate("Cloak");

        if let Err(error) = client.attempt_pair_verify().await {
            last = format!("{address}: handshake {error:?}");
            continue;
        }
        if let Err(error) = client.pair(&mut file, &ask_pin).await {
            last = format!("{address}: pairing {error:?}");
            continue;
        }

        use base64::Engine;
        return Ok(base64::engine::general_purpose::STANDARD.encode(file.to_bytes()));
    }
    Err(last)
}

/// Orders the advertisements so the one that looks like this phone goes
/// first; the rest are still tried, because the name in the advertisement
/// does not always carry the device name.
pub fn ordered<'a>(found: &'a [Found], device_name: &str) -> Vec<&'a Found> {
    let wanted = device_name.to_lowercase().replace('\u{2019}', "'").replace('\u{2018}', "'");
    let mut list: Vec<&Found> = found.iter().collect();
    list.sort_by_key(|f| !f.name.to_lowercase().replace('\u{2019}', "'").contains(&wanted));
    list
}


/// Every socket address worth dialling for one advertisement.
///
/// The USB link iOS brings up is IPv6 link-local only, and a link-local
/// address is meaningless without the interface it belongs to. mDNS does not
/// say which one, so each link-local address is tried on every interface
/// index this computer has. Wrong ones fail instantly; the right one is the
/// cable.
fn dial_targets(target: &Found) -> Vec<std::net::SocketAddr> {
    let mut list: Vec<std::net::SocketAddr> = Vec::new();
    for address in &target.addresses {
        match address {
            IpAddr::V4(v4) => list.push(std::net::SocketAddr::new(IpAddr::V4(*v4), target.port)),
            IpAddr::V6(v6) => {
                let link_local = (v6.segments()[0] & 0xffc0) == 0xfe80;
                if link_local {
                    for scope in interface_indexes() {
                        list.push(std::net::SocketAddr::V6(std::net::SocketAddrV6::new(*v6, target.port, 0, scope)));
                    }
                } else {
                    list.push(std::net::SocketAddr::new(IpAddr::V6(*v6), target.port));
                }
            }
        }
    }
    list
}

#[cfg(unix)]
fn interface_indexes() -> Vec<u32> {
    // if_nameindex() lists every interface with its index; that is exactly
    // the scope id a link-local address needs.
    let mut out = Vec::new();
    unsafe {
        let head = libc::if_nameindex();
        if head.is_null() {
            return (1..=40).collect();
        }
        let mut cursor = head;
        while !(*cursor).if_name.is_null() && (*cursor).if_index != 0 {
            let name = std::ffi::CStr::from_ptr((*cursor).if_name).to_string_lossy();
            // Skip loopback and the obvious tunnels; the phone is on en*/usb*.
            if !name.starts_with("lo") && !name.starts_with("utun") && !name.starts_with("ipsec") {
                out.push((*cursor).if_index);
            }
            cursor = cursor.add(1);
        }
        libc::if_freenameindex(head);
    }
    if out.is_empty() { (1..=40).collect() } else { out }
}

#[cfg(not(unix))]
fn interface_indexes() -> Vec<u32> {
    (1..=64).collect()
}
