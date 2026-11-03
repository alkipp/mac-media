//! Werkzeuge der Warteschlange: Schemas, Argumentprüfung und Antwortform.
//!
//! Die drei Tools gehören dem Gateway, nicht einem Backend, und tragen
//! deshalb keinen Backend-Namespace:
//!
//! - `submit_job` nimmt eine Aufgabe an und antwortet sofort mit der Kennung.
//! - `job_status` liefert Zustand, Fortschritt und Ergebnis.
//! - `job_cancel` bricht ab; eine laufende Aufgabe beendet dabei das Backend.

use mac_compute_jobs::{DEFAULT_PRIORITY, MAX_PRIORITY, MIN_PRIORITY};
use rmcp::ErrorData as McpError;
use rmcp::model::{CallToolResult, ContentBlock, JsonObject, Tool};
use serde_json::{Value, json};

/// Nimmt eine Aufgabe an.
pub const SUBMIT_JOB_TOOL: &str = "submit_job";

/// Liefert den Zustand einer Aufgabe.
pub const JOB_STATUS_TOOL: &str = "job_status";

/// Bricht eine Aufgabe ab.
pub const JOB_CANCEL_TOOL: &str = "job_cancel";

/// Die drei Gateway-Tools der Warteschlange.
pub fn job_tools() -> Vec<Tool> {
    vec![submit_job_tool(), job_status_tool(), job_cancel_tool()]
}

/// Geprüfte Argumente für `submit_job`.
#[derive(Debug, Clone, PartialEq)]
pub struct SubmitArgs {
    /// Namespaced Tool, z. B. `render_svg`.
    pub tool: String,
    /// Argumente des Backend-Tools.
    pub arguments: Value,
    /// Priorität 0–9, höher läuft zuerst.
    pub priority: u8,
}

/// Liest und prüft die Argumente von `submit_job`.
pub fn parse_submit(arguments: Option<&JsonObject>) -> Result<SubmitArgs, McpError> {
    let arguments = arguments
        .ok_or_else(|| invalid("submit_job erwartet die Felder tool, arguments, priority"))?;
    reject_unknown(arguments, &["tool", "arguments", "priority"])?;

    let tool = match arguments.get("tool") {
        Some(Value::String(tool)) if !tool.trim().is_empty() => tool.clone(),
        _ => {
            return Err(invalid(
                "tool muss ein nicht-leerer String sein, z. B. render_svg",
            ));
        }
    };
    let Some((backend, _)) = tool.split_once('_') else {
        return Err(invalid(format!(
            "tool '{tool}' hat kein Backend-Präfix wie 'render_svg'"
        )));
    };
    if backend.is_empty() {
        return Err(invalid(format!(
            "tool '{tool}' hat kein Backend-Präfix wie 'render_svg'"
        )));
    }

    let backend_arguments = match arguments.get("arguments") {
        None | Some(Value::Null) => Value::Object(JsonObject::new()),
        Some(Value::Object(map)) => Value::Object(map.clone()),
        Some(_) => return Err(invalid("arguments muss ein JSON-Objekt sein")),
    };

    let priority = match arguments.get("priority") {
        None | Some(Value::Null) => DEFAULT_PRIORITY,
        Some(Value::Number(number)) => {
            let value = number.as_u64().ok_or_else(|| {
                invalid(format!(
                    "priority muss zwischen {MIN_PRIORITY} und {MAX_PRIORITY} liegen"
                ))
            })?;
            u8::try_from(value)
                .ok()
                .filter(|priority| *priority <= MAX_PRIORITY)
                .ok_or_else(|| {
                    invalid(format!(
                        "priority muss zwischen {MIN_PRIORITY} und {MAX_PRIORITY} liegen"
                    ))
                })?
        }
        Some(_) => return Err(invalid("priority muss eine ganze Zahl sein")),
    };

    Ok(SubmitArgs {
        tool,
        arguments: backend_arguments,
        priority,
    })
}

/// Liest und prüft die Argumente von `job_status` und `job_cancel`.
pub fn parse_job_id(arguments: Option<&JsonObject>) -> Result<String, McpError> {
    let arguments =
        arguments.ok_or_else(|| invalid("erwartet wird das Feld job_id mit der Kennung"))?;
    reject_unknown(arguments, &["job_id"])?;
    match arguments.get("job_id") {
        Some(Value::String(id)) if !id.trim().is_empty() => Ok(id.clone()),
        _ => Err(invalid("job_id muss ein nicht-leerer String sein")),
    }
}

/// Textblock als Erfolgsantwort.
pub fn text_result(text: impl Into<String>) -> CallToolResult {
    CallToolResult::success(vec![ContentBlock::text(text)])
}

fn invalid(message: impl Into<String>) -> McpError {
    McpError::invalid_params(message.into(), None)
}

fn reject_unknown(arguments: &JsonObject, allowed: &[&str]) -> Result<(), McpError> {
    for key in arguments.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(invalid(format!(
                "unbekanntes Feld '{key}'; erlaubt: {}",
                allowed.join(", ")
            )));
        }
    }
    Ok(())
}

fn submit_job_tool() -> Tool {
    let schema = json!({
        "type": "object",
        "properties": {
            "tool": {
                "type": "string",
                "description": "Namespaced Tool aus `capabilities`, z. B. render_svg",
                "minLength": 3
            },
            "arguments": {
                "type": "object",
                "description": "Argumente des Backend-Tools",
                "default": {}
            },
            "priority": {
                "type": "integer",
                "description": "Höher läuft zuerst; gleiche Priorität nach Alter",
                "minimum": MIN_PRIORITY,
                "maximum": MAX_PRIORITY,
                "default": DEFAULT_PRIORITY
            }
        },
        "required": ["tool"],
        "additionalProperties": false
    });
    Tool::new(
        SUBMIT_JOB_TOOL,
        "Nimmt eine Aufgabe an und antwortet sofort mit Kennung und Warteposition",
        object_schema(schema),
    )
}

fn job_status_tool() -> Tool {
    let schema = json!({
        "type": "object",
        "properties": {
            "job_id": {
                "type": "string",
                "description": "Kennung aus submit_job, z. B. job-…",
                "minLength": 1
            }
        },
        "required": ["job_id"],
        "additionalProperties": false
    });
    Tool::new(
        JOB_STATUS_TOOL,
        "Zustand, Fortschritt, Fehler und Ergebnis einer Aufgabe",
        object_schema(schema),
    )
}

fn job_cancel_tool() -> Tool {
    let schema = json!({
        "type": "object",
        "properties": {
            "job_id": {
                "type": "string",
                "description": "Kennung aus submit_job, z. B. job-…",
                "minLength": 1
            }
        },
        "required": ["job_id"],
        "additionalProperties": false
    });
    Tool::new(
        JOB_CANCEL_TOOL,
        "Bricht eine wartende oder laufende Aufgabe ab",
        object_schema(schema),
    )
}

fn object_schema(schema: Value) -> JsonObject {
    schema.as_object().cloned().unwrap_or_default()
}
