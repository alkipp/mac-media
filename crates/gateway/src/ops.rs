//! Betriebswerkzeuge: Worker-Liste (`workers`) und Kennzahlen (`metrics`).
//!
//! Beide Tools antworten mit Textzeilen `schluessel: wert`, damit die Ausgabe
//! im Chat lesbar bleibt. Alle Zähler stammen aus der Warteschlange
//! ([`mac_compute_jobs::JobStore`]) und werden hier nicht zweitgeführt.
//!
//! Bewusste Grenze: Es gibt genau einen lokalen Worker. Eine Verteilung auf
//! mehrere Macs braucht einen gemeinsamen Store und einen Registry-Dienst;
//! beides ist nicht Teil dieses Schritts.
//!
//! Zwei Werte ergänzen die Zähler: Die mittlere Dauer abgeschlossener Aufgaben
//! kommt aus dem Store, damit kein Zähler im Gateway nach einem Neustart falsch
//! steht. Der Speicherbedarf gilt nur für diesen Prozess und kommt aus
//! `ps -o rss=`, das ohne zusätzliche Abhängigkeit unter macOS und Linux
//! funktioniert.

use std::time::{SystemTime, UNIX_EPOCH};

use mac_compute_jobs::{Limits, Stats};
use rmcp::model::{JsonObject, Tool};
use serde_json::{Value, json};
use tracing::warn;

use crate::state::Shared;

/// Liste der Worker.
pub const WORKERS_TOOL: &str = "workers";

/// Laufzeitkennzahlen des Gateways.
pub const METRICS_TOOL: &str = "metrics";

/// Hinweis, warum die Liste genau einen Worker enthält.
const LOCAL_ONLY_HINT: &str = "Verteilung auf mehrere Macs braucht einen gemeinsamen Store und \
     einen Registry-Dienst; dieses Gateway führt nur einen lokalen Worker, deshalb entsprechen \
     die Zähler genau der Warteschlange";

/// Ein MiB in Bytes; `ru_maxrss` wird darauf umgerechnet.
#[cfg(unix)]
const BYTES_PER_KIB: u64 = 1024;

/// Beide Betriebswerkzeuge des Gateways.
pub fn ops_tools() -> Vec<Tool> {
    vec![workers_tool(), metrics_tool()]
}

/// Kennzahlen des lokalen Workers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerSnapshot {
    /// Stabile Kennung `<host>-<8 hex>`.
    pub id: String,
    /// Hostname ohne Domain.
    pub host: String,
    /// Betriebssystem und Architektur, z. B. `macos/aarch64`.
    pub platform: String,
    /// Startzeit des Gateways und damit praktisch des Workers.
    pub started_at: SystemTime,
    /// Belegbare Plätze aus `maxConcurrent`.
    pub concurrency: u32,
}

/// Antwort von `workers`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Workers {
    /// Der einzige lokale Worker.
    pub worker: WorkerSnapshot,
    /// Zähler aus der Warteschlange; `None`, wenn der Store nicht lesbar war.
    pub stats: Option<Stats>,
    /// Meldung des Stores, falls er nicht lesbar war.
    pub stats_error: Option<String>,
}

impl Workers {
    /// Textzeilen der Antwort; `-` markiert nicht lesbare Zähler.
    pub fn render(&self) -> String {
        let mut lines = vec![
            "workers: 1".to_string(),
            "modus: lokal".to_string(),
            format!("worker.1.id: {}", self.worker.id),
            format!("worker.1.host: {}", self.worker.host),
            format!("worker.1.platform: {}", self.worker.platform),
            format!("worker.1.started_at: {}", iso8601(self.worker.started_at)),
            format!("worker.1.concurrency: {}", self.worker.concurrency),
            format!(
                "worker.1.running: {}",
                counter(self.stats.map(|s| s.running))
            ),
            format!(
                "worker.1.jobs_done: {}",
                counter(self.stats.map(|s| s.done))
            ),
            format!(
                "worker.1.jobs_failed: {}",
                counter(self.stats.map(|s| s.failed))
            ),
        ];
        if let Some(error) = &self.stats_error {
            lines.push(format!("worker.1.fehler: {error}"));
        }
        lines.push(format!("hinweis: {LOCAL_ONLY_HINT}"));
        lines.join("\n")
    }
}

/// Ein Backend, wie es `metrics` meldet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendReport {
    /// Name aus dem Manifest.
    pub name: String,
    /// `up`, `down` oder `disabled`.
    pub status: String,
    /// Anzahl der gemeldeten Tools; bei `down` und `disabled` null.
    pub tools: usize,
    /// Neustartversuche seit dem Start des Gateways.
    pub restarts: u32,
}

/// Antwort von `metrics`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Metrics {
    /// Startzeit des Gateways.
    pub started_at: SystemTime,
    /// Zähler aus der Warteschlange; `None`, wenn der Store nicht lesbar war.
    pub jobs: Option<Stats>,
    /// Meldung des Stores, falls er nicht lesbar war.
    pub jobs_error: Option<String>,
    /// Mittel der Laufzeiten abgeschlossener Aufgaben in Millisekunden;
    /// `None`, wenn keine Messwerte vorliegen oder der Store nicht lesbar war.
    pub avg_dauer_ms: Option<u64>,
    /// Anzahl der Laufzeit-Messwerte hinter [`Metrics::avg_dauer_ms`];
    /// `None`, wenn die Laufzeiten nicht lesbar waren.
    pub messwerte: Option<u64>,
    /// Meldung, falls die Laufzeiten nicht lesbar waren.
    pub dauer_error: Option<String>,
    /// Zustand aller Backends.
    pub backends: Vec<BackendReport>,
    /// Grenzen der Warteschlange.
    pub limits: Limits,
    /// Maximaler Speicherbedarf des Prozesses in MiB; `None`, wenn nicht
    /// lesbar.
    pub prozess_rss_mib: Option<u64>,
    /// Grund, warum der Speicherbedarf nicht lesbar war.
    pub prozess_fehler: Option<String>,
}

impl Metrics {
    /// Textzeilen der Antwort; `-` markiert nicht lesbare Werte.
    pub fn render(&self, now: SystemTime) -> String {
        let uptime = now.duration_since(self.started_at).unwrap_or_default();
        let mut lines = vec![
            format!("uptime_s: {}", uptime.as_secs()),
            format!("started_at: {}", iso8601(self.started_at)),
            format!("version: {}", mcp_core::version()),
        ];
        match &self.jobs {
            Some(stats) => {
                lines.push(format!("jobs.queued: {}", stats.queued));
                lines.push(format!("jobs.running: {}", stats.running));
                lines.push(format!("jobs.done: {}", stats.done));
                lines.push(format!("jobs.failed: {}", stats.failed));
                lines.push(format!("jobs.cancelled: {}", stats.cancelled));
            }
            None => lines.push("jobs: -".to_string()),
        }
        // Ohne Messwerte bleibt das Mittel offen; die Anzahl macht das
        // sichtbar, statt eine Null vorzutäuschen.
        lines.push(format!("jobs.avg_dauer_ms: {}", counter(self.avg_dauer_ms)));
        lines.push(format!("jobs.messwerte: {}", counter(self.messwerte)));
        if let Some(error) = &self.jobs_error {
            lines.push(format!("jobs.fehler: {error}"));
        }
        if let Some(error) = &self.dauer_error {
            lines.push(format!("jobs.dauer_fehler: {error}"));
        }
        lines.push(format!("backends: {}", self.backends.len()));
        for (index, backend) in self.backends.iter().enumerate() {
            let position = index + 1;
            lines.push(format!("backend.{position}.name: {}", backend.name));
            lines.push(format!("backend.{position}.status: {}", backend.status));
            lines.push(format!("backend.{position}.tools: {}", backend.tools));
            lines.push(format!("backend.{position}.restarts: {}", backend.restarts));
        }
        lines.push(format!(
            "limits.max_concurrent: {}",
            self.limits.max_concurrent
        ));
        lines.push(format!(
            "limits.max_per_backend: {}",
            self.limits.max_per_backend
        ));
        lines.push(format!("limits.max_queue: {}", self.limits.max_queue));
        lines.push(format!(
            "limits.max_queue_per_backend: {}",
            self.limits.max_queue_per_backend
        ));
        // `/proc` gibt es unter macOS nicht; `getrusage` liefert den Wert auf
        // beiden Systemen.
        lines.push(format!(
            "prozess_rss_mib: {}",
            counter(self.prozess_rss_mib)
        ));
        if let Some(error) = &self.prozess_fehler {
            lines.push(format!("prozess_fehler: {error}"));
        }
        lines.join("\n")
    }
}

impl Shared {
    /// Kennzahlen des lokalen Workers als Textzeilen.
    pub(crate) async fn workers(&self) -> String {
        let (stats, stats_error) = match self.store.stats().await {
            Ok(stats) => (Some(stats), None),
            Err(error) => {
                warn!(%error, "Worker-Zähler nicht lesbar");
                (None, Some(error.to_string()))
            }
        };
        Workers {
            worker: WorkerSnapshot {
                id: self.worker_id.clone(),
                host: self.host.clone(),
                platform: platform(),
                started_at: self.started_at,
                concurrency: self.store.limits().max_concurrent,
            },
            stats,
            stats_error,
        }
        .render()
    }

    /// Laufzeitkennzahlen als Textzeilen.
    pub(crate) async fn metrics(&self) -> String {
        let (jobs, jobs_error) = match self.store.stats().await {
            Ok(stats) => (Some(stats), None),
            Err(error) => {
                warn!(%error, "Kennzahlen der Warteschlange nicht lesbar");
                (None, Some(error.to_string()))
            }
        };
        let (avg_dauer_ms, messwerte, dauer_error) = match self.store.duration_stats().await {
            Ok(durations) => (durations.average_ms, Some(durations.samples), None),
            Err(error) => {
                warn!(%error, "Laufzeiten der Warteschlange nicht lesbar");
                (None, None, Some(error.to_string()))
            }
        };
        let (prozess_rss_mib, prozess_fehler) = match process_rss_mib() {
            Ok(mib) => (Some(mib), None),
            Err(error) => {
                warn!(%error, "Speicherbedarf des Prozesses nicht lesbar");
                (None, Some(error))
            }
        };
        let snapshot = self.registry.lock().await.metrics();
        // Kleine Kopie, damit die Sperre den Aufbau der Liste nicht umschließt.
        let counters = self.restarts.lock().await.clone();
        let backends = snapshot
            .into_iter()
            .map(|entry| {
                let restarts = counters.get(&entry.name).copied().unwrap_or_default();
                BackendReport {
                    name: entry.name,
                    status: entry.status.to_string(),
                    tools: entry.tools,
                    restarts,
                }
            })
            .collect();
        Metrics {
            started_at: self.started_at,
            jobs,
            jobs_error,
            avg_dauer_ms,
            messwerte,
            dauer_error,
            backends,
            limits: self.store.limits(),
            prozess_rss_mib,
            prozess_fehler,
        }
        .render(SystemTime::now())
    }
}

/// Stabile Kennung des lokalen Workers aus Hostname und Startzeit.
///
/// Die Startzeit ist über die Prozesslaufzeit konstant; die Kennung ändert
/// sich also nur mit einem Neustart und bleibt innerhalb eines Laufs stabil.
pub fn worker_id(host: &str, started_at: SystemTime) -> String {
    let millis = started_at
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis());
    let low = u32::try_from(millis & 0xffff_ffff).unwrap_or_default();
    let high = u32::try_from((millis >> 32) & 0xffff_ffff).unwrap_or_default();
    format!("{}-{:08x}", host_slug(host), low ^ high)
}

/// Kurzform eines Hostnamens: erste Namensstufe, klein, ohne Sonderzeichen.
pub fn host_slug(raw: &str) -> String {
    let label = raw.split('.').next().unwrap_or(raw).to_ascii_lowercase();
    let slug: String = label
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let slug = slug.trim_matches('-');
    if slug.is_empty() {
        "mac".to_string()
    } else {
        slug.to_string()
    }
}

/// Name des Hosts ohne zusätzliche Abhängigkeit.
///
/// Erst die Umgebungsvariable `HOSTNAME`, dann das Programm `hostname`, sonst
/// `localhost`. Der Aufruf passiert einmal beim Start des Gateways.
pub fn hostname() -> String {
    if let Ok(name) = std::env::var("HOSTNAME")
        && !name.trim().is_empty()
    {
        return name;
    }
    if let Ok(output) = std::process::Command::new("hostname").output()
        && output.status.success()
    {
        let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !name.is_empty() {
            return name;
        }
    }
    "localhost".to_string()
}

/// Betriebssystem und Architektur, z. B. `macos/aarch64`.
pub fn platform() -> String {
    format!("{}/{}", std::env::consts::OS, std::env::consts::ARCH)
}

/// Maximaler Speicherbedarf des Prozesses in MiB.
///
/// Quelle ist `ps -o rss= -p <pid>`: auf macOS und Linux in KiB, ohne
/// `unsafe` und ohne zusätzliche Abhängigkeit. Der Fehlertext nennt den
/// Grund, damit `metrics` ihn als `prozess_fehler` ausgeben kann.
pub fn process_rss_mib() -> Result<u64, String> {
    let pid = std::process::id().to_string();
    let output = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &pid])
        .output()
        .map_err(|error| format!("ps nicht ausführbar: {error}"))?;
    if !output.status.success() {
        return Err("ps meldet einen Fehler".to_string());
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let kib: u64 = text
        .trim()
        .parse()
        .map_err(|_| format!("ps liefert keine Zahl: {}", text.trim()))?;
    Ok(kib / BYTES_PER_KIB)
}

/// Zeitstempel in UTC als `YYYY-MM-DDTHH:MM:SSZ`.
pub fn iso8601(time: SystemTime) -> String {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs());
    let seconds = i64::try_from(seconds).unwrap_or(i64::MAX);
    let days = seconds.div_euclid(86_400);
    let rest = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3_600,
        (rest % 3_600) / 60,
        rest % 60
    )
}

/// Datum aus Tagen seit 1970-01-01, nach Howard Hinnant.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_part = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_part + 2) / 5 + 1;
    let month = if month_part < 10 {
        month_part + 3
    } else {
        month_part - 9
    };
    let year = if month <= 2 { year + 1 } else { year };
    (year, month, day)
}

/// Zähler als Text; `-` bedeutet „nicht lesbar“.
fn counter(value: Option<u64>) -> String {
    value.map_or_else(|| "-".to_string(), |count| count.to_string())
}

fn workers_tool() -> Tool {
    Tool::new(
        WORKERS_TOOL,
        "Liste der Worker mit Kennung, Host, Plattform, Plätzen und Zählern",
        no_args_schema(),
    )
}

fn metrics_tool() -> Tool {
    Tool::new(
        METRICS_TOOL,
        "Laufzeitkennzahlen: Uptime, Aufgaben samt mittlerer Dauer, Speicherbedarf, Backends \
         und Grenzen",
        no_args_schema(),
    )
}

fn no_args_schema() -> JsonObject {
    // OpenCode verlangt ein Objekt-Schema; ein leeres `{}` wird abgelehnt.
    let mut schema = JsonObject::new();
    schema.insert("type".to_string(), Value::String("object".to_string()));
    schema.insert("properties".to_string(), json!({}));
    schema.insert("additionalProperties".to_string(), Value::Bool(false));
    schema
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn snapshot() -> WorkerSnapshot {
        WorkerSnapshot {
            id: worker_id(
                "Mac.fritz.box",
                UNIX_EPOCH + Duration::from_secs(1_700_000_000),
            ),
            host: "mac".to_string(),
            platform: "macos/aarch64".to_string(),
            started_at: UNIX_EPOCH + Duration::from_secs(1_700_000_000),
            concurrency: 2,
        }
    }

    fn stats() -> Stats {
        Stats {
            queued: 3,
            running: 1,
            done: 7,
            failed: 2,
            cancelled: 1,
        }
    }

    #[test]
    fn worker_id_hat_host_und_acht_hexziffern() {
        let id = worker_id(
            "Mac.fritz.box",
            UNIX_EPOCH + Duration::from_secs(1_700_000_000),
        );
        let suffix = id.strip_prefix("mac-").expect("Host-Präfix");
        assert_eq!(suffix.len(), 8, "id: {id}");
        assert!(
            suffix.chars().all(|c| c.is_ascii_hexdigit()),
            "kein Hex: {suffix}"
        );
    }

    #[test]
    fn worker_id_ist_stabil_und_folgt_der_startzeit() {
        let start = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        let first = worker_id("mac", start);
        let second = worker_id("mac", start);
        assert_eq!(first, second, "gleiche Startzeit ergibt gleiche Kennung");
        assert_ne!(
            worker_id("mac", start),
            worker_id("mac", start + Duration::from_secs(1))
        );
        assert_ne!(
            worker_id("mac", start),
            worker_id("node-b", start),
            "Hostname geht in die Kennung ein"
        );
    }

    #[test]
    fn host_slug_reduziert_auf_die_erste_namensstufe() {
        assert_eq!(host_slug("Mac.fritz.box"), "mac");
        assert_eq!(host_slug("MacBook-Pro.local"), "macbook-pro");
        assert_eq!(host_slug("  "), "mac");
        assert_eq!(host_slug(""), "mac");
    }

    #[test]
    fn iso8601_kennt_epoche_und_bekannte_tage() {
        assert_eq!(iso8601(UNIX_EPOCH), "1970-01-01T00:00:00Z");
        assert_eq!(
            iso8601(UNIX_EPOCH + Duration::from_secs(1_000_000_000)),
            "2001-09-09T01:46:40Z"
        );
        // Schalttag 2024-02-29.
        assert_eq!(
            iso8601(UNIX_EPOCH + Duration::from_secs(1_709_164_800)),
            "2024-02-29T00:00:00Z"
        );
    }

    #[test]
    fn workers_mappen_zaehler_aus_der_statistik() {
        let text = Workers {
            worker: snapshot(),
            stats: Some(stats()),
            stats_error: None,
        }
        .render();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "workers: 1");
        assert_eq!(lines[1], "modus: lokal");
        assert!(text.contains("worker.1.running: 1"));
        assert!(text.contains("worker.1.jobs_done: 7"));
        assert!(text.contains("worker.1.jobs_failed: 2"));
        assert!(text.contains("worker.1.concurrency: 2"));
        assert!(text.contains("worker.1.started_at: 2023-11-14T22:13:20Z"));
        assert!(text.contains("hinweis: "));
        assert!(!text.contains("worker.1.fehler"));
    }

    #[test]
    fn workers_ohne_store_zeigen_striche_und_den_fehler() {
        let text = Workers {
            worker: snapshot(),
            stats: None,
            stats_error: Some("Datenbank gesperrt".to_string()),
        }
        .render();
        assert!(text.contains("worker.1.running: -"));
        assert!(text.contains("worker.1.jobs_done: -"));
        assert!(text.contains("worker.1.fehler: Datenbank gesperrt"));
    }

    #[test]
    fn metrics_enthaelt_kennzahlen_backends_und_grenzen() {
        let metrics = Metrics {
            started_at: UNIX_EPOCH,
            jobs: Some(stats()),
            jobs_error: None,
            avg_dauer_ms: Some(250),
            messwerte: Some(4),
            dauer_error: None,
            backends: vec![BackendReport {
                name: "render".to_string(),
                status: "up".to_string(),
                tools: 4,
                restarts: 2,
            }],
            limits: Limits::default(),
            prozess_rss_mib: Some(42),
            prozess_fehler: None,
        };
        let text = metrics.render(UNIX_EPOCH + Duration::from_secs(90));
        assert!(text.contains("uptime_s: 90"));
        assert!(text.contains("started_at: 1970-01-01T00:00:00Z"));
        assert!(text.contains(&format!("version: {}", mcp_core::version())));
        assert!(text.contains("jobs.queued: 3"));
        assert!(text.contains("jobs.running: 1"));
        assert!(text.contains("jobs.done: 7"));
        assert!(text.contains("jobs.failed: 2"));
        assert!(text.contains("jobs.cancelled: 1"));
        assert!(text.contains("jobs.avg_dauer_ms: 250"));
        assert!(text.contains("jobs.messwerte: 4"));
        assert!(text.contains("backends: 1"));
        assert!(text.contains("backend.1.name: render"));
        assert!(text.contains("backend.1.tools: 4"));
        assert!(text.contains("backend.1.restarts: 2"));
        assert!(text.contains("limits.max_concurrent: 1"));
        assert!(text.contains("limits.max_queue: 64"));
        assert!(text.contains("prozess_rss_mib: 42"));
        assert!(!text.contains("prozess: "), "alte Zeile ist ersetzt");
        assert!(!text.contains("prozess_fehler"));
        assert!(!text.contains("jobs.fehler"));
        assert!(!text.to_lowercase().contains("token"), "keine Secrets");
    }

    #[test]
    fn metrics_ohne_messwerte_zeigen_einen_strich() {
        let metrics = Metrics {
            started_at: UNIX_EPOCH,
            jobs: Some(Stats::default()),
            jobs_error: None,
            avg_dauer_ms: None,
            messwerte: Some(0),
            dauer_error: None,
            backends: Vec::new(),
            limits: Limits::default(),
            prozess_rss_mib: Some(7),
            prozess_fehler: None,
        };
        let text = metrics.render(UNIX_EPOCH);
        assert!(text.contains("jobs.avg_dauer_ms: -"), "{text}");
        assert!(text.contains("jobs.messwerte: 0"), "{text}");
        assert!(text.contains("prozess_rss_mib: 7"), "{text}");
    }

    #[test]
    fn metrics_ohne_store_melden_den_fehler() {
        let metrics = Metrics {
            started_at: UNIX_EPOCH,
            jobs: None,
            jobs_error: Some("Datenbank gesperrt".to_string()),
            avg_dauer_ms: None,
            messwerte: None,
            dauer_error: Some("Datenbank gesperrt".to_string()),
            backends: Vec::new(),
            limits: Limits::default(),
            prozess_rss_mib: None,
            prozess_fehler: Some("EPERM".to_string()),
        };
        let text = metrics.render(UNIX_EPOCH);
        assert!(text.contains("jobs: -"));
        assert!(text.contains("jobs.fehler: Datenbank gesperrt"));
        assert!(text.contains("jobs.dauer_fehler: Datenbank gesperrt"));
        assert!(text.contains("backends: 0"));
        assert!(!text.contains("jobs.queued"));
        assert!(text.contains("jobs.avg_dauer_ms: -"));
        assert!(text.contains("jobs.messwerte: -"));
        assert!(text.contains("prozess_rss_mib: -"));
        assert!(text.contains("prozess_fehler: EPERM"));
    }

    /// Der eigene Prozess liefert einen plausiblen Wert.
    #[test]
    fn prozess_rss_ist_lesbar() {
        let mib = process_rss_mib().expect("ps");
        assert!(mib > 0, "RSS: {mib} MiB");
    }
}
