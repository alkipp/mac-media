//! Dateibasierter Sitzungsspeicher für den Streamable-HTTP-Transport.
//!
//! Der Gateway hält MCP-Sitzungen im Arbeitsspeicher (`LocalSessionManager`).
//! Nach einem Neustart – jeder Deploy löst einen aus – beantwortet er die alte
//! `Mcp-Session-Id` mit `404 Not Found`. Clients wie OpenCode verlieren dann den
//! Zugang, bis sie von sich aus neu verbinden; passiert das mitten in einem
//! langen Bildlauf, ist die Arbeit verloren.
//!
//! rmcp kann Sitzungen aus einem externen Speicher wiederherstellen
//! (`StreamableHttpServerConfig::session_store`): trifft eine Anfrage auf eine
//! unbekannte Sitzung, lädt der Gateway die Initialize-Parameter, legt eine
//! frische Sitzung an und spielt den Handshake intern nach. Der Client merkt
//! davon nichts und behält seine Sitzungs-ID.
//!
//! Zwei Eigenschaften kommen hinzu:
//!
//! * **Wiederbelebung unbekannter IDs.** Fehlt die Datei – Sitzung von vor dem
//!   ersten Deploy mit Speicher, Datei aufgeräumt –, liefert [`load`] das
//!   zuletzt gesehene Client-Profil. Die Sitzung lebt weiter, statt mit 404 zu
//!   enden.
//! * **Pfad-Schutz.** Sitzungs-IDs kommen vom Client. Nur `[A-Za-z0-9-]` bis
//!   128 Zeichen werden als Dateiname verwendet; alles andere bekommt das
//!   Standardprofil ohne Dateizugriff.
//!
//! [`load`]: SessionStore::load

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use rmcp::model::{ClientCapabilities, Implementation, InitializeRequestParams, ProtocolVersion};
use rmcp::transport::streamable_http_server::session::store::{
    SessionState, SessionStore, SessionStoreError,
};
use tokio::sync::RwLock;

/// Unterverzeichnis des Zustandsverzeichnisses für Sitzungsdateien.
pub const SESSION_SUBDIR: &str = "sessions";

/// Längste akzeptierte Sitzungs-ID als Dateiname.
const MAX_ID_LEN: usize = 128;

/// Höchstzahl aufbewahrter Sitzungsdateien.
const MAX_FILES: usize = 512;

/// Höchstalter einer Sitzungsdatei; ältere werden beim Start entfernt.
const MAX_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);

/// Datei mit dem zuletzt gesehenen Client-Profil.
///
/// Der Punkt im Namen ist Absicht: [`FileSessionStore::path`] akzeptiert ihn
/// nicht als Sitzungs-ID, damit sich Profil und Sitzungen nie überschreiben.
const PROFILE_FILE: &str = "client-profile.json";

/// Sitzungsspeicher als Verzeichnis mit einer JSON-Datei je Sitzung.
pub struct FileSessionStore {
    dir: PathBuf,
    profile: RwLock<Option<SessionState>>,
}

impl FileSessionStore {
    /// Öffnet den Speicher unter `dir` und legt ihn bei Bedarf an.
    ///
    /// Beim Öffnen wird aufgeräumt: Dateien älter als 30 Tage und alles über
    /// 512 Einträge hinaus verschwindet. Das Profil bleibt erhalten.
    pub fn open(dir: impl Into<PathBuf>) -> io::Result<Self> {
        let dir = dir.into();
        fs::create_dir_all(&dir)?;
        prune(&dir);
        let profile = fs::read(dir.join(PROFILE_FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<SessionState>(&bytes).ok());
        Ok(Self {
            dir,
            profile: RwLock::new(profile),
        })
    }

    /// Verzeichnis der Sitzungsdateien.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Pfad zu einer Sitzungsdatei, sofern die ID als Dateiname taugt.
    fn path(&self, session_id: &str) -> Option<PathBuf> {
        if session_id.is_empty() || session_id.len() > MAX_ID_LEN {
            return None;
        }
        let valid = session_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-');
        valid.then(|| self.dir.join(format!("{session_id}.json")))
    }

    /// Zustand für eine unbekannte Sitzung: zuletzt gesehenes Profil.
    async fn fallback(&self) -> SessionState {
        self.profile
            .read()
            .await
            .clone()
            .unwrap_or_else(default_state)
    }

    /// Merkt sich das Client-Profil für spätere Wiederbelebungen.
    async fn remember(&self, state: &SessionState) {
        let mut profile = self.profile.write().await;
        *profile = Some(state.clone());
        let bytes = match serde_json::to_vec(state) {
            Ok(bytes) => bytes,
            Err(_) => return,
        };
        let _ = write_atomic(&self.dir.join(PROFILE_FILE), &bytes);
    }
}

/// Standardprofil, wenn noch kein Client gesehen wurde.
fn default_state() -> SessionState {
    let mut params = InitializeRequestParams::new(
        ClientCapabilities::default(),
        Implementation::new("unbekannter-client", "0"),
    );
    // Ältere, breit unterstützte Fassung: der Client sieht diesen Handshake
    // nicht, aber ein zu neuer Wert könnte Backends verwirren.
    params.protocol_version = ProtocolVersion::V_2025_06_18;
    SessionState::new(params)
}

#[async_trait::async_trait]
impl SessionStore for FileSessionStore {
    async fn load(&self, session_id: &str) -> Result<Option<SessionState>, SessionStoreError> {
        let Some(path) = self.path(session_id) else {
            tracing::debug!(session_id, "Sitzungs-ID unbrauchbar, Standardprofil");
            return Ok(Some(default_state()));
        };
        match fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<SessionState>(&bytes) {
                Ok(state) => {
                    self.remember(&state).await;
                    Ok(Some(state))
                }
                Err(error) => {
                    tracing::warn!(
                        session_id,
                        %error,
                        "Sitzungsdatei unlesbar, Sitzung wird mit Profil wiederbelebt"
                    );
                    Ok(Some(self.fallback().await))
                }
            },
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                Ok(Some(self.fallback().await))
            }
            Err(error) => Err(Box::new(error)),
        }
    }

    async fn store(&self, session_id: &str, state: &SessionState) -> Result<(), SessionStoreError> {
        self.remember(state).await;
        let Some(path) = self.path(session_id) else {
            tracing::debug!(session_id, "Sitzungs-ID unbrauchbar, nichts gespeichert");
            return Ok(());
        };
        let bytes =
            serde_json::to_vec(state).map_err(|error| Box::new(error) as SessionStoreError)?;
        write_atomic(&path, &bytes).map_err(|error| Box::new(error) as SessionStoreError)
    }

    async fn delete(&self, session_id: &str) -> Result<(), SessionStoreError> {
        let Some(path) = self.path(session_id) else {
            return Ok(());
        };
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(Box::new(error)),
        }
    }
}

/// Schreibt `bytes` erst in eine Nebendatei und benennt sie dann um.
///
/// So liest nie jemand eine halb geschriebene Sitzung; die Datei ist für den
/// Eigentümer beschreibbar (0600), weil sie Client-Angaben enthält.
fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("json.tmp");
    {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&tmp)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)
}

/// Entfernt alte und überzählige Sitzungsdateien.
fn prune(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let now = SystemTime::now();
    let mut files: Vec<(SystemTime, PathBuf)> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let name = path.file_name()?.to_str()?;
            if name == PROFILE_FILE || !name.ends_with(".json") {
                return None;
            }
            let modified = entry.metadata().ok()?.modified().ok()?;
            Some((modified, path))
        })
        .collect();
    files.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    for (index, (modified, path)) in files.into_iter().enumerate() {
        let too_old = now
            .duration_since(modified)
            .map(|age| age > MAX_AGE)
            .unwrap_or(false);
        if index >= MAX_FILES || too_old {
            let _ = fs::remove_file(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(protocol: ProtocolVersion) -> SessionState {
        let mut params = InitializeRequestParams::new(
            ClientCapabilities::default(),
            Implementation::new("test-client", "1"),
        );
        params.protocol_version = protocol;
        SessionState::new(params)
    }

    #[tokio::test]
    async fn unbekannte_sitzung_liefert_standardprofil() {
        let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
        let store = FileSessionStore::open(dir.path()).expect("Speicher");
        let loaded = store.load("nie-gesehen").await.expect("load");
        let loaded = loaded.expect("Wiederbelebung statt 404");
        assert_eq!(
            loaded.initialize_params.client_info.name,
            "unbekannter-client"
        );
    }

    #[tokio::test]
    async fn sitzung_ueberlebt_neustart() {
        let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
        let expected = state(ProtocolVersion::V_2025_11_25);
        {
            let store = FileSessionStore::open(dir.path()).expect("Speicher");
            store.store("abc-123", &expected).await.expect("store");
        }
        let reopened = FileSessionStore::open(dir.path()).expect("Speicher neu");
        let loaded = reopened
            .load("abc-123")
            .await
            .expect("load")
            .expect("Sitzung vorhanden");
        assert_eq!(
            loaded.initialize_params.protocol_version,
            expected.initialize_params.protocol_version
        );
        assert_eq!(
            loaded.initialize_params.client_info.name,
            expected.initialize_params.client_info.name
        );
    }

    #[tokio::test]
    async fn unbekannte_id_nach_neustart_nutzt_profil() {
        let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
        let seen = state(ProtocolVersion::V_2025_11_25);
        {
            let store = FileSessionStore::open(dir.path()).expect("Speicher");
            store.store("alte-sitzung", &seen).await.expect("store");
        }
        let reopened = FileSessionStore::open(dir.path()).expect("Speicher neu");
        let loaded = reopened
            .load("andere-sitzung")
            .await
            .expect("load")
            .expect("Wiederbelebung");
        assert_eq!(loaded.initialize_params.client_info.name, "test-client");
    }

    #[tokio::test]
    async fn pfad_ausbruch_wird_abgewiesen() {
        let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
        let store = FileSessionStore::open(dir.path()).expect("Speicher");
        for id in ["../../etc/passwd", "a/b", "", "x".repeat(200).as_str()] {
            assert!(store.path(id).is_none(), "{id} darf kein Dateiname sein");
            store
                .store(id, &state(ProtocolVersion::V_2025_06_18))
                .await
                .expect("store ohne Datei");
            let loaded = store.load(id).await.expect("load").expect("Zustand");
            assert_eq!(
                loaded.initialize_params.client_info.name, "unbekannter-client",
                "{id} bekommt das Standardprofil"
            );
        }
        let count = fs::read_dir(dir.path()).expect("lesen").count();
        assert_eq!(count, 1, "nur das Profil wird geschrieben");
    }

    #[tokio::test]
    async fn delete_entfernt_datei_und_laesst_wiederbelebung_zu() {
        let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
        let store = FileSessionStore::open(dir.path()).expect("Speicher");
        let value = state(ProtocolVersion::V_2025_11_25);
        store.store("abc-123", &value).await.expect("store");
        store.delete("abc-123").await.expect("delete");
        assert!(!dir.path().join("abc-123.json").exists());
        assert!(store.load("abc-123").await.expect("load").is_some());
    }

    #[tokio::test]
    async fn prune_entfernt_alte_dateien_und_behaelt_das_profil() {
        let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
        let store = FileSessionStore::open(dir.path()).expect("Speicher");
        store
            .store("alt", &state(ProtocolVersion::V_2025_11_25))
            .await
            .expect("store");
        let old = SystemTime::now() - MAX_AGE - Duration::from_secs(3_600);
        let file = fs::File::options()
            .write(true)
            .open(dir.path().join("alt.json"))
            .expect("Datei");
        file.set_modified(old).expect("Zeitstempel");
        drop(file);

        let reopened = FileSessionStore::open(dir.path()).expect("Speicher neu");
        assert!(!reopened.dir().join("alt.json").exists(), "alt ist weg");
        assert!(reopened.dir().join(PROFILE_FILE).exists(), "Profil bleibt");
    }
}
