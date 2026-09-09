use idevice::remote_pairing::{RemotePairingClient, RpPairingSocket};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let target = args.get(1).cloned().unwrap_or_else(|| {
        eprintln!("usage: rpprobe <ip:port>");
        std::process::exit(2);
    });

    let stream = match tokio::net::TcpStream::connect(target.as_str()).await {
        Ok(value) => value,
        Err(error) => {
            println!("CONNECT_FAILED {error}");
            return;
        }
    };
    let _ = stream.set_nodelay(true);
    println!("CONNECTED {target}");

    let socket = RpPairingSocket::new(stream);
    let mut client = RemotePairingClient::new(socket, "CloakProbe");

    match client.attempt_pair_verify().await {
        Ok(value) => println!("HANDSHAKE_OK {value:#?}"),
        Err(error) => println!("HANDSHAKE_ERR {error:?}"),
    }
}
