//! Prüft Bearer-Schutz und Konfigurationsregeln des Gateways.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use axum::body::Body;
use axum::http::{
    Method, Request, StatusCode,
    header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HOST, WWW_AUTHENTICATE},
};
use http_body_util::BodyExt;
use mac_compute_gateway::{
    Config, ConfigError, MIN_TOKEN_LEN, Registry, Shared, TokenGrace, router,
};
use mac_compute_jobs::{JobStore, Limits};
use std::sync::Arc;
use tempfile::TempDir;
use tower::ServiceExt;

const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// Abgelöster Token, formal gleich aufgebaut, aber verschieden.
const PREVIOUS: &str = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";

fn setup() -> (TempDir, Config) {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, format!("{TOKEN}\n")).expect("Token schreiben");
    let config = Config::new(
        "127.0.0.1:8787".parse().expect("Adresse"),
        dir.path().to_path_buf(),
        &token_file,
        None,
    )
    .expect("Konfiguration ist gültig");
    (dir, config)
}

/// Leere Warteschlange im Arbeitsspeicher.
fn queue() -> Arc<JobStore> {
    Arc::new(JobStore::in_memory(Limits::default()).expect("Queue"))
}

fn request(method: Method, uri: &str, token: Option<&str>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header(AUTHORIZATION, format!("Bearer {token}"));
    }
    builder.body(Body::empty()).expect("Request")
}

#[tokio::test]
async fn health_without_token_is_unauthorized() {
    let (_dir, config) = setup();
    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(request(Method::GET, "/health", None))
        .await
        .expect("Antwort");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        response
            .headers()
            .get(WWW_AUTHENTICATE)
            .map(|value| value.as_bytes()),
        Some(b"Bearer".as_slice())
    );
}

#[tokio::test]
async fn health_with_wrong_token_is_unauthorized() {
    let (_dir, config) = setup();
    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(request(Method::GET, "/health", Some("falscher-token")))
        .await
        .expect("Antwort");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn health_with_token_returns_ok() {
    let (_dir, config) = setup();
    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(request(Method::GET, "/health", Some(TOKEN)))
        .await
        .expect("Antwort");

    assert_eq!(response.status(), StatusCode::OK);
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("Body")
        .to_bytes();
    let value: serde_json::Value = serde_json::from_slice(&bytes).expect("JSON");
    assert_eq!(value["status"], "ok");
    assert_eq!(value["service"], "mac-compute-gateway");
}

#[tokio::test]
async fn bearer_scheme_is_case_insensitive() {
    let (_dir, config) = setup();
    let request = Request::builder()
        .method(Method::GET)
        .uri("/health")
        .header(AUTHORIZATION, format!("bearer {TOKEN}"))
        .body(Body::empty())
        .expect("Request");

    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(request)
        .await
        .expect("Antwort");
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn mcp_without_token_is_unauthorized() {
    let (_dir, config) = setup();
    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(request(Method::POST, "/mcp", None))
        .await
        .expect("Antwort");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn non_loopback_bind_is_rejected() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, TOKEN).expect("Token schreiben");

    let error = Config::new(
        "0.0.0.0:8787".parse::<SocketAddr>().expect("Adresse"),
        dir.path().to_path_buf(),
        &token_file,
        None,
    )
    .expect_err("0.0.0.0 muss abgelehnt werden");
    assert!(matches!(error, ConfigError::NonLoopbackBind(_)));
}

#[tokio::test]
async fn short_token_is_rejected() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, "zu-kurz").expect("Token schreiben");

    let error = Config::new(
        "127.0.0.1:8787".parse().expect("Adresse"),
        dir.path().to_path_buf(),
        &token_file,
        None,
    )
    .expect_err("kurzer Token muss abgelehnt werden");
    assert!(matches!(error, ConfigError::TokenTooShort));
    assert!(error.to_string().contains(&MIN_TOKEN_LEN.to_string()));
}

#[tokio::test]
async fn missing_token_file_is_rejected() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let token_file = dir.path().join("fehlt");

    let error = Config::new(
        "127.0.0.1:8787".parse().expect("Adresse"),
        dir.path().to_path_buf(),
        &token_file,
        None,
    )
    .expect_err("fehlende Datei muss abgelehnt werden");
    assert!(matches!(error, ConfigError::TokenFile { .. }));
}

#[tokio::test]
async fn missing_servers_dir_is_rejected() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, TOKEN).expect("Token schreiben");

    let error = Config::new(
        "127.0.0.1:8787".parse().expect("Adresse"),
        dir.path().join("servers.d"),
        &token_file,
        None,
    )
    .expect_err("fehlendes Verzeichnis muss abgelehnt werden");
    assert!(matches!(error, ConfigError::ServersDirMissing(_)));
}

#[tokio::test]
async fn relative_servers_dir_is_rejected() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, TOKEN).expect("Token schreiben");

    let error = Config::new(
        "127.0.0.1:8787".parse().expect("Adresse"),
        PathBuf::from("servers.d"),
        &token_file,
        None,
    )
    .expect_err("relativer Pfad muss abgelehnt werden");
    assert!(matches!(error, ConfigError::ServersDirRelative(_)));
}

fn mcp_request(host: &str) -> Request<Body> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": { "name": "test", "version": "0" }
        }
    })
    .to_string();

    Request::builder()
        .method(Method::POST)
        .uri("/mcp")
        .header(AUTHORIZATION, format!("Bearer {TOKEN}"))
        .header(HOST, host)
        .header(CONTENT_TYPE, "application/json")
        .header(ACCEPT, "application/json, text/event-stream")
        .body(Body::from(body))
        .expect("Request")
}

#[tokio::test]
async fn container_host_is_allowed() {
    let (_dir, config) = setup();
    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(mcp_request("host.containers.internal:8787"))
        .await
        .expect("Antwort");

    assert_ne!(
        response.status(),
        StatusCode::FORBIDDEN,
        "der Podman-Host muss erlaubt sein"
    );
}

#[tokio::test]
async fn foreign_host_is_rejected() {
    let (_dir, config) = setup();
    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(mcp_request("evil.example"))
        .await
        .expect("Antwort");

    assert_eq!(
        response.status(),
        StatusCode::FORBIDDEN,
        "fremde Host-Header bleiben gesperrt"
    );
}

#[tokio::test]
async fn log_dir_is_created_and_validated() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, TOKEN).expect("Token schreiben");
    let log_dir = dir.path().join("logs");

    Config::new(
        "127.0.0.1:8787".parse().expect("Adresse"),
        dir.path().to_path_buf(),
        &token_file,
        Some(log_dir.clone()),
    )
    .expect("Log-Verzeichnis wird angelegt");
    assert!(log_dir.is_dir());

    let error = Config::new(
        "127.0.0.1:8787".parse().expect("Adresse"),
        dir.path().to_path_buf(),
        &token_file,
        Some(PathBuf::from("logs")),
    )
    .expect_err("relativer Pfad muss abgelehnt werden");
    assert!(matches!(error, ConfigError::LogDirRelative(_)));
}

#[tokio::test]
async fn abgeloester_token_gilt_bis_zum_ablauf() {
    let (_dir, mut config) = setup();
    config.previous = Some(TokenGrace {
        token: PREVIOUS.to_string(),
        until: SystemTime::now() + Duration::from_secs(3_600),
    });

    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(request(Method::GET, "/health", Some(PREVIOUS)))
        .await
        .expect("Antwort");
    assert_eq!(response.status(), StatusCode::OK);

    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(request(Method::GET, "/health", Some(TOKEN)))
        .await
        .expect("Antwort");
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "aktueller Token bleibt gültig"
    );
}

#[tokio::test]
async fn abgeloester_token_ist_nach_dem_ablauf_ungueltig() {
    let (_dir, mut config) = setup();
    config.previous = Some(TokenGrace {
        token: PREVIOUS.to_string(),
        until: SystemTime::now() - Duration::from_secs(1),
    });

    let response = router(&config, Shared::new(Registry::empty(), queue()))
        .oneshot(request(Method::GET, "/health", Some(PREVIOUS)))
        .await
        .expect("Antwort");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn with_grace_liest_token_previous() {
    let (_dir, config) = setup();
    std::fs::write(
        config.token_file.with_file_name("token.previous"),
        format!("{PREVIOUS}\n"),
    )
    .expect("vorherigen Token schreiben");

    let with_grace = config
        .clone()
        .with_grace(Duration::from_secs(3_600))
        .expect("Übergangsfrist");
    let previous = with_grace.previous.expect("vorheriger Token");
    assert_eq!(previous.token, PREVIOUS);
    assert!(previous.until > SystemTime::now());

    let without = config
        .clone()
        .with_grace(Duration::ZERO)
        .expect("abgeschaltet");
    assert!(
        without.previous.is_none(),
        "0 Stunden schaltet die Frist ab"
    );

    std::fs::remove_file(config.token_file.with_file_name("token.previous"))
        .expect("Datei löschen");
    let missing = config
        .with_grace(Duration::from_secs(3_600))
        .expect("ohne Datei");
    assert!(missing.previous.is_none());
}

#[tokio::test]
async fn ungueltiger_vorheriger_token_bricht_den_start_ab() {
    let (_dir, config) = setup();
    std::fs::write(
        config.token_file.with_file_name("token.previous"),
        "zu-kurz",
    )
    .expect("Datei schreiben");

    let error = config
        .with_grace(Duration::from_secs(3_600))
        .expect_err("zu kurzer Token muss abgelehnt werden");
    assert!(
        matches!(error, ConfigError::PreviousTokenInvalid { .. }),
        "{error}"
    );
}
