//! Aufgaben-Warteschlange des `mac-compute`-Gateways.
//!
//! Das Modul kennt nur Aufgaben, Grenzen und SQLite – keine MCP-Typen. Der
//! Gateway nimmt Aufträge an, ein Worker holt sie über [`JobStore::claim_next`]
//! ab und schreibt Ergebnis oder Fehler zurück.
//!
//! ```text
//! submit_job ──▶ jobs.sqlite ──▶ claim_next ──▶ Backend-Aufruf
//!                    ▲                                │
//!                    └──── finish / fail / cancel ◀───┘
//! ```

mod model;
mod store;

pub use model::{
    DEFAULT_PRIORITY, ErrorKind, Job, JobFailure, JobState, Limits, LimitsError, MAX_PRIORITY,
    MAX_PROGRESS, MIN_PRIORITY, Stats, now_ms,
};
pub use store::{CancelOutcome, DurationStats, JobStore, StoreError};
