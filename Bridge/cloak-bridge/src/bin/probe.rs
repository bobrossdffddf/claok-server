use std::net::IpAddr;
use std::process::ExitCode;

use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, TcpProvider};
use idevice::services::lockdown::LockdownClient;
use idevice::usbmuxd::{UsbmuxdAddr, UsbmuxdConnection};
use idevice::IdeviceService;

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: probe <pairing.plist> <ip>");
        return ExitCode::from(2);
    }

    let bytes = match std::fs::read(&args[1]) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("cannot read pairing file: {error}");
            return ExitCode::from(3);
        }
    };

    let pairing = match PairingFile::from_bytes(&bytes) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("cannot parse pairing file: {error:?}");
            return ExitCode::from(4);
        }
    };

    println!("pairing parsed");
    println!("  host_id       {}", pairing.host_id);
    println!("  system_buid   {}", pairing.system_buid);
    println!("  udid          {:?}", pairing.udid);
    println!("  wifi mac      {}", pairing.wifi_mac_address);
    println!("  escrow bag    {:?} bytes", pairing.escrow_bag.as_ref().map(|b| b.len()));
    println!("  host key      {} bytes", pairing.host_private_key.len());
    println!("  root key      {} bytes", pairing.root_private_key.len());

    let target = args[2].clone();
    let provider: Box<dyn IdeviceProvider> = if target == "usb" {
        let mut mux = match UsbmuxdConnection::default().await {
            Ok(value) => value,
            Err(error) => {
                println!("usbmuxd unreachable {error:?}");
                return ExitCode::from(5);
            }
        };
        let devices = match mux.get_devices().await {
            Ok(value) => value,
            Err(error) => {
                println!("usbmuxd device list failed {error:?}");
                return ExitCode::from(5);
            }
        };
        let Some(device) = devices.first() else {
            println!("no device on usb");
            return ExitCode::from(5);
        };
        println!("\nusing usbmux for {}", device.udid);
        Box::new(device.to_provider(UsbmuxdAddr::default(), "CloakProbe"))
    } else {
        let addr: IpAddr = match target.parse() {
            Ok(value) => value,
            Err(error) => {
                eprintln!("bad ip: {error}");
                return ExitCode::from(5);
            }
        };
        println!("\nconnecting to {addr}:62078");
        Box::new(TcpProvider {
            addr,
            scope_id: None,
            pairing_file: pairing.clone(),
            label: "CloakProbe".to_string(),
        })
    };

    let mut lockdown = match LockdownClient::connect(provider.as_ref()).await {
        Ok(value) => value,
        Err(error) => {
            println!("CONNECT FAILED {error:?}");
            return ExitCode::from(6);
        }
    };
    println!("connected");

    match lockdown.idevice.get_type().await {
        Ok(value) => println!("QueryType = {value}"),
        Err(error) => println!("QUERYTYPE FAILED {error:?}"),
    }

    match lockdown.get_value(Some("ProductVersion"), None).await {
        Ok(value) => println!("plain get_value ProductVersion = {value:?}"),
        Err(error) => {
            println!("PLAIN GET_VALUE FAILED {error:?}");
            return ExitCode::from(7);
        }
    }

    match lockdown.start_session(&pairing).await {
        Ok(value) => println!("start_session OK, ssl={value}"),
        Err(error) => {
            println!("START_SESSION FAILED {error:?}");
            return ExitCode::from(8);
        }
    }

    match lockdown.get_value(Some("UniqueChipID"), None).await {
        Ok(value) => println!("session get_value UniqueChipID = {value:?}"),
        Err(error) => println!("session get_value failed {error:?}"),
    }

    ExitCode::SUCCESS
}
