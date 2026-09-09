use std::process::ExitCode;

use idevice::usbmuxd::UsbmuxdConnection;

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: cloak-pair-cli <output-path> [udid]");
        return ExitCode::from(2);
    }
    let output = args[1].clone();
    let wanted = args.get(2).cloned();

    let mut mux = match UsbmuxdConnection::default().await {
        Ok(value) => value,
        Err(error) => {
            eprintln!("cannot reach usbmuxd: {error}");
            return ExitCode::from(3);
        }
    };

    let devices = match mux.get_devices().await {
        Ok(value) => value,
        Err(error) => {
            eprintln!("cannot list devices: {error}");
            return ExitCode::from(4);
        }
    };

    if devices.is_empty() {
        eprintln!("no device connected");
        return ExitCode::from(5);
    }

    let udid = match wanted {
        Some(value) => value,
        None => devices[0].udid.clone(),
    };

    let pairing = match mux.get_pair_record(&udid).await {
        Ok(value) => value,
        Err(error) => {
            eprintln!("usbmuxd has no pair record for {udid}: {error}");
            return ExitCode::from(6);
        }
    };

    let bytes = match pairing.serialize() {
        Ok(value) => value,
        Err(error) => {
            eprintln!("cannot serialize pair record: {error}");
            return ExitCode::from(7);
        }
    };

    if bytes.is_empty() {
        eprintln!("pair record was empty");
        return ExitCode::from(8);
    }

    if let Err(error) = std::fs::write(&output, &bytes) {
        eprintln!("cannot write {output}: {error}");
        return ExitCode::from(9);
    }

    println!("{} {}", udid, bytes.len());
    ExitCode::SUCCESS
}
