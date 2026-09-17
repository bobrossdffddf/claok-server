pub mod remote_v3;

use crate::auth::grandslam::GrandSlam;
use plist::Dictionary;
use plist_macro::plist;
use reqwest::header::HeaderMap;
use rootcause::prelude::*;
use serde::Deserialize;
use std::{collections::HashMap, sync::Arc};
use tokio::sync::RwLock;
use tracing::warn;
use web_time::SystemTime;

#[derive(Deserialize, Debug, Clone)]
pub struct AnisetteClientInfo {
    pub client_info: String,
    pub user_agent: String,
}

#[derive(Debug, Clone)]
pub struct AnisetteData {
    machine_id: String,
    one_time_password: String,
    pub routing_info: String,
    _device_description: String,
    device_unique_identifier: String,
    _local_user_id: String,
    generated_at: SystemTime,
}

// Some headers don't seem to be required. I guess not including them is technically more efficient soooo
impl AnisetteData {
    pub fn get_headers(&self) -> HashMap<String, String> {
        //let dt: DateTime<Utc> = Utc::now().round_subsecs(0);

        HashMap::from_iter([
            // (
            //     "X-Apple-I-Client-Time".to_string(),
            //     dt.format("%+").to_string().replace("+00:00", "Z"),
            // ),
            // ("X-Apple-I-SRL-NO".to_string(), serial),
            // ("X-Apple-I-TimeZone".to_string(), "UTC".to_string()),
            // ("X-Apple-Locale".to_string(), "en_US".to_string()),
            // ("X-Apple-I-MD-RINFO".to_string(), self.routing_info.clone()),
            // ("X-Apple-I-MD-LU".to_string(), self.local_user_id.clone()),
            (
                "X-Mme-Device-Id".to_string(),
                self.device_unique_identifier.clone(),
            ),
            ("X-Apple-I-MD".to_string(), self.one_time_password.clone()),
            ("X-Apple-I-MD-M".to_string(), self.machine_id.clone()),
            // (
            //     "X-Mme-Client-Info".to_string(),
            //     self.device_description.clone(),
            // ),
        ])
    }

    /// Every anisette header, not just the three the sign-in endpoint needs.
    ///
    /// The sign-in endpoint carries most of this inside the request body, so
    /// leaving it out of the headers costs nothing there. The two factor
    /// endpoints have no body to put it in: headers are the only channel, and
    /// Apple refuses the lot with a bare 403 when they are missing. That is one
    /// cause presenting as three separate broken endpoints.
    pub fn get_full_headers(&self) -> HashMap<String, String> {
        let mut headers = self.get_headers();
        headers.insert("X-Apple-I-MD-RINFO".to_string(), self.routing_info.clone());
        headers.insert(
            "X-Apple-I-MD-LU".to_string(),
            self._local_user_id.clone(),
        );
        headers.insert("X-Apple-I-TimeZone".to_string(), "UTC".to_string());
        headers.insert("X-Apple-Locale".to_string(), "en_US".to_string());
        headers.insert("X-Apple-I-Client-Time".to_string(), apple_now());
        headers
    }

    pub fn get_header_map(&self) -> Result<HeaderMap, Report> {
        let headers_map = self.get_headers();
        let mut header_map = HeaderMap::new();

        for (key, value) in headers_map {
            header_map.insert(
                reqwest::header::HeaderName::from_bytes(key.as_bytes())?,
                reqwest::header::HeaderValue::from_str(&value)?,
            );
        }

        Ok(header_map)
    }

    pub fn get_client_provided_data(&self) -> Dictionary {
        let headers = self.get_headers();

        let mut cpd = plist!(dict {
            "bootstrap": "true",
            "icscrec": "true",
            "loc": "en_US",
            "pbe": "false",
            "prkgen": "true",
            "svct": "iCloud"
        });

        for (key, value) in headers {
            cpd.insert(key.to_string(), plist::Value::String(value));
        }

        cpd
    }

    pub fn needs_refresh(&self) -> bool {
        let elapsed = self.generated_at.elapsed();
        match elapsed {
            Ok(elapsed) => elapsed.as_secs() > 60,
            Err(_) => {
                warn!("Unable to determine anisette data age, treating as expired");
                true
            }
        }
    }
}

#[cfg_attr(feature = "wasm", async_trait::async_trait(?Send))]
#[cfg_attr(not(feature = "wasm"), async_trait::async_trait)]
pub trait AnisetteProvider {
    async fn get_anisette_data(&self) -> Result<AnisetteData, Report>;

    async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report>;

    async fn provision(&mut self, gs: Arc<GrandSlam>) -> Result<(), Report>;

    fn needs_provisioning(&self) -> Result<bool, Report>;
}

#[derive(Clone)]
pub struct AnisetteDataGenerator {
    provider: Arc<RwLock<dyn AnisetteProvider + Send + Sync>>,
    data: Option<Arc<AnisetteData>>,
}

impl AnisetteDataGenerator {
    pub fn new(provider: Arc<RwLock<dyn AnisetteProvider + Send + Sync>>) -> Self {
        AnisetteDataGenerator {
            provider,
            data: None,
        }
    }

    pub async fn get_anisette_data(
        &mut self,
        gs: Arc<GrandSlam>,
    ) -> Result<Arc<AnisetteData>, Report> {
        if let Some(data) = &self.data
            && !data.needs_refresh()
        {
            return Ok(data.clone());
        }

        // trying to avoid locking as write unless necessary to promote concurrency
        let provider = self.provider.read().await;

        if provider.needs_provisioning()? {
            drop(provider);
            let mut provider_write = self.provider.write().await;
            provider_write.provision(gs).await?;
            drop(provider_write);

            let provider = self.provider.read().await;
            let data = provider.get_anisette_data().await?;
            let arc_data = Arc::new(data);
            self.data = Some(arc_data.clone());
            Ok(arc_data)
        } else {
            let data = provider.get_anisette_data().await?;
            let arc_data = Arc::new(data);
            self.data = Some(arc_data.clone());
            Ok(arc_data)
        }
    }

    pub async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report> {
        let provider = self.provider.read().await;
        provider.get_client_info().await
    }
}

/// The current time the way Apple writes it: 2026-09-11T20:45:15Z.
pub(crate) fn apple_now() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let days = seconds.div_euclid(86_400);
    let rest = seconds.rem_euclid(86_400);
    let (hour, minute, second) = (rest / 3600, (rest % 3600) / 60, rest % 60);

    // Civil date from a day count, the usual Howard Hinnant arithmetic.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { y + 1 } else { y };

    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

#[cfg(test)]
mod clock_tests {
    use super::apple_now;

    #[test]
    fn it_reads_as_a_date_apple_would_accept() {
        let now = apple_now();
        assert_eq!(now.len(), 20, "{now}");
        assert!(now.ends_with('Z'), "{now}");
        assert_eq!(&now[4..5], "-", "{now}");
        assert_eq!(&now[10..11], "T", "{now}");
        let year: i64 = now[..4].parse().unwrap();
        assert!(year >= 2026 && year < 2100, "{now}");
    }
}
