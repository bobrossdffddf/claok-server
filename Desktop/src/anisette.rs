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
    // SideStore's maintained list comes first. The signing library's own
    // default, ani.stikstore.app, is deliberately last: it is not on that list
    // and its trust key is the one Apple invalidated, so leading with it means
    // every install fails before anything else gets a turn.
    "https://ani.sidestore.io",
    "https://ani.sidestore.app",
    "https://ani.sidestore.zip",
    "https://ani.846969.xyz",
    "https://ani.npeg.us",
    "https://anisette.wedotstud.io",
    "https://ani.neoarz.com",
    "https://ani.idevicehacked.com",
    "https://ani.xu30.top",
    "https://ani.owoellen.rocks",
    "https://ani.jaydenha.uk",
    "https://ani3server.fly.dev",
    "https://ani.stikstore.app",
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

    drop(push);

    // A helper Apple has refused to provision against is not coming back
    // within this run, and probably not today either. Unless that leaves
    // nothing at all, in which case trying a rejected one beats trying none.
    let filtered: Vec<String> = list
        .iter()
        .filter(|entry| !config.anisette_rejected.iter().any(|bad| bad == *entry))
        .cloned()
        .collect();

    if filtered.is_empty() { list } else { filtered }
}

/// Remembers that Apple would not provision against this one.
pub fn remember_rejected(url: &str) {
    let mut config = Config::load();
    let entry = url.trim_end_matches('/').to_string();
    if config.anisette_rejected.contains(&entry) {
        return;
    }
    config.anisette_rejected.push(entry);
    // Not a permanent blacklist. These come back when whoever runs them
    // re-provisions, so the list is trimmed rather than grown forever.
    while config.anisette_rejected.len() > 8 {
        config.anisette_rejected.remove(0);
    }
    if config.anisette_last_good.as_deref() == Some(url) {
        config.anisette_last_good = None;
    }
    config.save();
}

/// Every healthy helper, in order, so a run can work down the list.
///
/// Probed in waves rather than one at a time. These are a dozen independent
/// servers and asking them in turn meant a single slow one held up the whole
/// sign-in; run together, the wave costs what its slowest member costs. The
/// order of the answers is still the order of the list, because the preference
/// built into that order is the point of having one.
pub async fn healthy_candidates(config: &Config) -> Vec<String> {
    let Ok(client) = reqwest::Client::builder()
        .user_agent("Cloak Installer")
        .build()
    else {
        return candidates(config);
    };

    let mut list = candidates(config);
    if config.anisette_url.is_none() {
        merge_published(&mut list, &client).await;
    }

    let mut answering: Vec<String> = Vec::new();
    for wave in list.chunks(WAVE) {
        let probes: Vec<_> = wave
            .iter()
            .map(|url| {
                let client = client.clone();
                let url = url.clone();
                tokio::spawn(async move { healthy(&url, &client).await.then_some(url) })
            })
            .collect();
        for probe in probes {
            if let Ok(Some(url)) = probe.await {
                answering.push(url);
            }
        }

        // Enough to work down if the first one disappoints, which is all the
        // rest of the list is ever used for. Probing the remainder buys
        // nothing and costs everybody's time.
        if answering.len() >= ENOUGH {
            break;
        }
    }
    answering
}

/// How many helpers are probed at once.
const WAVE: usize = 6;

/// How many working helpers is enough to stop looking.
const ENOUGH: usize = 3;

/// Whether a server is answering with data Apple might accept.
///
/// Reachability is not enough, and neither is the front page. What matters is
/// the one endpoint the sign-in actually depends on: the one that mints the
/// machine identity. These are volunteer-run servers and that endpoint fails
/// on its own, returning 502 while everything else about the server looks
/// perfectly healthy, which is exactly the case that used to sink a sign-in
/// after a helper had already been chosen.
///
/// So this asks for headers the same way the sign-in will. A server that
/// cannot answer that is not a candidate, however well it serves its homepage.
pub async fn healthy(url: &str, client: &reqwest::Client) -> bool {
    let probe = client
        .post(format!("{url}/v3/get_headers"))
        .header("Content-Type", "application/json")
        .body(r#"{"identifier":"AAAAAAAAAAAAAAAAAAAAAA=="}"#)
        .timeout(Duration::from_secs(5))
        .send()
        .await;

    match probe {
        Ok(response) if response.status().is_success() => return true,
        Ok(response) => {
            tracing::info!("anisette {url}: headers endpoint answered HTTP {}", response.status());
        }
        Err(error) => {
            // Nothing answered at all, so there is no older dialect to fall
            // back to and asking twice only doubles the wait.
            tracing::info!("anisette {url}: headers endpoint {error}");
            return false;
        }
    }

    // Older servers predate that endpoint and still work, so they get the
    // original check rather than being dropped for speaking an older dialect.
    let response = match client
        .get(format!("{url}/"))
        .timeout(Duration::from_secs(5))
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

/// Whether the helper broke rather than Apple refusing anything.
///
/// A failure whose address is the helper's own is a failure that never reached
/// Apple: the server fell over while minting the identity. That costs nothing
/// against the account and moving to a different server is free, which is the
/// opposite of the situation where Apple itself has answered.
pub fn helper_broke(text: &str, url: &str) -> bool {
    if text.contains(url) {
        return true;
    }
    let lower = text.to_lowercase();
    // A failure against Apple's own host is not this helper falling over.
    if lower.contains("gsa.apple.com") || lower.contains("gsservice2") {
        return false;
    }
    lower.contains("/v3/get_headers")
        || lower.contains("/v3/client_info")
        || lower.contains("provisioning timed out")
        || lower.contains("timed out")
        || lower.contains("timeout")
}

/// Whether the identity the helper minted is one Apple will not verify.
///
/// Apple answers -22421 at the password step, worded as if something went
/// wrong at random. It did not. The one-time code that goes up with the
/// password is computed from a blob provisioned inside one particular helper,
/// and that helper keeps the other half of it. A blob from a different helper,
/// or one that server has since forgotten, produces a code that verifies
/// against nothing, and this is what Apple says about that.
///
/// It is not the password, and Apple has not judged the account: the proof
/// never got as far as being checked. Provisioning again is the whole fix.
pub fn stale_session(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("-22421")
        || lower.contains("session expired")
        || lower.contains("this action could not be completed")
}

/// What to say when provisioning again did not help either.
pub fn stale_session_message() -> String {
    "Apple would not verify this computer's identity.\n\nThe password was never judged, so \
     nothing has happened to the Apple ID. What Apple turned down is the one-time code that \
     goes up alongside it, which is produced by the sign-in helper rather than by Cloak.\n\n\
     Cloak threw that identity away and provisioned a fresh one against different helpers, \
     and Apple refused those too, so the helpers are having a bad day rather than anything \
     being wrong at your end.\n\nWait ten minutes and try once. If it keeps happening, put \
     a working helper address in the box under \"Sign-in helper\" on the previous screen."
        .to_string()
}

/// Whether Apple is throttling the identity rather than judging the account.
///
/// These helpers are public and every person using one shares the single
/// machine identity it provisioned itself as. Apple meters the password step
/// per machine, so a busy helper can sit permanently over its limit and every
/// login through it is refused before the password is ever examined.
///
/// This is not the account being locked out. No password was judged, so it
/// costs nothing against the account, and the next helper is a different
/// machine rather than another go at the same one.
pub fn slow_down() -> String {
    "Apple is asking for a slower pace and has not stopped asking.\n\nThis is not the account and not the password. Apple limits how quickly sign-in requests can arrive from one internet connection, and once it starts refusing, every further attempt keeps it refusing. Cloak already waited and tried again several times before showing you this.\n\nLeave it completely alone for ten minutes, then try once. Attempts during that time are what keep it going.\n\nIf it keeps happening, put the Mac on a phone hotspot and try once from there. That uses a different connection and will sign in immediately if the limit is the reason.".to_string()
}

pub fn identity_throttled(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("429") || lower.contains("too many requests")
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
    match healthy_candidates(config).await.into_iter().next() {
        Some(url) => {
            tracing::info!("using anisette server {url}");
            Ok(url)
        }
        None => {
            let tried = candidates(config);
            tracing::warn!("no anisette server answered out of {}", tried.len());
            Err(tried)
        }
    }
}

/// Whether Apple refused to provision against this helper.
///
/// The decisive one is -45003, invalid Trust Key. Each of these servers holds
/// an identity it provisions with, and when Apple invalidates one, every app
/// pointed at that server stops working at the same moment, for everybody,
/// including somebody signing in for the first time. Nothing about it is to do
/// with the account, and no amount of waiting fixes it: the only cure is a
/// different server.
pub fn helper_was_rejected(text: &str) -> bool {
    let lower = text.to_lowercase();

    // A timeout is the helper giving up on us, not Apple judging anything, and
    // calling it a refusal both blames the wrong party and burns one of the
    // attempts that are supposed to be reserved for answers from Apple.
    if lower.contains("timed out") || lower.contains("timeout") {
        return false;
    }

    // An unverifiable one-time code is its own thing and has its own cure.
    // Calling it a refusal would blacklist a helper that is working fine.
    if stale_session(text) {
        return false;
    }

    let provisioning_refused = lower.contains("-45003")
        || lower.contains("invalid trust key")
        || lower.contains("provisioning failed")
        || lower.contains("end provisioning error")
        || lower.contains("failed to provision");

    // Apple answers 503 on the grandslam endpoint when the identity it was
    // handed does not hold up, and it says nothing about why. The endpoint
    // itself answers normally at the same moment, so this is not an outage and
    // it is not the account: it is that particular helper's identity being
    // turned down. Another helper is a different identity and worth trying.
    let identity_refused = lower.contains("grandslam")
        && (lower.contains("503") || lower.contains("service temporarily unavailable"));

    provisioning_refused || identity_refused
}

/// Every helper Cloak knows about refused to provision.
pub fn all_helpers_rejected() -> String {
    "Apple would not accept any of the sign-in helpers.\n\nThese are public servers that produce the identity Apple insists on, and each holds a key Apple can invalidate. When that happens every app that installs without the App Store breaks at once, for everybody, including somebody signing in for the first time. Nothing is wrong with the Apple ID.\n\nCloak tried several different servers and Apple refused all of them, so this is an outage rather than a setting. It is normally fixed within a day by whoever runs them.\n\nIf somebody has published an address that works, it goes in the box under \"Sign-in helper\" on the previous screen.".to_string()
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
/// a Mac model, a macOS build and an Xcode version, and it has to be the same
/// machine the identity data was minted for. The helper reports both together
/// and they already agree, so this passes the pair straight through untouched
/// unless somebody has typed a replacement into the box on the sign-in screen.
///
/// Overriding it blindly is what makes Apple answer 503: the identity data
/// still describes the helper's machine and the description no longer does.
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
                return Ok(info);
            }
        }
        info.client_info = without_xcode(&info.client_info);
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

/// The same machine description, with the claim to be Xcode taken out.
///
/// Apple stopped accepting this header the moment it says the request is
/// coming from Xcode. Not a particular Xcode version, and nothing to do with
/// the Mac or the macOS build named alongside it: the presence of the Xcode
/// part alone is enough. Apple's edge answers 503 and the request never
/// reaches the sign-in service at all, which is why it looked like an outage
/// and why swapping helpers changed nothing. Every helper reports itself as
/// Xcode, so every one of them was blocked in exactly the same way.
///
/// Taking that part out is enough. The Mac and the macOS build stay exactly as
/// the helper reported them, so they still match the identity data it minted,
/// and what is left is an ordinary AuthKit client, which Apple answers
/// normally.
pub fn without_xcode(value: &str) -> String {
    let Some(start) = value.find(" (com.apple.dt.Xcode") else {
        return value.to_string();
    };
    let Some(offset) = value[start..].find(')') else {
        return value.to_string();
    };
    let mut out = String::with_capacity(value.len());
    out.push_str(&value[..start]);
    out.push_str(&value[start + offset + 1..]);
    out
}

// MARK: - What Apple is told this machine is

/// The machine description Apple is shown.
///
/// This is not free-form and it is not the machine Cloak happens to be running
/// on. The identity data that goes up alongside it is minted by the sign-in
/// helper, which provisioned itself as one specific Mac running one specific
/// version of macOS, and it reports that same description from its own
/// endpoint. The two travel together and Apple checks that they agree. Send
/// identity data minted for a 2016 MacBook Pro on macOS 13 while claiming to be
/// a 2026 Mac on macOS 27 and Apple answers 503 with no explanation, which
/// reads exactly like an outage and is not one.
///
/// So there is deliberately no automatic value here. Left alone, the helper's
/// own description is used and the pair matches. The box on the sign-in screen
/// exists for the case where somebody publishes a replacement string that has
/// to go up with a helper that is already serving the matching identity data,
/// and it is the only thing that can override it.
pub fn client_info(config: &Config) -> Option<String> {
    let chosen = config.client_info.as_deref()?.trim();
    if chosen.is_empty() {
        return None;
    }
    Some(chosen.to_string())
}

#[cfg(test)]
mod client_info_tests {
    use super::without_xcode;

    #[test]
    fn the_xcode_claim_is_removed() {
        assert_eq!(
            without_xcode(
                "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
            ),
            "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1>"
        );
    }

    #[test]
    fn the_machine_is_left_alone() {
        let plain = "<Mac15,7> <macOS;15.3.1;24D70> <com.apple.AuthKit/1>";
        assert_eq!(without_xcode(plain), plain);
    }

    #[test]
    fn nothing_is_lost_when_there_is_no_closing_bracket() {
        let broken = "<Mac15,7> <macOS;15.3.1;24D70> <com.apple.AuthKit/1 (com.apple.dt.Xcode/9";
        assert_eq!(without_xcode(broken), broken);
    }
}
