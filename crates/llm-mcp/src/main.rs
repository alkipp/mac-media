//! Startet `llm-mcp` mit warmem Modell.

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = llm_mcp::LlmServer::default_model_path()?;
    eprintln!("llm-mcp: lade Modell {}", path.display());
    let server = llm_mcp::LlmServer::load(&path)?;
    eprintln!("llm-mcp: Modell geladen");
    tokio::runtime::Runtime::new()?.block_on(llm_mcp::run_stdio(server))
}
