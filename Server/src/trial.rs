use axum::extract::State;
use axum::http::HeaderMap;
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::store::{now, TrialRow};
use crate::{Problem, Shared};

pub const DAILY_SECONDS: i64 = 10 * 60;
const TICK_GRACE: i64 = 75;
const MAX_DEVICES_PER_IP: i64 = 4;

#[derive(Deserialize)]
pub struct TrialBody {
    device_id: String,
    #[serde(default)]
    tz_minutes: i64,
}

#[derive(Serialize)]
pub struct TrialAnswer {
    token: String,
    remaining: i64,
    allowance: i64,
    running: bool,
    resets_at: i64,
    day: String,
}

fn client_ip(headers: &HeaderMap) -> String {
    for name in ["cf-connecting-ip", "x-real-ip", "x-forwarded-for"] {
        if let Some(value) = headers.get(name).and_then(|v| v.to_str().ok()) {
            if let Some(first) = value.split(',').next() {
                let trimmed = first.trim();
                if !trimmed.is_empty() {
                    return trimmed.to_string();
                }
            }
        }
    }
    String::new()
}

fn day_for(tz_minutes: i64, at: i64) -> (String, i64) {
    let local = at + tz_minutes * 60;
    let day_index = local.div_euclid(86_400);
    let date = chrono::DateTime::from_timestamp(day_index * 86_400, 0)
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default();
    let resets_at = (day_index + 1) * 86_400 - tz_minutes * 60;
    (date, resets_at)
}

fn settle(row: &mut TrialRow, at: i64) {
    if let Some(since) = row.active_since {
        let last = row.last_tick.unwrap_or(since).max(since);
        let end = (last + TICK_GRACE).min(at);
        row.used += (end - since).max(0);
        row.used = row.used.min(DAILY_SECONDS);
        row.active_since = None;
        row.last_tick = None;
    }
}

fn live_used(row: &TrialRow, at: i64) -> i64 {
    match row.active_since {
        Some(since) => (row.used + (at - since).max(0)).min(DAILY_SECONDS),
        None => row.used,
    }
}

fn answer(context: &crate::Context, device: &str, row: &TrialRow, day: String, resets_at: i64, at: i64) -> TrialAnswer {
    let remaining = (DAILY_SECONDS - live_used(row, at)).max(0);
    let claims = crate::OwnedClaims {
        lic: format!("trial:{device}"),
        dev: device.to_string(),
        plan: "trial".to_string(),
        exp: resets_at.max(at + 600),
        iat: at,
        rem: remaining,
        run: row.active_since.is_some(),
    };
    let payload = serde_json::to_vec(&claims).unwrap_or_default();
    TrialAnswer {
        token: context.keys.sign(&payload),
        remaining,
        allowance: DAILY_SECONDS,
        running: row.active_since.is_some() && remaining > 0,
        resets_at,
        day,
    }
}

fn prepare(context: &crate::Context, body: &TrialBody, headers: &HeaderMap) -> Result<(String, String, i64, TrialRow, String), Problem> {
    let device = body.device_id.trim().to_string();
    if device.len() < 8 || device.len() > 64 {
        return Err(Problem::bad("No device was named in that request."));
    }
    let at = now();
    let tz = context.store.trial_timezone(&device, body.tz_minutes).map_err(Problem::internal)?;
    let (day, resets_at) = day_for(tz, at);
    let ip = client_ip(headers);
    if !ip.is_empty() && !context.store.trial_known(&device, &day).map_err(Problem::internal)? {
        let count = context.store.trial_devices_on_ip(&ip, &day).map_err(Problem::internal)?;
        if count >= MAX_DEVICES_PER_IP {
            return Err(Problem::forbidden("Today's free minutes have already been used on this network. Get a licence to keep going."));
        }
    }
    let row = context.store.trial_row(&device, &day).map_err(Problem::internal)?;
    Ok((device, day, resets_at, row, ip))
}

pub async fn status(State(context): State<Shared>, headers: HeaderMap, Json(body): Json<TrialBody>) -> Result<Json<TrialAnswer>, Problem> {
    let (device, day, resets_at, row, ip) = prepare(&context, &body, &headers)?;
    context.store.trial_save(&device, &day, &row, &ip).map_err(Problem::internal)?;
    Ok(Json(answer(&context, &device, &row, day, resets_at, now())))
}

pub async fn start(State(context): State<Shared>, headers: HeaderMap, Json(body): Json<TrialBody>) -> Result<Json<TrialAnswer>, Problem> {
    let (device, day, resets_at, mut row, ip) = prepare(&context, &body, &headers)?;
    let at = now();
    if let Some(since) = row.active_since {
        let last = row.last_tick.unwrap_or(since);
        if at - last > TICK_GRACE {
            settle(&mut row, at);
        }
    }
    if row.used >= DAILY_SECONDS {
        context.store.trial_save(&device, &day, &row, &ip).map_err(Problem::internal)?;
        return Err(Problem::forbidden("Today's 30 free minutes are used up. They come back at midnight, or get a licence for unlimited use."));
    }
    if row.active_since.is_none() {
        row.active_since = Some(at);
    }
    row.last_tick = Some(at);
    context.store.trial_save(&device, &day, &row, &ip).map_err(Problem::internal)?;
    Ok(Json(answer(&context, &device, &row, day, resets_at, at)))
}

pub async fn tick(State(context): State<Shared>, headers: HeaderMap, Json(body): Json<TrialBody>) -> Result<Json<TrialAnswer>, Problem> {
    let (device, day, resets_at, mut row, ip) = prepare(&context, &body, &headers)?;
    let at = now();
    if let Some(since) = row.active_since {
        let last = row.last_tick.unwrap_or(since);
        if at - last > TICK_GRACE {
            settle(&mut row, at);
        } else {
            row.last_tick = Some(at);
            if live_used(&row, at) >= DAILY_SECONDS {
                settle(&mut row, at);
                row.used = DAILY_SECONDS;
            }
        }
    }
    context.store.trial_save(&device, &day, &row, &ip).map_err(Problem::internal)?;
    Ok(Json(answer(&context, &device, &row, day, resets_at, at)))
}

pub async fn stop(State(context): State<Shared>, headers: HeaderMap, Json(body): Json<TrialBody>) -> Result<Json<TrialAnswer>, Problem> {
    let (device, day, resets_at, mut row, ip) = prepare(&context, &body, &headers)?;
    let at = now();
    if row.active_since.is_some() {
        row.last_tick = Some(at);
        settle(&mut row, at);
    }
    context.store.trial_save(&device, &day, &row, &ip).map_err(Problem::internal)?;
    Ok(Json(answer(&context, &device, &row, day, resets_at, at)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settle_caps_at_last_tick_plus_grace() {
        let mut row = TrialRow { used: 100, active_since: Some(1_000), last_tick: Some(1_300) };
        settle(&mut row, 10_000);
        assert_eq!(row.used, 100 + 300 + TICK_GRACE);
        assert!(row.active_since.is_none());
    }

    #[test]
    fn settle_never_exceeds_allowance() {
        let mut row = TrialRow { used: DAILY_SECONDS - 10, active_since: Some(0), last_tick: Some(5_000) };
        settle(&mut row, 6_000);
        assert_eq!(row.used, DAILY_SECONDS);
    }

    #[test]
    fn day_rolls_at_local_midnight() {
        let (a, reset) = day_for(-420, 1_757_980_800);
        let (b, _) = day_for(-420, reset);
        assert_ne!(a, b);
    }
}
