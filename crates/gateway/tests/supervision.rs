//! Prüft Reload und Aufsicht: Backend-Crash und Timeout beenden das Gateway
//! nicht, das Backend wird als `down` markiert und neu gestartet.

use std::sync::Arc;
use std::time::Duration;

use mac_compute_gateway::{Backend, Backoff, Registry, Shared};
use mac_compute_jobs::{JobStore, Limits};
use mcp_core::{Manifest, Transport};
use mock_mcp::MockServer;
use rmcp::{ServiceExt, model::CallToolRequestParams, object};
use tokio::io::duplex;
use tokio::task::JoinHandle;

const TIMEOUT_MS: u64 = 1_000;

fn manifest(name: &str, enabled: bool) -> Manifest {
    Manifest {
        name: name.to_string(),
        version: None,
        transport: Transport::Stdio,
        command: vec!["/nonexistent/mock-mcp".to_string(), "--stdio".to_string()],
        capabilities: vec!["test".to_string()],
        timeout: TIMEOUT_MS,
        max_memory_mb: 256,
        enabled,
    }
}

async fn shared_with_mock(backoff: Backoff) -> (Arc<Shared>, JoinHandle<()>) {
    let (client_io, server_io) = duplex(64 * 1024);
    let handle = tokio::spawn(async move {
        let service = MockServer::new()
            .serve(server_io)
            .await
            .expect("Mock startet");
        let _ = service.waiting().await;
    });

    let client = ().serve(client_io).await.expect("Client verbindet");
    let backend = Backend::from_service(manifest("mock", true), client).await;
    let queue = Arc::new(JobStore::in_memory(Limits::default()).expect("Queue"));
    (
        Shared::with_backoff(Registry::new(vec![backend]), backoff, queue),
        handle,
    )
}

fn tool_names(tools: &[rmcp::model::Tool]) -> Vec<String> {
    let mut names: Vec<String> = tools.iter().map(|tool| tool.name.to_string()).collect();
    names.sort();
    names
}

/// Tools, die das Gateway selbst bereitstellt.
fn gateway_tools() -> Vec<String> {
    let mut names = [
        "capabilities",
        "job_cancel",
        "job_status",
        "metrics",
        "submit_job",
        "workers",
    ]
    .map(str::to_string)
    .to_vec();
    names.sort();
    names
}

#[tokio::test]
async fn reload_ersetzt_die_registry() {
    let (shared, _server) = shared_with_mock(Backoff::default()).await;
    assert!(tool_names(&shared.tools().await).contains(&"mock_echo".to_string()));

    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let disabled = serde_json::to_string_pretty(&manifest("mock", false)).expect("JSON");
    std::fs::write(dir.path().join("mock.json"), disabled).expect("Manifest schreiben");

    shared.reload(dir.path()).await;

    assert_eq!(tool_names(&shared.tools().await), gateway_tools());
    assert_eq!(
        shared.capabilities().await["backends"][0]["status"],
        "disabled"
    );
}

#[tokio::test]
async fn timeout_markiert_backend_als_down() {
    let (shared, _server) = shared_with_mock(Backoff::default()).await;

    let error = shared
        .call(CallToolRequestParams::new("mock_sleep").with_arguments(object!({ "ms": 2_000 })))
        .await
        .expect_err("Timeout muss ein Fehler sein");
    assert!(
        error.to_string().contains("Zeitlimit"),
        "unerwarteter Fehler: {error}"
    );

    assert_eq!(shared.capabilities().await["backends"][0]["status"], "down");
    assert_eq!(tool_names(&shared.tools().await), gateway_tools());
}

#[tokio::test]
async fn crash_wird_erkannt_und_neustart_versucht() {
    let backoff = Backoff {
        attempts: 1,
        base: Duration::from_millis(1),
    };
    let (shared, server) = shared_with_mock(backoff).await;
    server.abort();

    let mut restarted = None;
    for _ in 0..100 {
        if let Some(name) = shared.supervise_once().await {
            restarted = Some(name);
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    assert_eq!(restarted.as_deref(), Some("mock"), "Crash wurde erkannt");
    assert_eq!(
        shared.capabilities().await["backends"][0]["status"],
        "down",
        "Neustart scheitert am fehlenden Binary"
    );
    assert_eq!(tool_names(&shared.tools().await), gateway_tools());
}

#[tokio::test]
async fn gateway_bleibt_ohne_sessions_funktionsfaehig() {
    let (shared, _server) = shared_with_mock(Backoff::default()).await;
    shared.notify_tools_changed().await;
    assert!(tool_names(&shared.tools().await).contains(&"mock_echo".to_string()));
}
