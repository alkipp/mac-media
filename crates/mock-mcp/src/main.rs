//! Startet das Test-Backend über stdio.

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    mock_mcp::run_stdio().await
}
