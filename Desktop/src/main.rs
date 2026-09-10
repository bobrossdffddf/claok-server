#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod agent;
mod anisette;
mod assets;
mod config;
mod device;
mod handoff;
mod state;
mod ui;
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

    let ipa = find_ipa(args.ipa);

    if args.refresh {
        let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
        return match runtime.block_on(worker::refresh_now(ipa, args.force)) {
            Ok(()) => Ok(()),
            Err(message) => {
                eprintln!("{message}");
                std::process::exit(1);
            }
        };
    }

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
    Ok(())
}
