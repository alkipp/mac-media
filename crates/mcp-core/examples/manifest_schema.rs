//! Gibt das JSON-Schema der Manifest-Datei auf stdout aus.
//!
//! Aufruf: `cargo run -p mcp-core --example manifest_schema`
//!
//! Die Ausgabe wird nach `config/manifest.schema.json` geschrieben; ein Test
//! prüft, dass beide übereinstimmen.

fn main() {
    let schema = mcp_core::manifest_schema();
    let json = serde_json::to_string_pretty(&schema).expect("Schema ist serialisierbar");
    println!("{json}");
}
