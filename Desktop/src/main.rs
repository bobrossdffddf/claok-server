#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod agent;
mod anisette;
#[cfg(feature = "gui")]
mod assets;
mod config;
mod device;
mod handoff;
mod rppair;
mod cli;
mod state;
#[cfg(feature = "gui")] mod theme;
#[cfg(feature = "gui")]
mod ui;
mod usbmux;
#[cfg(feature = "gui")]
mod viz;
mod worker;

use std::path::PathBuf;

use clap::Parser;

#[derive(Parser)]
#[command(name = "Cloak Installer", version, about = "Puts Cloak on your iPhone and keeps it there.")]
struct Args {
    /// Renew the signature if it is close to running out, then quit. This is
    /// what the daily scheduled job runs; there is no window.
    #[arg(long)]
    refresh: bool,

    /// Renew whether or not it looks necessary.
    #[arg(long)]
    force: bool,

    /// Use a Cloak app file from somewhere other than next to this program.
    #[arg(long)]
    ipa: Option<PathBuf>,

    /// Run in the terminal instead of opening a window. This is the default on
    /// Linux, and what a Chromebook uses.
    #[arg(long)]
    cli: bool,

    /// Print everything about why a phone will or will not talk, and stop.
    #[arg(long)]
    doctor: bool,
}

/// Where Cloak.ipa lives.
///
/// On a Mac the installer is an app bundle and the payload sits in Resources.
/// On Windows it is a folder with an exe in it. Both are covered, and a
/// `--ipa` flag covers everything else.
fn find_ipa(override_path: Option<PathBuf>) -> PathBuf {
    if let Some(path) = override_path {
        return path;
    }
    let exe = std::env::current_exe().unwrap_or_default();
    let dir = exe.parent().map(PathBuf::from).unwrap_or_default();

    let candidates = [
        dir.join("Cloak.ipa"),
        dir.join("../Resources/Cloak.ipa"),
        dir.join("Resources/Cloak.ipa"),
        PathBuf::from("Cloak.ipa"),
    ];
    for candidate in candidates {
        if candidate.exists() {
            return candidate;
        }
    }
    dir.join("Cloak.ipa")
}

/// Where the running log goes. Finder launched apps have no terminal, so
/// without this there is nowhere for a failure to be read back from.
pub fn log_file_path() -> std::path::PathBuf {
    let base = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let dir = base.join("Library").join("Logs").join("Cloak");
    let _ = std::fs::create_dir_all(&dir);
    dir.join("installer.log")
}

/// Appends to the log file on every write. The volume is a few lines per
/// install, so reopening each time costs nothing and keeps the file readable
/// even if the app is force quit.
struct LogSink(std::path::PathBuf);

impl std::io::Write for LogSink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.0)?;
        file.write_all(buf)?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    let log_path = log_file_path();
    tracing_subscriber::fmt()
        .with_ansi(false)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "warn,cloak_installer=info".into()),
        )
        .with_writer(move || LogSink(log_path.clone()))
        .init();
    tracing::info!("Cloak Installer {} starting", env!("CARGO_PKG_VERSION"));
    tracing::warn!("build marker: living-cover v1");

    let ipa = find_ipa(args.ipa);

    if args.doctor {
        let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
        println!("{}", runtime.block_on(device::doctor()));
        return Ok(());
    }

    if args.refresh {
        let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
        return match runtime.block_on(worker::refresh_now(ipa, args.force)) {
            Ok(()) => Ok(()),
            Err(message) => {
                eprintln!("{message}");
                tracing::error!("scheduled renewal failed: {message}");
                // Nobody is watching a launchd job. Say so where they will see
                // it, or the first sign is Cloak refusing to open in a week.
                #[cfg(target_os = "macos")]
                {
                    let text = format!(
                        "Cloak could not renew itself: {}. Open Cloak Installer with the phone plugged in.",
                        message.replace('"', "'")
                    );
                    let _ = std::process::Command::new("osascript")
                        .arg("-e")
                        .arg(format!("display notification \"{text}\" with title \"Cloak\""))
                        .status();
                }
                std::process::exit(1);
            }
        };
    }

    // No window on Linux, and none when asked for, or when the GUI was not
    // built into this binary at all (the portable Linux build).
    let headless = args.cli || cfg!(target_os = "linux") || cfg!(not(feature = "gui"));
    if headless {
        std::process::exit(cli::run(ipa));
    }

    #[cfg(feature = "gui")]
    {
        let channels = worker::spawn(ipa);
        let options = eframe::NativeOptions {
            viewport: egui::ViewportBuilder::default()
                .with_inner_size([840.0, 620.0])
                .with_min_inner_size([780.0, 560.0])
                .with_title("Cloak Installer"),
            ..Default::default()
        };
        eframe::run_native(
            "Cloak Installer",
            options,
            Box::new(|cc| Ok(Box::new(ui::Installer::new(channels, cc)))),
        )?;
    }
    Ok(())
}
