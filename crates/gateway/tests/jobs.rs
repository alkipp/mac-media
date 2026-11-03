//! Prüft die Aufgaben-Werkzeuge des Gateways gegen das Test-Backend.

use std::sync::Arc;
use std::time::Duration;

use mac_compute_gateway::{Backend, Registry, Shared};
use mac_compute_jobs::{JobStore, Limits};
use mcp_core::{Manifest, Transport};
use mock_mcp::MockServer;
use rmcp::{
    ServiceExt,
    model::{CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock},
};
use serde_json::Value;
use tokio::io::duplex;
use tokio::task::JoinHandle;

const TIMEOUT_MS: u64 = 10_000;

fn manifest() -> Manifest {
    Manifest {
        name: "mock".to_string(),
        version: None,
        transport: Transport::Stdio,
        command: vec!["/nonexistent/mock-mcp".to_string(), "--stdio".to_string()],
        capabilities: vec!["test".to_string()],
        timeout: TIMEOUT_MS,
        max_memory_mb: 256,
        enabled: true,
    }
}

/// Baut Gateway und Backend über eine In-Process-Verbindung.
///
/// Der Store wird zusätzlich zurückgegeben, damit Tests Aufgaben ohne Worker
/// direkt anlegen und abschließen können.
async fn setup(limits: Limits) -> (Arc<Shared>, JoinHandle<()>, Arc<JobStore>) {
    let (client_io, server_io) = duplex(64 * 1024);
    let server = tokio::spawn(async move {
        let service = MockServer::new()
            .serve(server_io)
            .await
            .expect("Mock startet");
        let _ = service.waiting().await;
    });

    let client = ().serve(client_io).await.expect("Client verbindet");
    let backend = Backend::from_service(manifest(), client).await;
    let store = Arc::new(JobStore::in_memory(limits).expect("Queue"));
    let shared = Shared::new(Registry::new(vec![backend]), Arc::clone(&store));
    (shared, server, store)
}

fn text_of(result: &CallToolResult) -> String {
    result
        .content
        .iter()
        .filter_map(|block| match block {
            ContentBlock::Text(text) => Some(text.text.clone()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

async fn call(shared: &Arc<Shared>, name: &str, arguments: Value) -> Result<Value, String> {
    let request = CallToolRequestParams::new(name.to_string())
        .with_arguments(arguments.as_object().cloned().unwrap_or_default());
    let response = shared
        .call(request)
        .await
        .map_err(|error| error.to_string())?;
    let result = match response {
        CallToolResponse::Complete(result) => result,
        _ => panic!("unerwartete Antwort auf {name}"),
    };
    serde_json::from_str(&text_of(&result)).map_err(|error| error.to_string())
}

async fn submit(
    shared: &Arc<Shared>,
    tool: &str,
    arguments: Value,
    priority: u8,
) -> Result<Value, String> {
    call(
        shared,
        "submit_job",
        serde_json::json!({
            "tool": tool,
            "arguments": arguments,
            "priority": priority,
        }),
    )
    .await
}

async fn status(shared: &Arc<Shared>, id: &str) -> Value {
    call(shared, "job_status", serde_json::json!({ "job_id": id }))
        .await
        .expect("job_status")
}

/// Wartet, bis die Aufgabe den erwarteten Zustand erreicht.
async fn wait_for_state(shared: &Arc<Shared>, id: &str, expected: &str) -> Value {
    let mut last = Value::Null;
    for _ in 0..200 {
        last = status(shared, id).await;
        if last["job"]["state"] == expected {
            return last;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("Zustand '{expected}' nicht erreicht, zuletzt: {last}");
}

#[tokio::test]
async fn aufgabe_wird_ausgefuehrt_und_abgeschlossen() {
    let (shared, _server, _store) = setup(Limits::default()).await;
    let worker = tokio::spawn(Arc::clone(&shared).run_worker());

    let accepted = submit(
        &shared,
        "mock_echo",
        serde_json::json!({ "message": "hallo" }),
        5,
    )
    .await
    .expect("Aufgabe angenommen");
    let id = accepted["job_id"].as_str().expect("job_id").to_string();
    assert_eq!(accepted["state"], "queued");

    let finished = wait_for_state(&shared, &id, "done").await;
    assert_eq!(finished["job"]["progress"], 100);
    let result = &finished["job"]["result"];
    assert_eq!(result["content"][0]["text"], "hallo");

    let capabilities = shared.capabilities().await;
    assert_eq!(capabilities["queue"]["done"], 1);
    assert_eq!(capabilities["queue"]["queued"], 0);
    assert_eq!(capabilities["queue"]["limits"]["maxConcurrent"], 1);

    worker.abort();
}

#[tokio::test]
async fn unbekanntes_tool_wird_abgelehnt() {
    let (shared, _server, _store) = setup(Limits::default()).await;
    let error = submit(&shared, "nope_echo", serde_json::json!({}), 5)
        .await
        .expect_err("unbekanntes Tool");
    assert!(error.contains("Unbekanntes Tool"), "{error}");

    let error = submit(&shared, "mock_unbekannt", serde_json::json!({}), 5)
        .await
        .expect_err("unbekanntes Tool");
    assert!(error.contains("Unbekanntes Tool"), "{error}");

    let error = submit(&shared, "echo", serde_json::json!({}), 5)
        .await
        .expect_err("fehlendes Präfix");
    assert!(error.contains("Präfix"), "{error}");
}

#[tokio::test]
async fn volle_queue_wird_gemeldet() {
    let (shared, _server, _store) = setup(Limits {
        max_queue: 1,
        max_queue_per_backend: 1,
        ..Limits::default()
    })
    .await;

    submit(&shared, "mock_echo", serde_json::json!({}), 5)
        .await
        .expect("erste Aufgabe");
    let error = submit(&shared, "mock_echo", serde_json::json!({}), 5)
        .await
        .expect_err("zweite Aufgabe");
    assert!(error.contains("voll"), "{error}");
}

#[tokio::test]
async fn abbruch_einer_laufenden_aufgabe_beendet_das_backend() {
    let (shared, _server, _store) = setup(Limits::default()).await;
    let worker = tokio::spawn(Arc::clone(&shared).run_worker());

    let accepted = submit(&shared, "mock_sleep", serde_json::json!({ "ms": 5_000 }), 5)
        .await
        .expect("Aufgabe angenommen");
    let id = accepted["job_id"].as_str().expect("job_id").to_string();
    wait_for_state(&shared, &id, "rendering").await;

    let cancelled = call(&shared, "job_cancel", serde_json::json!({ "job_id": id }))
        .await
        .expect("Abbruch");
    assert_eq!(cancelled["state"], "cancelled");
    assert_eq!(cancelled["changed"], true);

    let again = call(&shared, "job_cancel", serde_json::json!({ "job_id": id }))
        .await
        .expect("Abbruch wiederholt");
    assert_eq!(again["state"], "cancelled");
    assert_eq!(again["changed"], false);

    let mut status_down = false;
    for _ in 0..40 {
        if shared.capabilities().await["backends"][0]["status"] == "down" {
            status_down = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert!(status_down, "Backend muss nach dem Abbruch beendet sein");

    worker.abort();
}

#[tokio::test]
async fn unbekannte_kennung_ist_ein_eingabefehler() {
    let (shared, _server, _store) = setup(Limits::default()).await;
    let error = call(
        &shared,
        "job_status",
        serde_json::json!({ "job_id": "job-unbekannt" }),
    )
    .await
    .expect_err("unbekannte Aufgabe");
    assert!(error.contains("unbekannt"), "{error}");

    let error = call(&shared, "job_status", serde_json::json!({}))
        .await
        .expect_err("job_id fehlt");
    assert!(error.contains("job_id"), "{error}");
}

#[tokio::test]
async fn werkzeuge_erscheinen_in_der_liste() {
    let (shared, _server, _store) = setup(Limits::default()).await;
    let mut names: Vec<String> = shared
        .tools()
        .await
        .iter()
        .map(|tool| tool.name.to_string())
        .collect();
    names.sort();
    assert!(names.contains(&"submit_job".to_string()));
    assert!(names.contains(&"job_status".to_string()));
    assert!(names.contains(&"job_cancel".to_string()));
    assert!(names.contains(&"workers".to_string()));
    assert!(names.contains(&"metrics".to_string()));
    assert!(names.contains(&"mock_echo".to_string()));
}

/// Ruft ein Gateway-Tool auf, das Textzeilen statt JSON liefert.
async fn call_text(shared: &Arc<Shared>, name: &str) -> String {
    let response = shared
        .call(CallToolRequestParams::new(name.to_string()))
        .await
        .expect("Tool-Aufruf");
    match response {
        CallToolResponse::Complete(result) => text_of(&result),
        _ => panic!("unerwartete Antwort auf {name}"),
    }
}

#[tokio::test]
async fn workers_und_metrics_liefern_textzeilen() {
    let (shared, _server, _store) = setup(Limits::default()).await;

    let workers = call_text(&shared, "workers").await;
    assert!(
        workers.starts_with("workers: 1\nmodus: lokal\n"),
        "{workers}"
    );
    assert!(workers.contains("worker.1.id: "), "{workers}");
    assert!(workers.contains("worker.1.host: "), "{workers}");
    assert!(workers.contains("worker.1.platform: "), "{workers}");
    assert!(workers.contains("worker.1.started_at: "), "{workers}");
    assert!(workers.contains("worker.1.concurrency: 1"), "{workers}");
    assert!(workers.contains("worker.1.running: 0"), "{workers}");
    assert!(workers.contains("worker.1.jobs_done: 0"), "{workers}");
    assert!(workers.contains("worker.1.jobs_failed: 0"), "{workers}");
    assert!(workers.contains("hinweis: "), "{workers}");

    let metrics = call_text(&shared, "metrics").await;
    assert!(metrics.contains("uptime_s: "), "{metrics}");
    assert!(metrics.contains("version: "), "{metrics}");
    assert!(metrics.contains("jobs.queued: 0"), "{metrics}");
    assert!(metrics.contains("jobs.running: 0"), "{metrics}");
    assert!(metrics.contains("backends: 1"), "{metrics}");
    assert!(metrics.contains("backend.1.name: mock"), "{metrics}");
    assert!(metrics.contains("backend.1.status: up"), "{metrics}");
    assert!(metrics.contains("limits.max_concurrent: 1"), "{metrics}");
    assert!(metrics.contains("limits.max_queue: 64"), "{metrics}");
    // Ohne abgeschlossene Aufgabe gibt es noch keinen Messwert.
    assert!(metrics.contains("jobs.avg_dauer_ms: -"), "{metrics}");
    assert!(metrics.contains("jobs.messwerte: 0"), "{metrics}");
    // Der eigene Prozess liefert einen RSS; ein Strich wäre ein Fehler.
    let rss = metrics
        .lines()
        .find(|line| line.starts_with("prozess_rss_mib: "))
        .unwrap_or_else(|| panic!("keine RSS-Zeile: {metrics}"));
    assert!(!rss.ends_with(": -"), "{metrics}");
    assert!(!metrics.contains("prozess_fehler"), "{metrics}");
}

#[tokio::test]
async fn metrics_mittelt_die_dauer_abgeschlossener_aufgaben() {
    let (shared, _server, store) = setup(Limits::default()).await;

    let job = store
        .submit("mock_echo", "mock", serde_json::json!({}), 5)
        .await
        .expect("Aufgabe angenommen");
    let claimed = store
        .claim_next()
        .await
        .expect("Anspruch")
        .expect("Aufgabe wartet");
    store
        .finish(&claimed.id, serde_json::json!({ "ok": true }))
        .await
        .expect("Aufgabe abgeschlossen");
    assert_eq!(claimed.id, job.id);

    let metrics = call_text(&shared, "metrics").await;
    assert!(metrics.contains("jobs.done: 1"), "{metrics}");
    assert!(metrics.contains("jobs.messwerte: 1"), "{metrics}");
    assert!(metrics.contains("jobs.avg_dauer_ms: "), "{metrics}");
    assert!(!metrics.contains("jobs.avg_dauer_ms: -"), "{metrics}");
}
