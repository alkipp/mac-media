//! Prüft Discovery, Namespace und Tool-Routing des Gateways.

use mac_compute_gateway::{Backend, CAPABILITIES_TOOL, Registry};
use mcp_core::{Manifest, Transport};
use mock_mcp::MockServer;
use rmcp::{
    ServiceExt,
    model::{CallToolRequestParams, CallToolResponse},
    object,
};
use serde_json::Value;
use tempfile::TempDir;
use tokio::io::duplex;
use tokio::task::JoinHandle;

const TIMEOUT_MS: u64 = 1_000;

fn manifest(name: &str, command: Vec<String>, enabled: bool) -> Manifest {
    Manifest {
        name: name.to_string(),
        version: None,
        transport: Transport::Stdio,
        command,
        capabilities: vec!["test".to_string()],
        timeout: TIMEOUT_MS,
        max_memory_mb: 256,
        enabled,
    }
}

fn write_manifest(dir: &TempDir, file: &str, manifest: &Manifest) {
    let json = serde_json::to_string_pretty(manifest).expect("Manifest als JSON");
    std::fs::write(dir.path().join(file), json).expect("Manifest schreiben");
}

fn missing_binary() -> Vec<String> {
    vec!["/nonexistent/mock-mcp".to_string(), "--stdio".to_string()]
}

fn text_of(response: CallToolResponse) -> String {
    match response {
        CallToolResponse::Complete(result) => {
            let value = serde_json::to_value(&result).expect("Ergebnis als JSON");
            value["content"][0]["text"]
                .as_str()
                .expect("Text-Inhalt")
                .to_string()
        }
        _ => panic!("unerwartete Antwort des Gateways"),
    }
}

/// Startet den Mock in-process und verbindet ihn über einen Duplex-Kanal.
async fn registry_with_mock() -> (Registry, JoinHandle<()>) {
    let (client_io, server_io) = duplex(64 * 1024);
    let handle = tokio::spawn(async move {
        let service = MockServer::new()
            .serve(server_io)
            .await
            .expect("Mock startet");
        let _ = service.waiting().await;
    });

    let client = ().serve(client_io).await.expect("Client verbindet");
    let backend = Backend::from_service(manifest("mock", missing_binary(), true), client).await;
    (Registry::new(vec![backend]), handle)
}

#[tokio::test]
async fn missing_binary_marks_backend_down() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    write_manifest(
        &dir,
        "broken.json",
        &manifest("broken", missing_binary(), true),
    );

    let registry = Registry::load(dir.path()).await;
    let capabilities = registry.capabilities();

    assert_eq!(capabilities["backends"][0]["name"], "broken");
    assert_eq!(capabilities["backends"][0]["status"], "down");
    assert!(capabilities["backends"][0]["error"].is_string());
    assert_eq!(registry.tools().len(), 1, "nur capabilities");
}

#[tokio::test]
async fn invalid_manifest_is_skipped() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    std::fs::write(dir.path().join("bad.json"), "{ kein json").expect("Datei schreiben");
    write_manifest(
        &dir,
        "disabled.json",
        &manifest("disabled", missing_binary(), false),
    );

    let registry = Registry::load(dir.path()).await;
    let capabilities = registry.capabilities();

    assert_eq!(capabilities["backends"].as_array().expect("Liste").len(), 1);
    assert_eq!(capabilities["backends"][0]["name"], "disabled");
}

#[tokio::test]
async fn disabled_backend_has_no_tools() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    write_manifest(
        &dir,
        "disabled.json",
        &manifest("disabled", missing_binary(), false),
    );

    let registry = Registry::load(dir.path()).await;
    let capabilities = registry.capabilities();

    assert_eq!(capabilities["backends"][0]["status"], "disabled");
    assert_eq!(
        capabilities["backends"][0]["tools"]
            .as_array()
            .expect("Liste")
            .len(),
        0
    );
    assert_eq!(registry.tools().len(), 1, "nur capabilities");
}

#[tokio::test]
async fn duplicate_names_are_skipped() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    write_manifest(
        &dir,
        "a.json",
        &manifest("doppelt", missing_binary(), false),
    );
    write_manifest(
        &dir,
        "b.json",
        &manifest("doppelt", missing_binary(), false),
    );

    let registry = Registry::load(dir.path()).await;
    assert_eq!(
        registry.capabilities()["backends"]
            .as_array()
            .expect("Liste")
            .len(),
        1
    );
}

#[tokio::test]
async fn aggregiert_tools_und_routet_aufrufe() {
    let (mut registry, _server) = registry_with_mock().await;

    let mut names: Vec<String> = registry
        .tools()
        .iter()
        .map(|tool| tool.name.to_string())
        .collect();
    names.sort();
    assert_eq!(names, [CAPABILITIES_TOOL, "mock_echo", "mock_sleep"]);

    let result = registry
        .call(
            CallToolRequestParams::new("mock_echo")
                .with_arguments(object!({ "message": "über den Gateway" })),
        )
        .await
        .expect("echo läuft");
    assert_eq!(text_of(result), "über den Gateway");

    let result = registry
        .call(CallToolRequestParams::new(CAPABILITIES_TOOL))
        .await
        .expect("capabilities läuft");
    let capabilities: Value = serde_json::from_str(&text_of(result)).expect("JSON");
    assert_eq!(capabilities["backends"][0]["status"], "up");
    assert_eq!(capabilities["backends"][0]["name"], "mock");
    assert_eq!(capabilities["backends"][0]["timeout"], TIMEOUT_MS);
    assert_eq!(capabilities["backends"][0]["maxMemoryMB"], 256);
}

#[tokio::test]
async fn capabilities_tool_hat_objektschema() {
    let (registry, _server) = registry_with_mock().await;
    let tools = registry.tools();
    let capabilities = tools
        .iter()
        .find(|tool| tool.name == CAPABILITIES_TOOL)
        .expect("capabilities ist vorhanden");

    assert_eq!(
        capabilities
            .input_schema
            .get("type")
            .and_then(|value| value.as_str()),
        Some("object"),
        "OpenCode verlangt ein Objekt-Schema"
    );
}

#[tokio::test]
async fn unbekanntes_tool_ist_ein_fehler() {
    let (mut registry, _server) = registry_with_mock().await;

    let error = registry
        .call(CallToolRequestParams::new("mock_gibtsnicht"))
        .await
        .expect_err("unbekanntes Tool");
    assert!(error.to_string().contains("Unbekanntes Tool"));
}

#[tokio::test]
async fn timeout_wird_erzwungen() {
    let (mut registry, _server) = registry_with_mock().await;

    let error = registry
        .call(CallToolRequestParams::new("mock_sleep").with_arguments(object!({ "ms": 2_000 })))
        .await
        .expect_err("Timeout");
    assert!(
        error.to_string().contains("Zeitlimit"),
        "unerwarteter Fehler: {error}"
    );
}
