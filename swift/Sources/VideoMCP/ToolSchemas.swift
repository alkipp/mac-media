// ToolSchemas.swift — JSON-Schemata der Video-Tools.
//
// Eigene Datei, damit die Schemata nicht als Top-Level-Variablen von
// `main.swift` (main-actor-isoliert) in den `@Sendable`-Handlern hängen.

import Foundation
import MCP

enum ToolSchemas {
    /// `codec` für `render_video`, `render_start` und `render_3d`.
    static let codec: Value = .object([
        "type": .string("string"),
        "description": .string("Video-Codec: h264 (Default), hevc, prores422, prores4444"),
        "enum": .array([
            .string("h264"),
            .string("hevc"),
            .string("prores422"),
            .string("prores4444"),
        ]),
    ])

    /// `audio_path` für `render_video`, `render_start` und `render_3d`.
    static let audio: Value = .object([
        "type": .string("string"),
        "description": .string(
            "Pfad zu einer Audiodatei (WAV, M4A, MP3); wird an das Video gemuxt"
        ),
    ])

    /// Ein Effekt; die Reihenfolge im Array ist die Anwendungsreihenfolge.
    static let effect: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "type": .object([
                "type": .string("string"),
                "description": .string("Effektart"),
                "enum": .array([
                    .string("blur"),
                    .string("bloom"),
                    .string("color"),
                    .string("vignette"),
                ]),
            ]),
            "radius": .object([
                "type": .string("number"),
                "description": .string("Radius in Pixeln (blur, bloom) bzw. Weite (vignette)"),
            ]),
            "intensity": .object([
                "type": .string("number"),
                "description": .string("Stärke (bloom, vignette)"),
            ]),
            "saturation": .object([
                "type": .string("number"),
                "description": .string("Sättigung (color), Default 1.0"),
            ]),
            "contrast": .object([
                "type": .string("number"),
                "description": .string("Kontrast (color), Default 1.0"),
            ]),
            "brightness": .object([
                "type": .string("number"),
                "description": .string("Helligkeit (color), Default 0.0"),
            ]),
        ]),
        "required": .array([.string("type")]),
    ])

    /// `effects` für `render_video`, `render_start` und `render_3d`.
    static let effects: Value = .object([
        "type": .string("array"),
        "description": .string(
            "Effekte in Anwendungsreihenfolge: blur, bloom, color, vignette; "
                + "ohne Angabe bleibt der Frame unverändert"
        ),
        "items": ToolSchemas.effect,
    ])

    /// `timeout_s` für `render_video` und `render_start`.
    static let timeout: Value = .object([
        "type": .string("number"),
        "description": .string(
            "Zeitlimit in Sekunden für den render-mcp-Subprozess eines Laufs "
                + "(Default 600, Umgebungsvariable RENDER_TIMEOUT_S); ein Budget "
                + "für Rendern und Encoding zusammen"
        ),
        "exclusiveMinimum": .int(0),
    ])

    /// Gemeinsame Eigenschaften von `render_video` und `render_start` (2D).
    static let renderProperties: [String: Value] = [
        "scene": .object([
            "type": .string("object"),
            "description": .string("Szene v1 als JSON-Objekt"),
        ]),
        "scene_path": .object([
            "type": .string("string"),
            "description": .string("Pfad zu einer Szenen-Datei"),
        ]),
        "name": .object([
            "type": .string("string"),
            "description": .string("Dateiname ohne Endung, Default video"),
        ]),
        "keep_frames": .object([
            "type": .string("boolean"),
            "description": .string("Frames nach dem Encoding behalten, Default false"),
        ]),
        "codec": ToolSchemas.codec,
        "audio_path": ToolSchemas.audio,
        "effects": ToolSchemas.effects,
        "timeout_s": ToolSchemas.timeout,
    ]

    /// 3D-Szene als JSON-Objekt oder Datei.
    static let scene3DSources: [String: Value] = [
        "scene3d": .object([
            "type": .string("object"),
            "description": .string(
                "3D-Szene v1 als JSON-Objekt: version, width, height, fps, duration, "
                    + "background, camera, light, objects"
            ),
        ]),
        "scene3d_path": .object([
            "type": .string("string"),
            "description": .string("Pfad zu einer 3D-Szenen-Datei"),
        ]),
    ]

    /// Eigenschaften von `render_start`: 2D- und 3D-Quellen, genau eine davon.
    static var renderStartProperties: [String: Value] {
        renderProperties.merging(scene3DSources) { _, new in new }
    }

    /// Eigenschaften von `render_3d`.
    static var render3DProperties: [String: Value] {
        var properties = scene3DSources
        properties["name"] = .object([
            "type": .string("string"),
            "description": .string("Dateiname ohne Endung, Default video"),
        ])
        properties["keep_frames"] = .object([
            "type": .string("boolean"),
            "description": .string("Frames nach dem Encoding behalten, Default false"),
        ])
        properties["codec"] = ToolSchemas.codec
        properties["audio_path"] = ToolSchemas.audio
        properties["effects"] = ToolSchemas.effects
        return properties
    }

    /// Einzelnes `id`-Argument von `render_status` und `render_cancel`.
    static let jobID: Value = .object([
        "type": .string("string"),
        "description": .string("Kennung aus render_start"),
    ])
}
