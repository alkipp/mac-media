//! Gemeinsamer Zustand des Gateways: Registry, Warteschlange, Sessions, Aufsicht.
//!
//! Die Registry liegt hinter einer asynchronen Sperre, damit Reload und
//! Aufsicht sie ersetzen können, ohne einen laufenden Aufruf zu blockieren:
//! Der Aufruf löst sein Ziel unter der Sperre auf und spricht das Backend
//! danach ohne Sperre an.
//!
//! Aufgaben liegen in SQLite ([`mac_compute_jobs::JobStore`]). Direkte Aufrufe
//! laufen weiterhin sofort durch; `submit_job` legt eine Aufgabe an, die ein
//! Worker ausführt.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use mac_compute_jobs::{CancelOutcome, JobStore, Limits, Stats, StoreError};
use mcp_core::Manifest;
use rmcp::{
    ErrorData as McpError, RoleServer,
    model::{CallToolRequestParams, CallToolResponse, Tool},
    service::Peer,
};
use serde_json::{Value, json};
use tokio::sync::{Mutex, Notify};
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use crate::discovery::{
    Backend, BackendStatus, CAPABILITIES_TOOL, DispatchError, Registry, Target, dispatch,
};
use crate::jobs::{
    JOB_CANCEL_TOOL, JOB_STATUS_TOOL, SUBMIT_JOB_TOOL, job_tools, parse_job_id, parse_submit,
    text_result,
};
use crate::ops::{METRICS_TOOL, WORKERS_TOOL, ops_tools};

/// Wiederholungen und Wartezeit beim Neustart eines Backends.
#[derive(Debug, Clone, Copy)]
pub struct Backoff {
    /// Anzahl der Versuche insgesamt.
    pub attempts: u32,
    /// Erste Wartezeit; verdoppelt sich nach jedem Fehlversuch.
    pub base: Duration,
}

impl Default for Backoff {
    fn default() -> Self {
        Self {
            attempts: 3,
            base: Duration::from_secs(1),
        }
    }
}

/// Zustand, den HTTP-Router, Hintergrundtasks und Sessions teilen.
pub struct Shared {
    pub(crate) registry: Mutex<Registry>,
    sessions: Mutex<Vec<Peer<RoleServer>>>,
    backoff: Backoff,
    pub(crate) store: Arc<JobStore>,
    pub(crate) running: Mutex<HashMap<String, CancellationToken>>,
    pub(crate) wake: Notify,
    /// Startzeit des Gateways; Grundlage für Uptime und Worker-Kennung.
    pub(crate) started_at: SystemTime,
    /// Stabile Kennung des lokalen Workers (Hostname plus Startzeit).
    pub(crate) worker_id: String,
    /// Hostname des Rechners, auf dem der Gateway läuft.
    pub(crate) host: String,
    /// Prozesslokale Neustartversuche je Backend, gezählt von der Aufsicht.
    pub(crate) restarts: Mutex<HashMap<String, u32>>,
}

impl Shared {
    /// Teilt eine Registry und eine Warteschlange mit Standard-Backoff.
    pub fn new(registry: Registry, store: Arc<JobStore>) -> Arc<Self> {
        Self::with_backoff(registry, Backoff::default(), store)
    }

    /// Teilt Registry und Warteschlange mit eigenem Backoff (Tests).
    pub fn with_backoff(registry: Registry, backoff: Backoff, store: Arc<JobStore>) -> Arc<Self> {
        let started_at = SystemTime::now();
        let host = crate::ops::hostname();
        let worker_id = crate::ops::worker_id(&host, started_at);
        Arc::new(Self {
            registry: Mutex::new(registry),
            sessions: Mutex::new(Vec::new()),
            backoff,
            store,
            running: Mutex::new(HashMap::new()),
            wake: Notify::new(),
            started_at,
            worker_id,
            host,
            restarts: Mutex::new(HashMap::new()),
        })
    }

    /// Aktuelle Tool-Liste: Gateway-Tools plus alle Tools laufender Backends.
    pub async fn tools(&self) -> Vec<Tool> {
        let mut tools = self.registry.lock().await.tools();
        tools.extend(job_tools());
        tools.extend(ops_tools());
        tools
    }

    /// Aktueller Backend-Status, ergänzt um den Stand der Warteschlange.
    pub async fn capabilities(&self) -> Value {
        let mut value = self.registry.lock().await.capabilities();
        let stats = match self.store.stats().await {
            Ok(stats) => stats,
            Err(error) => {
                warn!(%error, "Stand der Warteschlange nicht lesbar");
                Stats::default()
            }
        };
        let Limits {
            max_queue,
            max_queue_per_backend,
            max_concurrent,
            max_per_backend,
        } = self.store.limits();
        if let Some(object) = value.as_object_mut() {
            object.insert(
                "queue".to_string(),
                json!({
                    "queued": stats.queued,
                    "running": stats.running,
                    "done": stats.done,
                    "failed": stats.failed,
                    "cancelled": stats.cancelled,
                    "limits": {
                        "maxQueue": max_queue,
                        "maxQueuePerBackend": max_queue_per_backend,
                        "maxConcurrent": max_concurrent,
                        "maxPerBackend": max_per_backend,
                    },
                }),
            );
        }
        value
    }

    /// Leitet einen Aufruf weiter; Fehler markieren das Backend als down.
    pub async fn call(&self, request: CallToolRequestParams) -> Result<CallToolResponse, McpError> {
        let route = match &*request.name {
            CAPABILITIES_TOOL => Route::Capabilities,
            WORKERS_TOOL => Route::Workers,
            METRICS_TOOL => Route::Metrics,
            SUBMIT_JOB_TOOL => Route::Submit,
            JOB_STATUS_TOOL => Route::Status,
            JOB_CANCEL_TOOL => Route::Cancel,
            _ => Route::Forward,
        };
        match route {
            Route::Capabilities => {
                let text = serde_json::to_string_pretty(&self.capabilities().await)
                    .map_err(|error| McpError::internal_error(error.to_string(), None))?;
                Ok(text_response(text))
            }
            Route::Workers => Ok(text_response(self.workers().await)),
            Route::Metrics => Ok(text_response(self.metrics().await)),
            Route::Submit => self.submit_job(request.arguments).await,
            Route::Status => self.job_status(request.arguments).await,
            Route::Cancel => self.cancel_job(request.arguments).await,
            Route::Forward => self.forward(request).await,
        }
    }

    async fn forward(&self, request: CallToolRequestParams) -> Result<CallToolResponse, McpError> {
        let target = self.registry.lock().await.target(&request.name)?;
        match dispatch(&target, request).await {
            Ok(response) => Ok(response),
            Err(DispatchError { backend, error, .. }) => {
                self.mark_backend_down(&backend, error.to_string()).await;
                Err(error)
            }
        }
    }

    /// Löst ein Tool auf, ohne es aufzurufen; prüft damit die Existenz.
    pub(crate) async fn resolve_target(&self, tool: &str) -> Result<Target, McpError> {
        self.registry.lock().await.target(tool)
    }

    /// Markiert ein Backend als down und meldet die geänderte Tool-Liste.
    pub(crate) async fn mark_backend_down(&self, backend: &str, message: String) {
        self.registry.lock().await.mark_down(backend, message);
        self.notify_tools_changed().await;
    }

    /// Nimmt eine Aufgabe an und weckt einen Worker.
    async fn submit_job(
        &self,
        arguments: Option<rmcp::model::JsonObject>,
    ) -> Result<CallToolResponse, McpError> {
        let args = parse_submit(arguments.as_ref())?;
        let target = self.resolve_target(&args.tool).await?;
        let job = self
            .store
            .submit(&args.tool, &target.backend, args.arguments, args.priority)
            .await
            .map_err(store_error)?;
        let position = self.store.position(&job.id).await.ok().flatten();
        self.wake.notify_waiters();
        info!(job = %job.id, tool = %job.tool, priority = job.priority, "Aufgabe angenommen");
        Ok(text_response_json(json!({
            "job_id": job.id,
            "tool": job.tool,
            "backend": job.backend,
            "state": job.state,
            "priority": job.priority,
            "queue_position": position,
        })))
    }

    /// Liefert Zustand, Fortschritt und Ergebnis einer Aufgabe.
    async fn job_status(
        &self,
        arguments: Option<rmcp::model::JsonObject>,
    ) -> Result<CallToolResponse, McpError> {
        let id = parse_job_id(arguments.as_ref())?;
        let job = self.store.get(&id).await.map_err(store_error)?;
        let position = self.store.position(&id).await.ok().flatten();
        Ok(text_response_json(json!({
            "job": job,
            "queue_position": position,
        })))
    }

    /// Bricht eine wartende Aufgabe ab oder beendet eine laufende.
    async fn cancel_job(
        &self,
        arguments: Option<rmcp::model::JsonObject>,
    ) -> Result<CallToolResponse, McpError> {
        let id = parse_job_id(arguments.as_ref())?;
        let outcome = self.store.cancel(&id).await.map_err(store_error)?;
        let (job, changed, running) = match outcome {
            CancelOutcome::Cancelled { job, was_running } => (job, true, was_running),
            CancelOutcome::AlreadyFinished(job) => (job, false, false),
        };
        if running {
            let token = self.running.lock().await.get(&id).cloned();
            match token {
                Some(token) => {
                    info!(job = %id, "Abbruch angefordert, Backend wird beendet");
                    token.cancel();
                }
                None => warn!(job = %id, "Laufende Aufgabe ohne Worker-Eintrag"),
            }
        }
        self.wake.notify_waiters();
        Ok(text_response_json(json!({
            "job_id": job.id,
            "state": job.state,
            "changed": changed,
        })))
    }

    /// Merkt sich die Session, damit sie bei Reload benachrichtigt werden kann.
    pub async fn register_session(&self, peer: Peer<RoleServer>) {
        let mut sessions = self.sessions.lock().await;
        sessions.retain(|existing| !existing.is_transport_closed());
        sessions.push(peer);
    }

    /// Sendet `tools/list_changed` an alle offenen Sessions.
    pub async fn notify_tools_changed(&self) {
        let mut sessions = self.sessions.lock().await;
        let mut alive = Vec::with_capacity(sessions.len());
        for peer in sessions.drain(..) {
            if peer.notify_tool_list_changed().await.is_ok() {
                alive.push(peer);
            }
        }
        *sessions = alive;
    }

    /// Lädt die Manifeste neu und ersetzt die Registry.
    pub async fn reload(&self, servers_dir: &Path) {
        let registry = Registry::load(servers_dir).await;
        let count = registry.len();
        *self.registry.lock().await = registry;
        info!(backends = count, "Registry neu geladen");
        self.notify_tools_changed().await;
    }

    /// Prüft alle Backends und startet das erste mit geschlossenem Transport
    /// neu. Gibt den Namen zurück, wenn etwas passiert ist.
    pub async fn supervise_once(&self) -> Option<String> {
        let manifest = self.registry.lock().await.first_closed()?;
        let name = manifest.name.clone();
        warn!(backend = %name, "Backend-Verbindung geschlossen, starte neu");

        let backend = connect_with_backoff(manifest, self.backoff).await;
        let up = backend.status == BackendStatus::Up;
        self.registry.lock().await.replace(backend);
        {
            let mut restarts = self.restarts.lock().await;
            *restarts.entry(name.clone()).or_default() += 1;
        }
        if up {
            info!(backend = %name, "Backend neu gestartet");
        } else {
            warn!(backend = %name, "Backend bleibt down");
        }
        self.notify_tools_changed().await;
        Some(name)
    }
}

/// Ziel eines eingehenden Tool-Aufrufs.
enum Route {
    /// Status der Backends und der Warteschlange.
    Capabilities,
    /// Liste der Worker.
    Workers,
    /// Laufzeitkennzahlen.
    Metrics,
    /// Aufgabe annehmen.
    Submit,
    /// Zustand einer Aufgabe.
    Status,
    /// Aufgabe abbrechen.
    Cancel,
    /// An ein Backend weiterleiten.
    Forward,
}

/// Textantwort eines Gateway-Tools.
fn text_response(text: String) -> CallToolResponse {
    CallToolResponse::Complete(text_result(text))
}

/// Textantwort mit JSON-Inhalt.
fn text_response_json(value: Value) -> CallToolResponse {
    text_response(serde_json::to_string_pretty(&value).unwrap_or_else(|_| "{}".to_string()))
}

/// Übersetzt einen Speicherfehler in einen MCP-Fehler.
///
/// Volle Warteschlange und unbekannte Kennungen sind Eingabefehler, alles
/// andere ist ein Fehler des Gateways.
fn store_error(error: StoreError) -> McpError {
    match error {
        StoreError::UnknownJob(_)
        | StoreError::QueueFull { .. }
        | StoreError::QueueFullBackend { .. } => McpError::invalid_params(error.to_string(), None),
        other => McpError::internal_error(other.to_string(), None),
    }
}

async fn connect_with_backoff(manifest: Manifest, backoff: Backoff) -> Backend {
    let attempts = backoff.attempts.max(1);
    let mut wait = backoff.base;
    let mut last = None;

    for attempt in 1..=attempts {
        let backend = Backend::connect(manifest.clone()).await;
        if backend.status == BackendStatus::Up {
            return backend;
        }
        warn!(
            backend = %manifest.name,
            attempt,
            attempts,
            "Neustart fehlgeschlagen"
        );
        last = Some(backend);
        if attempt < attempts {
            sleep(wait).await;
            wait *= 2;
        }
    }

    last.expect("mindestens ein Versuch")
}
