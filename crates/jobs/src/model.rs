//! Zustände, Grenzen und Datensätze der Aufgaben-Warteschlange.
//!
//! Eine Aufgabe durchläuft `queued` → `rendering` → optional `encoding` und
//! `muxing` → `done`. Fehler führen nach `failed`, ein Abbruch nach
//! `cancelled`. `rendering` ist der allgemeine „läuft“-Zustand; meldet ein
//! Backend später eine feinere Phase, wechselt die Aufgabe nach `encoding`
//! oder `muxing`.

use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Kleinste erlaubte Priorität.
pub const MIN_PRIORITY: u8 = 0;

/// Größte erlaubte Priorität.
pub const MAX_PRIORITY: u8 = 9;

/// Priorität, wenn der Aufrufer keine angibt.
pub const DEFAULT_PRIORITY: u8 = 5;

/// Größter erlaubter Fortschritt in Prozent.
pub const MAX_PROGRESS: u8 = 100;

/// Aktuelle Zeit in Millisekunden seit der Unix-Epoche.
pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| {
            i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX)
        })
}

/// Zustand einer Aufgabe.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    /// Angenommen, wartet auf einen freien Platz.
    Queued,
    /// Läuft im Backend (allgemeiner Fortschrittszustand).
    Rendering,
    /// Frames sind fertig, das Video wird kodiert.
    Encoding,
    /// Bild und Ton werden zusammengeführt.
    Muxing,
    /// Erfolgreich abgeschlossen.
    Done,
    /// Mit Fehler beendet.
    Failed,
    /// Abgebrochen.
    Cancelled,
}

impl JobState {
    /// Text, wie er in der Datenbank und im JSON steht.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Rendering => "rendering",
            Self::Encoding => "encoding",
            Self::Muxing => "muxing",
            Self::Done => "done",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    /// Zustand zu einem Text aus der Datenbank.
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "queued" => Self::Queued,
            "rendering" => Self::Rendering,
            "encoding" => Self::Encoding,
            "muxing" => Self::Muxing,
            "done" => Self::Done,
            "failed" => Self::Failed,
            "cancelled" => Self::Cancelled,
            _ => return None,
        })
    }

    /// `true`, solange die Aufgabe das Backend belegt.
    pub fn is_running(self) -> bool {
        matches!(self, Self::Rendering | Self::Encoding | Self::Muxing)
    }

    /// `true`, wenn kein weiterer Wechsel mehr möglich ist.
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Done | Self::Failed | Self::Cancelled)
    }

    /// `true`, wenn der Wechsel nach `next` erlaubt ist.
    pub fn can_transition_to(self, next: Self) -> bool {
        match self {
            Self::Queued => matches!(next, Self::Rendering | Self::Failed | Self::Cancelled),
            Self::Rendering => matches!(
                next,
                Self::Encoding | Self::Muxing | Self::Done | Self::Failed | Self::Cancelled
            ),
            Self::Encoding => matches!(
                next,
                Self::Muxing | Self::Done | Self::Failed | Self::Cancelled
            ),
            Self::Muxing => matches!(next, Self::Done | Self::Failed | Self::Cancelled),
            Self::Done | Self::Failed | Self::Cancelled => false,
        }
    }
}

impl std::fmt::Display for JobState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Art eines Aufgabenfehlers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// Aufruf war formal ungültig.
    InvalidRequest,
    /// Backend war nicht erreichbar oder das Tool unbekannt.
    BackendUnavailable,
    /// Das Zeitlimit des Manifests ist abgelaufen.
    Timeout,
    /// Aufgabe wurde abgebrochen.
    Cancelled,
    /// Gateway wurde beendet, während die Aufgabe lief.
    Interrupted,
    /// Sonstiger Fehler im Gateway.
    Internal,
}

impl ErrorKind {
    /// Text, wie er im JSON steht.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::BackendUnavailable => "backend_unavailable",
            Self::Timeout => "timeout",
            Self::Cancelled => "cancelled",
            Self::Interrupted => "interrupted",
            Self::Internal => "internal",
        }
    }

    /// Art zu einem Text aus der Datenbank.
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "invalid_request" => Self::InvalidRequest,
            "backend_unavailable" => Self::BackendUnavailable,
            "timeout" => Self::Timeout,
            "cancelled" => Self::Cancelled,
            "interrupted" => Self::Interrupted,
            "internal" => Self::Internal,
            _ => return None,
        })
    }
}

impl std::fmt::Display for ErrorKind {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Fehler einer Aufgabe, wie er in `job_status` erscheint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobFailure {
    /// Einordnung des Fehlers.
    pub kind: ErrorKind,
    /// Meldung für den Aufrufer.
    pub message: String,
}

impl JobFailure {
    /// Erzeugt einen Fehler mit Einordnung.
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

/// Grenzen der Warteschlange.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Limits {
    /// Höchstzahl wartender Aufgaben insgesamt.
    pub max_queue: u32,
    /// Höchstzahl wartender Aufgaben je Backend.
    pub max_queue_per_backend: u32,
    /// Höchstzahl gleichzeitig laufender Aufgaben insgesamt.
    pub max_concurrent: u32,
    /// Höchstzahl gleichzeitig laufender Aufgaben je Backend.
    pub max_per_backend: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_queue: 64,
            max_queue_per_backend: 32,
            max_concurrent: 1,
            max_per_backend: 1,
        }
    }
}

/// Fehler bei unzulässigen Grenzen.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LimitsError {
    /// Ein Wert ist null.
    #[error("Grenze '{0}' muss mindestens 1 sein")]
    Zero(&'static str),

    /// Ein Wert liegt über der Obergrenze.
    #[error("Grenze '{name}' darf höchstens {max} sein")]
    TooLarge {
        /// Name der Grenze.
        name: &'static str,
        /// Erlaubtes Maximum.
        max: u32,
    },

    /// Eine Grenze passt nicht zu einer anderen.
    #[error("Grenze '{name}' darf {other} nicht überschreiten")]
    Inconsistent {
        /// Name der Grenze.
        name: &'static str,
        /// Grenze, die die Obergrenze bildet.
        other: &'static str,
    },
}

/// Größter sinnvoller Wert für eine einzelne Grenze.
const MAX_LIMIT: u32 = 1_024;

impl Limits {
    /// Prüft die Grenzen auf Plausibilität.
    ///
    /// Wartende Aufgaben je Backend dürfen die Gesamtzahl nicht übersteigen,
    /// gleichzeitig laufende je Backend nicht die Gesamtzahl.
    pub fn validate(&self) -> Result<(), LimitsError> {
        for (name, value) in [
            ("max_queue", self.max_queue),
            ("max_queue_per_backend", self.max_queue_per_backend),
            ("max_concurrent", self.max_concurrent),
            ("max_per_backend", self.max_per_backend),
        ] {
            if value == 0 {
                return Err(LimitsError::Zero(name));
            }
            if value > MAX_LIMIT {
                return Err(LimitsError::TooLarge {
                    name,
                    max: MAX_LIMIT,
                });
            }
        }
        if self.max_queue_per_backend > self.max_queue {
            return Err(LimitsError::Inconsistent {
                name: "max_queue_per_backend",
                other: "max_queue",
            });
        }
        if self.max_per_backend > self.max_concurrent {
            return Err(LimitsError::Inconsistent {
                name: "max_per_backend",
                other: "max_concurrent",
            });
        }
        Ok(())
    }
}

/// Eine Aufgabe, wie sie in der Datenbank liegt.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Job {
    /// Eindeutige Kennung, `job-<uuid>`.
    pub id: String,
    /// Namespaced Tool, z. B. `render_svg`.
    pub tool: String,
    /// Backend, das den Aufruf ausführt.
    pub backend: String,
    /// Argumente des Backend-Tools als JSON-Objekt.
    pub arguments: serde_json::Value,
    /// Aktueller Zustand.
    pub state: JobState,
    /// Priorität, höher läuft zuerst.
    pub priority: u8,
    /// Fortschritt in Prozent.
    pub progress: u8,
    /// Ergebnis des Backend-Aufrufs, sobald `done`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    /// Fehler, sobald `failed`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JobFailure>,
    /// Aufnahmezeit in Millisekunden seit der Unix-Epoche.
    pub created_at: i64,
    /// Zeit der letzten Änderung.
    pub updated_at: i64,
    /// Beginn der Ausführung.
    pub started_at: Option<i64>,
    /// Ende der Ausführung.
    pub finished_at: Option<i64>,
}

impl Job {
    /// `true`, wenn die Aufgabe beendet ist.
    pub fn is_terminal(&self) -> bool {
        self.state.is_terminal()
    }
}

/// Zählerstände der Warteschlange.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stats {
    /// Wartende Aufgaben.
    pub queued: u64,
    /// Laufende Aufgaben.
    pub running: u64,
    /// Erfolgreich beendete Aufgaben.
    pub done: u64,
    /// Fehlgeschlagene Aufgaben.
    pub failed: u64,
    /// Abgebrochene Aufgaben.
    pub cancelled: u64,
}
