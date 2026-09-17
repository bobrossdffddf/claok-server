//! Installing Cloak with no computer, straight from Safari.
//!
//! Every on-device signer in the wild still needs another installer already on
//! the phone to bootstrap it. The one route that needs nothing but Safari is
//! Apple's own over-the-air install: a signed app served from an
//! `itms-services://` manifest. Apple gates ad-hoc installs on the device's
//! UDID, so the phone has to tell the server which device it is before the
//! server can sign for it. Apple built a mechanism for exactly that, the
//! Profile Service enrolment payload, and this drives it end to end:
//!
//!   1. Safari opens the install page and taps Install.
//!   2. The page hands iOS an enrolment profile. iOS gathers the UDID and the
//!      model and POSTs them back, signed, with no typing.
//!   3. The server registers that UDID on the developer account, signs Cloak
//!      for it, and answers with an `itms-services` link.
//!   4. Safari installs Cloak. No cable, no Mac, no second app.
//!
//! The signing itself is handed to whatever tool the operator has wired up
//! (zsign against an ad-hoc profile, the Apple Developer API to add the UDID),
//! because that part needs the account's private key and does not belong in
//! this file. Everything here is the plumbing around it: the page, the
//! profile, the manifest, and reading the UDID out of what iOS sends back.

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, StatusCode};
use axum::response::{Html, IntoResponse, Redirect};

use crate::{Problem, Shared};

/// Everything the OTA flow needs to know about where it lives and what it
/// serves. All from the environment, so a deployment sets it once.
#[derive(Clone)]
pub struct OtaConfig {
    /// The public https base, e.g. https://get.cloak.app. Manifests must point
    /// at https or iOS refuses the install without a word.
    pub base_url: String,
    /// The app's bundle id, as signed.
    pub bundle_id: String,
    /// The name iOS shows while installing.
    pub title: String,
    /// The current version string.
    pub version: String,
    /// The base .ipa, before per-device signing.
    pub ipa_path: std::path::PathBuf,
    /// A command that signs the base ipa for one udid:
    /// `<cmd> <udid> <in.ipa> <out.ipa>`. When unset, the base ipa is served
    /// as-is, which only installs on devices already in its profile.
    pub sign_cmd: Option<String>,
    /// Where signed per-device ipas are cached.
    pub work_dir: std::path::PathBuf,
}

impl OtaConfig {
    pub fn from_env() -> Option<OtaConfig> {
        let base_url = std::env::var("CLOAK_OTA_BASE_URL").ok()?;
        let ipa_path = std::env::var("CLOAK_IPA").ok()?.into();
        let work_dir: std::path::PathBuf = std::env::var("CLOAK_OTA_WORK")
            .unwrap_or_else(|_| "ota-work".into())
            .into();
        let _ = std::fs::create_dir_all(&work_dir);
        Some(OtaConfig {
            base_url: base_url.trim_end_matches('/').to_string(),
            bundle_id: std::env::var("CLOAK_BUNDLE_ID").unwrap_or_else(|_| "app.cloak.ios".into()),
            title: std::env::var("CLOAK_APP_TITLE").unwrap_or_else(|_| "Cloak".into()),
            version: std::env::var("CLOAK_APP_VERSION").unwrap_or_else(|_| "1.5".into()),
            ipa_path,
            sign_cmd: std::env::var("CLOAK_SIGN_CMD").ok().filter(|s| !s.is_empty()),
            work_dir,
        })
    }
}

fn config(context: &Shared) -> Result<&OtaConfig, Problem> {
    context
        .ota
        .as_ref()
        .ok_or_else(|| Problem::not_found("Over-the-air install is not set up on this server."))
}

// MARK: - The pages

/// The landing page. One button, and the honest small print underneath it.
pub async fn landing(State(context): State<Shared>) -> Result<impl IntoResponse, Problem> {
    let ota = config(&context)?;
    Ok(Html(landing_html(&ota.title, &ota.base_url)))
}

pub fn landing_html(title: &str, base: &str) -> String {
    format!(
        r#"<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Install {title}</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ margin:0; font: -apple-system-body, system-ui; background:#0c1015; color:#eef2f6;
         min-height:100dvh; display:flex; align-items:center; justify-content:center; padding:24px; }}
  .card {{ max-width:420px; width:100%; text-align:center; }}
  h1 {{ font-size:34px; margin:0 0 8px; letter-spacing:-0.02em; }}
  p {{ color:#a9b2bd; line-height:1.5; margin:0 0 20px; }}
  a.btn {{ display:block; background:#3be0c8; color:#08201d; font-weight:700; font-size:18px;
          text-decoration:none; padding:16px; border-radius:16px; margin:8px 0; }}
  a.btn.secondary {{ background:#182029; color:#eef2f6; }}
  small {{ color:#6b7683; display:block; margin-top:16px; line-height:1.5; }}
  .steps {{ text-align:left; background:#111722; border-radius:16px; padding:16px 20px; margin:20px 0; }}
  .steps li {{ margin:8px 0; color:#c7cfd8; }}
</style></head>
<body><div class="card">
  <h1>{title}</h1>
  <p>Install straight from here. No computer, no cable.</p>
  <a class="btn" href="{base}/enroll">Install {title}</a>
  <ol class="steps">
    <li>Tap Install. iOS asks to show a profile — allow it.</li>
    <li>Settings opens with Profile Downloaded. Tap it, then Install.</li>
    <li>Come back here. {title} signs for your phone and installs itself.</li>
    <li>First launch: Settings, General, VPN &amp; Device Management, trust the developer.</li>
  </ol>
  <small>{title} signs itself for your device using your own free Apple ID after install. This page only registers which iPhone you are so the download will open.</small>
</div></body></html>"#,
        title = html_escape(title),
        base = html_escape(base),
    )
}

/// Hands iOS the enrolment profile that gathers the UDID.
pub async fn enroll(State(context): State<Shared>) -> Result<impl IntoResponse, Problem> {
    let ota = config(&context)?;
    let profile = enroll_profile(&ota.base_url, &ota.title);
    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/x-apple-aspen-config"),
            (
                header::CONTENT_DISPOSITION,
                "attachment; filename=\"cloak-install.mobileconfig\"",
            ),
        ],
        profile,
    ))
}

/// The Profile Service payload. iOS reads `DeviceAttributes`, gathers exactly
/// those, and POSTs a signed plist to `URL`. Nothing is installed by this
/// profile; it exists only to make the phone name itself.
pub fn enroll_profile(base: &str, title: &str) -> String {
    let uuid = stable_uuid(&format!("{base}/enroll"));
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <dict>
    <key>URL</key>
    <string>{base}/enrolled</string>
    <key>DeviceAttributes</key>
    <array>
      <string>UDID</string>
      <string>PRODUCT</string>
      <string>VERSION</string>
      <string>DEVICE_NAME</string>
    </array>
  </dict>
  <key>PayloadOrganization</key>
  <string>{title}</string>
  <key>PayloadDisplayName</key>
  <string>{title} Install</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
  <key>PayloadUUID</key>
  <string>{uuid}</string>
  <key>PayloadIdentifier</key>
  <string>app.cloak.enroll</string>
  <key>PayloadType</key>
  <string>Profile Service</string>
  <key>PayloadDescription</key>
  <string>Tells {title} which iPhone this is, so the download will open. Nothing is installed by this step.</string>
</dict>
</plist>"#,
        base = xml_escape(base),
        title = xml_escape(title),
        uuid = uuid,
    )
}

/// Receives the signed device attributes from iOS, reads the UDID, signs, and
/// sends Safari on to the install.
pub async fn enrolled(State(context): State<Shared>, body: axum::body::Bytes) -> impl IntoResponse {
    let ota = match config(&context) {
        Ok(ota) => ota,
        Err(problem) => return problem.into_response(),
    };

    let Some(udid) = udid_from_enrollment(&body) else {
        return Problem::bad("Could not read this device's identifier from Apple's reply.")
            .into_response();
    };
    if !looks_like_udid(&udid) {
        return Problem::bad("That does not look like a device identifier.").into_response();
    }

    // Sign in the background. The wait page polls until the ipa is ready and
    // then flips to the itms-services link, so a slow signer never times the
    // request out.
    let ota_clone = ota.clone();
    let udid_clone = udid.clone();
    tokio::spawn(async move {
        if let Err(error) = sign_for(&ota_clone, &udid_clone).await {
            tracing::error!("signing for {udid_clone} failed: {error}");
        }
    });

    Redirect::to(&format!("{}/install/{}", ota.base_url, udid)).into_response()
}

/// The wait-and-install page. Polls for the signed build, then opens the
/// itms-services link that installs it.
pub async fn install_page(
    State(context): State<Shared>,
    Path(udid): Path<String>,
) -> Result<impl IntoResponse, Problem> {
    let ota = config(&context)?;
    if !looks_like_udid(&udid) {
        return Err(Problem::bad("That does not look like a device identifier."));
    }
    Ok(Html(install_html(&ota.base_url, &ota.title, &udid)))
}

pub fn install_html(base: &str, title: &str, udid: &str) -> String {
    let manifest = format!("{base}/manifest/{udid}.plist");
    let itms = format!("itms-services://?action=download-manifest&url={}", url_encode(&manifest));
    format!(
        r#"<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Installing {title}</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ margin:0; font: -apple-system-body, system-ui; background:#0c1015; color:#eef2f6;
         min-height:100dvh; display:flex; align-items:center; justify-content:center; padding:24px; text-align:center; }}
  h1 {{ font-size:28px; margin:0 0 8px; }}
  p {{ color:#a9b2bd; line-height:1.5; }}
  a.btn {{ display:none; background:#3be0c8; color:#08201d; font-weight:700; font-size:18px;
          text-decoration:none; padding:16px 24px; border-radius:16px; margin-top:16px; }}
  .spin {{ width:32px; height:32px; border:3px solid #223; border-top-color:#3be0c8; border-radius:50%;
          animation:spin 0.9s linear infinite; margin:20px auto; }}
  @keyframes spin {{ to {{ transform:rotate(360deg); }} }}
</style></head>
<body><div>
  <h1 id="head">Signing {title} for your iPhone</h1>
  <p id="msg">This takes a few seconds. Keep this page open.</p>
  <div class="spin" id="spin"></div>
  <a class="btn" id="go" href="{itms}">Install {title}</a>
<script>
  var udid = {udid_json};
  var base = {base_json};
  async function poll() {{
    try {{
      var r = await fetch(base + '/status/' + udid, {{cache:'no-store'}});
      var j = await r.json();
      if (j.ready) {{
        document.getElementById('spin').style.display = 'none';
        document.getElementById('head').textContent = 'Ready';
        document.getElementById('msg').textContent = 'Tap Install, then Install again when iOS asks.';
        document.getElementById('go').style.display = 'inline-block';
        location.href = document.getElementById('go').href;
        return;
      }}
      if (j.failed) {{
        document.getElementById('spin').style.display = 'none';
        document.getElementById('head').textContent = 'Signing failed';
        document.getElementById('msg').textContent = j.reason || 'Try again in a minute.';
        return;
      }}
    }} catch (e) {{}}
    setTimeout(poll, 2000);
  }}
  poll();
</script>
</div></body></html>"#,
        title = html_escape(title),
        itms = html_escape(&itms),
        udid_json = json_string(udid),
        base_json = json_string(base),
    )
}

/// Whether the signed build for this device is ready yet.
pub async fn status(
    State(context): State<Shared>,
    Path(udid): Path<String>,
) -> Result<impl IntoResponse, Problem> {
    let ota = config(&context)?;
    let out = signed_path(ota, &udid);
    let failed = ota.work_dir.join(format!("{udid}.failed"));
    let body = if out.exists() {
        serde_json::json!({ "ready": true })
    } else if let Ok(reason) = std::fs::read_to_string(&failed) {
        serde_json::json!({ "ready": false, "failed": true, "reason": reason })
    } else {
        serde_json::json!({ "ready": false })
    };
    Ok(axum::Json(body))
}

/// The itms-services manifest for one device.
pub async fn manifest(
    State(context): State<Shared>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, Problem> {
    let ota = config(&context)?;
    let udid = name.strip_suffix(".plist").unwrap_or(&name);
    if !looks_like_udid(udid) {
        return Err(Problem::bad("That does not look like a device identifier."));
    }
    let ipa_url = format!("{}/ipa/{}.ipa", ota.base_url, udid);
    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/xml")],
        manifest_plist(&ipa_url, &ota.bundle_id, &ota.version, &ota.title),
    ))
}

/// The install manifest. iOS reads the software-package url and downloads the
/// ipa; the images are optional but a missing display-image shows a grey tile.
pub fn manifest_plist(ipa_url: &str, bundle_id: &str, version: &str, title: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>{ipa}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>{bundle}</string>
        <key>bundle-version</key>
        <string>{version}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>{title}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>"#,
        ipa = xml_escape(ipa_url),
        bundle = xml_escape(bundle_id),
        version = xml_escape(version),
        title = xml_escape(title),
    )
}

/// Serves the signed ipa for one device.
pub async fn ipa(
    State(context): State<Shared>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, Problem> {
    let ota = config(&context)?;
    let udid = name.strip_suffix(".ipa").unwrap_or(&name);
    if !looks_like_udid(udid) {
        return Err(Problem::bad("That does not look like a device identifier."));
    }
    let path = signed_path(ota, udid);
    let bytes = tokio::fs::read(&path).await.map_err(|_| {
        Problem::not_found("This build is not ready yet. Go back and wait for signing to finish.")
    })?;
    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/octet-stream"),
            (header::CONTENT_DISPOSITION, "attachment; filename=\"Cloak.ipa\""),
        ],
        Body::from(bytes),
    ))
}

// MARK: - Signing

fn signed_path(ota: &OtaConfig, udid: &str) -> std::path::PathBuf {
    ota.work_dir.join(format!("{udid}.ipa"))
}

/// Signs the base ipa for one device, via the operator's configured signer.
async fn sign_for(ota: &OtaConfig, udid: &str) -> Result<(), String> {
    let out = signed_path(ota, udid);
    if out.exists() {
        return Ok(());
    }
    let failed = ota.work_dir.join(format!("{udid}.failed"));
    let _ = std::fs::remove_file(&failed);

    let Some(cmd) = &ota.sign_cmd else {
        // No signer wired up. In that state the base ipa only installs on
        // devices already inside its own profile, which is fine for a first
        // test from the operator's own phone but not for anybody else.
        tokio::fs::copy(&ota.ipa_path, &out)
            .await
            .map_err(|e| format!("no signer set and the base ipa could not be copied: {e}"))?;
        return Ok(());
    };

    let status = tokio::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(cmd)
        .env("CLOAK_UDID", udid)
        .env("CLOAK_IN_IPA", &ota.ipa_path)
        .env("CLOAK_OUT_IPA", &out)
        .status()
        .await
        .map_err(|e| format!("could not run the signer: {e}"))?;

    if status.success() && out.exists() {
        Ok(())
    } else {
        let reason = "Signing did not produce a build for this device.";
        let _ = std::fs::write(&failed, reason);
        Err(reason.to_string())
    }
}

// MARK: - Reading the UDID out of Apple's reply

/// iOS answers the enrolment profile with a PKCS#7-signed plist. The plist is
/// carried in the clear inside the signed blob, so the UDID can be read by
/// finding the plist and pulling the value after the `UDID` key, without
/// verifying the signature (which would need Apple's WWDR chain and buys
/// nothing here: a forged UDID only signs a build that will not install).
pub fn udid_from_enrollment(body: &[u8]) -> Option<String> {
    let text = extract_plist(body)?;
    value_after_key(&text, "UDID")
}

/// Pulls the embedded XML plist out of a DER blob, or returns the body as text
/// when it already is a plist (some clients post it plain).
fn extract_plist(body: &[u8]) -> Option<String> {
    let haystack = String::from_utf8_lossy(body);
    let start = haystack.find("<?xml").or_else(|| haystack.find("<plist"))?;
    let end = haystack[start..].find("</plist>").map(|e| start + e + "</plist>".len())?;
    Some(haystack[start..end].to_string())
}

/// The string value immediately following `<key>NAME</key>` in a plist.
fn value_after_key(plist: &str, key: &str) -> Option<String> {
    let needle = format!("<key>{key}</key>");
    let after = &plist[plist.find(&needle)? + needle.len()..];
    let open = after.find("<string>")? + "<string>".len();
    let close = after[open..].find("</string>")?;
    Some(after[open..open + close].trim().to_string())
}

/// A modern iOS UDID is 25 hex+dash (A-serial) or the old 40 hex. Anything else
/// is not one, and letting it through would sign a build for a bad name.
pub fn looks_like_udid(value: &str) -> bool {
    let v = value.trim();
    if v.len() == 40 && v.chars().all(|c| c.is_ascii_hexdigit()) {
        return true;
    }
    // iPhone 15 era: 8 hex, a dash, 16 hex.
    if v.len() == 25 {
        let bytes: Vec<char> = v.chars().collect();
        return bytes[8] == '-'
            && bytes[..8].iter().all(|c| c.is_ascii_hexdigit())
            && bytes[9..].iter().all(|c| c.is_ascii_hexdigit());
    }
    false
}

// MARK: - Small helpers

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}
fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}
fn json_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}
fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// A stable UUIDv3-ish string from a name, so the profile UUID does not churn.
fn stable_uuid(name: &str) -> String {
    let mut h: u128 = 0xcbf29ce484222325;
    for b in name.bytes() {
        h ^= b as u128;
        h = h.wrapping_mul(0x100000001b3);
    }
    let x = h ^ (h >> 64);
    format!(
        "{:08X}-{:04X}-{:04X}-{:04X}-{:012X}",
        (x >> 96) as u32 & 0xffff_ffff,
        (x >> 80) as u16,
        ((x >> 64) as u16 & 0x0fff) | 0x3000,
        ((x >> 48) as u16 & 0x3fff) | 0x8000,
        (x & 0xffff_ffff_ffff) as u64,
    )
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_carries_the_right_fields() {
        let m = manifest_plist("https://x.app/ipa/AB-CD.ipa", "app.cloak.ios", "1.5", "Cloak");
        assert!(m.contains("<string>https://x.app/ipa/AB-CD.ipa</string>"));
        assert!(m.contains("<string>app.cloak.ios</string>"));
        assert!(m.contains("<string>software-package</string>"));
        assert!(m.contains("<key>bundle-version</key>\n        <string>1.5</string>"));
    }

    #[test]
    fn enroll_profile_is_a_profile_service() {
        let p = enroll_profile("https://x.app", "Cloak");
        assert!(p.contains("<string>Profile Service</string>"));
        assert!(p.contains("<string>https://x.app/enrolled</string>"));
        assert!(p.contains("<string>UDID</string>"));
    }

    #[test]
    fn reads_udid_from_a_signed_reply() {
        // A DER blob with the plist carried in the clear inside it.
        let mut body = vec![0x30u8, 0x82, 0x01, 0x00, 0xAB, 0xCD];
        let plist = r#"<?xml version="1.0"?><plist version="1.0"><dict><key>UDID</key><string>00008150-001A02D22178401C</string><key>PRODUCT</key><string>iPhone17,1</string></dict></plist>"#;
        body.extend_from_slice(plist.as_bytes());
        body.extend_from_slice(&[0x00, 0x11, 0x22]);
        assert_eq!(udid_from_enrollment(&body).as_deref(), Some("00008150-001A02D22178401C"));
    }

    #[test]
    fn reads_udid_from_a_plain_plist() {
        let plist = r#"<plist version="1.0"><dict><key>UDID</key><string>abcdef0123456789abcdef0123456789abcdef01</string></dict></plist>"#;
        assert_eq!(
            udid_from_enrollment(plist.as_bytes()).as_deref(),
            Some("abcdef0123456789abcdef0123456789abcdef01")
        );
    }

    #[test]
    fn nonsense_has_no_udid() {
        assert_eq!(udid_from_enrollment(b"not a plist at all"), None);
    }

    #[test]
    fn udid_shapes() {
        assert!(looks_like_udid("00008150-001A02D22178401C"));
        assert!(looks_like_udid("abcdef0123456789abcdef0123456789abcdef01"));
        assert!(!looks_like_udid("hello"));
        assert!(!looks_like_udid("00008150001A02D22178401C"));
        assert!(!looks_like_udid("../../etc/passwd"));
        assert!(!looks_like_udid("00008150-001A02D22178401G"));
    }

    #[test]
    fn itms_link_is_url_encoded() {
        let html = install_html("https://x.app", "Cloak", "00008150-001A02D22178401C");
        assert!(html.contains("itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fx.app%2Fmanifest%2F"));
    }

    #[test]
    fn pages_escape_their_inputs() {
        let html = landing_html("Cloak<script>", "https://x.app");
        assert!(!html.contains("<script>"));
        assert!(html.contains("Cloak&lt;script&gt;"));
    }
}
