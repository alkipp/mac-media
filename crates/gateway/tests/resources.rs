//! Prüft die Ressourcen des Gateways über den MCP-Endpunkt.
//!
//! Ohne `resources`-Capability beantwortet der Gateway `resources/list` und
//! `resources/read` mit "method not found"; Clients, die eine Ressource lesen
//! wollen (OpenCode: `read_mcp_resource`), melden dann "does not expose
//! resources".

use std::sync::Arc;

use axum::body::Body;
use axum::http::{
    Method, Request, StatusCode,
    header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HOST},
};
use http_body_util::BodyExt;
use mac_compute_gateway::{Config, Gateway, Registry, Shared, TOOLS_RESOURCE_URI, router};
use mac_compute_jobs::{JobStore, Limits};
use rmcp::ServerHandler;
use tempfile::TempDir;
use tower::ServiceExt;

const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn shared() -> Arc<Shared> {
    Shared::new(
        Registry::empty(),
        Arc::new(JobStore::in_memory(Limits::default()).expect("Queue")),
    )
}

#[test]
fn initialize_advertises_resources() {
    let capabilities = Gateway::new(shared()).get_info().capabilities;
    assert!(
        capabilities.resources.is_some(),
        "resources-Capability muss angekündigt sein"
    );
}

fn config(dir: &TempDir) -> Config {
    let token_file = dir.path().join("token");
    std::fs::write(&token_file, format!("{TOKEN}\n")).expect("Token schreiben");
    let servers = dir.path().join("servers.d");
    std::fs::create_dir_all(&servers).expect("Manifest-Verzeichnis");
    Config::with_state_dir(
        "127.0.0.1:8787".parse().expect("Adresse"),
        servers,
        dir.path().join("state"),
        &token_file,
        None,
    )
    .expect("Konfiguration ist gültig")
}

/// Schickt einen JSON-RPC-Aufruf und liefert die Antwort aus dem SSE-Strom.
async fn call(
    config: &Config,
    session: Option<&str>,
    body: serde_json::Value,
) -> (StatusCode, Option<String>, String) {
    let mut builder = Request::builder()
        .method(Method::POST)
        .uri("/mcp")
        .header(AUTHORIZATION, format!("Bearer {TOKEN}"))
        .header(CONTENT_TYPE, "application/json")
        .header(HOST, "localhost")
        .header(ACCEPT, "application/json, text/event-stream");
    if let Some(session) = session {
        builder = builder.header("Mcp-Session-Id", session);
    }
    let request = builder.body(Body::from(body.to_string())).expect("Request");
    let response = router(config, shared())
        .oneshot(request)
        .await
        .expect("Antwort");
    let status = response.status();
    let session = response
        .headers()
        .get("mcp-session-id")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("Body")
        .to_bytes();
    (
        status,
        session,
        String::from_utf8_lossy(&bytes).into_owned(),
    )
}

fn payload(body: &str) -> serde_json::Value {
    body.lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .filter_map(|data| serde_json::from_str::<serde_json::Value>(data).ok())
        .next_back()
        .expect("JSON-RPC-Antwort im SSE-Strom")
}

#[tokio::test]
async fn tools_resource_ist_lesbar() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let config = config(&dir);

    let (status, session, _) = call(
        &config,
        None,
        serde_json::json!({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": { "name": "test", "version": "0" }
            }
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let session = session.expect("Sitzungs-ID");

    let (status, _, body) = call(
        &config,
        Some(&session),
        serde_json::json!({ "jsonrpc": "2.0", "id": 2, "method": "resources/list", "params": {} }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let listed = payload(&body);
    assert_eq!(listed["result"]["resources"][0]["uri"], TOOLS_RESOURCE_URI);

    let (status, _, body) = call(
        &config,
        Some(&session),
        serde_json::json!({
            "jsonrpc": "2.0", "id": 3, "method": "resources/read",
            "params": { "uri": TOOLS_RESOURCE_URI }
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let read = payload(&body);
    let text = read["result"]["contents"][0]["text"]
        .as_str()
        .expect("Text-Ressource");
    let tools: serde_json::Value = serde_json::from_str(text).expect("JSON");
    assert!(tools.is_array(), "Tool-Liste als JSON-Array");
}

#[tokio::test]
async fn unbekannte_ressource_ist_ein_fehler() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let config = config(&dir);
    let (_, session, _) = call(
        &config,
        None,
        serde_json::json!({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": { "name": "test", "version": "0" }
            }
        }),
    )
    .await;
    let session = session.expect("Sitzungs-ID");

    let (status, _, body) = call(
        &config,
        Some(&session),
        serde_json::json!({
            "jsonrpc": "2.0", "id": 2, "method": "resources/read",
            "params": { "uri": "mac-media://gibt-es-nicht" }
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let error = payload(&body);
    assert_eq!(error["error"]["code"], -32002, "Resource not found");
}
