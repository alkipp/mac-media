//! Startet das gebaute `mock-mcp`-Binary und spricht MCP über stdio.
//!
//! Damit sind Tool-Liste, Argument-Schema und Fehlerfälle ohne Gateway prüfbar.

use rmcp::{
    ServiceExt,
    model::CallToolRequestParams,
    object,
    transport::{ConfigureCommandExt, TokioChildProcess},
};
use tokio::process::Command;

fn transport() -> Result<TokioChildProcess, Box<dyn std::error::Error>> {
    let transport = TokioChildProcess::new(
        Command::new(env!("CARGO_BIN_EXE_mock-mcp")).configure(|command| {
            command.arg("--stdio");
        }),
    )?;
    Ok(transport)
}

#[tokio::test]
async fn lists_echo_and_sleep() -> Result<(), Box<dyn std::error::Error>> {
    let client = ().serve(transport()?).await?;

    let info = client.peer_info().expect("Server-Info");
    assert_eq!(
        info.server_info.as_ref().expect("serverInfo").name,
        "mock-mcp",
        "der Server meldet seinen eigenen Namen"
    );

    let tools = client.list_all_tools().await?;
    let mut names: Vec<String> = tools.iter().map(|tool| tool.name.to_string()).collect();
    names.sort();
    assert_eq!(names, ["echo", "sleep"]);

    client.cancel().await?;
    Ok(())
}

#[tokio::test]
async fn echo_returns_the_message() -> Result<(), Box<dyn std::error::Error>> {
    let client = ().serve(transport()?).await?;

    let result = client
        .call_tool(
            CallToolRequestParams::new("echo")
                .with_arguments(object!({ "message": "hallo vom mock" })),
        )
        .await?;
    let value = rmcp::serde_json::to_value(&result)?;
    assert_eq!(value["content"][0]["text"], "hallo vom mock");

    client.cancel().await?;
    Ok(())
}

#[tokio::test]
async fn sleep_rejects_out_of_range_values() -> Result<(), Box<dyn std::error::Error>> {
    let client = ().serve(transport()?).await?;

    let error = client
        .call_tool(CallToolRequestParams::new("sleep").with_arguments(object!({ "ms": 1 })))
        .await
        .expect_err("ms=1 muss abgelehnt werden");
    assert!(
        error.to_string().contains("ms muss zwischen"),
        "unerwarteter Fehler: {error}"
    );

    client.cancel().await?;
    Ok(())
}

#[tokio::test]
async fn sleep_waits_and_confirms() -> Result<(), Box<dyn std::error::Error>> {
    let client = ().serve(transport()?).await?;

    let result = client
        .call_tool(CallToolRequestParams::new("sleep").with_arguments(object!({ "ms": 10 })))
        .await?;
    let value = rmcp::serde_json::to_value(&result)?;
    assert_eq!(value["content"][0]["text"], "10 ms gewartet");

    client.cancel().await?;
    Ok(())
}
