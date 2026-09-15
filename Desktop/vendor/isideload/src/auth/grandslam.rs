use super::middleware::WasmProxyMiddleware;
use plist::Dictionary;
use plist_macro::plist_to_xml_string;
use plist_macro::pretty_print_dictionary;
#[cfg(not(feature = "wasm"))]
use reqwest::Certificate;
use reqwest::{
    ClientBuilder,
    header::{HeaderMap, HeaderValue},
};
use reqwest_middleware::ClientBuilder as MwClientBuilder;
use rootcause::prelude::*;
use tracing::{debug, warn};

use crate::{SideloadError, anisette::AnisetteClientInfo, util::plist::PlistDataExtract};

#[cfg(not(feature = "wasm"))]
const APPLE_ROOT: &[u8] = include_bytes!("./apple_root.der");
const URL_BAG: &str = "https://gsa.apple.com/grandslam/GsService2/lookup";

pub struct GrandSlam {
    pub client: reqwest_middleware::ClientWithMiddleware,
    pub client_info: AnisetteClientInfo,
    url_bag: Dictionary,
}


/// Apple refuses requests that arrive too fast, but only once it has said so.
///
/// Apple's edge answers 429 to bursts from one internet connection. There is no
/// Retry-After and no account involvement, and it clears after a short quiet
/// period, which is why waiting hours achieves nothing while attempts keep
/// arriving.
///
/// The obvious response, spacing every request out, is wrong. Provisioning runs
/// over a websocket where the helper is waiting on us to relay Apple's answers,
/// and it gives up if we dawdle, so a fixed delay in front of every request
/// turns a working provision into a timeout.
///
/// So nothing is slowed down until Apple actually objects. A 429 sets a cooling
/// off period that later requests wait out, and the first success clears it.
const BACKOFF: std::time::Duration = std::time::Duration::from_secs(12);
const MAX_ATTEMPTS: u32 = 4;

static COOLING_OFF: std::sync::OnceLock<tokio::sync::Mutex<Option<std::time::Instant>>> =
    std::sync::OnceLock::new();

fn cooling_off() -> &'static tokio::sync::Mutex<Option<std::time::Instant>> {
    COOLING_OFF.get_or_init(|| tokio::sync::Mutex::new(None))
}

async fn pace() {
    let gate = cooling_off();
    let until = { *gate.lock().await };
    if let Some(until) = until {
        let now = std::time::Instant::now();
        if until > now {
            let wait = until - now;
            debug!("waiting {}s for Apple to cool off", wait.as_secs());
            tokio::time::sleep(wait).await;
        }
    }
}

async fn start_cooling_off(pause: std::time::Duration) {
    *cooling_off().lock().await = Some(std::time::Instant::now() + pause);
}

async fn stop_cooling_off() {
    *cooling_off().lock().await = None;
}

impl GrandSlam {
    /// Create a new GrandSlam instance
    ///
    /// # Arguments
    /// - `client`: The reqwest client to use for requests
    pub async fn new(
        client_info: AnisetteClientInfo,
        debug: bool,
        proxy_url: Option<String>,
    ) -> Result<Self, Report> {
        let client =
            Self::build_reqwest_client(debug, proxy_url).context("Failed to build HTTP client")?;
        let base_headers = Self::base_headers(&client_info, false)?;
        let url_bag = Self::fetch_url_bag(&client, base_headers).await?;
        Ok(Self {
            client,
            client_info,
            url_bag,
        })
    }

    /// Fetch the URL bag from GrandSlam and cache it
    pub async fn fetch_url_bag(
        client: &reqwest_middleware::ClientWithMiddleware,
        base_headers: HeaderMap,
    ) -> Result<Dictionary, Report> {
        debug!("Fetching URL bag from GrandSlam");
        let resp = client
            .get(URL_BAG)
            .headers(base_headers)
            .send()
            .await
            .context("Failed to fetch URL Bag")?
            .text()
            .await
            .context("Failed to read URL Bag response text")?;

        let dict: Dictionary =
            plist::from_bytes(resp.as_bytes()).context("Failed to parse URL Bag plist")?;
        let urls = dict
            .get("urls")
            .and_then(|v| v.as_dictionary())
            .cloned()
            .ok_or_else(|| report!("URL Bag plist missing 'urls' dictionary"))?;

        Ok(urls)
    }

    pub fn get_url(&self, key: &str) -> Result<String, Report> {
        let url = self
            .url_bag
            .get_string(key)
            .context("Unable to find key in URL bag")?;
        Ok(url)
    }

    pub fn get(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .get(url)
            .headers(Self::base_headers(&self.client_info, false)?);

        Ok(builder)
    }

    pub fn get_sms(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .get(url)
            .headers(Self::base_headers(&self.client_info, true)?);

        Ok(builder)
    }

    pub fn put_sms(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .put(url)
            .headers(Self::base_headers(&self.client_info, true)?);

        Ok(builder)
    }

    pub fn post(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .post(url)
            .headers(Self::base_headers(&self.client_info, false)?);

        Ok(builder)
    }

    pub fn post_sms(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .post(url)
            .headers(Self::base_headers(&self.client_info, true)?);

        Ok(builder)
    }

    pub fn patch(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .patch(url)
            .headers(Self::base_headers(&self.client_info, false)?);

        Ok(builder)
    }

    pub async fn plist_request(
        &self,
        url: &str,
        body: &Dictionary,
        additional_headers: Option<HeaderMap>,
    ) -> Result<Dictionary, Report> {
        let extra = additional_headers.unwrap_or_else(reqwest::header::HeaderMap::new);
        let payload = plist_to_xml_string(body);

        let mut attempt: u32 = 0;
        let resp = loop {
            attempt += 1;
            pace().await;

            let resp = self
                .post(url)?
                .headers(extra.clone())
                .body(payload.clone())
                .send()
                .await
                .context("Failed to send grandslam request")?;

            if resp.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
                let pause = BACKOFF * attempt;
                start_cooling_off(pause).await;
                if attempt < MAX_ATTEMPTS {
                    warn!(
                        "Apple asked for a slower pace, waiting {}s before retrying",
                        pause.as_secs()
                    );
                    tokio::time::sleep(pause).await;
                    continue;
                }
            } else if resp.status().is_success() {
                stop_cooling_off().await;
            }

            break resp;
        };

        // Apple explains a refusal in the body and the headers, and throwing the
        // response away on a bad status throws that explanation away with it.
        let status = resp.status();
        if !status.is_success() {
            let retry_after = resp
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("none")
                .to_string();
            let detail = resp.text().await.unwrap_or_default();
            let detail = detail.trim();
            let detail = if detail.len() > 400 { &detail[..400] } else { detail };
            warn!("grandslam refused with {status} (retry-after: {retry_after}): {detail}");
            bail!("Received error response from grandslam: {status} (retry-after: {retry_after})");
        }

        let resp = resp
            .text()
            .await
            .context("Failed to read grandslam response as text")?;

        let dict: Dictionary = plist::from_bytes(resp.as_bytes())
            .context("Failed to parse grandslam response plist")
            .attach_with(|| resp.clone())?;

        let response_plist = dict
            .get("Response")
            .and_then(|v| v.as_dictionary())
            .cloned()
            .ok_or_else(|| {
                report!("grandslam response missing 'Response'")
                    .attach(pretty_print_dictionary(&dict))
            })?;

        Ok(response_plist)
    }

    pub(crate) fn base_headers(
        client_info: &AnisetteClientInfo,
        sms: bool,
    ) -> Result<reqwest::header::HeaderMap, Report> {
        let mut headers = reqwest::header::HeaderMap::new();
        if !sms {
            headers.insert("Content-Type", HeaderValue::from_static("text/x-xml-plist"));
            headers.insert("Accept", HeaderValue::from_static("text/x-xml-plist"));
        } else {
            headers.insert("Content-Type", HeaderValue::from_static("application/json"));
            headers.insert("Accept", HeaderValue::from_static("application/json"));
        }
        headers.insert(
            "X-Mme-Client-Info",
            HeaderValue::from_str(&client_info.client_info)?,
        );
        headers.insert(
            "User-Agent",
            HeaderValue::from_str(&client_info.user_agent)?,
        );
        headers.insert(
            "X-Xcode-Version",
            HeaderValue::from_static("27.0 (27A5218g)"),
        );
        headers.insert(
            "X-Apple-App-Info",
            HeaderValue::from_static("com.apple.gs.xcode.auth"),
        );
        // Apple's edge serves at most two requests per connection since
        // 2026-08-31. Close after every request so the next one is a new
        // connection and never lands on an exhausted one.
        headers.insert("Connection", HeaderValue::from_static("close"));

        Ok(headers)
    }

    /// Build a reqwest client with the Apple root certificate
    ///
    /// # Arguments
    /// - `debug`: DANGER, If true, accept invalid certificates and enable verbose connection logging
    /// # Errors
    /// Returns an error if the reqwest client cannot be built
    pub fn build_reqwest_client(
        debug: bool,
        proxy_url: Option<String>,
    ) -> Result<reqwest_middleware::ClientWithMiddleware, Report> {
        #[cfg(not(feature = "wasm"))]
        let cert = Certificate::from_der(APPLE_ROOT)?;
        #[cfg(not(feature = "wasm"))]
        let client = ClientBuilder::new()
            .add_root_certificate(cert)
            .http1_title_case_headers()
            // Apple's gsa.apple.com edge began serving at most two requests per
            // TCP connection around 2026-08-31, refusing the third and later
            // requests on a reused keep-alive connection with an edge error
            // (503, or the empty idmsa web 403 on the /auth 2FA endpoints). The
            // sign-in plus the 2FA steps are well past two requests, so every
            // 2FA request was landing on an exhausted pooled connection and
            // being refused. Giving every request its own fresh connection is
            // the fix (matches AltSign PR #52). Do not pool idle connections.
            .pool_max_idle_per_host(0)
            .danger_accept_invalid_certs(debug)
            .connection_verbose(debug)
            .build()?;
        #[cfg(feature = "wasm")]
        let client = ClientBuilder::new().build()?;

        let builder = MwClientBuilder::new(client);
        let builder = if let Some(proxy_url) = proxy_url {
            builder.with(WasmProxyMiddleware::new(proxy_url))
        } else {
            builder
        };
        Ok(builder.build())
    }
}

pub trait GrandSlamErrorChecker {
    fn check_grandslam_error(self) -> Result<Dictionary, Report<SideloadError>>;
}

impl GrandSlamErrorChecker for Dictionary {
    fn check_grandslam_error(self) -> Result<Self, Report<SideloadError>> {
        let result = match self.get("Status") {
            Some(plist::Value::Dictionary(d)) => d,
            _ => &self,
        };

        if result.get_signed_integer("ec").unwrap_or(0) != 0 {
            bail!(SideloadError::AuthWithMessage(
                result.get_signed_integer("ec").unwrap_or(-1),
                result.get_str("em").unwrap_or("Unknown error").to_string(),
            ))
        }

        Ok(self)
    }
}
