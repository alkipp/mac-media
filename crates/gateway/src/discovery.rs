//! Discovery der Backend-Manifeste und Proxy für ihre Tools.
//!
//! Ein Manifest unter `servers.d/*.json` beschreibt ein Backend. Das Gateway
//! startet nur aktivierte Backends, fragt `tools/list` ab und stellt die Tools
//! unter `<name>_<tool>` bereit. Fehler eines Backends bleiben lokal: das
//! Gateway läuft weiter und meldet den Status über das Tool `capabilities`.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use mcp_core::Manifest;
use rmcp::{
    ErrorData as McpError, RoleClient, ServiceExt,
    model::{
        CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, JsonObject, Tool,
    },
    service::{Peer, RunningService},
    transport::TokioChildProcess,
};
use serde_json::{Value, json};
use tokio::process::Command;
use tokio::time::timeout;
use tracing::{error, info, warn};

/// Name des Gateway-Tools, das den Backend-Status meldet.
pub const CAPABILITIES_TOOL: &str = "capabilities";

/// Größte erlaubte Länge eines Tool-Namens laut MCP.
const MAX_TOOL_NAME_LEN: usize = 64;

/// Zustand eines Backends.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackendStatus {
    /// Backend läuft und hat Tools gemeldet.
    Up,
    /// Im Manifest deaktiviert.
    Disabled,
    /// Start oder Handshake fehlgeschlagen.
    Down(String),
}

impl BackendStatus {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Up => "up",
            Self::Disabled => "disabled",
            Self::Down(_) => "down",
        }
    }
}

/// Ein Backend samt laufender Verbindung.
pub struct Backend {
    /// Manifest, aus dem das Backend gestartet wurde.
    pub manifest: Manifest,
    /// Aktueller Zustand.
    pub status: BackendStatus,
    /// Tools mit den Originalnamen des Backends.
    pub tools: Vec<Tool>,
    peer: Option<Peer<RoleClient>>,
    // Hält die Verbindung am Leben; wird beim Drop geschlossen.
    _service: Option<RunningService<RoleClient, ()>>,
}

impl Backend {
    /// Startet das Backend als Kindprozess und fragt seine Tools ab.
    pub async fn connect(manifest: Manifest) -> Self {
        match spawn_service(&manifest).await {
            Ok(service) => Self::from_service(manifest, service).await,
            Err(message) => Self::down(manifest, message),
        }
    }

    /// Baut das Backend aus einer bereits verbundenen Service-Instanz.
    ///
    /// Öffentlich, damit Tests eine In-Process-Verbindung (z. B. Duplex) ohne
    /// Kindprozess verwenden können.
    pub async fn from_service(manifest: Manifest, service: RunningService<RoleClient, ()>) -> Self {
        let tools = match service.list_all_tools().await {
            Ok(tools) => tools,
            Err(error) => {
                return Self::down(manifest, format!("tools/list fehlgeschlagen: {error}"));
            }
        };
        let prefix = format!("{}_", manifest.name);
        let tools: Vec<Tool> = tools
            .into_iter()
            .filter(|tool| {
                let namespaced = format!("{prefix}{}", tool.name);
                let valid =
                    namespaced.len() <= MAX_TOOL_NAME_LEN && is_valid_tool_name(&namespaced);
                if !valid {
                    warn!(
                        backend = %manifest.name,
                        tool = %tool.name,
                        "Tool-Name ist ungültig oder zu lang und wird übersprungen"
                    );
                }
                valid
            })
            .collect();
        info!(backend = %manifest.name, tools = tools.len(), "Backend bereit");
        Self {
            manifest,
            status: BackendStatus::Up,
            tools,
            peer: Some(service.peer().clone()),
            _service: Some(service),
        }
    }

    fn down(manifest: Manifest, message: String) -> Self {
        error!(backend = %manifest.name, error = %message, "Backend nicht verfügbar");
        Self {
            manifest,
            status: BackendStatus::Down(message),
            tools: Vec::new(),
            peer: None,
            _service: None,
        }
    }

    fn disabled(manifest: Manifest) -> Self {
        info!(backend = %manifest.name, "Backend ist im Manifest deaktiviert");
        Self {
            manifest,
            status: BackendStatus::Disabled,
            tools: Vec::new(),
            peer: None,
            _service: None,
        }
    }

    /// Tools mit Gateway-Namespace (`<name>_<tool>`).
    pub fn namespaced_tools(&self) -> impl Iterator<Item = Tool> + '_ {
        self.tools.iter().map(|tool| {
            let mut namespaced = tool.clone();
            namespaced.name = format!("{}_{}", self.manifest.name, tool.name).into();
            namespaced
        })
    }

    /// Ursprünglicher Tool-Name im Backend.
    fn tool_name<'a>(&self, namespaced: &'a str) -> Option<&'a str> {
        namespaced.strip_prefix(&format!("{}_", self.manifest.name))
    }

    fn is_transport_closed(&self) -> bool {
        self.peer
            .as_ref()
            .is_some_and(|peer| peer.is_transport_closed())
    }
}

/// Zustand eines Backends, wie ihn das Tool `metrics` braucht.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendMetrics {
    /// Name aus dem Manifest.
    pub name: String,
    /// `up`, `down` oder `disabled`.
    pub status: &'static str,
    /// Anzahl der gemeldeten Tools; bei `down` und `disabled` leer.
    pub tools: usize,
}

/// Aufrufziel für ein namespaced Tool.
pub struct Target {
    /// Name des Backends.
    pub backend: String,
    /// Tool-Name im Backend (ohne Namespace).
    pub tool: String,
    /// Timeout aus dem Manifest.
    pub timeout: Duration,
    /// Verbindung zum Backend.
    pub peer: Peer<RoleClient>,
}

/// Ursache eines fehlgeschlagenen Backend-Aufrufs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchKind {
    /// Das Backend hat den Aufruf mit Fehler beantwortet.
    Backend,
    /// Das Manifest-Timeout ist abgelaufen.
    Timeout,
}

/// Fehler beim Weiterleiten eines Aufrufs, inklusive Backend-Zuordnung.
pub struct DispatchError {
    /// Backend, das den Fehler verursacht hat.
    pub backend: String,
    /// Ursache des Fehlers.
    pub kind: DispatchKind,
    /// Fehler für den Client.
    pub error: McpError,
}

/// Leitet einen Aufruf an das Backend weiter und erzwingt das Timeout.
pub async fn dispatch(
    target: &Target,
    request: CallToolRequestParams,
) -> Result<CallToolResponse, DispatchError> {
    let mut forwarded = CallToolRequestParams::new(target.tool.clone());
    forwarded.arguments = request.arguments;

    match timeout(target.timeout, target.peer.call_tool(forwarded)).await {
        Ok(Ok(result)) => Ok(CallToolResponse::Complete(result)),
        Ok(Err(error)) => Err(DispatchError {
            backend: target.backend.clone(),
            kind: DispatchKind::Backend,
            error: McpError::internal_error(format!("Backend '{}': {error}", target.backend), None),
        }),
        Err(_) => Err(DispatchError {
            backend: target.backend.clone(),
            kind: DispatchKind::Timeout,
            error: McpError::internal_error(
                format!(
                    "Backend '{}' hat das Zeitlimit von {} ms überschritten",
                    target.backend,
                    target.timeout.as_millis()
                ),
                None,
            ),
        }),
    }
}

/// Alle Backends, die aus einem Verzeichnis geladen wurden.
pub struct Registry {
    backends: Vec<Backend>,
}

impl Registry {
    /// Registry aus bereits geladenen Backends.
    pub fn new(backends: Vec<Backend>) -> Self {
        Self { backends }
    }

    /// Leere Registry, nützlich für Tests und den Start ohne Backends.
    pub fn empty() -> Self {
        Self::new(Vec::new())
    }

    /// Liest `servers.d/*.json`, validiert jedes Manifest und startet die
    /// aktivierten Backends. Ungültige Manifeste werden übersprungen.
    pub async fn load(servers_dir: &Path) -> Self {
        let mut backends = Vec::new();
        let mut names = HashSet::new();
        for path in manifest_paths(servers_dir) {
            let manifest = match read_manifest(&path) {
                Ok(manifest) => manifest,
                Err(message) => {
                    error!(file = %path.display(), error = %message, "Manifest abgelehnt");
                    continue;
                }
            };
            if !names.insert(manifest.name.clone()) {
                error!(
                    file = %path.display(),
                    name = %manifest.name,
                    "Manifest mit doppeltem Namen übersprungen"
                );
                continue;
            }
            if manifest.enabled {
                backends.push(Backend::connect(manifest).await);
            } else {
                backends.push(Backend::disabled(manifest));
            }
        }
        info!(backends = backends.len(), "Discovery abgeschlossen");
        Self::new(backends)
    }

    /// Anzahl der bekannten Backends, auch deaktivierte.
    pub fn len(&self) -> usize {
        self.backends.len()
    }

    /// `true`, wenn kein Backend konfiguriert ist.
    pub fn is_empty(&self) -> bool {
        self.backends.is_empty()
    }

    /// Tool-Liste für OpenCode: Gateway-Tool plus alle Tools laufender Backends.
    pub fn tools(&self) -> Vec<Tool> {
        let mut tools = vec![capabilities_tool()];
        for backend in &self.backends {
            if backend.status == BackendStatus::Up {
                tools.extend(backend.namespaced_tools());
            }
        }
        tools
    }

    /// Status, Limits und Tools aller Backends als JSON.
    pub fn capabilities(&self) -> Value {
        let backends: Vec<Value> = self
            .backends
            .iter()
            .map(|backend| {
                let error = match &backend.status {
                    BackendStatus::Down(message) => Some(message.as_str()),
                    _ => None,
                };
                json!({
                    "name": backend.manifest.name,
                    "version": backend.manifest.version,
                    "status": backend.status.as_str(),
                    "capabilities": backend.manifest.capabilities,
                    "timeout": backend.manifest.timeout,
                    "maxMemoryMB": backend.manifest.max_memory_mb,
                    "tools": backend
                        .tools
                        .iter()
                        .map(|tool| tool.name.to_string())
                        .collect::<Vec<_>>(),
                    "error": error,
                })
            })
            .collect();
        json!({
            "gateway": { "version": mcp_core::version() },
            "backends": backends,
        })
    }

    /// Name, Zustand und Tool-Anzahl je Backend für das Tool `metrics`.
    ///
    /// Die Liste umfasst auch deaktivierte und ausgefallene Backends, damit
    /// der Ausfall sichtbar bleibt.
    pub fn metrics(&self) -> Vec<BackendMetrics> {
        self.backends
            .iter()
            .map(|backend| BackendMetrics {
                name: backend.manifest.name.clone(),
                status: backend.status.as_str(),
                tools: backend.tools.len(),
            })
            .collect()
    }

    /// Sucht das Backend zu einem namespaced Tool und klont die Verbindung.
    pub fn target(&self, namespaced: &str) -> Result<Target, McpError> {
        for backend in &self.backends {
            if backend.status != BackendStatus::Up {
                continue;
            }
            let Some(tool) = backend.tool_name(namespaced) else {
                continue;
            };
            if !backend.tools.iter().any(|entry| entry.name == tool) {
                continue;
            }
            let Some(peer) = &backend.peer else {
                continue;
            };
            return Ok(Target {
                backend: backend.manifest.name.clone(),
                tool: tool.to_string(),
                timeout: Duration::from_millis(backend.manifest.timeout),
                peer: peer.clone(),
            });
        }
        Err(McpError::invalid_params(
            format!("Unbekanntes Tool '{namespaced}'"),
            None,
        ))
    }

    /// Markiert ein Backend als down und schließt seine Verbindung.
    pub fn mark_down(&mut self, name: &str, message: String) {
        if let Some(backend) = self
            .backends
            .iter_mut()
            .find(|backend| backend.manifest.name == name && backend.status == BackendStatus::Up)
        {
            error!(backend = %name, error = %message, "Backend wird als down markiert");
            backend.status = BackendStatus::Down(message);
            backend.tools.clear();
            backend.peer = None;
            backend._service = None;
        }
    }

    /// Ersetzt ein Backend durch eine neue Instanz.
    pub fn replace(&mut self, backend: Backend) {
        if let Some(slot) = self
            .backends
            .iter_mut()
            .find(|entry| entry.manifest.name == backend.manifest.name)
        {
            *slot = backend;
        } else {
            self.backends.push(backend);
        }
    }

    /// Erstes laufendes Backend, dessen Transport geschlossen wurde.
    pub fn first_closed(&self) -> Option<Manifest> {
        self.backends
            .iter()
            .find(|backend| backend.status == BackendStatus::Up && backend.is_transport_closed())
            .map(|backend| backend.manifest.clone())
    }

    /// Führt einen Aufruf aus und markiert das Backend bei Fehlern als down.
    ///
    /// Wird von Tests genutzt; das Gateway geht über [`crate::Shared`], damit
    /// die Sperre nicht über den gesamten Aufruf gehalten wird.
    pub async fn call(
        &mut self,
        request: CallToolRequestParams,
    ) -> Result<CallToolResponse, McpError> {
        if request.name == CAPABILITIES_TOOL {
            let text = serde_json::to_string_pretty(&self.capabilities())
                .map_err(|error| McpError::internal_error(error.to_string(), None))?;
            return Ok(CallToolResponse::Complete(CallToolResult::success(vec![
                ContentBlock::text(text),
            ])));
        }

        let target = self.target(&request.name)?;
        match dispatch(&target, request).await {
            Ok(response) => Ok(response),
            Err(failure) => {
                self.mark_down(&failure.backend, failure.error.to_string());
                Err(failure.error)
            }
        }
    }
}

fn capabilities_tool() -> Tool {
    // OpenCode verlangt ein Objekt-Schema; ein leeres `{}` wird abgelehnt.
    let mut schema = JsonObject::new();
    schema.insert("type".to_string(), Value::String("object".to_string()));
    Tool::new(
        CAPABILITIES_TOOL,
        "Status, Limits und Tools aller Backends",
        schema,
    )
}

async fn spawn_service(manifest: &Manifest) -> Result<RunningService<RoleClient, ()>, String> {
    let mut command = Command::new(&manifest.command[0]);
    command.args(&manifest.command[1..]);
    let transport = TokioChildProcess::new(command).map_err(|error| format!("spawn: {error}"))?;
    ().serve(transport)
        .await
        .map_err(|error| format!("initialize: {error}"))
}

fn manifest_paths(dir: &Path) -> Vec<PathBuf> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) => {
            warn!(dir = %dir.display(), %error, "Manifest-Verzeichnis nicht lesbar");
            return Vec::new();
        }
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        })
        .collect();
    paths.sort();
    paths
}

fn read_manifest(path: &Path) -> Result<Manifest, String> {
    let raw = fs::read_to_string(path).map_err(|error| error.to_string())?;
    let expanded = mcp_core::expand_placeholders(&raw);
    let manifest: Manifest = serde_json::from_str(&expanded).map_err(|error| error.to_string())?;
    manifest.validate().map_err(|error| error.to_string())?;
    Ok(manifest)
}

fn is_valid_tool_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
}
