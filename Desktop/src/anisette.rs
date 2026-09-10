//! Choosing an Apple sign-in helper.
//!
//! Apple will not accept a sign-in without a set of device-identity headers
//! that only a real Mac can generate. Everyone doing this uses a shared public
//! server, an "anisette" server, to produce them, and the signing library
//! points at exactly one of those with no way to change it.
//!
//! That single point of failure took down every copy of Cloak at once, and
//! other apps in the same position along with it, because they all lean on the
//! same handful of volunteer-run servers. When one of them stops answering, or
//! starts answering with data Apple rejects, Apple returns a 503 and the whole
//! sign-in dies with an error that has nothing to do with the person's account.
//!
//! So: a list rather than one address. Try them in turn, remember the one that
//! worked, and let it be set by hand when none of the built-in ones do.

use std::time::Duration;

use crate::config::Config;

/// Where the community keeps its list. Fetched when it can be, so a server
/// that appears after this build shipped is still usable.
const DIRECTORY: &str = "https://servers.sidestore.io/servers.json";

/// Known servers, in the order they are worth trying.
///
/// The first is the signing library's own default, kept at the front because
/// when it is healthy it is the best tested. The rest come from SideStore's
/// maintained list, which exists for exactly this reason.
pub const KNOWN: &[&str] = &[
    "https://ani.stikstore.app",
    "https://ani.sidestore.io",
    "https://ani.sidestore.app",
    "https://ani.846969.xyz",
    "https://ani.npeg.us",
    "https://anisette.wedotstud.io",
    "https://ani.neoarz.com",
    "https://ani.idevicehacked.com",
];

/// Every server worth trying, best first.
///
/// A server set by hand wins outright: somebody who has gone looking for one
/// has a reason. After that comes whichever worked last time, because a server
/// that answered an hour ago will probably answer now, and then the rest.
pub fn candidates(config: &Config) -> Vec<String> {
    let mut list: Vec<String> = Vec::new();

    let mut push = |value: &str| {
        let trimmed = value.trim().trim_end_matches('/').to_string();
        if !trimmed.is_empty() && !list.contains(&trimmed) {
            list.push(trimmed);
        }
    };

    if let Some(chosen) = config.anisette_url.as_deref() {
        push(chosen);
        // An explicit choice is a choice. Falling through to the built-in list
        // behind somebody's back would hide the fact that theirs is broken.
        return list;
    }

    if let Some(last) = config.anisette_last_good.as_deref() {
        push(last);
    }
    for server in KNOWN {
        push(server);
    }
    list
}

/// Whether a server is answering with data Apple might accept.
///
/// Reachability is not enough. A server can be up and still be handing out
/// nothing usable, which is the failure that looks like a wrong password.
/// The `X-Apple-I-MD-M` field is the machine identity itself, so its presence
/// is the difference between a working helper and a web server.
pub async fn healthy(url: &str, client: &reqwest::Client) -> bool {
    let response = match client
        .get(format!("{url}/"))
        .timeout(Duration::from_secs(8))
        .send()
        .await
    {
        Ok(response) => response,
        Err(error) => {
            tracing::info!("anisette {url}: {error}");
            return false;
        }
    };

    if !response.status().is_success() {
        tracing::info!("anisette {url}: HTTP {}", response.status());
        return false;
    }

    match response.text().await {
        Ok(body) => {
            let ok = body.contains("X-Apple-I-MD-M");
            if !ok {
                tracing::info!("anisette {url}: answered, but with nothing usable");
            }
            ok
        }
        Err(_) => false,
    }
}

/// Adds any servers the community has published since this build.
///
/// Entirely optional. The built-in list is enough to sign in, and this only
/// widens it, so a failure here is not worth mentioning to anybody.
pub async fn merge_published(list: &mut Vec<String>, client: &reqwest::Client) {
    #[derive(serde::Deserialize)]
    struct Directory {
        servers: Vec<Entry>,
    }
    #[derive(serde::Deserialize)]
    struct Entry {
        address: String,
    }

    let fetched = client
        .get(DIRECTORY)
        .timeout(Duration::from_secs(6))
        .send()
        .await
        .ok();

    let Some(response) = fetched else { return };
    let Ok(directory) = response.json::<Directory>().await else {
        return;
    };

    for entry in directory.servers {
        // Plain http servers are on that list. Apple credentials are not going
        // anywhere near one.
        if !entry.address.starts_with("https://") {
            continue;
        }
        let trimmed = entry.address.trim_end_matches('/').to_string();
        if !list.contains(&trimmed) {
            list.push(trimmed);
        }
    }
}

/// The first server that is actually serving usable data.
///
/// Returns the list it tried alongside, so a total failure can say what was
/// attempted rather than just that something went wrong.
pub async fn pick(config: &Config) -> Result<String, Vec<String>> {
    let client = match reqwest::Client::builder()
        .user_agent("Cloak Installer")
        .build()
    {
        Ok(client) => client,
        Err(_) => return Err(candidates(config)),
    };

    let mut list = candidates(config);
    if config.anisette_url.is_none() {
        merge_published(&mut list, &client).await;
    }

    for url in &list {
        if healthy(url, &client).await {
            tracing::info!("using anisette server {url}");
            return Ok(url.clone());
        }
    }

    tracing::warn!("no anisette server answered out of {}", list.len());
    Err(list)
}

/// What to tell somebody when every one of them is down.
pub fn none_available(tried: &[String]) -> String {
    format!(
        "Apple's sign-in helpers are not answering.\n\nSigning in needs one of these to \
         produce the identity Apple asks for. Cloak tried {} of them and none replied with \
         anything usable, which usually means they are having an outage rather than anything \
         being wrong at your end. Other apps that sideload will be failing at the same time.\n\n\
         Waiting an hour normally fixes it. If you know of a working one, put it in the box \
         under \"Sign-in helper\" on the previous screen.",
        tried.len()
    )
}

// MARK: - The identity Apple is shown

/// A helper provider whose client identity can be changed.
///
/// Apple is told what kind of machine is asking, in a single header that names
/// a Mac model, a macOS build and an Xcode version. The signing library has one
/// of those strings compiled into it with no way to set it, and when Apple
/// stopped accepting that exact string every tool sharing it stopped working
/// the same morning. Nothing was wrong with anybody's account.
///
/// This wraps the real provider and passes everything through untouched except
/// that one field, so the value can be changed from the settings box without
/// waiting for a new build of Cloak, let alone a new release of the library.
pub struct Identified {
    inner: isideload::anisette::remote_v3::RemoteV3AnisetteProvider,
    client_info: Option<String>,
}

impl Identified {
    pub fn new(
        inner: isideload::anisette::remote_v3::RemoteV3AnisetteProvider,
        client_info: Option<String>,
    ) -> Self {
        Self { inner, client_info }
    }
}

#[async_trait::async_trait]
impl isideload::anisette::AnisetteProvider for Identified {
    async fn get_anisette_data(
        &self,
    ) -> Result<isideload::anisette::AnisetteData, rootcause::prelude::Report> {
        self.inner.get_anisette_data().await
    }

    async fn get_client_info(
        &self,
    ) -> Result<isideload::anisette::AnisetteClientInfo, rootcause::prelude::Report> {
        let mut info = self.inner.get_client_info().await?;
        if let Some(override_value) = &self.client_info {
            let trimmed = override_value.trim();
            if !trimmed.is_empty() {
                info.client_info = trimmed.to_string();
            }
        }
        Ok(info)
    }

    async fn provision(
        &mut self,
        gs: std::sync::Arc<isideload::auth::grandslam::GrandSlam>,
    ) -> Result<(), rootcause::prelude::Report> {
        self.inner.provision(gs).await
    }

    fn needs_provisioning(&self) -> Result<bool, rootcause::prelude::Report> {
        self.inner.needs_provisioning()
    }
}

// MARK: - Telling Apple the truth

/// The identity of the machine this is actually running on.
///
/// The string Apple is shown names a Mac model, a macOS build and an Xcode
/// version. The signing library has one compiled in, so every install of every
/// tool built on it sends the same three values, which is precisely what makes
/// them easy to refuse in one go: block that string and the whole ecosystem
/// stops at once, which is what happened.
///
/// A Mac already knows its own answers, and they are true. Reading them means
/// no two machines send the same thing, and there is nothing shared left to
/// block. On Windows there is no Mac to ask, so the library's own value stands
/// and the box on the sign-in screen is the way out.
#[cfg(target_os = "macos")]
pub fn host_client_info() -> Option<String> {
    fn ask(program: &str, args: &[&str]) -> Option<String> {
        let output = std::process::Command::new(program).args(args).output().ok()?;
        if !output.status.success() {
            return None;
        }
        let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if value.is_empty() { None } else { Some(value) }
    }

    let model = ask("sysctl", &["-n", "hw.model"])?;
    let version = ask("sw_vers", &["-productVersion"])?;
    let build = ask("sw_vers", &["-buildVersion"])?;

    // Xcode's own build number, which is what the Xcode part of the string is.
    // Not being installed is normal and not a reason to give up on the rest.
    let xcode = xcode_build().unwrap_or_else(|| "24959".to_string());

    Some(format!(
        "<{model}> <macOS;{version};{build}> <com.apple.AuthKit/1 (com.apple.dt.Xcode/{xcode})>"
    ))
}

#[cfg(target_os = "macos")]
fn xcode_build() -> Option<String> {
    let candidates = [
        "/Applications/Xcode.app/Contents/version.plist",
        "/Applications/Xcode-beta.app/Contents/version.plist",
    ];
    for path in candidates {
        let Ok(value) = plist::from_file::<_, plist::Value>(path) else {
            continue;
        };
        let dictionary = value.as_dictionary()?;
        if let Some(build) = dictionary.get("CFBundleVersion") {
            if let Some(text) = build.as_string() {
                return Some(text.to_string());
            }
            if let Some(number) = build.as_signed_integer() {
                return Some(number.to_string());
            }
        }
    }
    None
}

#[cfg(not(target_os = "macos"))]
pub fn host_client_info() -> Option<String> {
    None
}

/// What Apple will be told, given what has been configured.
pub fn client_info(config: &Config) -> Option<String> {
    if let Some(chosen) = config.client_info.as_deref() {
        let trimmed = chosen.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    host_client_info()
}
