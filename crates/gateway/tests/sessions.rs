//! Prüft, dass MCP-Sitzungen einen Neustart des Gateways überleben.
//!
//! Vor dem Sitzungsspeicher beantwortete der Gateway die alte
//! `Mcp-Session-Id` nach jedem Deploy mit `404 Not Found`; der Client verlor
//! den Zugang, bis er von sich aus neu verband.

use std::sync::Arc;

use axum::Router;
use axum::body::Body;
use axum::http::{
    Method, Request, StatusCode,
    header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HOST},
};
use http_body_util::BodyExt;
use mac_compute_gateway::{Config, Registry, Shared, router};
use mac_compute_jobs::{JobStore, Limits};
use tempfile::TempDir;
use tower::ServiceExt;

const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

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

/// Ein Gateway-Prozess: eigener Router, eigener Arbeitsspeicher.
fn process(config: &Config) -> Router {
    let shared = Shared::new(
        Registry::empty(),
        Arc::new(JobStore::in_memory(Limits::default()).expect("Queue")),
    );
    router(config, shared)
}

/// Schickt einen JSON-RPC-Aufruf an `/mcp`.
async fn call(
    process: &Router,
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

    let response = process.clone().oneshot(request).await.expect("Antwort");
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

fn initialize() -> serde_json::Value {
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": { "name": "test", "version": "0" }
        }
    })
}

fn tools_list(id: u64) -> serde_json::Value {
    serde_json::json!({ "jsonrpc": "2.0", "id": id, "method": "tools/list", "params": {} })
}

#[tokio::test]
async fn sitzung_ueberlebt_gateway_neustart() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let config = config(&dir);

    // Erster Prozess: Sitzung aufbauen.
    let first = process(&config);
    let (status, session, body) = call(&first, None, initialize()).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let session = session.expect("Sitzungs-ID aus dem Handshake");

    let (status, _, body) = call(&first, Some(&session), tools_list(2)).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "Sitzung lebt im laufenden Prozess: {body}"
    );

    // Zweiter Prozess (neuer Router, gleicher Zustand): alte ID bleibt gültig.
    let second = process(&config);
    let (status, _, body) = call(&second, Some(&session), tools_list(3)).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "nach dem Neustart wird die Sitzung wiederhergestellt statt 404: {body}"
    );
    assert!(body.contains("\"tools\""), "Antwort enthält die Tool-Liste");
}

#[tokio::test]
async fn nie_gesehene_sitzung_wird_wiederbelebt() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let config = config(&dir);
    let gateway = process(&config);

    // ID aus einem Prozess, der noch keinen Sitzungsspeicher hatte.
    let (status, _, body) = call(
        &gateway,
        Some("11111111-2222-3333-4444-555555555555"),
        tools_list(4),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "unbekannte IDs bekommen das Standardprofil statt 404: {body}"
    );
}

#[tokio::test]
async fn unbrauchbare_sitzungs_id_bleibt_ohne_datei() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let config = config(&dir);
    let gateway = process(&config);

    let (status, _, body) = call(&gateway, Some("../../etc/passwd"), tools_list(5)).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "kein Pfad-Ausbruch, kein Fehler: {body}"
    );

    let sessions = dir.path().join("state").join("sessions");
    let files: Vec<String> = std::fs::read_dir(&sessions)
        .expect("Sitzungsverzeichnis")
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    assert!(
        !files.iter().any(|name| name.contains("passwd")),
        "keine Datei außerhalb des Schemas: {files:?}"
    );
}
