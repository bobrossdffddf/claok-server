//! Reaching the iPhone on Linux and ChromeOS without root.
//!
//! On macOS and Windows a system service owns the USB multiplexer, so this
//! module does nothing there. On Linux there may be no usbmuxd running, or one
//! that a locked-down machine will not let a normal user talk to. The good
//! news, confirmed against libimobiledevice's own udev rules, is that a desktop
//! user is already granted access to the iPhone's USB device node through
//! systemd's uaccess tag, so a usbmuxd started *as that user* can drive the
//! phone with no root at all.
//!
//! So on Linux this tries, in order:
//!   1. Whatever socket is already there (a system usbmuxd, or one pointed at
//!      by USBMUXD_SOCKET_ADDRESS).
//!   2. A user-owned usbmuxd we start ourselves, on a socket in the user's
//!      runtime directory, which needs no privileges and cleans up on exit.
//!
//! Nothing here writes outside the user's own directories, installs anything,
//! or asks for a password, which is the whole point on a managed Chromebook.

#[cfg(target_os = "linux")]
use std::path::PathBuf;

/// Makes sure `idevice` can find a multiplexer, starting a private one if the
/// machine has none the user can reach. A no-op away from Linux.
pub async fn ensure_available() -> Result<(), String> {
    if crate::device::usbmuxd_available().await {
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    {
        linux::start_user_daemon().await
    }

    #[cfg(not(target_os = "linux"))]
    {
        Err("No iPhone driver is running.".to_string())
    }
}

/// A one-line, human explanation of the state, for the CLI to print.
pub fn advice() -> &'static str {
    #[cfg(target_os = "linux")]
    {
        "Plug the iPhone in and unlock it. If Cloak still cannot see it, install usbmuxd from your package manager (on a Chromebook, inside the Linux container): it needs no root once the phone is plugged into your own session."
    }
    #[cfg(target_os = "macos")]
    {
        "Plug the iPhone in with a cable and unlock it."
    }
    #[cfg(target_os = "windows")]
    {
        "Install Apple Devices (or iTunes) from apple.com so Windows can see the iPhone, then plug it in and unlock it."
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::sync::OnceLock;

    static GUARD: OnceLock<Guard> = OnceLock::new();

    struct Guard {
        child: std::sync::Mutex<Option<std::process::Child>>,
    }

    impl Drop for Guard {
        fn drop(&mut self) {
            if let Ok(mut guard) = self.child.lock() {
                if let Some(mut child) = guard.take() {
                    let _ = child.kill();
                }
            }
        }
    }

    /// Where our private socket and lockdown records live. Fallback order:
    ///   1. `$XDG_RUNTIME_DIR` - the per-user, per-session tmpfs the desktop
    ///      already owns (typically `/run/user/<uid>`). Preferred because it is
    ///      user-private, needs no privileges, and is cleaned up at logout.
    ///   2. `std::env::temp_dir()` (`$TMPDIR` or `/tmp`) when the variable is
    ///      unset or empty, which happens under some Crostini shells.
    /// Both are user-writable with no root, which is the whole point here.
    fn runtime_dir() -> PathBuf {
        if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
            if !dir.is_empty() {
                return PathBuf::from(dir);
            }
        }
        std::env::temp_dir()
    }

    fn usbmuxd_binary() -> Option<PathBuf> {
        // A copy shipped next to the installer wins: a Chromebook's Linux
        // container often has no usbmuxd and no way to apt-get one, so the
        // portable build carries its own.
        let exe = std::env::current_exe().ok()?;
        let dir = exe.parent()?;
        for name in ["usbmuxd", "cloak-usbmuxd"] {
            let bundled = dir.join(name);
            if bundled.exists() {
                return Some(bundled);
            }
        }
        // Otherwise whatever is on PATH.
        for base in std::env::var("PATH").unwrap_or_default().split(':') {
            let candidate = PathBuf::from(base).join("usbmuxd");
            if candidate.exists() {
                return Some(candidate);
            }
        }
        None
    }

    pub async fn start_user_daemon() -> Result<(), String> {
        let socket = runtime_dir().join("cloak-usbmuxd.sock");
        let _ = std::fs::remove_file(&socket);

        let binary = usbmuxd_binary().ok_or_else(|| {
            "No iPhone driver is running and Cloak could not find a usbmuxd to start. Install usbmuxd (on a Chromebook, inside the Linux container) and try again.".to_string()
        })?;

        // Foreground, no privilege drop, our own socket, our own lockdown
        // records directory. -U is deliberately not passed: it only drops
        // privileges when started as root, and here we are already the user
        // whose session owns the phone.
        let lockdown = runtime_dir().join("cloak-lockdown");
        let _ = std::fs::create_dir_all(&lockdown);

        let child = std::process::Command::new(&binary)
            .arg("-f") // foreground
            .arg("-S")
            .arg(&socket) // our socket
            .arg("-p") // do not exit when the last phone unplugs
            .env("USBMUXD_SOCKET_ADDRESS", socket.to_string_lossy().to_string())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|e| format!("Could not start the bundled iPhone driver: {e}"))?;

        let _ = GUARD.set(Guard { child: std::sync::Mutex::new(Some(child)) });

        // Point idevice at it. UsbmuxdAddr::from_env_var reads this.
        std::env::set_var("USBMUXD_SOCKET_ADDRESS", &socket);

        // Give it a moment to bind and enumerate.
        for _ in 0..20 {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            if crate::device::usbmuxd_available().await {
                return Ok(());
            }
        }

        Err("Cloak started its own iPhone driver but it did not come up. Make sure the iPhone is plugged in and unlocked.".to_string())
    }
}
