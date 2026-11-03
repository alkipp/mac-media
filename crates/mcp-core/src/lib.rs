//! Gemeinsame Typen für Gateway und Backends.
//!
//! Ein Backend wird durch ein Manifest beschrieben: Name, Transport, Kommando,
//! Capabilities und Limits. Das Gateway liest die Manifeste aus `servers.d/`,
//! validiert sie und startet nur die aktivierten Backends.
//!
//! Die Regeln sind absichtlich eng: keine Shell-Strings, absolute Pfade,
//! begrenzte Namen und Limits. Ein ungültiges Manifest wird abgelehnt, bevor
//! ein Prozess startet.

use std::collections::HashSet;
use std::path::Path;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Inhalt der Repo-Datei `VERSION` – eine Quelle für Gateway, `/health` und
/// `serverInfo` (nicht die Crate-Version aus `Cargo.toml`).
pub const VERSION_FILE: &str = include_str!("../../../VERSION");

/// Repo-Version ohne Zeilenumbruch; das ist die Version, die nach außen gilt.
#[must_use]
pub fn version() -> &'static str {
    VERSION_FILE.trim()
}

/// Platzhalter, der beim Laden durch das Home-Verzeichnis ersetzt wird.
pub const HOME_PLACEHOLDER: &str = "@HOME@";

/// Platzhalter für `~/Library/Application Support/mac-compute`.
pub const APP_SUPPORT_PLACEHOLDER: &str = "@APP_SUPPORT@";

/// Ersetzt die Platzhalter in einem Manifest-Text.
///
/// Die eingecheckten Manifeste unter `config/servers.d/` sind
/// maschinenunabhängig; das Gateway setzt `@HOME@` und `@APP_SUPPORT@` beim
/// Laden ein. Ohne `HOME` in der Umgebung bleibt der Text unverändert, damit
/// die Prüfung danach mit einem klaren Fehler abbricht.
#[must_use]
pub fn expand_placeholders(raw: &str) -> String {
    let Some(home) = std::env::var_os("HOME").and_then(|value| value.into_string().ok()) else {
        return raw.to_string();
    };
    let app_support = format!("{home}/Library/Application Support/mac-compute");
    raw.replace(APP_SUPPORT_PLACEHOLDER, &app_support)
        .replace(HOME_PLACEHOLDER, &home)
}

/// Maximale Länge für `name` und `capabilities`-Einträge.
pub const MAX_NAME_LEN: usize = 32;

/// Standard-Timeout eines Backend-Aufrufs in Millisekunden.
pub const DEFAULT_TIMEOUT_MS: u64 = 600_000;

/// Kleinstes erlaubtes Timeout in Millisekunden.
pub const MIN_TIMEOUT_MS: u64 = 1_000;

/// Größtes erlaubtes Timeout in Millisekunden (24 h).
pub const MAX_TIMEOUT_MS: u64 = 86_400_000;

/// Standard-Speicherlimit eines Backends in MiB.
pub const DEFAULT_MAX_MEMORY_MB: u32 = 4_096;

/// Kleinstes erlaubtes Speicherlimit in MiB.
pub const MIN_MAX_MEMORY_MB: u32 = 64;

/// Größtes erlaubtes Speicherlimit in MiB (64 GiB).
pub const MAX_MAX_MEMORY_MB: u32 = 65_536;

const fn default_timeout_ms() -> u64 {
    DEFAULT_TIMEOUT_MS
}

const fn default_max_memory_mb() -> u32 {
    DEFAULT_MAX_MEMORY_MB
}

const fn default_enabled() -> bool {
    true
}

/// Transport, über den das Gateway ein Backend erreicht.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Transport {
    /// Lokaler Kindprozess über stdin/stdout.
    Stdio,
}

/// Manifest eines Backends, wie es unter `servers.d/*.json` liegt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    /// Kurzer, eindeutiger Name. Bestimmt den Tool-Namespace (`<name>_<tool>`).
    pub name: String,

    /// Optionale Version des Backends, wie sie das Binary meldet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,

    /// Transport zum Backend.
    pub transport: Transport,

    /// Kommando als Array: Programm und Argumente, kein Shell-String.
    pub command: Vec<String>,

    /// Ressourcen, die das Backend bereitstellt (nicht die Tool-Namen).
    pub capabilities: Vec<String>,

    /// Zeitlimit pro Aufruf in Millisekunden.
    #[serde(default = "default_timeout_ms")]
    #[schemars(range(min = 1_000, max = 86_400_000))]
    pub timeout: u64,

    /// Speicherlimit des Backends in MiB.
    #[serde(rename = "maxMemoryMB", default = "default_max_memory_mb")]
    #[schemars(range(min = 64, max = 65_536))]
    pub max_memory_mb: u32,

    /// `false` hält das Backend konfiguriert, startet es aber nicht.
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

/// Fehler bei der Prüfung eines Manifests.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ManifestError {
    /// Der Name ist leer, zu lang oder enthält unerlaubte Zeichen.
    #[error(
        "name ist ungültig: 1–32 Zeichen, klein, Ziffern und '-', Beginn mit einem Buchstaben, kein '-' am Ende"
    )]
    InvalidName,

    /// Die Version ist leer, zu lang oder beginnt nicht mit einer Ziffer.
    #[error("version ist ungültig: 1–32 Zeichen, Beginn mit einer Ziffer")]
    InvalidVersion,

    /// Das Kommando-Array ist leer.
    #[error("command ist leer: Programm und Argumente werden als Array erwartet")]
    EmptyCommand,

    /// Das Programm im Kommando ist kein absoluter Pfad.
    #[error("command[0] muss ein absoluter Pfad sein, war: {0}")]
    NonAbsoluteCommand(String),

    /// Ein Argument ist leer.
    #[error("command[{index}] ist leer")]
    EmptyArgument {
        /// Position im Kommando-Array.
        index: usize,
    },

    /// Ein Argument enthält ein Null-Byte.
    #[error("command[{index}] enthält ein Null-Byte")]
    NulByte {
        /// Position im Kommando-Array.
        index: usize,
    },

    /// Es wurde keine Capability angegeben.
    #[error("capabilities ist leer: mindestens eine Ressource angeben")]
    EmptyCapabilities,

    /// Eine Capability hat ein unerlaubtes Format.
    #[error(
        "capability '{0}' ist ungültig: 1–32 Zeichen, klein, Ziffern und '-', kein '-' am Anfang oder Ende"
    )]
    InvalidCapability(String),

    /// Eine Capability ist doppelt eingetragen.
    #[error("capability '{0}' ist doppelt eingetragen")]
    DuplicateCapability(String),

    /// Das Timeout liegt außerhalb der Grenzen.
    #[error("timeout {0} liegt außerhalb von {MIN_TIMEOUT_MS}–{MAX_TIMEOUT_MS} ms")]
    TimeoutOutOfRange(u64),

    /// Das Speicherlimit liegt außerhalb der Grenzen.
    #[error("maxMemoryMB {0} liegt außerhalb von {MIN_MAX_MEMORY_MB}–{MAX_MAX_MEMORY_MB} MiB")]
    MemoryOutOfRange(u32),
}

/// Prüft Zeichen und Länge eines Namens oder Capability-Eintrags: klein,
/// Ziffern, Bindestrich, kein Bindestrich am Anfang oder Ende.
fn has_valid_chars(value: &str) -> bool {
    if value.is_empty() || value.len() > MAX_NAME_LEN {
        return false;
    }
    value
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !value.starts_with('-')
        && !value.ends_with('-')
}

/// Ein Name beginnt zusätzlich mit einem Buchstaben, damit der Tool-Namespace
/// eindeutig bleibt.
fn is_valid_name(value: &str) -> bool {
    has_valid_chars(value) && value.starts_with(|c: char| c.is_ascii_lowercase())
}

fn is_valid_version(value: &str) -> bool {
    if value.is_empty() || value.len() > MAX_NAME_LEN {
        return false;
    }
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !first.is_ascii_digit() {
        return false;
    }
    chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '+' | '-'))
}

impl Manifest {
    /// Prüft alle Felder gegen die Regeln aus der Spezifikation.
    pub fn validate(&self) -> Result<(), ManifestError> {
        if !is_valid_name(&self.name) {
            return Err(ManifestError::InvalidName);
        }
        if let Some(version) = &self.version
            && !is_valid_version(version)
        {
            return Err(ManifestError::InvalidVersion);
        }
        if self.command.is_empty() {
            return Err(ManifestError::EmptyCommand);
        }
        for (index, arg) in self.command.iter().enumerate() {
            if arg.is_empty() {
                return Err(ManifestError::EmptyArgument { index });
            }
            if arg.contains('\0') {
                return Err(ManifestError::NulByte { index });
            }
        }
        if !Path::new(&self.command[0]).is_absolute() {
            return Err(ManifestError::NonAbsoluteCommand(self.command[0].clone()));
        }
        if self.capabilities.is_empty() {
            return Err(ManifestError::EmptyCapabilities);
        }
        let mut seen = HashSet::new();
        for capability in &self.capabilities {
            if !has_valid_chars(capability) {
                return Err(ManifestError::InvalidCapability(capability.clone()));
            }
            if !seen.insert(capability) {
                return Err(ManifestError::DuplicateCapability(capability.clone()));
            }
        }
        if !(MIN_TIMEOUT_MS..=MAX_TIMEOUT_MS).contains(&self.timeout) {
            return Err(ManifestError::TimeoutOutOfRange(self.timeout));
        }
        if !(MIN_MAX_MEMORY_MB..=MAX_MAX_MEMORY_MB).contains(&self.max_memory_mb) {
            return Err(ManifestError::MemoryOutOfRange(self.max_memory_mb));
        }
        Ok(())
    }

    /// Namespace, unter dem die Tools dieses Backends erscheinen.
    pub fn namespace(&self) -> &str {
        &self.name
    }
}

/// Fehler beim Aufbau einer Manifest-Menge.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ManifestSetError {
    /// Ein Manifest ist ungültig.
    #[error("Manifest '{name}' ist ungültig: {source}")]
    Invalid {
        /// Name aus dem Manifest, auch wenn er selbst ungültig ist.
        name: String,
        /// Ursprünglicher Prüffehler.
        #[source]
        source: ManifestError,
    },

    /// Zwei Manifeste verwenden denselben Namen.
    #[error("Name '{0}' ist doppelt vergeben")]
    DuplicateName(String),
}

/// Geprüfte Sammlung von Manifesten.
#[derive(Debug, Clone, Default)]
pub struct ManifestSet {
    manifests: Vec<Manifest>,
}

impl ManifestSet {
    /// Validiert alle Manifeste und lehnt doppelte Namen ab.
    pub fn new(manifests: Vec<Manifest>) -> Result<Self, ManifestSetError> {
        let mut names = HashSet::new();
        for manifest in &manifests {
            manifest
                .validate()
                .map_err(|source| ManifestSetError::Invalid {
                    name: manifest.name.clone(),
                    source,
                })?;
            if !names.insert(manifest.name.clone()) {
                return Err(ManifestSetError::DuplicateName(manifest.name.clone()));
            }
        }
        Ok(Self { manifests })
    }

    /// Alle Manifeste, auch die deaktivierten.
    pub fn iter(&self) -> impl Iterator<Item = &Manifest> {
        self.manifests.iter()
    }

    /// Nur die aktivierten Manifeste, in Dateireihenfolge.
    pub fn enabled(&self) -> impl Iterator<Item = &Manifest> {
        self.manifests.iter().filter(|manifest| manifest.enabled)
    }

    /// Manifest zu einem Namen.
    pub fn get(&self, name: &str) -> Option<&Manifest> {
        self.manifests.iter().find(|manifest| manifest.name == name)
    }

    /// Anzahl der Manifeste.
    pub fn len(&self) -> usize {
        self.manifests.len()
    }

    /// `true`, wenn keine Manifeste vorhanden sind.
    pub fn is_empty(&self) -> bool {
        self.manifests.is_empty()
    }
}

/// JSON-Schema der Manifest-Datei, abgeleitet aus [`Manifest`].
pub fn manifest_schema() -> serde_json::Value {
    serde_json::to_value(schemars::schema_for!(Manifest))
        .expect("Manifest-Schema muss serialisierbar sein")
}

#[cfg(test)]
mod tests {
    use super::{VERSION_FILE, version};

    #[test]
    fn version_is_set() {
        assert!(!version().is_empty());
        assert!(!version().contains('\n'), "VERSION enthält einen Umbruch");
        assert!(
            version().split('.').count() == 3,
            "VERSION ist nicht MAJOR.MINOR.PATCH: {}",
            version()
        );
        assert_eq!(version(), VERSION_FILE.trim());
    }
}
