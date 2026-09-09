//! Licences and update checks for Cloak.
//!
//! One binary, one SQLite file, no runtime dependencies. Run it behind
//! whatever already terminates TLS on the box.

mod gate;
mod keys;
mod store;

use std::net::SocketAddr;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use rand::Rng;
use serde::{Deserialize, Serialize};
use tower_http::cors::CorsLayer;

use keys::Keys;
use store::{now, Release, Store};

/// How long a signed token is good for before the phone has to ask again.
/// Generous on purpose: a server that is down for a fortnight should not turn
/// every paying customer's app off.
const TOKEN_DAYS: i64 = 14;

struct Context {
    store: Store,
    keys: Keys,
    admin_token: String,
    /// Where the developer disk image lives. This is the part of Cloak that
    /// is not shipped inside the app, so a copy with the licence check torn
    /// out still cannot simulate anything.
    ddi_dir: std::path::PathBuf,
}

type Shared = Arc<Context>;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,cloak_server=info".into()),
        )
        .init();

    let database = std::env::var("CLOAK_DB").unwrap_or_else(|_| "cloak.sqlite".into());
    let key_path = std::env::var("CLOAK_KEY").unwrap_or_else(|_| "cloak-signing.key".into());
    let admin_token = std::env::var("CLOAK_ADMIN_TOKEN").unwrap_or_default();
    let port: u16 = std::env::var("CLOAK_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(8787);

    if admin_token.is_empty() {
        eprintln!("Set CLOAK_ADMIN_TOKEN before starting, or anyone can mint licences.");
        std::process::exit(1);
    }

    let ddi_dir: std::path::PathBuf = std::env::var("CLOAK_DDI_DIR")
        .unwrap_or_else(|_| "ddi".into())
        .into();

    let store = Store::open(&database)?;
    let keys = Keys::load_or_create(std::path::Path::new(&key_path))?;

    println!();
    println!("  Public key for the app: {}", keys.public_base64());
    println!("  Paste that into Licensing.serverPublicKey in CloakKit.");
    println!();

    for name in DDI_FILES {
        if !ddi_dir.join(name).exists() {
            eprintln!("  Missing {}/{name}. Cloak cannot finish setup until it is there.", ddi_dir.display());
        }
    }

    let context: Shared = Arc::new(Context { store, keys, admin_token, ddi_dir });

    let app = Router::new()
        .route("/v1/health", get(health))
        .route("/v1/pubkey", get(pubkey))
        .route("/v1/activate", post(activate))
        .route("/v1/validate", post(validate))
        .route("/v1/deactivate", post(deactivate))
        .route("/v1/update", get(update))
        .route("/v1/ddi/{name}", get(developer_image))
        .route("/v1/admin/licenses", get(list_licenses).post(create_license))
        .route("/v1/admin/revoke", post(revoke))
        .route("/v1/admin/release", post(publish_release))
        .layer(CorsLayer::permissive())
        .with_state(context);

    let address = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(address).await?;
    tracing::info!("listening on {address}");
    axum::serve(listener, app).await?;
    Ok(())
}

// MARK: - Public

async fn health() -> impl IntoResponse {
    Json(serde_json::json!({ "ok": true }))
}

/// The public half of the signing key.
///
/// Public by definition, and serving it means the app can be pointed at a
/// server with one command instead of somebody copying base64 out of a log
/// and into a source file by hand.
async fn pubkey(State(context): State<Shared>) -> impl IntoResponse {
    Json(serde_json::json!({ "public_key": context.keys.public_base64() }))
}

#[derive(Deserialize)]
struct ActivateBody {
    license: String,
    device_id: String,
    #[serde(default)]
    device_name: String,
}

#[derive(Serialize)]
struct TokenBody {
    token: String,
    plan: String,
    expires_at: i64,
}

#[derive(Serialize)]
struct Claims<'a> {
    lic: &'a str,
    dev: &'a str,
    plan: &'a str,
    exp: i64,
    iat: i64,
}

async fn activate(
    State(context): State<Shared>,
    Json(body): Json<ActivateBody>,
) -> Result<Json<TokenBody>, Problem> {
    let key = normalise(&body.license);
    if body.device_id.trim().is_empty() {
        return Err(Problem::bad("No device was named in that request."));
    }

    let license = context
        .store
        .license(&key)
        .map_err(Problem::internal)?
        .ok_or_else(|| Problem::not_found("That licence key does not exist. Check it for typos."))?;

    if license.revoked {
        return Err(Problem::forbidden("That licence has been withdrawn."));
    }
    if let Some(expiry) = license.expires_at {
        if expiry < now() {
            return Err(Problem::forbidden("That licence has expired."));
        }
    }

    // One device per licence. The rule is enforced by there being room for
    // exactly one row, not by counting.
    match context.store.activation(&key).map_err(Problem::internal)? {
        Some(existing) if existing.device_id != body.device_id => {
            return Err(Problem::conflict(format!(
                "That licence is already in use on {}. Release it there first, or use the release link on your receipt.",
                if existing.device_name.is_empty() { "another device".into() } else { existing.device_name }
            )));
        }
        _ => {}
    }

    context
        .store
        .activate(&key, &body.device_id, &body.device_name)
        .map_err(Problem::internal)?;

    Ok(Json(mint(&context, &key, &body.device_id, &license.plan)))
}

fn mint(context: &Context, license: &str, device: &str, plan: &str) -> TokenBody {
    let expires_at = now() + TOKEN_DAYS * 86_400;
    let claims = Claims { lic: license, dev: device, plan, exp: expires_at, iat: now() };
    let payload = serde_json::to_vec(&claims).unwrap_or_default();
    TokenBody { token: context.keys.sign(&payload), plan: plan.to_string(), expires_at }
}

#[derive(Deserialize)]
struct ValidateBody {
    license: String,
    device_id: String,
}

/// Called quietly by the app while it still has a valid token, so a licence
/// withdrawn today stops working within a fortnight rather than never.
async fn validate(
    State(context): State<Shared>,
    Json(body): Json<ValidateBody>,
) -> Result<Json<TokenBody>, Problem> {
    let key = normalise(&body.license);
    let license = context
        .store
        .license(&key)
        .map_err(Problem::internal)?
        .ok_or_else(|| Problem::not_found("That licence key does not exist."))?;

    if license.revoked {
        return Err(Problem::forbidden("That licence has been withdrawn."));
    }
    if let Some(expiry) = license.expires_at {
        if expiry < now() {
            return Err(Problem::forbidden("That licence has expired."));
        }
    }

    match context.store.activation(&key).map_err(Problem::internal)? {
        Some(existing) if existing.device_id == body.device_id => {
            let _ = context.store.touch(&key);
            Ok(Json(mint(&context, &key, &body.device_id, &license.plan)))
        }
        Some(_) => Err(Problem::conflict("That licence is in use on a different device.")),
        None => Err(Problem::not_found("That licence is not active on any device.")),
    }
}

#[derive(Deserialize)]
struct DeactivateBody {
    license: String,
    device_id: String,
}

/// Lets somebody move to a new phone without being told to email support.
async fn deactivate(
    State(context): State<Shared>,
    Json(body): Json<DeactivateBody>,
) -> Result<Json<serde_json::Value>, Problem> {
    let key = normalise(&body.license);
    match context.store.activation(&key).map_err(Problem::internal)? {
        Some(existing) if existing.device_id == body.device_id => {
            context.store.deactivate(&key).map_err(Problem::internal)?;
            Ok(Json(serde_json::json!({ "ok": true })))
        }
        Some(_) => Err(Problem::forbidden(
            "Only the device currently using this licence can release it.",
        )),
        None => Ok(Json(serde_json::json!({ "ok": true }))),
    }
}

#[derive(Deserialize)]
struct UpdateQuery {
    #[serde(default = "ios")]
    platform: String,
    #[serde(default)]
    build: i64,
}

fn ios() -> String {
    "ios".into()
}

async fn update(
    State(context): State<Shared>,
    Query(query): Query<UpdateQuery>,
) -> Result<Json<serde_json::Value>, Problem> {
    let release = context.store.release(&query.platform).map_err(Problem::internal)?;
    let Some(release) = release else {
        return Ok(Json(serde_json::json!({ "available": false })));
    };

    Ok(Json(serde_json::json!({
        "available": release.build > query.build,
        "build": release.build,
        "version": release.version,
        "url": release.url,
        "notes": release.notes,
        "required": release.required,
    })))
}

// MARK: - The developer disk image

/// The three files iOS needs before it will simulate anything.
const DDI_FILES: [&str; 3] = ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"];

/// Serves the developer disk image, to a licensed device only.
///
/// This is what turns the licence from a switch into a dependency. A patched
/// app that skips every check still has no image, and without the image iOS
/// will not expose the location service at all, so there is nothing to
/// simulate with. Getting round it means sourcing the image separately rather
/// than flipping a boolean.
async fn developer_image(
    State(context): State<Shared>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, Problem> {
    if !DDI_FILES.contains(&name.as_str()) {
        return Err(Problem::not_found("No such file."));
    }

    let token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .unwrap_or_default();

    gate::check(&context.keys, &context.store, token)
        .map_err(|refusal| Problem::forbidden(refusal.message()))?;

    let path = context.ddi_dir.join(&name);
    let bytes = tokio::fs::read(&path).await.map_err(|_| {
        Problem::not_found("That file is not on this server yet. Put the developer disk image in the ddi folder.")
    })?;

    Ok((
        [
            (axum::http::header::CONTENT_TYPE, "application/octet-stream"),
            (axum::http::header::CACHE_CONTROL, "no-store"),
        ],
        Body::from(bytes),
    ))
}

// MARK: - Admin

fn check_admin(context: &Context, headers: &HeaderMap) -> Result<(), Problem> {
    let given = headers
        .get("x-admin-token")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    if given == context.admin_token && !given.is_empty() {
        Ok(())
    } else {
        Err(Problem::forbidden("No."))
    }
}

#[derive(Deserialize)]
struct CreateBody {
    #[serde(default = "standard")]
    plan: String,
    #[serde(default)]
    note: String,
    #[serde(default = "one")]
    count: usize,
    #[serde(default)]
    days: Option<i64>,
}

fn standard() -> String {
    "standard".into()
}

fn one() -> usize {
    1
}

async fn create_license(
    State(context): State<Shared>,
    headers: HeaderMap,
    Json(body): Json<CreateBody>,
) -> Result<Json<serde_json::Value>, Problem> {
    check_admin(&context, &headers)?;

    let expires_at = body.days.map(|days| now() + days * 86_400);
    let mut made = Vec::new();
    for _ in 0..body.count.clamp(1, 500) {
        let key = fresh_key();
        context
            .store
            .create_license(&key, &body.plan, &body.note, expires_at)
            .map_err(Problem::internal)?;
        made.push(key);
    }
    Ok(Json(serde_json::json!({ "licenses": made })))
}

async fn list_licenses(
    State(context): State<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, Problem> {
    check_admin(&context, &headers)?;
    let rows = context.store.all_licenses().map_err(Problem::internal)?;
    let list: Vec<_> = rows
        .into_iter()
        .map(|(license, activation)| {
            serde_json::json!({
                "key": license.key,
                "plan": license.plan,
                "note": license.note,
                "created_at": license.created_at,
                "expires_at": license.expires_at,
                "revoked": license.revoked,
                "device": activation.as_ref().map(|a| serde_json::json!({
                    "id": a.device_id,
                    "name": a.device_name,
                    "activated_at": a.activated_at,
                    "last_seen": a.last_seen,
                })),
            })
        })
        .collect();
    Ok(Json(serde_json::json!({ "licenses": list })))
}

#[derive(Deserialize)]
struct RevokeBody {
    license: String,
    #[serde(default)]
    revoked: bool,
    #[serde(default)]
    release_device: bool,
}

async fn revoke(
    State(context): State<Shared>,
    headers: HeaderMap,
    Json(body): Json<RevokeBody>,
) -> Result<Json<serde_json::Value>, Problem> {
    check_admin(&context, &headers)?;
    let key = normalise(&body.license);
    let changed = context.store.set_revoked(&key, body.revoked).map_err(Problem::internal)?;
    if body.release_device {
        let _ = context.store.deactivate(&key);
    }
    Ok(Json(serde_json::json!({ "ok": changed > 0 })))
}

#[derive(Deserialize)]
struct ReleaseBody {
    #[serde(default = "ios")]
    platform: String,
    build: i64,
    version: String,
    url: String,
    #[serde(default)]
    notes: String,
    #[serde(default)]
    required: bool,
}

async fn publish_release(
    State(context): State<Shared>,
    headers: HeaderMap,
    Json(body): Json<ReleaseBody>,
) -> Result<Json<serde_json::Value>, Problem> {
    check_admin(&context, &headers)?;
    context
        .store
        .publish(&Release {
            platform: body.platform,
            build: body.build,
            version: body.version,
            url: body.url,
            notes: body.notes,
            required: body.required,
        })
        .map_err(Problem::internal)?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

// MARK: - Keys and errors

/// Readable, unambiguous, and awkward to mistype. No letters that look like
/// digits, grouped so somebody can read one down a phone line.
fn fresh_key() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut generator = rand::thread_rng();
    let mut groups = Vec::new();
    for _ in 0..4 {
        let group: String = (0..5)
            .map(|_| ALPHABET[generator.gen_range(0..ALPHABET.len())] as char)
            .collect();
        groups.push(group);
    }
    format!("CLOAK-{}", groups.join("-"))
}

fn normalise(key: &str) -> String {
    key.trim().to_uppercase().replace(' ', "")
}

struct Problem {
    status: StatusCode,
    message: String,
}

impl Problem {
    fn bad(message: impl Into<String>) -> Self {
        Self { status: StatusCode::BAD_REQUEST, message: message.into() }
    }
    fn not_found(message: impl Into<String>) -> Self {
        Self { status: StatusCode::NOT_FOUND, message: message.into() }
    }
    fn forbidden(message: impl Into<String>) -> Self {
        Self { status: StatusCode::FORBIDDEN, message: message.into() }
    }
    fn conflict(message: impl Into<String>) -> Self {
        Self { status: StatusCode::CONFLICT, message: message.into() }
    }
    fn internal(error: impl std::fmt::Display) -> Self {
        tracing::error!("{error}");
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: "Something went wrong here rather than at your end. Try again shortly.".into(),
        }
    }
}

impl IntoResponse for Problem {
    fn into_response(self) -> axum::response::Response {
        (self.status, Json(serde_json::json!({ "error": self.message }))).into_response()
    }
}
