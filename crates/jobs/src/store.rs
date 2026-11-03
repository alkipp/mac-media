//! SQLite-Speicher für Aufgaben: Annahme, Anspruch, Fortschritt und Abschluss.
//!
//! Alle Zugriffe laufen über [`JobStore`]. Die Sperre schützt genau eine
//! Verbindung; jede Operation läuft in `spawn_blocking`, damit der
//! Tokio-Runtime nicht blockiert. Die Datenbank ist die einzige Quelle für
//! Zustand und Zähler – es gibt keine zweiten Zähler im Speicher, die nach
//! einem Neustart auseinanderlaufen könnten.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::{Connection, OptionalExtension, Row, TransactionBehavior, params};
use serde_json::Value;
use uuid::Uuid;

use crate::model::{
    ErrorKind, Job, JobFailure, JobState, Limits, LimitsError, MAX_PRIORITY, MAX_PROGRESS, Stats,
    now_ms,
};

/// Schema-Version der Datenbank.
const SCHEMA_VERSION: i64 = 1;

/// Spalten in der Reihenfolge, die [`row_to_job`] erwartet.
const JOB_COLUMNS: &str = "id, tool, backend, arguments, state, priority, progress, result, \
     error_kind, error_message, created_at, updated_at, started_at, finished_at";

/// Tabellen und Indizes der ersten Schema-Version.
const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS jobs (
    id            TEXT PRIMARY KEY,
    tool          TEXT NOT NULL,
    backend       TEXT NOT NULL,
    arguments     TEXT NOT NULL,
    state         TEXT NOT NULL,
    priority      INTEGER NOT NULL,
    progress      INTEGER NOT NULL,
    result        TEXT,
    error_kind    TEXT,
    error_message TEXT,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    started_at    INTEGER,
    finished_at   INTEGER
);
CREATE INDEX IF NOT EXISTS jobs_queue ON jobs(state, priority DESC, created_at ASC);
CREATE INDEX IF NOT EXISTS jobs_backend ON jobs(backend, state);
";

/// Laufzeiten abgeschlossener Aufgaben.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DurationStats {
    /// Mittel der Laufzeiten in Millisekunden, auf ganze Millisekunden
    /// gerundet; `None`, solange kein Messwert vorliegt.
    pub average_ms: Option<u64>,
    /// Anzahl der berücksichtigten Messwerte.
    pub samples: u64,
}

/// Ergebnis eines Abbruchs.
#[derive(Debug, Clone, PartialEq)]
pub enum CancelOutcome {
    /// Aufgabe wurde abgebrochen.
    Cancelled {
        /// Zustand nach dem Abbruch (`cancelled`).
        job: Job,
        /// `true`, wenn die Aufgabe bereits im Backend lief.
        was_running: bool,
    },
    /// Aufgabe war schon beendet und bleibt unverändert.
    AlreadyFinished(Job),
}

/// Fehler des Aufgaben-Speichers.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    /// SQLite meldet einen Fehler.
    #[error("Datenbankfehler: {0}")]
    Database(#[from] rusqlite::Error),

    /// Ein JSON-Wert ließ sich nicht schreiben oder lesen.
    #[error("JSON-Fehler: {0}")]
    Json(#[from] serde_json::Error),

    /// Das Zustandsverzeichnis ließ sich nicht anlegen.
    #[error("Zustandsverzeichnis '{path}' ist nicht nutzbar: {source}")]
    StateDir {
        /// Pfad des Verzeichnisses.
        path: PathBuf,
        /// Ursprünglicher Fehler.
        #[source]
        source: std::io::Error,
    },

    /// Die Dateirechte ließen sich nicht setzen.
    #[error("Rechte für '{path}' ließen sich nicht setzen: {source}")]
    Permissions {
        /// Betroffener Pfad.
        path: PathBuf,
        /// Ursprünglicher Fehler.
        #[source]
        source: std::io::Error,
    },

    /// Die Grenzen sind unplausibel.
    #[error("Grenzen sind ungültig: {0}")]
    Limits(#[from] LimitsError),

    /// Die Datenbank stammt aus einer neueren Version.
    #[error("Datenbankschema {found} ist neuer als erwartet ({expected})")]
    SchemaTooNew {
        /// Gefundene Version.
        found: u32,
        /// Erwartete Version.
        expected: u32,
    },

    /// Die Aufgabe existiert nicht.
    #[error("Aufgabe '{0}' ist unbekannt")]
    UnknownJob(String),

    /// Die Gesamtwarteschlange ist voll.
    #[error("Warteschlange ist voll ({limit} Aufgaben)")]
    QueueFull {
        /// Erlaubte Länge.
        limit: u32,
    },

    /// Die Warteschlange eines Backends ist voll.
    #[error("Warteschlange von '{backend}' ist voll ({limit} Aufgaben)")]
    QueueFullBackend {
        /// Backend, dessen Warteschlange voll ist.
        backend: String,
        /// Erlaubte Länge.
        limit: u32,
    },

    /// Die Priorität liegt außerhalb der Grenzen.
    #[error("Priorität {0} liegt außerhalb von 0–9")]
    InvalidPriority(u8),

    /// Der Fortschritt liegt außerhalb der Grenzen.
    #[error("Fortschritt {0} liegt außerhalb von 0–100")]
    InvalidProgress(u8),

    /// Die Argumente sind kein JSON-Objekt.
    #[error("arguments muss ein JSON-Objekt sein")]
    InvalidArguments,

    /// Der Zustandswechsel ist nicht erlaubt.
    #[error("Zustandswechsel {from} → {to} ist unzulässig")]
    InvalidTransition {
        /// Ausgangszustand.
        from: JobState,
        /// Zielzustand.
        to: JobState,
    },

    /// Die Aufgabe ist bereits beendet.
    #[error("Aufgabe '{id}' ist bereits beendet ({state})")]
    AlreadyFinished {
        /// Kennung der Aufgabe.
        id: String,
        /// Zustand, in dem sie sich befindet.
        state: JobState,
    },

    /// Der blockierende Task wurde abgebrochen.
    #[error("Datenbank-Task wurde abgebrochen: {0}")]
    Join(String),
}

/// Aufgaben-Speicher über einer SQLite-Datei.
#[derive(Debug)]
pub struct JobStore {
    inner: Arc<Mutex<Connection>>,
    limits: Limits,
}

impl JobStore {
    /// Öffnet die Datenbank, legt das Verzeichnis an und richtet das Schema ein.
    pub fn open(path: &Path, limits: Limits) -> Result<Self, StoreError> {
        limits.validate()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|source| StoreError::StateDir {
                path: parent.to_path_buf(),
                source,
            })?;
            restrict(parent, 0o700)?;
        }
        let connection = Connection::open(path)?;
        restrict(path, 0o600)?;
        Self::prepare(connection, limits)
    }

    /// Speicher im Arbeitsspeicher; für Tests und Werkzeuge ohne Datei.
    pub fn in_memory(limits: Limits) -> Result<Self, StoreError> {
        limits.validate()?;
        Self::prepare(Connection::open_in_memory()?, limits)
    }

    fn prepare(connection: Connection, limits: Limits) -> Result<Self, StoreError> {
        connection.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA busy_timeout = 5000;
             PRAGMA foreign_keys = ON;",
        )?;
        let found: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        let expected = SCHEMA_VERSION;
        if found > expected {
            return Err(StoreError::SchemaTooNew {
                found: u32::try_from(found).unwrap_or(u32::MAX),
                expected: u32::try_from(expected).unwrap_or(u32::MAX),
            });
        }
        connection.execute_batch(SCHEMA)?;
        connection.pragma_update(None, "user_version", expected)?;
        Ok(Self {
            inner: Arc::new(Mutex::new(connection)),
            limits,
        })
    }

    /// Grenzen dieser Warteschlange.
    #[must_use]
    pub fn limits(&self) -> Limits {
        self.limits
    }

    /// Führt eine Operation mit der Verbindung in einem blockierenden Task aus.
    async fn with_connection<T, F>(&self, operation: F) -> Result<T, StoreError>
    where
        T: Send + 'static,
        F: FnOnce(&mut Connection, &Limits) -> Result<T, StoreError> + Send + 'static,
    {
        let inner = Arc::clone(&self.inner);
        let limits = self.limits;
        tokio::task::spawn_blocking(move || {
            let mut connection = inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            operation(&mut connection, &limits)
        })
        .await
        .map_err(|error| StoreError::Join(error.to_string()))?
    }

    /// Nimmt eine Aufgabe an, sofern die Warteschlange Platz hat.
    pub async fn submit(
        &self,
        tool: &str,
        backend: &str,
        arguments: Value,
        priority: u8,
    ) -> Result<Job, StoreError> {
        if priority > MAX_PRIORITY {
            return Err(StoreError::InvalidPriority(priority));
        }
        if !arguments.is_object() {
            return Err(StoreError::InvalidArguments);
        }
        let tool = tool.to_string();
        let backend = backend.to_string();
        self.with_connection(move |connection, limits| {
            let queued_total: i64 = connection.query_row(
                "SELECT COUNT(*) FROM jobs WHERE state = 'queued'",
                [],
                |row| row.get(0),
            )?;
            if queued_total >= i64::from(limits.max_queue) {
                return Err(StoreError::QueueFull {
                    limit: limits.max_queue,
                });
            }
            let queued_backend: i64 = connection.query_row(
                "SELECT COUNT(*) FROM jobs WHERE state = 'queued' AND backend = ?1",
                [&backend],
                |row| row.get(0),
            )?;
            if queued_backend >= i64::from(limits.max_queue_per_backend) {
                return Err(StoreError::QueueFullBackend {
                    backend: backend.clone(),
                    limit: limits.max_queue_per_backend,
                });
            }
            let now = now_ms();
            let job = Job {
                id: format!("job-{}", Uuid::new_v4()),
                tool,
                backend,
                arguments,
                state: JobState::Queued,
                priority,
                progress: 0,
                result: None,
                error: None,
                created_at: now,
                updated_at: now,
                started_at: None,
                finished_at: None,
            };
            connection.execute(
                "INSERT INTO jobs (id, tool, backend, arguments, state, priority, progress, \
                 created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7, ?7)",
                params![
                    job.id,
                    job.tool,
                    job.backend,
                    serde_json::to_string(&job.arguments)?,
                    job.state.as_str(),
                    i64::from(job.priority),
                    job.created_at,
                ],
            )?;
            Ok(job)
        })
        .await
    }

    /// Liest eine Aufgabe.
    pub async fn get(&self, id: &str) -> Result<Job, StoreError> {
        let id = id.to_string();
        self.with_connection(move |connection, _| load(connection, &id))
            .await
    }

    /// Position in der Warteschlange; `None`, wenn die Aufgabe nicht wartet.
    pub async fn position(&self, id: &str) -> Result<Option<u32>, StoreError> {
        let id = id.to_string();
        self.with_connection(move |connection, _| {
            let job = load(connection, &id)?;
            if job.state != JobState::Queued {
                return Ok(None);
            }
            let ahead: i64 = connection.query_row(
                "SELECT COUNT(*) FROM jobs WHERE state = 'queued' AND (priority > ?1 OR \
                 (priority = ?1 AND created_at < ?2) OR (priority = ?1 AND created_at = ?2 \
                 AND id < ?3))",
                params![i64::from(job.priority), job.created_at, job.id],
                |row| row.get(0),
            )?;
            Ok(Some(u32::try_from(ahead).unwrap_or(u32::MAX)))
        })
        .await
    }

    /// Holt die nächste ausführbare Aufgabe und markiert sie als `rendering`.
    ///
    /// Ausgewählt wird nach Priorität (höher zuerst), dann nach Alter. Ist das
    /// Backend einer Aufgabe bereits ausgelastet, wird sie übersprungen; so
    /// kann kein Backend die Warteschlange monopolisieren.
    pub async fn claim_next(&self) -> Result<Option<Job>, StoreError> {
        self.with_connection(move |connection, limits| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;

            let running: i64 = transaction.query_row(
                "SELECT COUNT(*) FROM jobs WHERE state IN ('rendering', 'encoding', 'muxing')",
                [],
                |row| row.get(0),
            )?;
            if running >= i64::from(limits.max_concurrent) {
                return Ok(None);
            }

            let mut per_backend = std::collections::HashMap::new();
            {
                let mut statement = transaction.prepare(
                    "SELECT backend, COUNT(*) FROM jobs \
                     WHERE state IN ('rendering', 'encoding', 'muxing') GROUP BY backend",
                )?;
                let rows = statement.query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })?;
                for row in rows {
                    let (backend, count) = row?;
                    per_backend.insert(backend, count);
                }
            }

            let candidate = {
                let mut statement = transaction.prepare(&format!(
                    "SELECT {JOB_COLUMNS} FROM jobs WHERE state = 'queued' \
                     ORDER BY priority DESC, created_at ASC, id ASC"
                ))?;
                let rows = statement.query_map([], row_to_job)?;
                let mut candidate = None;
                for job in rows {
                    let job = job?;
                    let busy = per_backend.get(&job.backend).copied().unwrap_or(0);
                    if busy >= i64::from(limits.max_per_backend) {
                        continue;
                    }
                    candidate = Some(job);
                    break;
                }
                candidate
            };

            let Some(mut job) = candidate else {
                return Ok(None);
            };
            let now = now_ms();
            let changed = transaction.execute(
                "UPDATE jobs SET state = 'rendering', started_at = ?1, updated_at = ?1 \
                 WHERE id = ?2 AND state = 'queued'",
                params![now, job.id],
            )?;
            if changed != 1 {
                return Ok(None);
            }
            job.state = JobState::Rendering;
            job.started_at = Some(now);
            job.updated_at = now;
            transaction.commit()?;
            Ok(Some(job))
        })
        .await
    }

    /// Setzt Fortschritt und optional die Phase einer laufenden Aufgabe.
    pub async fn set_progress(
        &self,
        id: &str,
        progress: u8,
        state: Option<JobState>,
    ) -> Result<Job, StoreError> {
        if progress > MAX_PROGRESS {
            return Err(StoreError::InvalidProgress(progress));
        }
        let id = id.to_string();
        self.with_connection(move |connection, _| {
            let job = load(connection, &id)?;
            if let Some(next) = state {
                if next.is_terminal() {
                    return Err(StoreError::InvalidTransition {
                        from: job.state,
                        to: next,
                    });
                }
                if next != job.state && !job.state.can_transition_to(next) {
                    return Err(StoreError::InvalidTransition {
                        from: job.state,
                        to: next,
                    });
                }
            }
            let now = now_ms();
            let next_state = state.unwrap_or(job.state);
            connection.execute(
                "UPDATE jobs SET progress = ?1, state = ?2, updated_at = ?3 WHERE id = ?4",
                params![i64::from(progress), next_state.as_str(), now, job.id],
            )?;
            load(connection, &job.id)
        })
        .await
    }

    /// Schließt eine Aufgabe erfolgreich ab.
    pub async fn finish(&self, id: &str, result: Value) -> Result<Job, StoreError> {
        let id = id.to_string();
        self.with_connection(move |connection, _| {
            let job = load(connection, &id)?;
            ensure_running(&job, JobState::Done)?;
            let now = now_ms();
            connection.execute(
                "UPDATE jobs SET state = 'done', progress = 100, result = ?1, \
                 finished_at = ?2, updated_at = ?2 WHERE id = ?3",
                params![serde_json::to_string(&result)?, now, job.id],
            )?;
            load(connection, &id)
        })
        .await
    }

    /// Beendet eine Aufgabe mit Fehler.
    pub async fn fail(&self, id: &str, kind: ErrorKind, message: &str) -> Result<Job, StoreError> {
        let id = id.to_string();
        let message = message.to_string();
        self.with_connection(move |connection, _| {
            let job = load(connection, &id)?;
            ensure_running(&job, JobState::Failed)?;
            let now = now_ms();
            connection.execute(
                "UPDATE jobs SET state = 'failed', error_kind = ?1, error_message = ?2, \
                 finished_at = ?3, updated_at = ?3 WHERE id = ?4",
                params![kind.as_str(), message, now, job.id],
            )?;
            load(connection, &id)
        })
        .await
    }

    /// Bricht eine wartende oder laufende Aufgabe ab.
    pub async fn cancel(&self, id: &str) -> Result<CancelOutcome, StoreError> {
        let id = id.to_string();
        self.with_connection(move |connection, _| {
            let job = load(connection, &id)?;
            if job.state.is_terminal() {
                return Ok(CancelOutcome::AlreadyFinished(job));
            }
            if !job.state.can_transition_to(JobState::Cancelled) {
                return Err(StoreError::InvalidTransition {
                    from: job.state,
                    to: JobState::Cancelled,
                });
            }
            let was_running = job.state.is_running();
            let now = now_ms();
            connection.execute(
                "UPDATE jobs SET state = 'cancelled', error_kind = 'cancelled', \
                 error_message = 'Aufgabe wurde abgebrochen', finished_at = ?1, updated_at = ?1 \
                 WHERE id = ?2",
                params![now, job.id],
            )?;
            let job = load(connection, &id)?;
            Ok(CancelOutcome::Cancelled { job, was_running })
        })
        .await
    }

    /// Markiert Aufgaben, die beim Beenden des Gateways liefen, als `failed`.
    ///
    /// Wartende Aufgaben bleiben erhalten und laufen nach dem Neustart weiter.
    pub async fn mark_interrupted(&self) -> Result<usize, StoreError> {
        self.with_connection(move |connection, _| {
            let now = now_ms();
            let changed = connection.execute(
                "UPDATE jobs SET state = 'failed', error_kind = 'interrupted', \
                 error_message = 'Gateway wurde während der Ausführung beendet', \
                 finished_at = ?1, updated_at = ?1 \
                 WHERE state IN ('rendering', 'encoding', 'muxing')",
                params![now],
            )?;
            Ok(changed)
        })
        .await
    }

    /// Mittel und Anzahl der Laufzeiten abgeschlossener Aufgaben.
    ///
    /// Gezählt werden nur Endzustände (`done`, `failed`, `cancelled`) mit
    /// beiden Zeitstempeln und nicht negativer Differenz; Aufgaben ohne
    /// Messwert – etwa abgebrochene Wartende – bleiben außen vor. Ohne
    /// Messwerte bleibt [`DurationStats::average_ms`] leer.
    pub async fn duration_stats(&self) -> Result<DurationStats, StoreError> {
        self.with_connection(move |connection, _| {
            let (total, samples): (i64, i64) = connection.query_row(
                "SELECT COALESCE(SUM(finished_at - started_at), 0), COUNT(*) FROM jobs \
                 WHERE state IN ('done', 'failed', 'cancelled') \
                 AND started_at IS NOT NULL AND finished_at IS NOT NULL \
                 AND finished_at >= started_at",
                [],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )?;
            let samples = u64::try_from(samples).unwrap_or(0);
            let average_ms = if samples == 0 {
                None
            } else {
                let total = u64::try_from(total).unwrap_or(0);
                // Ganzzahlig gerundet; die Summe ist wegen `>= 0` nie negativ.
                total.saturating_add(samples / 2).checked_div(samples)
            };
            Ok(DurationStats {
                average_ms,
                samples,
            })
        })
        .await
    }

    /// Mittel der Laufzeiten in Millisekunden; `None` ohne Messwerte.
    pub async fn average_duration_ms(&self) -> Result<Option<u64>, StoreError> {
        Ok(self.duration_stats().await?.average_ms)
    }

    /// Zählerstände aller Zustände.
    pub async fn stats(&self) -> Result<Stats, StoreError> {
        self.with_connection(move |connection, _| {
            let mut statement =
                connection.prepare("SELECT state, COUNT(*) FROM jobs GROUP BY state")?;
            let rows = statement.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })?;
            let mut stats = Stats::default();
            for row in rows {
                let (state, count) = row?;
                let count = u64::try_from(count).unwrap_or(0);
                match JobState::parse(&state) {
                    Some(JobState::Queued) => stats.queued += count,
                    Some(state) if state.is_running() => stats.running += count,
                    Some(JobState::Done) => stats.done += count,
                    Some(JobState::Failed) => stats.failed += count,
                    Some(JobState::Cancelled) => stats.cancelled += count,
                    _ => {}
                }
            }
            Ok(stats)
        })
        .await
    }
}

fn ensure_running(job: &Job, target: JobState) -> Result<(), StoreError> {
    if job.state.is_terminal() {
        return Err(StoreError::AlreadyFinished {
            id: job.id.clone(),
            state: job.state,
        });
    }
    if !job.state.can_transition_to(target) {
        return Err(StoreError::InvalidTransition {
            from: job.state,
            to: target,
        });
    }
    Ok(())
}

fn load(connection: &Connection, id: &str) -> Result<Job, StoreError> {
    connection
        .query_row(
            &format!("SELECT {JOB_COLUMNS} FROM jobs WHERE id = ?1"),
            [id],
            row_to_job,
        )
        .optional()?
        .ok_or_else(|| StoreError::UnknownJob(id.to_string()))
}

fn row_to_job(row: &Row<'_>) -> rusqlite::Result<Job> {
    let state_text: String = row.get(4)?;
    let state = JobState::parse(&state_text)
        .ok_or_else(|| conversion_error(4, format!("unbekannter Zustand '{state_text}'")))?;

    let priority: i64 = row.get(5)?;
    let progress: i64 = row.get(6)?;
    let error_kind: Option<String> = row.get(8)?;
    let error_message: Option<String> = row.get(9)?;
    let error = match (error_kind, error_message) {
        (Some(kind), Some(message)) => {
            let kind = ErrorKind::parse(&kind)
                .ok_or_else(|| conversion_error(8, format!("unbekannte Fehlerart '{kind}'")))?;
            Some(JobFailure { kind, message })
        }
        _ => None,
    };

    Ok(Job {
        id: row.get(0)?,
        tool: row.get(1)?,
        backend: row.get(2)?,
        arguments: json_column(row, 3)?.unwrap_or(Value::Object(serde_json::Map::new())),
        state,
        priority: u8::try_from(priority)
            .map_err(|_| conversion_error(5, format!("Priorität {priority} passt nicht")))?,
        progress: u8::try_from(progress)
            .map_err(|_| conversion_error(6, format!("Fortschritt {progress} passt nicht")))?,
        result: json_column(row, 7)?,
        error,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
        started_at: row.get(12)?,
        finished_at: row.get(13)?,
    })
}

fn json_column(row: &Row<'_>, index: usize) -> rusqlite::Result<Option<Value>> {
    let raw: Option<String> = row.get(index)?;
    let Some(raw) = raw else {
        return Ok(None);
    };
    serde_json::from_str(&raw)
        .map(Some)
        .map_err(|error| conversion_error(index, error.to_string()))
}

fn conversion_error(index: usize, message: String) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        index,
        rusqlite::types::Type::Text,
        Box::new(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            message,
        )),
    )
}

/// Setzt restriktive Rechte auf Verzeichnis oder Datei (Unix/macOS).
#[cfg(unix)]
fn restrict(path: &Path, mode: u32) -> Result<(), StoreError> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(mode)).map_err(|source| {
        StoreError::Permissions {
            path: path.to_path_buf(),
            source,
        }
    })
}

/// Auf anderen Systemen gibt es keine Unix-Rechte; der Aufruf bleibt leer.
#[cfg(not(unix))]
fn restrict(_path: &Path, _mode: u32) -> Result<(), StoreError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> JobStore {
        JobStore::in_memory(Limits::default()).expect("Queue")
    }

    /// Legt eine Aufgabe mit festen Zeitstempeln direkt in der Datenbank an.
    fn insert_job(
        store: &JobStore,
        id: &str,
        state: &str,
        started_at: Option<i64>,
        finished_at: Option<i64>,
    ) {
        let connection = store.inner.lock().expect("Verbindung");
        connection
            .execute(
                "INSERT INTO jobs (id, tool, backend, arguments, state, priority, progress, \
                 created_at, updated_at, started_at, finished_at) \
                 VALUES (?1, 'mock_echo', 'mock', '{}', ?2, 5, 0, 0, 0, ?3, ?4)",
                params![id, state, started_at, finished_at],
            )
            .expect("Aufgabe angelegt");
    }

    #[tokio::test]
    async fn average_duration_mittelt_abgeschlossene_aufgaben() {
        let store = store();
        // 300 ms, 100 ms und 200 ms ergeben zusammen 600 ms.
        insert_job(&store, "job-a", "done", Some(1_000), Some(1_300));
        insert_job(&store, "job-b", "failed", Some(2_000), Some(2_100));
        insert_job(&store, "job-c", "cancelled", Some(3_000), Some(3_200));
        // Wartet noch: kein Messwert.
        insert_job(&store, "job-d", "queued", None, None);
        // Nur ein Zeitstempel: zählt nicht.
        insert_job(&store, "job-e", "done", Some(4_000), None);
        // Negative Differenz: zählt nicht.
        insert_job(&store, "job-f", "done", Some(5_000), Some(4_000));

        let stats = store.duration_stats().await.expect("Laufzeiten");
        assert_eq!(stats.samples, 3);
        assert_eq!(stats.average_ms, Some(200));
        let average = store.average_duration_ms().await.expect("Mittel");
        assert_eq!(average, Some(200));
    }

    #[tokio::test]
    async fn average_duration_ohne_messwerte_ist_leer() {
        let store = store();
        insert_job(&store, "job-a", "queued", None, None);

        let stats = store.duration_stats().await.expect("Laufzeiten");
        assert_eq!(stats, DurationStats::default());
        let average = store.average_duration_ms().await.expect("Mittel");
        assert_eq!(average, None);
    }

    #[tokio::test]
    async fn average_duration_rundet_auf_ganze_millisekunden() {
        let store = store();
        insert_job(&store, "job-a", "done", Some(0), Some(100));
        insert_job(&store, "job-b", "done", Some(0), Some(101));

        // (100 + 101) / 2 = 100,5 → 101.
        let average = store.average_duration_ms().await.expect("Mittel");
        assert_eq!(average, Some(101));
    }
}
