//! A terminal front end, for Linux and Chromebooks where the window either
//! will not draw or is not wanted.
//!
//! It drives exactly the same background worker the window does, so nothing
//! about signing, pairing or installing changes: only how questions are asked
//! and answers read. Everything runs from a Crostini shell on a managed
//! Chromebook with no admin rights.

use std::io::{BufRead, Write};
use std::path::PathBuf;

use crate::worker::{self, Command, Event};

pub fn run(ipa: PathBuf) -> i32 {
    println!("\nCloak Installer (terminal)\n");

    // A private, user-owned iPhone driver if the machine has none. Needs no
    // root and cleans itself up when this exits.
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("Could not start: {error}");
            return 1;
        }
    };
    if let Err(message) = runtime.block_on(crate::usbmux::ensure_available()) {
        eprintln!("{message}\n\n{}", crate::usbmux::advice());
        return 1;
    }
    drop(runtime);

    let mut channels = worker::spawn(ipa);
    let commands = channels.commands.clone();

    println!("Looking for an iPhone...");
    let _ = commands.send(Command::Scan);

    let mut asked_for_login = false;

    while let Some(event) = channels.events.blocking_recv() {
        match event {
            Event::DriverMissing => {
                eprintln!("\nNo iPhone driver is reachable.\n{}", crate::usbmux::advice());
                return 1;
            }
            Event::Phones(found) => {
                let phones = found;
                if phones.is_empty() {
                    eprintln!("\nNo iPhone found. Plug it in with a cable, unlock it, and tap Trust if asked. Then run this again.");
                    return 1;
                }
                let phone = match pick_phone(&phones) {
                    Some(phone) => phone,
                    None => return 1,
                };
                if !phone.trusted {
                    eprintln!("\n{} has not trusted this computer yet. Unlock it, tap Trust on the phone, then run this again.", phone.name);
                    return 1;
                }
                println!("\nUsing {} (iOS {}).", phone.name, phone.ios_version);

                if worker::developer_mode_ok(phone) {
                    begin_login(&commands, phone, &mut asked_for_login);
                } else {
                    println!("\nDeveloper Mode needs turning on. Cloak will do it; the phone will restart.");
                    println!("When it comes back, unlock it and answer the \"Turn on Developer Mode?\" prompt, then run this installer again.");
                    let _ = commands.send(Command::EnableDeveloperMode { udid: phone.udid.clone() });
                }
            }
            Event::DeveloperModeRevealed => {
                println!("The Developer Mode switch is now visible in Settings > Privacy & Security.");
            }
            Event::DeveloperModeManual => {
                println!("\nTurn Developer Mode on yourself: Settings > Privacy & Security > Developer Mode, switch it on, let the phone restart, then run this installer again.");
                return 0;
            }
            Event::Rebooting => {
                println!("The phone is restarting to turn Developer Mode on. Run this installer again once it is back and unlocked.");
                return 0;
            }
            Event::Status(text) => {
                if !text.is_empty() { println!("  {text}"); }
            }
            Event::Diagnosis(text) => println!("\n{text}"),
            Event::Progress(fraction) => print_bar(fraction),
            Event::NeedTwoFactor(params) => {
                let prompt = if params.sms {
                    "\nApple texted you a verification code. Enter it: "
                } else {
                    "\nApple sent a code to your other Apple devices. Enter it: "
                };
                match prompt_line(prompt) {
                    Some(code) if !code.trim().is_empty() => {
                        let _ = commands.send(Command::TwoFactor(
                            isideload::auth::apple_account::TwoFactorCallbackResponse::SubmitCode(code.trim().to_string()),
                        ));
                    }
                    _ => {
                        let _ = commands.send(Command::TwoFactor(
                            isideload::auth::apple_account::TwoFactorCallbackResponse::Abort,
                        ));
                        eprintln!("No code entered. Stopping.");
                        return 1;
                    }
                }
            }
            Event::NeedPairingPin => {
                match prompt_line("\nType the six digit code shown on the iPhone: ") {
                    Some(pin) => { let _ = commands.send(Command::PairingPin(pin.trim().to_string())); }
                    None => return 1,
                }
            }
            Event::Trusted(true) => println!("  iOS trusted the signature automatically."),
            Event::Trusted(false) => {
                println!("\nOne last step, on the phone: Settings > General > VPN & Device Management, tap your Apple ID under Developer App, and Trust it.");
            }
            Event::Installed => {
                println!("\nDone. Cloak is on your iPhone. Open it and follow the setup there.");
                println!("It re-signs itself every seven days from the phone, so you do not need this computer again.");
                return 0;
            }
            Event::Failed(message) => {
                eprintln!("\n{message}");
                return 1;
            }
        }

    }

    1
}

fn pick_phone(phones: &[crate::device::Phone]) -> Option<&crate::device::Phone> {
    if phones.len() == 1 {
        return phones.first();
    }
    println!("\nMore than one iPhone is plugged in:");
    for (index, phone) in phones.iter().enumerate() {
        println!("  {}) {} (iOS {})", index + 1, phone.name, phone.ios_version);
    }
    let answer = prompt_line("Which one? ")?;
    let index: usize = answer.trim().parse().ok()?;
    phones.get(index.checked_sub(1)?)
}

fn begin_login(commands: &tokio::sync::mpsc::UnboundedSender<Command>, phone: &crate::device::Phone, asked: &mut bool) {
    if *asked {
        return;
    }
    *asked = true;

    println!("\nSign in with your Apple ID. A free one is fine.");
    println!("Cloak uses it only to sign the app with Apple, the same way Xcode would. Nothing is sent anywhere else.\n");

    let apple_id = prompt_line("Apple ID email: ").unwrap_or_default();
    let password = prompt_password("Password: ").unwrap_or_default();
    if apple_id.trim().is_empty() || password.is_empty() {
        eprintln!("An Apple ID and password are needed. Stopping.");
        std::process::exit(1);
    }

    let _ = commands.send(Command::Install {
        udid: phone.udid.clone(),
        apple_id: apple_id.trim().to_string(),
        password,
        remember: false,
    });
}

fn prompt_line(prompt: &str) -> Option<String> {
    print!("{prompt}");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    match std::io::stdin().lock().read_line(&mut line) {
        Ok(0) | Err(_) => None,
        Ok(_) => Some(line.trim_end_matches(['\n', '\r']).to_string()),
    }
}

/// Reads a password without echoing it where the terminal allows it, and falls
/// back to a plain read where it does not (a Crostini pipe, say).
fn prompt_password(prompt: &str) -> Option<String> {
    print!("{prompt}");
    let _ = std::io::stdout().flush();

    #[cfg(unix)]
    {
        if let Some(value) = read_password_noecho() {
            println!();
            return Some(value);
        }
    }
    prompt_line("")
}

#[cfg(unix)]
fn read_password_noecho() -> Option<String> {
    use std::os::unix::io::AsRawFd;
    let fd = std::io::stdin().as_raw_fd();
    unsafe {
        let mut term: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(fd, &mut term) != 0 {
            return None;
        }
        let original = term;
        term.c_lflag &= !libc::ECHO;
        if libc::tcsetattr(fd, libc::TCSANOW, &term) != 0 {
            return None;
        }
        let mut line = String::new();
        let result = std::io::stdin().lock().read_line(&mut line);
        libc::tcsetattr(fd, libc::TCSANOW, &original);
        match result {
            Ok(0) | Err(_) => None,
            Ok(_) => Some(line.trim_end_matches(['\n', '\r']).to_string()),
        }
    }
}

fn print_bar(fraction: f32) {
    let width = 28usize;
    let filled = ((fraction.clamp(0.0, 1.0)) * width as f32).round() as usize;
    let bar: String = std::iter::repeat('#').take(filled)
        .chain(std::iter::repeat('-').take(width - filled))
        .collect();
    print!("\r  [{bar}] {:>3.0}%", fraction * 100.0);
    if fraction >= 1.0 {
        println!();
    }
    let _ = std::io::stdout().flush();
}
