// video-mcp — AVFoundation/VideoToolbox-Backend für das mac-compute-Gateway.
//
// Schritte 9 bis 17 des Vollausbaus. Bei 2D kommen die Frames vom Rust-Backend
// render-mcp (Subprozess); bei 3D zeichnet SceneKit über Metal. Das Encoding
// macht AVAssetWriter mit H.264, HEVC oder ProRes; auf Wunsch wird eine Tonspur
// dazugemuxt.
//
// Tools:
//   info           — Encoder, Hardware-Pfad, Codecs, render-mcp, Pfade
//   render_video   — Szene rendern und schreiben (synchron)
//   render_3d      — 3D-Szene (SceneKit/Metal) rendern und schreiben
//   render_start   — dasselbe asynchron (2D oder 3D), liefert eine Kennung
//   render_status  — Zustand und Fortschritt eines Laufs
//   render_cancel  — Lauf abbrechen
//
// Aufruf:
//   video-mcp                                   stdio-MCP (Gateway)
//   video-mcp --render <szene.json> <out> [--codec <name>] [--audio <datei>] [--bloom n] [--vignette n]
//   video-mcp --render3d <szene3d.json> <out> [--codec <name>] [--audio <datei>]
//   video-mcp --probe <datei>                   Codec, Endung, Dauer, Frames
//   video-mcp --help                            Hilfe
//
// Eingaben liegen ausschließlich unter .../mac-compute/inbox/, Ausgaben unter
// .../artifacts/<uuid>/ — dieselben Verzeichnisse wie bei media-mcp.

import Darwin
import Foundation
import MCP

Paths.prepare()
installSignalHandlers()

/// Optionen aus den Tool-Argumenten von `render_video`, `render_start` und
/// `render_3d`.
func renderOptions(from arguments: [String: Value]) throws -> RenderOptions {
    var options = RenderOptions()
    options.keepFrames = arguments["keep_frames"]?.boolValue ?? false
    if let codec = arguments["codec"]?.stringValue, !codec.isEmpty {
        options.codec = try VideoCodec.parse(codec)
    }
    if let path = arguments["audio_path"]?.stringValue {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            options.audio = URL(fileURLWithPath: trimmed).standardizedFileURL
        }
    }
    if let timeout = arguments["timeout_s"] {
        guard let seconds = numberValue(timeout), seconds.isFinite, seconds > 0 else {
            throw VideoError("timeout_s muss eine positive Zahl in Sekunden sein")
        }
        options.timeout = seconds
    }
    options.effects = try EffectSpec.list(in: arguments)
    return options
}

/// Zahl aus einem Tool-Argument; JSON-Integer kommen als `.int`, Kommazahlen
/// als `.double`.
func numberValue(_ value: Value) -> Double? {
    if let double = value.doubleValue { return double }
    if let integer = value.intValue { return Double(integer) }
    return nil
}

/// Argumente von `render_video`: 2D-Szene als Objekt oder Datei.
struct RenderRequest: Sendable {
    let scene: SceneInput
    let name: String
    let options: RenderOptions

    init(arguments: [String: Value]) throws {
        scene = try SceneInput.from(arguments: arguments)
        let rawName = arguments["name"]?.stringValue ?? "video"
        name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        options = try renderOptions(from: arguments)
    }
}

/// Argumente von `render_start`: 2D- oder 3D-Szene, genau eine Quelle.
struct RenderStartRequest: Sendable {
    let source: RenderSource
    let name: String
    let options: RenderOptions

    init(arguments: [String: Value]) throws {
        source = try RenderSource.from(arguments: arguments)
        let rawName = arguments["name"]?.stringValue ?? "video"
        name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        options = try renderOptions(from: arguments)
    }
}

/// Argumente von `render_3d`.
struct Render3DRequest: Sendable {
    let scene: Scene3DInput
    let name: String
    let options: RenderOptions

    init(arguments: [String: Value]) throws {
        scene = try Scene3DInput.from(arguments: arguments)
        let rawName = arguments["name"]?.stringValue ?? "video"
        name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        options = try renderOptions(from: arguments)
    }
}

/// Kommandozeile; ohne Argumente oder mit `--stdio` läuft der MCP-Server.
enum CLI {
    case stdio
    case render(scene: URL, output: URL, codec: VideoCodec, audio: URL?, effects: [EffectSpec])
    case render3DScene(scene: URL, output: URL, codec: VideoCodec, audio: URL?, effects: [EffectSpec])
    case probe(file: URL)
    case help
    case invalid(String)

    static let usage = """
    Aufruf:
      video-mcp                                  stdio-MCP für das Gateway
      video-mcp --render <szene.json> <out> [--codec <name>] [--audio <datei>]
                                                 Szene rendern (Klartext)
      video-mcp --render3d <szene3d.json> <out> [--codec <name>] [--audio <datei>]
                                                 [--bloom n] [--vignette n] [--saturation n]
                                                 3D-Szene rendern (Klartext)
      video-mcp --probe <datei>                  Video prüfen (Klartext)
      video-mcp --help                           diese Hilfe

    Codecs: h264 (Default, MP4), hevc (MP4), prores422 (MOV), prores4444 (MOV)
    Effekte: bloom, vignette und saturation auch als CLI-Flags; blur nur als Tool-Parameter
    """

    static func parse(_ arguments: [String]) -> CLI {
        guard !arguments.isEmpty else { return .stdio }
        if arguments.contains("--help") || arguments.contains("-h") {
            return .help
        }

        var mode: String?
        var positional: [String] = []
        var codecName: String?
        var audioPath: String?
        var bloom: Double?
        var vignette: Double?
        var saturation: Double?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--stdio":
                if mode != nil {
                    return .invalid("nur ein Modus erlaubt: \(argument)")
                }
                mode = argument
            case "--render", "--render3d", "--probe":
                if mode != nil {
                    return .invalid("nur ein Modus erlaubt: \(argument)")
                }
                mode = argument
            case "--codec", "--audio", "--bloom", "--vignette", "--saturation":
                guard index + 1 < arguments.count else {
                    return .invalid("\(argument) braucht einen Wert")
                }
                let raw = arguments[index + 1]
                switch argument {
                case "--codec": codecName = raw
                case "--audio": audioPath = raw
                default:
                    guard let value = Double(raw), value.isFinite else {
                        return .invalid("\(argument) braucht eine Zahl")
                    }
                    switch argument {
                    case "--bloom": bloom = value
                    case "--vignette": vignette = value
                    default: saturation = value
                    }
                }
                index += 1
            default:
                if argument.hasPrefix("-") {
                    return .invalid("unbekanntes Argument: \(argument)")
                }
                positional.append(argument)
            }
            index += 1
        }

        let codec: VideoCodec
        do {
            codec = try VideoCodec.parse(codecName ?? VideoCodec.h264.name)
        } catch {
            return .invalid("\(error)")
        }
        let audio = audioPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        var effects: [EffectSpec] = []
        if let bloom {
            effects.append(.bloom(intensity: bloom, radius: 16))
        }
        if let saturation {
            effects.append(.color(saturation: saturation, contrast: 1.06, brightness: 0))
        }
        if let vignette {
            effects.append(.vignette(intensity: vignette, radius: 1.5))
        }

        switch mode {
        case .none, .some("--stdio"):
            if !positional.isEmpty {
                return .invalid("unerwartete Argumente: \(positional.joined(separator: " "))")
            }
            if codecName != nil || audio != nil {
                return .invalid("--codec und --audio gelten nur für --render und --render3d")
            }
            return .stdio
        case .some("--render"):
            guard positional.count == 2 else {
                return .invalid(
                    "--render braucht zwei Pfade: --render <szene.json> <out>"
                )
            }
            return .render(
                scene: URL(fileURLWithPath: positional[0]).standardizedFileURL,
                output: URL(fileURLWithPath: positional[1]).standardizedFileURL,
                codec: codec,
                audio: audio,
                effects: effects
            )
        case .some("--render3d"):
            guard positional.count == 2 else {
                return .invalid(
                    "--render3d braucht zwei Pfade: --render3d <szene3d.json> <out>"
                )
            }
            return .render3DScene(
                scene: URL(fileURLWithPath: positional[0]).standardizedFileURL,
                output: URL(fileURLWithPath: positional[1]).standardizedFileURL,
                codec: codec,
                audio: audio,
                effects: effects
            )
        case .some("--probe"):
            guard positional.count == 1 else {
                return .invalid("--probe braucht genau eine Datei: --probe <datei>")
            }
            if codecName != nil || audio != nil {
                return .invalid("--codec und --audio gelten nur für --render und --render3d")
            }
            return .probe(file: URL(fileURLWithPath: positional[0]).standardizedFileURL)
        default:
            return .invalid("unbekannter Modus: \(mode ?? "")")
        }
    }

    /// `--render`: gleicher Ablauf wie das Tool, Ergebnis als Klartext.
    static func runRender(
        scene: URL,
        output: URL,
        codec: VideoCodec,
        audio: URL?,
        effects: [EffectSpec]
    ) async -> Int32 {
        do {
            let report = try await renderVideo(
                scene: .file(scene),
                name: output.deletingPathExtension().lastPathComponent,
                keepFrames: false,
                output: output,
                codec: codec,
                audio: audio,
                effects: effects
            )
            print(report.text)
            return 0
        } catch {
            writeError("\(error)")
            return 1
        }
    }

    /// `--render3d`: 3D-Szene rendern, Ergebnis als Klartext.
    static func runRender3D(
        scene: URL,
        output: URL,
        codec: VideoCodec,
        audio: URL?,
        effects: [EffectSpec]
    ) async -> Int32 {
        do {
            let report = try await render3D(
                scene: .file(scene),
                name: output.deletingPathExtension().lastPathComponent,
                keepFrames: false,
                output: output,
                codec: codec,
                audio: audio,
                effects: effects
            )
            print(report.text)
            return 0
        } catch {
            writeError("\(error)")
            return 1
        }
    }

    /// `--probe`: Metadaten einer bestehenden Datei.
    static func runProbe(file: URL) async -> Int32 {
        do {
            print(try await probeText(file))
            return 0
        } catch {
            writeError("\(error)")
            return 1
        }
    }
}

/// `render_video`: Szene rendern; jeder Fehler wird als isError-Text gemeldet.
func renderVideoTool(_ arguments: [String: Value]?) async -> CallTool.Result {
    do {
        let request = try RenderRequest(arguments: arguments ?? [:])
        let report = try await renderVideo(
            scene: request.scene,
            name: request.name,
            keepFrames: request.options.keepFrames,
            output: nil,
            codec: request.options.codec,
            audio: request.options.audio,
            effects: request.options.effects,
            timeout: request.options.timeout
        )
        return textResult(report.text)
    } catch {
        return textResult("\(error)", isError: true)
    }
}

/// `render_3d`: 3D-Szene rendern; jeder Fehler wird als isError-Text gemeldet.
func render3DTool(_ arguments: [String: Value]?) async -> CallTool.Result {
    do {
        let request = try Render3DRequest(arguments: arguments ?? [:])
        let report = try await render3D(
            scene: request.scene,
            name: request.name,
            keepFrames: request.options.keepFrames,
            output: nil,
            codec: request.options.codec,
            audio: request.options.audio,
            effects: request.options.effects
        )
        return textResult(report.text)
    } catch {
        return textResult("\(error)", isError: true)
    }
}

/// `render_start`: Lauf anlegen und im Hintergrund starten.
func renderStartTool(_ arguments: [String: Value]?) async -> CallTool.Result {
    do {
        let request = try RenderStartRequest(arguments: arguments ?? [:])
        // Defektes Audio soll sofort auffallen, nicht erst im Hintergrund.
        if let audio = request.options.audio {
            _ = try await validateAudioSource(audio)
        }
        let id = try await RenderJobs.shared.start(
            source: request.source,
            name: request.name,
            options: request.options
        )
        var lines = [
            "id: \(id)",
            "state: running",
            "progress: 0",
            "codec: \(request.options.codec.name)",
        ]
        if request.source.isThreeD {
            lines.append("scene: 3d")
        }
        return textResult(lines.joined(separator: "\n"))
    } catch {
        return textResult("\(error)", isError: true)
    }
}

/// `render_status`: Zustand, Fortschritt und ggf. Ergebnis eines Laufs.
func renderStatusTool(_ arguments: [String: Value]?) async -> CallTool.Result {
    guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
        return textResult("id fehlt", isError: true)
    }
    do {
        return textResult(try await RenderJobs.shared.status(id: id).text)
    } catch {
        return textResult("\(error)", isError: true)
    }
}

/// `render_cancel`: Lauf abbrechen; antwortet ohne auf das Aufräumen zu warten.
func renderCancelTool(_ arguments: [String: Value]?) async -> CallTool.Result {
    guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
        return textResult("id fehlt", isError: true)
    }
    do {
        return textResult(try await RenderJobs.shared.cancel(id: id).text)
    } catch {
        return textResult("\(error)", isError: true)
    }
}

// Die Kommandozeile entscheidet vor dem MCP-Start; ohne Modus läuft stdio.
switch CLI.parse(Array(CommandLine.arguments.dropFirst())) {
case .stdio:
    break
case .render(let scene, let output, let codec, let audio, let effects):
    let code = await CLI.runRender(
        scene: scene,
        output: output,
        codec: codec,
        audio: audio,
        effects: effects
    )
    exit(code)
case .render3DScene(let scene, let output, let codec, let audio, let effects):
    let code = await CLI.runRender3D(
        scene: scene,
        output: output,
        codec: codec,
        audio: audio,
        effects: effects
    )
    exit(code)
case .probe(let file):
    let code = await CLI.runProbe(file: file)
    exit(code)
case .help:
    print(CLI.usage)
    exit(0)
case .invalid(let message):
    writeError(message)
    FileHandle.standardError.write(Data((CLI.usage + "\n").utf8))
    exit(2)
}

let server = Server(
    name: "video-mcp",
    version: videoBackendVersion,
    capabilities: .init(
        tools: .init(listChanged: false)
    )
)

await server.withMethodHandler(ListTools.self) { _ in
    let tools = [
        Tool(
            name: "info",
            description: "Meldet Video-Encoder, Hardware-Pfad, Codecs, render-mcp und Pfade",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "render_video",
            description: "Rendert eine Szene über render-mcp zu Frames und einem Video "
                + "(H.264/HEVC/ProRes, optional mit Ton); wartet auf das Ergebnis",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(ToolSchemas.renderProperties),
            ])
        ),
        Tool(
            name: "render_3d",
            description: "Rendert eine 3D-Szene (SceneKit/Metal) über eine Kamera mit "
                + "Licht und Objekten zu einem Video; optional mit Effekten und Ton",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(ToolSchemas.render3DProperties),
            ])
        ),
        Tool(
            name: "render_start",
            description: "Startet denselben Ablauf im Hintergrund und liefert eine Kennung "
                + "(render-<uuid>); Szene als scene/scene_path (2D, render-mcp) oder "
                + "scene3d/scene3d_path (3D, SceneKit), genau eine Quelle; höchstens zwei "
                + "Läufe gleichzeitig",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(ToolSchemas.renderStartProperties),
            ])
        ),
        Tool(
            name: "render_status",
            description: "Zustand (running/done/failed/cancelled) und Fortschritt 0–100",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": ToolSchemas.jobID
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        Tool(
            name: "render_cancel",
            description: "Bricht einen laufenden Render-Lauf ab (SIGTERM an render-mcp)",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": ToolSchemas.jobID
                ]),
                "required": .array([.string("id")]),
            ])
        ),
    ]
    return .init(tools: tools)
}

await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "info":
        return textResult(info())

    case "render_video":
        return await renderVideoTool(params.arguments)

    case "render_3d":
        return await render3DTool(params.arguments)

    case "render_start":
        return await renderStartTool(params.arguments)

    case "render_status":
        return await renderStatusTool(params.arguments)

    case "render_cancel":
        return await renderCancelTool(params.arguments)

    default:
        return textResult("Unbekanntes Tool: \(params.name)", isError: true)
    }
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
