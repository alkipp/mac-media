//! Worker: holt Aufgaben aus der Warteschlange und führt sie im Backend aus.
//!
//! Der Gateway startet so viele Worker, wie `maxConcurrent` erlaubt. Jeder
//! Worker beansprucht genau eine Aufgabe, wartet auf deren Ergebnis und
//! schreibt Zustand, Fortschritt und Fehler zurück. Ein Abbruch beendet das
//! Backend, weil ein hängender Aufruf sonst bis zum Manifest-Timeout laufen
//! würde; die Aufsicht startet es danach neu.

use std::sync::Arc;
use std::time::Duration;

use mac_compute_jobs::{ErrorKind, Job, StoreError};
use rmcp::model::{CallToolRequestParams, CallToolResponse, JsonObject};
use serde_json::Value;
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use crate::discovery::DispatchKind;
use crate::state::Shared;

/// Wartezeit, wenn die Warteschlange leer ist.
const IDLE_WAIT: Duration = Duration::from_millis(500);

impl Shared {
    /// Läuft endlos: Aufgabe holen, ausführen, Ergebnisse zurückschreiben.
    pub async fn run_worker(self: Arc<Self>) {
        loop {
            match self.store.claim_next().await {
                Ok(Some(job)) => self.execute(job).await,
                Ok(None) => {
                    let _ = tokio::time::timeout(IDLE_WAIT, self.wake.notified()).await;
                }
                Err(error) => {
                    warn!(%error, "Warteschlange nicht lesbar");
                    tokio::time::sleep(IDLE_WAIT).await;
                }
            }
        }
    }

    /// Führt eine beanspruchte Aufgabe aus und schreibt das Ergebnis zurück.
    async fn execute(&self, job: Job) {
        let target = match self.resolve_target(&job.tool).await {
            Ok(target) => target,
            Err(error) => {
                self.fail(&job.id, ErrorKind::BackendUnavailable, &error.to_string())
                    .await;
                return;
            }
        };

        let token = CancellationToken::new();
        self.running
            .lock()
            .await
            .insert(job.id.clone(), token.clone());

        // Zwischen Anspruch und Eintrag kann der Abbruch bereits eingetroffen sein.
        match self.store.get(&job.id).await {
            Ok(current) if current.state.is_terminal() => {
                self.running.lock().await.remove(&job.id);
                debug!(job = %job.id, "Aufgabe wurde vor dem Start abgebrochen");
                return;
            }
            Ok(_) => {}
            Err(error) => warn!(job = %job.id, %error, "Zustand nicht lesbar"),
        }

        let arguments = match &job.arguments {
            Value::Object(map) => map.clone(),
            _ => JsonObject::new(),
        };
        let request = CallToolRequestParams::new(target.tool.clone()).with_arguments(arguments);

        let outcome = tokio::select! {
            biased;
            () = token.cancelled() => None,
            response = crate::discovery::dispatch(&target, request) => Some(response),
        };
        self.running.lock().await.remove(&job.id);

        match outcome {
            None => {
                info!(job = %job.id, backend = %target.backend, "Aufgabe abgebrochen");
                self.mark_backend_down(
                    &target.backend,
                    format!("Aufgabe {} wurde abgebrochen", job.id),
                )
                .await;
            }
            Some(Ok(response)) => {
                let result = match response {
                    CallToolResponse::Complete(result) => {
                        serde_json::to_value(result).unwrap_or(Value::Null)
                    }
                    _ => {
                        warn!(job = %job.id, "Backend lieferte eine Zwischenantwort");
                        Value::Null
                    }
                };
                match self.store.finish(&job.id, result).await {
                    Ok(_) => info!(job = %job.id, tool = %job.tool, "Aufgabe abgeschlossen"),
                    Err(StoreError::AlreadyFinished { state, .. }) => {
                        info!(job = %job.id, %state, "Aufgabe war bereits beendet");
                    }
                    Err(error) => warn!(job = %job.id, %error, "Ergebnis nicht gespeichert"),
                }
            }
            Some(Err(failure)) => {
                let kind = match failure.kind {
                    DispatchKind::Timeout => ErrorKind::Timeout,
                    DispatchKind::Backend => ErrorKind::BackendUnavailable,
                };
                warn!(
                    job = %job.id,
                    backend = %failure.backend,
                    "Aufgabe fehlgeschlagen: {}",
                    failure.error
                );
                self.mark_backend_down(&failure.backend, failure.error.to_string())
                    .await;
                self.fail(&job.id, kind, &failure.error.to_string()).await;
            }
        }
        self.wake.notify_waiters();
    }

    /// Schreibt einen Fehler zur Aufgabe, ohne den Worker zu beenden.
    async fn fail(&self, id: &str, kind: ErrorKind, message: &str) {
        match self.store.fail(id, kind, message).await {
            Ok(_) => {}
            Err(StoreError::AlreadyFinished { state, .. }) => {
                debug!(job = %id, %state, "Aufgabe war bereits beendet");
            }
            Err(error) => warn!(job = %id, %error, "Fehler nicht gespeichert"),
        }
    }
}
