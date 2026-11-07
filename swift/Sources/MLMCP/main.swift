// ml-mcp — CoreML/Vision-Backend für das mac-compute-Gateway.
//
// Tools:
//   ml_info      — Metal-Gerät und verfügbare CoreML-Compute-Geräte
//   ml_models    — CoreML-Modelle im Modellverzeichnis mit Metadaten
//   ml_ane_probe — Compute-Zuordnung der Layer eines Prüfmodells
//   ml_classify  — Bildklassifikation über Vision (Apple-Modell)
//   ml_ocr       — Texterkennung aus Bild und PDF (Vision, ohne Modell)
//
// Der Transport ist stdio (MCP). Logs gehen ausschließlich nach stderr, damit
// stdout dem Protokoll vorbehalten bleibt.

import CoreML
import Foundation
import ImageIO
import MCP
import Metal
import Vision

/// Größte akzeptierte Bildgröße (PNG-Bytes, dekodiert).
let maxImageBytes = 8 * 1024 * 1024

/// Verzeichnisse des Gateways; Eingaben liegen unter `inbox`, Schreibziele
/// unter `artifacts`.
enum WorkspacePaths {
    nonisolated static let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-compute")
    nonisolated static let inbox = base.appendingPathComponent("inbox")
    nonisolated static let artifacts = base.appendingPathComponent("artifacts")
}

try? FileManager.default.createDirectory(at: WorkspacePaths.inbox, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: WorkspacePaths.artifacts, withIntermediateDirectories: true)

/// Prüft, dass ein Pfad unter `inbox/` liegt und existiert.
func resolveInbox(_ raw: String) throws -> URL {
    var value = raw
    if value.hasPrefix("/inbox/") { value = String(value.dropFirst("/inbox/".count)) }
    let url: URL
    if value.hasPrefix("/") {
        url = URL(fileURLWithPath: value)
    } else {
        url = WorkspacePaths.inbox.appendingPathComponent(value)
    }
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    let inbox = WorkspacePaths.inbox.standardizedFileURL.resolvingSymlinksInPath()
    guard resolved.path.hasPrefix(inbox.path + "/") else {
        throw MCPError.invalidParams("Pfad muss unter \(inbox.path) liegen")
    }
    guard FileManager.default.fileExists(atPath: resolved.path) else {
        throw MCPError.invalidParams("Datei nicht gefunden: \(resolved.lastPathComponent)")
    }
    return resolved
}

/// Legt einen Ausgabeordner unter `artifacts/` an.
func artifactsDirectory() throws -> URL {
    let target = WorkspacePaths.artifacts.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    return target
}

/// Reports the Metal device and the CoreML compute devices.
func computeInfo() -> String {
    var lines: [String] = []
    if let device = MTLCreateSystemDefaultDevice() {
        lines.append("metal: \(device.name)")
    } else {
        lines.append("metal: keines")
    }

    if #available(macOS 14.0, *) {
        let devices = MLComputeDevice.allComputeDevices.map { device -> String in
            switch device {
            case .cpu:
                return "cpu"
            case .gpu:
                return "gpu"
            case .neuralEngine:
                return "neuralEngine"
            @unknown default:
                return "unknown"
            }
        }
        lines.append("coreml_compute_devices: \(devices.joined(separator: ", "))")
    } else {
        lines.append("coreml_compute_devices: nicht verfügbar (macOS < 14)")
    }

    lines.append("vision: VNClassifyImageRequest verfügbar")

    let languages = supportedOCRLanguages()
    if languages.isEmpty {
        lines.append("ocr: Vision-Texterkennung nicht verfügbar")
    } else {
        let sample = languages.prefix(8).joined(separator: ", ")
        lines.append("ocr: Vision Revision 3, \(languages.count) Sprachen (\(sample), …)")
    }
    return lines.joined(separator: "\n")
}

/// Decodes a base64 PNG and classifies it with Vision's built-in model.
func classify(imageBase64: String, maxResults: Int) throws -> String {
    guard let data = Data(base64Encoded: imageBase64) else {
        throw MCPError.invalidParams("image_base64 ist kein gültiges Base64")
    }
    guard data.count <= maxImageBytes else {
        throw MCPError.invalidParams("Bild ist größer als 8 MiB")
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw MCPError.invalidParams("Bild konnte nicht dekodiert werden")
    }

    let started = Date()
    let request = VNClassifyImageRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let elapsed = Date().timeIntervalSince(started) * 1000

    let observations = (request.results ?? []).prefix(maxResults)
    if observations.isEmpty {
        return "keine Klassifikation (\(String(format: "%.1f", elapsed)) ms)"
    }

    var lines = ["\(image.width)×\(image.height), \(String(format: "%.1f", elapsed)) ms"]
    for observation in observations {
        lines.append(
            String(format: "%@: %.3f", observation.identifier, observation.confidence)
        )
    }
    return lines.joined(separator: "\n")
}


/// Ergebnis mit einem Textblock (neue API ohne Deprecation).
func textResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
}

/// Führt `ocr` aus: Argumente prüfen, erkennen, ausgeben oder ablegen.
func runOCRVariante(_ arguments: [String: Value]?) async -> CallTool.Result {
    guard let raw = arguments?["path"]?.stringValue, !raw.isEmpty else {
        return textResult("path fehlt", isError: true)
    }
    do {
        let url = try resolveInbox(raw)
        var options = OCROptions()

        if let level = arguments?["level"]?.stringValue {
            guard let parsed = level == "fast"
                ? VNRequestTextRecognitionLevel.fast
                : (level == "accurate" ? .accurate : nil)
            else {
                return textResult("level muss accurate oder fast sein", isError: true)
            }
            options.level = parsed
        }

        let requested = arguments?["languages"]?.arrayValue?.compactMap(\.stringValue) ?? []
        options.languages = try validatedLanguages(requested.isEmpty ? options.languages : requested)
        options.customWords =
            arguments?["custom_words"]?.arrayValue?.compactMap(\.stringValue) ?? []
        options.correction = arguments?["language_correction"]?.boolValue ?? true
        options.minConfidence = Float(arguments?["min_confidence"]?.doubleValue ?? 0)
        options.dpi = CGFloat(min(max(arguments?["dpi"]?.intValue ?? 200, 100), 400))
        options.forceOCR = arguments?["force_ocr"]?.boolValue ?? false

        let pageSpec = arguments?["pages"]?.stringValue ?? "1-"
        let format = arguments?["format"]?.stringValue ?? "text"
        guard format == "text" || format == "json" else {
            return textResult("format muss text oder json sein", isError: true)
        }
        let write = arguments?["write"]?.boolValue ?? false

        let started = Date()
        let pages = try await runOCR(url: url, pageSpec: pageSpec, options: options)
        let totalMS = Date().timeIntervalSince(started) * 1000

        let payload = format == "json" ? renderJSON(pages, totalMS: totalMS) : renderText(pages)
        guard write else {
            if format == "text", payload.isEmpty { return textResult("kein Text erkannt") }
            return textResult(payload)
        }

        let directory = try artifactsDirectory()
        let name = format == "json" ? "ocr.json" : "ocr.txt"
        let target = directory.appendingPathComponent(name)
        try payload.write(to: target, atomically: true, encoding: .utf8)
        return textResult(
            renderSummary(
                pages: pages,
                totalMS: totalMS,
                file: target.path,
                sandboxPath: "/artifacts/\(directory.lastPathComponent)/\(name)"
            )
        )
    } catch {
        return textResult("OCR fehlgeschlagen: \(error.localizedDescription)", isError: true)
    }
}

/// Liest eine Zahl, egal ob das JSON sie als Ganzzahl oder als Kommazahl liefert.
func numberValue(_ value: Value?) -> Double? {
    guard let value else { return nil }
    if let double = value.doubleValue { return double }
    if let int = value.intValue { return Double(int) }
    return nil
}

/// Führt `analyze` aus: Argumente prüfen, deuten, ausgeben oder ablegen.
func runAnalyzeVariante(_ arguments: [String: Value]?) async -> CallTool.Result {
    guard let raw = arguments?["path"]?.stringValue, !raw.isEmpty else {
        return textResult("path fehlt", isError: true)
    }
    do {
        let url = try resolveInbox(raw)
        var options = AnalyzeOptions()

        if let regionValue = arguments?["region"], !regionValue.isNull {
            guard let object = regionValue.objectValue else {
                return textResult("region muss ein Objekt mit x, y, width, height sein", isError: true)
            }
            guard let x = numberValue(object["x"]),
                  let y = numberValue(object["y"]),
                  let width = numberValue(object["width"]),
                  let height = numberValue(object["height"])
            else {
                return textResult("region braucht x, y, width und height als Zahl", isError: true)
            }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0,
                  rect.maxX <= 1.0001, rect.maxY <= 1.0001
            else {
                return textResult(
                    "region liegt außerhalb des Bildes: x/y ab 0, Breite/Höhe bis 1",
                    isError: true
                )
            }
            options.region = rect
        }

        options.question = arguments?["question"]?.stringValue
        if let detail = arguments?["detail"]?.stringValue {
            guard let parsed = AnalyzeDetail(rawValue: detail) else {
                return textResult("detail muss brief, normal oder objects sein", isError: true)
            }
            options.detail = parsed
        }
        if let language = arguments?["language"]?.stringValue {
            guard language == "de" || language == "en" else {
                return textResult("language muss de oder en sein", isError: true)
            }
            options.language = language
        }
        options.runVision = arguments?["vision"]?.boolValue ?? true
        options.maxLabels = min(max(arguments?["max_labels"]?.intValue ?? 12, 1), 40)

        let format = arguments?["format"]?.stringValue ?? "text"
        guard format == "text" || format == "json" else {
            return textResult("format muss text oder json sein", isError: true)
        }
        let write = arguments?["write"]?.boolValue ?? false

        let result = try await analyzeImage(url: url, options: options)
        let payload = format == "json"
            ? try renderAnalysisJSON(result)
            : renderAnalysis(result, question: options.question)

        guard write else { return textResult(payload) }

        let directory = try artifactsDirectory()
        let name = format == "json" ? "analyze.json" : "analyze.txt"
        let target = directory.appendingPathComponent(name)
        try payload.write(to: target, atomically: true, encoding: .utf8)
        return textResult("\(payload)\n\nDatei: /artifacts/\(directory.lastPathComponent)/\(name)")
    } catch {
        return textResult("Analyse fehlgeschlagen: \(error.localizedDescription)", isError: true)
    }
}

let server = Server(
    name: "ml-mcp",
    version: "0.2.0",
    capabilities: .init(
        tools: .init(listChanged: false)
    )
)

await server.withMethodHandler(ListTools.self) { _ in
    let tools = [
        Tool(
            name: "info",
            description: "Meldet Metal-Gerät und verfügbare CoreML-Compute-Geräte",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "models",
            description: "Listet die CoreML-Modelle im Modellverzeichnis mit Größe, Datum,"
                + " Version, Autor und Compute-Geräten (60 s Cache)",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "refresh": .object([
                        "type": .string("boolean"),
                        "description": .string("Cache übergehen und neu scannen (Standard false)"),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "ane_probe",
            description: "Prüft über MLComputePlan, welchem Gerät CoreML die Layer zuordnet",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "classify",
            description: "Klassifiziert ein PNG (Base64) über Vision",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "image_base64": .object([
                        "type": .string("string"),
                        "description": .string("PNG als Base64 (max. 8 MiB)"),
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(10),
                        "description": .string("Anzahl der Treffer (1–10, Standard 5)"),
                    ]),
                ]),
                "required": .array([.string("image_base64")]),
            ])
        ),
        Tool(
            name: "ocr",
            description: "Erkennt Text aus Bild oder PDF über Vision (ohne Modell). PDFs mit"
                + " Textebene werden ohne OCR gelesen, Seiten laufen parallel.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Pfad unter /inbox (Bild oder PDF)"),
                    ]),
                    "pages": .object([
                        "type": .string("string"),
                        "description": .string("Seitenbereich für PDF, z. B. 1-5,8,12- (Standard 1-)"),
                    ]),
                    "languages": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Sprachkennungen, Standard [de-DE, en-US]"),
                    ]),
                    "level": .object([
                        "type": .string("string"),
                        "enum": .array([.string("accurate"), .string("fast")]),
                        "description": .string("Erkennungsstufe (Standard accurate)"),
                    ]),
                    "language_correction": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Sprachkorrektur; bei Nummern und IBANs abschalten (Standard true)"
                        ),
                    ]),
                    "custom_words": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Eigennamen und Fachwörter, die die Erkennung stützen"),
                    ]),
                    "min_confidence": .object([
                        "type": .string("number"),
                        "minimum": .int(0),
                        "maximum": .int(1),
                        "description": .string("Zeilen unter dieser Konfidenz verwerfen (Standard 0)"),
                    ]),
                    "dpi": .object([
                        "type": .string("integer"),
                        "minimum": .int(100),
                        "maximum": .int(400),
                        "description": .string("Renderauflösung für PDF-Seiten ohne Textebene (Standard 200)"),
                    ]),
                    "force_ocr": .object([
                        "type": .string("boolean"),
                        "description": .string("Textebene des PDFs übergehen und immer erkennen (Standard false)"),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("text"), .string("json")]),
                        "description": .string("text (Standard) oder json mit Zeilen, BBox und Konfidenz"),
                    ]),
                    "write": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Ergebnis als ocr.txt/ocr.json unter /artifacts ablegen (Standard false)"
                        ),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        Tool(
            name: "analyze",
            description: "Deutet ein Bild: Gegenstände mit Position, Details, Text, "
                + "Bildqualität. Kombiniert Vision-Detektoren mit dem lokalen "
                + "Sprachmodell (macOS 27). Mit `region` wird ein Ausschnitt "
                + "genauer gelesen.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Pfad unter /inbox (HEIC, JPEG, PNG, TIFF)"),
                    ]),
                    "region": .object([
                        "type": .string("object"),
                        "description": .string(
                            "Ausschnitt als Anteile des Bildes, Ursprung links oben: "
                                + "{\"x\":0.2,\"y\":0.1,\"width\":0.5,\"height\":0.5}"
                        ),
                        "properties": .object([
                            "x": .object(["type": .string("number")]),
                            "y": .object(["type": .string("number")]),
                            "width": .object(["type": .string("number")]),
                            "height": .object(["type": .string("number")]),
                        ]),
                        "required": .array([
                            .string("x"), .string("y"), .string("width"), .string("height"),
                        ]),
                    ]),
                    "question": .object([
                        "type": .string("string"),
                        "description": .string("Zusatzfrage, die das Modell beantworten soll"),
                    ]),
                    "detail": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("brief"), .string("normal"), .string("objects"),
                        ]),
                        "description": .string(
                            "brief (ein Satz), normal (Standard), objects (jede Fläche "
                                + "zusätzlich einzeln benennen; je Fläche ein Modellaufruf)"
                        ),
                    ]),
                    "language": .object([
                        "type": .string("string"),
                        "enum": .array([.string("de"), .string("en")]),
                        "description": .string("Sprache der Deutung (Standard de)"),
                    ]),
                    "vision": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Detektoren mitlaufen lassen (Standard true); false spart Zeit"
                        ),
                    ]),
                    "max_labels": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(40),
                        "description": .string("Anzahl der Szenenlabels (Standard 12)"),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("text"), .string("json")]),
                        "description": .string("text (Standard) oder json"),
                    ]),
                    "write": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Ergebnis als analyze.txt/analyze.json unter /artifacts ablegen"
                        ),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
    ]
    return .init(tools: tools)
}

await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "info":
        return textResult(computeInfo())

    case "models":
        let refresh = params.arguments?["refresh"]?.boolValue ?? false
        let (scan, fromCache) = await modelRegistry.scan(refresh: refresh)
        return textResult(scan.render(fromCache: fromCache))

    case "ane_probe":
        let models = ModelPaths.directory
        let model = models.appendingPathComponent("ane_probe.mlmodel")
        guard FileManager.default.fileExists(atPath: model.path) else {
            return textResult("ane_probe.mlmodel fehlt unter \(models.path)", isError: true)
        }
        do {
            return textResult(try await aneProbe(modelPath: model))
        } catch {
            return textResult("\(error)", isError: true)
        }

    case "classify":
        guard let image = params.arguments?["image_base64"]?.stringValue else {
            return textResult("image_base64 fehlt", isError: true)
        }
        let requested = params.arguments?["max_results"]?.intValue ?? 5
        let maxResults = min(max(requested, 1), 10)
        do {
            return textResult(try classify(imageBase64: image, maxResults: maxResults))
        } catch {
            return textResult("\(error)", isError: true)
        }

    case "ocr":
        return await runOCRVariante(params.arguments)

    case "analyze":
        return await runAnalyzeVariante(params.arguments)

    default:
        return textResult("Unbekanntes Tool: \(params.name)", isError: true)
    }
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
