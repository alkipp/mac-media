//! Prüft die MCP-Capabilities des Gateways.

use std::sync::Arc;

use mac_compute_gateway::{Gateway, Registry, Shared};
use mac_compute_jobs::{JobStore, Limits};
use rmcp::ServerHandler;

/// Ohne `tools.listChanged` ignorieren Clients die Benachrichtigung nach einem
/// Reload: OpenCode registriert den Handler nur bei angekündigter Capability.
#[test]
fn initialize_advertises_tool_list_changed() {
    let queue = Arc::new(JobStore::in_memory(Limits::default()).expect("Queue"));
    let gateway = Gateway::new(Shared::new(Registry::empty(), queue));

    let capabilities = gateway.get_info().capabilities;
    let tools = capabilities.tools.expect("tools-Capability fehlt");
    assert_eq!(
        tools.list_changed,
        Some(true),
        "tools.listChanged muss angekündigt sein"
    );
}
