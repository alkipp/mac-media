//! `mock-mcp`: Test-Backend für Gateway und Integrationstests.
//!
//! Stellt zwei Tools über stdio bereit:
//!
//! - `echo` gibt den übergebenen Text zurück.
//! - `sleep` wartet eine begrenzte Zeit, damit Timeouts prüfbar sind.
//!
//! Der Server ersetzt keine Hardware; er macht Discovery, Namespace und
//! Zeitlimits ohne GPU, ANE oder Media Engine testbar.

use rmcp::{
    ErrorData as McpError, ServerHandler, ServiceExt,
    handler::server::wrapper::Parameters,
    model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerConfig},
    tool, tool_handler, tool_router,
    transport::stdio,
};
use schemars::JsonSchema;
use serde::Deserialize;

/// Größte erlaubte Nachricht für `echo`.
const MAX_ECHO_CHARS: usize = 4096;

/// Kürzeste Wartezeit für `sleep`.
const MIN_SLEEP_MS: u64 = 10;

/// Längste Wartezeit für `sleep`.
const MAX_SLEEP_MS: u64 = 60_000;

/// Argumente für `echo`.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct EchoArgs {
    /// Text, der unverändert zurückgegeben wird (max. 4096 Zeichen).
    #[schemars(length(max = 4096))]
    pub message: String,
}

/// Argumente für `sleep`.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct SleepArgs {
    /// Wartezeit in Millisekunden (10–60000).
    #[schemars(range(min = 10, max = 60_000))]
    pub ms: u64,
}

/// Test-Backend mit fester Tool-Liste.
#[derive(Clone, Copy, Default)]
pub struct MockServer;

impl MockServer {
    /// Erzeugt den Server.
    pub fn new() -> Self {
        Self
    }
}

#[tool_router]
impl MockServer {
    #[tool(description = "Gibt den übergebenen Text unverändert zurück")]
    fn echo(
        &self,
        Parameters(EchoArgs { message }): Parameters<EchoArgs>,
    ) -> Result<CallToolResult, McpError> {
        if message.chars().count() > MAX_ECHO_CHARS {
            return Err(McpError::invalid_params(
                format!("message ist länger als {MAX_ECHO_CHARS} Zeichen"),
                None,
            ));
        }
        Ok(CallToolResult::success(vec![ContentBlock::text(message)]))
    }

    #[tool(description = "Wartet die angegebene Zeit in Millisekunden und bestätigt sie")]
    async fn sleep(
        &self,
        Parameters(SleepArgs { ms }): Parameters<SleepArgs>,
    ) -> Result<CallToolResult, McpError> {
        if !(MIN_SLEEP_MS..=MAX_SLEEP_MS).contains(&ms) {
            return Err(McpError::invalid_params(
                format!("ms muss zwischen {MIN_SLEEP_MS} und {MAX_SLEEP_MS} liegen"),
                None,
            ));
        }
        tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
        Ok(CallToolResult::success(vec![ContentBlock::text(format!(
            "{ms} ms gewartet"
        ))]))
    }
}

#[tool_handler]
impl ServerHandler for MockServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("mock-mcp", env!("CARGO_PKG_VERSION")))
            .with_instructions("Test-Backend mit den Tools echo und sleep.")
    }
}

/// Bedient das Backend über stdio, bis der Client die Verbindung schließt.
pub async fn run_stdio() -> Result<(), Box<dyn std::error::Error>> {
    let service = MockServer::new().serve(stdio()).await?;
    service.waiting().await?;
    Ok(())
}
