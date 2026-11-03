//! Prüfungen für Manifest-Typen, Validierung und JSON-Schema.

use mcp_core::{
    DEFAULT_MAX_MEMORY_MB, DEFAULT_TIMEOUT_MS, Manifest, ManifestError, ManifestSet,
    ManifestSetError, Transport,
};

fn valid_json() -> serde_json::Value {
    serde_json::json!({
        "name": "render",
        "transport": "stdio",
        "command": [
            "/Users/example/Library/Application Support/mac-compute/bin/render-mcp",
            "--stdio"
        ],
        "capabilities": ["gpu", "svg", "2d"],
        "timeout": 600_000,
        "maxMemoryMB": 4096,
        "enabled": true
    })
}

fn valid() -> Manifest {
    serde_json::from_value(valid_json()).expect("Beispielmanifest ist gültig")
}

#[test]
fn valid_manifest_parses_and_validates() {
    let manifest = valid();
    assert_eq!(manifest.name, "render");
    assert_eq!(manifest.transport, Transport::Stdio);
    assert_eq!(manifest.capabilities, ["gpu", "svg", "2d"]);
    assert_eq!(manifest.namespace(), "render");
    manifest.validate().expect("Manifest ist gültig");
}

#[test]
fn defaults_are_applied() {
    let mut json = valid_json();
    json.as_object_mut().expect("Objekt").remove("timeout");
    json.as_object_mut().expect("Objekt").remove("maxMemoryMB");
    json.as_object_mut().expect("Objekt").remove("enabled");
    let manifest: Manifest = serde_json::from_value(json).expect("Defaults greifen");
    assert_eq!(manifest.timeout, DEFAULT_TIMEOUT_MS);
    assert_eq!(manifest.max_memory_mb, DEFAULT_MAX_MEMORY_MB);
    assert!(manifest.enabled);
    assert_eq!(manifest.version, None);
}

#[test]
fn unknown_field_is_rejected() {
    let mut json = valid_json();
    json["shell"] = serde_json::json!("render-mcp --stdio");
    let result: Result<Manifest, _> = serde_json::from_value(json);
    let error = result.expect_err("unbekanntes Feld muss abgelehnt werden");
    assert!(error.to_string().contains("shell"), "Fehler: {error}");
}

#[test]
fn unknown_transport_is_rejected() {
    let mut json = valid_json();
    json["transport"] = serde_json::json!("http");
    let result: Result<Manifest, _> = serde_json::from_value(json);
    assert!(result.is_err(), "http ist in V1 nicht erlaubt");
}

#[test]
fn invalid_names_are_rejected() {
    for name in [
        "Render",
        "1render",
        "",
        "render_mcp",
        "render-",
        &"a".repeat(33),
    ] {
        let mut manifest = valid();
        manifest.name = name.to_string();
        assert_eq!(
            manifest.validate(),
            Err(ManifestError::InvalidName),
            "Name '{name}' hätte abgelehnt werden müssen"
        );
    }
}

#[test]
fn valid_names_are_accepted() {
    for name in ["a", "render", "ml", "llm", "gpu-2", "media"] {
        let mut manifest = valid();
        manifest.name = name.to_string();
        manifest
            .validate()
            .unwrap_or_else(|error| panic!("Name '{name}' sollte gültig sein: {error}"));
    }
}

#[test]
fn version_is_optional_and_validated() {
    let mut manifest = valid();
    manifest.version = Some("1.2.3".to_string());
    manifest.validate().expect("Version ist gültig");

    for version in ["v1.2.3", "", &"1".repeat(33)] {
        manifest.version = Some(version.to_string());
        assert_eq!(manifest.validate(), Err(ManifestError::InvalidVersion));
    }
}

#[test]
fn empty_command_is_rejected() {
    let mut manifest = valid();
    manifest.command.clear();
    assert_eq!(manifest.validate(), Err(ManifestError::EmptyCommand));
}

#[test]
fn relative_command_is_rejected() {
    let mut manifest = valid();
    manifest.command[0] = "render-mcp".to_string();
    assert_eq!(
        manifest.validate(),
        Err(ManifestError::NonAbsoluteCommand("render-mcp".to_string()))
    );
}

#[test]
fn empty_argument_is_rejected() {
    let mut manifest = valid();
    manifest.command.push(String::new());
    assert_eq!(
        manifest.validate(),
        Err(ManifestError::EmptyArgument { index: 2 })
    );
}

#[test]
fn nul_byte_is_rejected() {
    let mut manifest = valid();
    manifest.command.push("--out\0evil".to_string());
    assert_eq!(
        manifest.validate(),
        Err(ManifestError::NulByte { index: 2 })
    );
}

#[test]
fn empty_capabilities_are_rejected() {
    let mut manifest = valid();
    manifest.capabilities.clear();
    assert_eq!(manifest.validate(), Err(ManifestError::EmptyCapabilities));
}

#[test]
fn invalid_capability_is_rejected() {
    let mut manifest = valid();
    manifest.capabilities.push("GPU".to_string());
    assert_eq!(
        manifest.validate(),
        Err(ManifestError::InvalidCapability("GPU".to_string()))
    );
}

#[test]
fn duplicate_capability_is_rejected() {
    let mut manifest = valid();
    manifest.capabilities.push("gpu".to_string());
    assert_eq!(
        manifest.validate(),
        Err(ManifestError::DuplicateCapability("gpu".to_string()))
    );
}

#[test]
fn timeout_bounds_are_enforced() {
    let mut manifest = valid();
    for timeout in [999, 86_400_001] {
        manifest.timeout = timeout;
        assert_eq!(
            manifest.validate(),
            Err(ManifestError::TimeoutOutOfRange(timeout))
        );
    }
    for timeout in [1_000, 600_000, 86_400_000] {
        manifest.timeout = timeout;
        manifest
            .validate()
            .unwrap_or_else(|error| panic!("Timeout {timeout} sollte gültig sein: {error}"));
    }
}

#[test]
fn memory_bounds_are_enforced() {
    let mut manifest = valid();
    for memory in [63, 65_537] {
        manifest.max_memory_mb = memory;
        assert_eq!(
            manifest.validate(),
            Err(ManifestError::MemoryOutOfRange(memory))
        );
    }
    for memory in [64, 4_096, 65_536] {
        manifest.max_memory_mb = memory;
        manifest
            .validate()
            .unwrap_or_else(|error| panic!("Speicher {memory} sollte gültig sein: {error}"));
    }
}

#[test]
fn disabled_manifest_stays_valid() {
    let mut manifest = valid();
    manifest.enabled = false;
    manifest.validate().expect("deaktiviert ist erlaubt");
}

#[test]
fn set_rejects_duplicate_names() {
    let first = valid();
    let second = valid();
    let error = ManifestSet::new(vec![first, second]).expect_err("doppelter Name");
    assert_eq!(error, ManifestSetError::DuplicateName("render".to_string()));
}

#[test]
fn set_reports_invalid_manifest_with_name() {
    let mut manifest = valid();
    manifest.timeout = 10;
    let error = ManifestSet::new(vec![manifest]).expect_err("Timeout ist ungültig");
    assert_eq!(
        error,
        ManifestSetError::Invalid {
            name: "render".to_string(),
            source: ManifestError::TimeoutOutOfRange(10),
        }
    );
}

#[test]
fn set_filters_disabled_manifests() {
    let mut ml = valid();
    ml.name = "ml".to_string();
    ml.enabled = false;
    let set = ManifestSet::new(vec![valid(), ml]).expect("Menge ist gültig");

    assert_eq!(set.len(), 2);
    assert_eq!(set.enabled().count(), 1);
    assert!(set.get("ml").is_some());
    assert_eq!(set.get("ml").map(|manifest| manifest.enabled), Some(false));
}

#[test]
fn example_manifests_validate() {
    let raw = include_str!("../../../config/servers.d/mock.json");
    let expanded = mcp_core::expand_placeholders(raw);
    let manifest: Manifest =
        serde_json::from_str(&expanded).expect("config/servers.d/mock.json ist valides JSON");
    manifest
        .validate()
        .expect("config/servers.d/mock.json ist gültig");
    assert_eq!(manifest.name, "mock");
}

#[test]
fn placeholders_expand_to_absolute_paths() {
    let raw = r#"{"command":["@APP_SUPPORT@/bin/mock-mcp","@HOME@/.config/mac-compute/token"]}"#;
    let expanded = mcp_core::expand_placeholders(raw);
    let value: serde_json::Value = serde_json::from_str(&expanded).expect("JSON");
    let command = value["command"].as_array().expect("command");
    let program = command[0].as_str().expect("command[0]");
    assert!(
        program.starts_with('/'),
        "Platzhalter wurden nicht aufgelöst: {program}"
    );
    assert!(program.ends_with("/bin/mock-mcp"));
    assert!(!expanded.contains("@APP_SUPPORT@"));
    assert!(!expanded.contains("@HOME@"));
}

#[test]
fn schema_matches_checked_in_file() {
    let checked_in: serde_json::Value =
        serde_json::from_str(include_str!("../../../config/manifest.schema.json"))
            .expect("config/manifest.schema.json ist valides JSON");
    assert_eq!(
        checked_in,
        mcp_core::manifest_schema(),
        "Schema neu erzeugen: cargo run -p mcp-core --example manifest_schema > config/manifest.schema.json"
    );
}
