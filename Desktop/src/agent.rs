//! Keeping Cloak alive.
//!
//! A free Apple ID signs an app for seven days. After that iOS refuses to
//! launch it until it has been signed again. Nobody wants to remember to do
//! that, so the installer asks the operating system to do it: a launchd agent
//! on a Mac, a scheduled task on Windows. Both run this same program once a
//! day with `--refresh`, and it does nothing at all unless the signature is
//! within two days of running out.

use std::path::PathBuf;

pub fn executable() -> PathBuf {
    std::env::current_exe().unwrap_or_else(|_| PathBuf::from("cloak-installer"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Schedule {
    Installed,
    NotInstalled,
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;

    const LABEL: &str = "app.cloak.installer.refresh";

    fn plist_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_default();
        PathBuf::from(home).join(format!("Library/LaunchAgents/{LABEL}.plist"))
    }

    pub fn status() -> Schedule {
        if plist_path().exists() { Schedule::Installed } else { Schedule::NotInstalled }
    }

    pub fn install() -> Result<(), String> {
        let path = plist_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }

        let exe = executable();
        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{}</string>
        <string>--refresh</string>
    </array>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
"#,
            exe.display()
        );

        std::fs::write(&path, plist).map_err(|e| e.to_string())?;

        let _ = std::process::Command::new("launchctl")
            .args(["unload", &path.to_string_lossy()])
            .output();
        std::process::Command::new("launchctl")
            .args(["load", &path.to_string_lossy()])
            .output()
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn remove() -> Result<(), String> {
        let path = plist_path();
        let _ = std::process::Command::new("launchctl")
            .args(["unload", &path.to_string_lossy()])
            .output();
        let _ = std::fs::remove_file(&path);
        Ok(())
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use super::*;

    const TASK: &str = "Cloak Refresh";

    pub fn status() -> Schedule {
        let output = std::process::Command::new("schtasks")
            .args(["/Query", "/TN", TASK])
            .output();
        match output {
            Ok(out) if out.status.success() => Schedule::Installed,
            _ => Schedule::NotInstalled,
        }
    }

    pub fn install() -> Result<(), String> {
        let exe = executable();
        let command = format!("\"{}\" --refresh", exe.display());
        let output = std::process::Command::new("schtasks")
            .args([
                "/Create", "/F",
                "/TN", TASK,
                "/TR", &command,
                "/SC", "HOURLY",
                "/MO", "6",
            ])
            .output()
            .map_err(|e| e.to_string())?;
        if output.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
        }
    }

    pub fn remove() -> Result<(), String> {
        let _ = std::process::Command::new("schtasks")
            .args(["/Delete", "/F", "/TN", TASK])
            .output();
        Ok(())
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
mod platform {
    use super::*;
    pub fn status() -> Schedule { Schedule::NotInstalled }
    pub fn install() -> Result<(), String> { Err("Automatic renewal is only set up on macOS and Windows.".into()) }
    pub fn remove() -> Result<(), String> { Ok(()) }
}

pub use platform::{install, remove, status};
