#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod agent;
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

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "warn,cloak_installer=info".into()),
        )
        .init();

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
