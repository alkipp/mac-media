//! `mac-compute-gateway`: ein MCP-Endpunkt vor mehreren nativen Backends.
//!
//! Das Gateway bindet nur an Loopback, verlangt einen Bearer-Token und reicht
//! `tools/list` und `tools/call` an die Backends aus `servers.d/` weiter.
//! Fehler eines Backends beenden das Gateway nicht.

mod discovery;
mod jobs;
mod ops;
mod sessions;
mod state;
pub mod watcher;
mod worker;

use std::fs;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use axum::{
    Json, Router,
    extract::{Request, State},
    http::{HeaderValue, StatusCode, header::AUTHORIZATION, header::WWW_AUTHENTICATE},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use rmcp::{
    ErrorData as McpError, RoleServer, ServerHandler,
    model::{
        CallToolRequestParams, CallToolResponse, Implementation, ListResourcesResult,
        ListToolsResult, PaginatedRequestParams, ReadResourceRequestParams, ReadResourceResponse,
        ReadResourceResult, Resource, ResourceContents, ServerCapabilities, ServerConfig,
    },
    service::{NotificationContext, RequestContext},
    transport::streamable_http_server::{
        StreamableHttpServerConfig, StreamableHttpService, session::local::LocalSessionManager,
    },
};
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use thiserror::Error;

pub use discovery::{Backend, BackendStatus, CAPABILITIES_TOOL, Registry};
pub use jobs::{JOB_CANCEL_TOOL, JOB_STATUS_TOOL, SUBMIT_JOB_TOOL};
pub use ops::{METRICS_TOOL, WORKERS_TOOL};
pub use sessions::{FileSessionStore, SESSION_SUBDIR};
pub use state::{Backoff, Shared};

/// Ressource mit der aggregierten Tool-Liste des Gateways.
pub const TOOLS_RESOURCE_URI: &str = "mac-media://tools";

/// Kleinste akzeptierte Token-Länge.
pub const MIN_TOKEN_LEN: usize = 32;

/// Fehler beim Aufbau der Gateway-Konfiguration.
#[derive(Debug, Error)]
pub enum ConfigError {
    /// Die Token-Datei ist nicht lesbar.
    #[error("token file '{path}' ist nicht lesbar: {source}")]
    TokenFile {
        /// Pfad der Token-Datei.
        path: PathBuf,
        /// Ursprünglicher Lesefehler.
        #[source]
        source: std::io::Error,
    },

    /// Der Token ist zu kurz.
    #[error("token ist kürzer als {MIN_TOKEN_LEN} Zeichen")]
    TokenTooShort,

    /// Der Token enthält Leerraum.
    #[error("token enthält Leerraum")]
    TokenWithWhitespace,

    /// Das Manifest-Verzeichnis ist kein absoluter Pfad.
    #[error("servers dir '{0}' ist kein absoluter Pfad")]
    ServersDirRelative(PathBuf),

    /// Das Manifest-Verzeichnis fehlt.
    #[error("servers dir '{0}' ist kein Verzeichnis")]
    ServersDirMissing(PathBuf),

    /// Die Bind-Adresse ist nicht Loopback.
    #[error("bind '{0}' ist keine Loopback-Adresse; der Gateway bleibt lokal")]
    NonLoopbackBind(SocketAddr),

    /// Das Log-Verzeichnis ist kein absoluter Pfad.
    #[error("log dir '{0}' ist kein absoluter Pfad")]
    LogDirRelative(PathBuf),

    /// Das Zustandsverzeichnis ist kein absoluter Pfad.
    #[error("state dir '{0}' ist kein absoluter Pfad")]
    StateDirRelative(PathBuf),

    /// Das Log-Verzeichnis ist nicht lesbar oder anlegbar.
    #[error("log dir '{path}' ist nicht nutzbar: {source}")]
    LogDir {
        /// Pfad des Log-Verzeichnisses.
        path: PathBuf,
        /// Ursprünglicher Fehler.
        #[source]
        source: std::io::Error,
    },

    /// Die Datei mit dem abgelösten Token ist nicht lesbar.
    #[error("token.previous '{path}' ist nicht lesbar: {source}")]
    PreviousTokenFile {
        /// Pfad der Datei.
        path: PathBuf,
        /// Ursprünglicher Lesefehler.
        #[source]
        source: std::io::Error,
    },

    /// Der abgelöste Token ist formal ungültig.
    #[error("token.previous '{path}' ist ungültig: {reason}")]
    PreviousTokenInvalid {
        /// Pfad der Datei.
        path: PathBuf,
        /// Grund der Ablehnung.
        reason: &'static str,
    },
}

/// Ein abgelöster, noch befristet gültiger Token.
#[derive(Debug, Clone)]
pub struct TokenGrace {
    /// Der bisherige Token.
    pub token: String,
    /// Ab diesem Zeitpunkt wird er nicht mehr akzeptiert.
    pub until: SystemTime,
}

/// Vorgabe für die Übergangsfrist eines abgelösten Tokens (7 Tage).
pub const DEFAULT_TOKEN_GRACE: Duration = Duration::from_secs(7 * 24 * 3600);

/// Dateiname des abgelösten Tokens neben der Token-Datei.
const PREVIOUS_TOKEN_FILE: &str = "token.previous";

/// Geprüfte Laufzeitkonfiguration des Gateways.
#[derive(Debug, Clone)]
pub struct Config {
    /// Adresse, an die gebunden wird.
    pub bind: SocketAddr,
    /// Verzeichnis mit den Backend-Manifesten.
    pub servers_dir: PathBuf,
    /// Verzeichnis für Datenbank und Laufzeitstatus.
    pub state_dir: PathBuf,
    /// Bearer-Token ohne Zeilenende.
    pub token: String,
    /// Abgelöster Token, der noch bis `until` gilt.
    pub previous: Option<TokenGrace>,
    /// Pfad der Token-Datei; `token.previous` liegt daneben.
    pub token_file: PathBuf,
    /// Optionales Log-Verzeichnis.
    pub log_dir: Option<PathBuf>,
}

impl Config {
    /// Liest den Token, prüft die Pfade und erzwingt Loopback.
    ///
    /// Das Zustandsverzeichnis liegt ohne eigene Angabe neben `servers.d/`,
    /// also unter `.../mac-compute/state`.
    pub fn new(
        bind: SocketAddr,
        servers_dir: PathBuf,
        token_file: &Path,
        log_dir: Option<PathBuf>,
    ) -> Result<Self, ConfigError> {
        Self::build(bind, servers_dir, None, token_file, log_dir)
    }

    /// Wie [`Config::new`], aber mit ausdrücklichem Zustandsverzeichnis.
    pub fn with_state_dir(
        bind: SocketAddr,
        servers_dir: PathBuf,
        state_dir: PathBuf,
        token_file: &Path,
        log_dir: Option<PathBuf>,
    ) -> Result<Self, ConfigError> {
        Self::build(bind, servers_dir, Some(state_dir), token_file, log_dir)
    }

    fn build(
        bind: SocketAddr,
        servers_dir: PathBuf,
        state_dir: Option<PathBuf>,
        token_file: &Path,
        log_dir: Option<PathBuf>,
    ) -> Result<Self, ConfigError> {
        if !bind.ip().is_loopback() {
            return Err(ConfigError::NonLoopbackBind(bind));
        }
        if !servers_dir.is_absolute() {
            return Err(ConfigError::ServersDirRelative(servers_dir));
        }
        if !servers_dir.is_dir() {
            return Err(ConfigError::ServersDirMissing(servers_dir));
        }
        let state_dir = state_dir.unwrap_or_else(|| {
            servers_dir
                .parent()
                .map_or_else(|| servers_dir.join("state"), |parent| parent.join("state"))
        });
        if !state_dir.is_absolute() {
            return Err(ConfigError::StateDirRelative(state_dir));
        }
        if let Some(dir) = &log_dir {
            if !dir.is_absolute() {
                return Err(ConfigError::LogDirRelative(dir.clone()));
            }
            fs::create_dir_all(dir).map_err(|source| ConfigError::LogDir {
                path: dir.clone(),
                source,
            })?;
        }
        let raw = fs::read_to_string(token_file).map_err(|source| ConfigError::TokenFile {
            path: token_file.to_path_buf(),
            source,
        })?;
        let token = raw.trim();
        if token.len() < MIN_TOKEN_LEN {
            return Err(ConfigError::TokenTooShort);
        }
        if token.chars().any(char::is_whitespace) {
            return Err(ConfigError::TokenWithWhitespace);
        }
        Ok(Self {
            bind,
            servers_dir,
            state_dir,
            token: token.to_string(),
            previous: None,
            token_file: token_file.to_path_buf(),
            log_dir,
        })
    }

    /// Lädt einen befristet gültigen Vorgänger-Token aus `token.previous`.
    ///
    /// Die Datei liegt neben der Token-Datei. Sie gilt ab ihrem Änderungsdatum
    /// für `grace`; ohne Datei oder nach Ablauf bleibt `previous` leer. Eine
    /// vorhandene, aber ungültige Datei lässt den Start scheitern, damit ein
    /// Tippfehler nicht unbemerkt den Zugang verliert.
    pub fn with_grace(mut self, grace: Duration) -> Result<Self, ConfigError> {
        self.previous = load_previous_token(&self.token_file, grace)?;
        Ok(self)
    }
}

fn load_previous_token(
    token_file: &Path,
    grace: Duration,
) -> Result<Option<TokenGrace>, ConfigError> {
    let path = token_file.with_file_name(PREVIOUS_TOKEN_FILE);
    if grace.is_zero() || !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(&path).map_err(|source| ConfigError::PreviousTokenFile {
        path: path.clone(),
        source,
    })?;
    let token = raw.trim();
    if token.len() < MIN_TOKEN_LEN {
        return Err(ConfigError::PreviousTokenInvalid {
            path,
            reason: "kürzer als 32 Zeichen",
        });
    }
    if token.chars().any(char::is_whitespace) {
        return Err(ConfigError::PreviousTokenInvalid {
            path,
            reason: "enthält Leerraum",
        });
    }
    let modified = fs::metadata(&path)
        .and_then(|metadata| metadata.modified())
        .unwrap_or_else(|_| SystemTime::now());
    let until = modified + grace;
    if SystemTime::now() >= until {
        return Ok(None);
    }
    Ok(Some(TokenGrace {
        token: token.to_string(),
        until,
    }))
}

/// MCP-Server des Gateways: aggregiert die Tools aller Backends.
#[derive(Clone)]
pub struct Gateway {
    shared: Arc<Shared>,
}

impl Gateway {
    /// Erzeugt den Gateway über einem geteilten Zustand.
    pub fn new(shared: Arc<Shared>) -> Self {
        Self { shared }
    }
}

impl ServerHandler for Gateway {
    fn get_info(&self) -> ServerConfig {
        // `list_changed` ist Pflicht: der Gateway schickt nach Reload und
        // Backend-Neustart `notifications/tools/list_changed`; Clients wie
        // OpenCode registrieren den Handler nur, wenn die Capability hier
        // angekündigt ist. Ohne sie bleibt eine neue Tool-Liste unsichtbar,
        // bis die Sitzung neu verbindet.
        ServerConfig::new(
            ServerCapabilities::builder()
                .enable_tools()
                .enable_tool_list_changed()
                .enable_resources()
                .build(),
        )
        .with_server_info(Implementation::new(
            "mac-compute-gateway",
            mcp_core::version(),
        ))
        .with_instructions(
            "Gateway für native Mac-Backends. `capabilities` meldet Status und Limits.",
        )
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        Ok(ListToolsResult {
            tools: self.shared.tools().await,
            ..Default::default()
        })
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        self.shared.call(request).await
    }

    /// Eine Ressource: die aggregierte Tool-Liste als JSON.
    ///
    /// Der Gateway hat keinen Datei- oder Dokumentbestand; die Liste ist der
    /// einzige Zustand, der sich sinnvoll als Ressource lesen lässt. Artefakte
    /// (Bilder, Videos) liegen im Artefaktverzeichnis und werden über die
    /// Tool-Ergebnisse verteilt, nicht über Ressourcen.
    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, McpError> {
        let resource = Resource::new(TOOLS_RESOURCE_URI, "tools")
            .with_title("Tools des Gateways")
            .with_description("Alle Tools aller eingebundenen Backends als JSON")
            .with_mime_type("application/json");
        Ok(ListResourcesResult::with_all_items(vec![resource]))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, McpError> {
        if request.uri != TOOLS_RESOURCE_URI {
            return Err(McpError::resource_not_found(
                format!("unbekannte Ressource '{}'", request.uri),
                None,
            ));
        }
        let tools: Vec<Value> = self
            .shared
            .tools()
            .await
            .into_iter()
            .map(|tool| {
                json!({
                    "name": tool.name,
                    "description": tool.description,
                })
            })
            .collect();
        let text = serde_json::to_string_pretty(&tools)
            .map_err(|error| McpError::internal_error(error.to_string(), None))?;
        Ok(ReadResourceResult::new(vec![
            ResourceContents::text(text, TOOLS_RESOURCE_URI).with_mime_type("application/json"),
        ])
        .into())
    }

    async fn on_initialized(&self, context: NotificationContext<RoleServer>) {
        self.shared.register_session(context.peer.clone()).await;
    }
}

#[derive(Clone)]
struct AppState {
    token: Arc<str>,
    previous: Option<TokenGrace>,
}

/// Baut den HTTP-Router mit Bearer-Prüfung für alle Routen.
pub fn router(config: &Config, shared: Arc<Shared>) -> Router {
    let state = AppState {
        token: Arc::from(config.token.as_str()),
        previous: config.previous.clone(),
    };
    let gateway = Gateway::new(shared);
    // rmcp erlaubt standardmäßig nur Loopback-Hosts (DNS-Rebinding-Schutz).
    // Der Podman-Container erreicht den Gateway als `host.containers.internal`;
    // Token und Bindung an 127.0.0.1 bleiben unverändert.
    let mut http_config = StreamableHttpServerConfig::default().with_allowed_hosts([
        "localhost",
        "127.0.0.1",
        "::1",
        "host.containers.internal",
    ]);
    // Sitzungen überleben einen Neustart: ohne Speicher antwortet der Gateway
    // auf die alte `Mcp-Session-Id` mit 404 und der Client verliert den Zugang,
    // bis er neu verbindet. Details: `sessions`.
    match FileSessionStore::open(config.state_dir.join(SESSION_SUBDIR)) {
        Ok(store) => http_config.session_store = Some(Arc::new(store)),
        Err(error) => tracing::warn!(
            %error,
            "Sitzungsspeicher nicht verfügbar; Sitzungen enden mit dem Prozess"
        ),
    }
    let mcp = StreamableHttpService::new(
        move || Ok(gateway.clone()),
        LocalSessionManager::default().into(),
        http_config,
    );

    Router::new()
        .route("/health", get(health))
        .nest_service("/mcp", mcp)
        .layer(middleware::from_fn_with_state(state, require_token))
}

async fn health() -> Json<Value> {
    Json(json!({
        "status": "ok",
        "service": "mac-compute-gateway",
        "version": mcp_core::version(),
    }))
}

async fn require_token(State(state): State<AppState>, request: Request, next: Next) -> Response {
    if !is_authorized(&request, &state) {
        let mut response = (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "unauthorized" })),
        )
            .into_response();
        response
            .headers_mut()
            .insert(WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
        return response;
    }
    next.run(request).await
}

/// Prüft den Bearer-Token gegen den aktuellen und den abgelösten Token.
fn is_authorized(request: &Request, state: &AppState) -> bool {
    let Some(token) = bearer_token(request) else {
        return false;
    };
    if token.as_bytes().ct_eq(state.token.as_bytes()).into() {
        return true;
    }
    let Some(previous) = &state.previous else {
        return false;
    };
    if SystemTime::now() >= previous.until {
        return false;
    }
    let matches: bool = token.as_bytes().ct_eq(previous.token.as_bytes()).into();
    if !matches {
        return false;
    }
    tracing::debug!("abgelöster Token akzeptiert");
    true
}

fn bearer_token(request: &Request) -> Option<&str> {
    let value = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())?;
    let (scheme, token) = value.split_once(' ')?;
    scheme.eq_ignore_ascii_case("bearer").then_some(token)
}
