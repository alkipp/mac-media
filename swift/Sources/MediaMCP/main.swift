// media-mcp — VideoToolbox-Backend für das mac-compute-Gateway.
//
// Tools:
//   info       — VideoToolbox-Encoder und Hardware-Beschleunigung
//   probe      — Dauer, Auflösung, Framerate und Codec einer Datei
//   thumbnail  — PNG-Vorschaubild zu einem Zeitpunkt
//   transcode  — Export nach H.264 oder HEVC (MP4) mit SHA-256
//
// Eingaben liegen ausschließlich unter
// ~/Library/Application Support/mac-compute/inbox/.
// Ausgaben landen unter .../artifacts/<uuid>/.

import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
import MCP
import VideoToolbox

enum Paths {
    nonisolated static let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-compute")
    nonisolated static let inbox = base.appendingPathComponent("inbox")
    nonisolated static let artifacts = base.appendingPathComponent("artifacts")
}

try? FileManager.default.createDirectory(at: Paths.inbox, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: Paths.artifacts, withIntermediateDirectories: true)

/// Zahl aus den Tool-Argumenten; akzeptiert Ganzzahl und Kommazahl.
func doubleArg(_ arguments: [String: Value]?, _ key: String) -> Double? {
    guard let value = arguments?[key] else { return nil }
    if let number = value.doubleValue { return number }
    if let number = value.intValue { return Double(number) }
    return nil
}

/// Ergebnis mit einem Textblock.
func textResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
}

/// Prüft, dass ein Pfad unter `inbox/` liegt und existiert.
func resolveInput(_ raw: String) throws -> URL {
    let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
    let inbox = Paths.inbox.standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(inbox.path + "/") else {
        throw MCPError.invalidParams("Pfad muss unter \(inbox.path) liegen")
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw MCPError.invalidParams("Datei nicht gefunden: \(url.lastPathComponent)")
    }
    return url
}

/// Vier-Zeichen-Codec als Text.
func fourCC(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}

/// VideoToolbox-Encoder mit Hardware-Kennzeichen.
func encoderInfo() -> String {
    var list: CFArray?
    guard VTCopyVideoEncoderList(nil, &list) == noErr,
          let encoders = list as? [[String: Any]]
    else {
        return "VideoToolbox: keine Encoder gemeldet"
    }

    var lines = ["encoder (hardware):"]
    for encoder in encoders {
        let name = encoder[kVTVideoEncoderList_EncoderName as String] as? String ?? "?"
        let codec = encoder[kVTVideoEncoderList_CodecName as String] as? String ?? "?"
        let hardware =
            (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue
            ?? false
        lines.append("- \(codec) / \(name) (hardware: \(hardware))")
    }
    return lines.joined(separator: "\n")
}

/// Metadaten einer Datei.
func probe(_ url: URL) async throws -> String {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    var lines = [
        "file: \(url.lastPathComponent)",
        String(format: "duration: %.2f s", duration.seconds),
    ]

    let tracks = try await asset.loadTracks(withMediaType: .video)
    if let track = tracks.first {
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let formats = try await track.load(.formatDescriptions)
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        lines.append(
            String(
                format: "video: %.0f×%.0f, %.1f fps, codec %@",
                size.width, size.height, fps, codec
            )
        )
    } else {
        lines.append("video: keine Videospur")
    }

    let audio = try await asset.loadTracks(withMediaType: .audio)
    lines.append("audio: \(audio.count) Spur(en)")
    return lines.joined(separator: "\n")
}

/// Mittlere Helligkeit eines BGRA-Pixelpuffers, grob abgetastet (jedes 16. Pixel).
func meanLuma(_ buffer: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    var sum = 0.0
    var count = 0.0
    for y in stride(from: 0, to: height, by: 4) {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in stride(from: 0, to: width, by: 4) {
            let pixel = x * 4
            sum += (Double(row[pixel]) + Double(row[pixel + 1]) + Double(row[pixel + 2])) / 3
            count += 1
        }
    }
    return count > 0 ? sum / count : -1
}

/// Schreibt ein PNG-Vorschaubild in ein neues Artefakt-Verzeichnis.
///
/// Dekodiert über `AVAssetReader` statt `AVAssetImageGenerator`: Der Generator
/// lieferte im Serverprozess schwarze Bilder, obwohl dieselbe Datei in
/// QuickTime und im CLI-Test korrekt aussah.
func thumbnail(_ url: URL, seconds: Double, width: Int) async throws -> String {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw MCPError.internalError("Datei enthält keine Videospur")
    }

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
    )
    reader.add(output)
    guard reader.startReading() else {
        throw MCPError.internalError("Video lässt sich nicht lesen")
    }
    defer { reader.cancelReading() }

    // Nächstgelegenen Frame ab dem gewünschten Zeitpunkt nehmen; bis dahin
    // bleibt der letzte gelesene Frame als Rückfallebene stehen.
    let target = CMTime(seconds: seconds, preferredTimescale: 600)
    var lastBuffer: CVPixelBuffer?
    var chosen: CVPixelBuffer?

    var chosenSeconds = -1.0
    while let sample = output.copyNextSampleBuffer() {

        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        lastBuffer = buffer
        if CMSampleBufferGetPresentationTimeStamp(sample) >= target {
            chosen = buffer
            chosenSeconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            break
        }
    }
    guard let buffer = chosen ?? lastBuffer else {
        throw MCPError.internalError("Kein Frame bei \(seconds) s gefunden")
    }


    var decoded: CGImage?
    guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &decoded) == noErr,
          let source = decoded
    else {
        throw MCPError.internalError("Frame lässt sich nicht in ein Bild wandeln")
    }

    // Diagnose: mittlere Helligkeit direkt aus dem dekodierten Puffer. Steht hier
    // 0, liefert schon die Dekodierung Schwarz; sonst liegt es an der Wandlung.
    let luma = meanLuma(buffer)

    let targetWidth = min(max(width, 16), 4096)
    let targetHeight = max(1, Int((Double(source.height) * Double(targetWidth)
        / Double(source.width)).rounded()))
    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw MCPError.internalError("Bildkontext konnte nicht erzeugt werden")
    }
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    guard let image = context.makeImage() else {
        throw MCPError.internalError("Vorschaubild konnte nicht skaliert werden")
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, "public.png" as CFString, 1, nil
    ) else {
        throw MCPError.internalError("PNG-Ziel konnte nicht erzeugt werden")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw MCPError.internalError("PNG konnte nicht geschrieben werden")
    }

    let directory = Paths.artifacts.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let outputURL = directory.appendingPathComponent("thumbnail.png")
    try (data as Data).write(to: outputURL)
    let bytes = (data as Data).count
    return "thumbnail: \(outputURL.path)\nbytes: \(bytes)\nimage: \(image.width)×\(image.height)\nluma: \(String(format: "%.1f", luma)), pts: \(String(format: "%.2f", chosenSeconds))"
}

/// Exportiert die Datei als MP4 und liefert Pfad, Größe und SHA-256.
func transcode(_ url: URL, preset: String) async throws -> String {
    let asset = AVURLAsset(url: url)
    let presetName =
        preset == "hevc"
        ? AVAssetExportPresetHEVCHighestQuality
        : AVAssetExportPresetHighestQuality
    guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
        throw MCPError.internalError("Export-Session konnte nicht erstellt werden")
    }

    let directory = Paths.artifacts.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let output = directory.appendingPathComponent("output.mp4")
    try await session.export(to: output, as: .mp4)

    let data = try Data(contentsOf: output)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return "output: \(output.path)\nbytes: \(data.count)\nsha256: \(digest)\npreset: \(preset)"
}

let server = Server(
    name: "media-mcp",
    version: "0.1.0",
    capabilities: .init(
        tools: .init(listChanged: false)
    )
)

await server.withMethodHandler(ListTools.self) { _ in
    let tools = [
        Tool(
            name: "info",
            description: "Meldet VideoToolbox-Encoder und Hardware-Beschleunigung",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "probe",
            description: "Liest Dauer, Auflösung, Framerate und Codec einer Mediendatei",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Pfad unter .../mac-compute/inbox/"),
                    ])
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        Tool(
            name: "thumbnail",
            description: "Erzeugt ein PNG-Vorschaubild zu einem Zeitpunkt",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Pfad unter .../mac-compute/inbox/"),
                    ]),
                    "at_seconds": .object([
                        "type": .string("number"),
                        "minimum": .double(0),
                        "description": .string("Zeitpunkt in Sekunden (Standard 0)"),
                    ]),
                    "width": .object([
                        "type": .string("integer"),
                        "minimum": .int(16),
                        "maximum": .int(4096),
                        "description": .string("Breite in Pixeln (Standard 640)"),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        Tool(
            name: "encode",
            description: "Encodiert ein H.264-Testvideo über VTCompressionSession (Hardware erzwungen)",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "width": .object([
                        "type": .string("integer"),
                        "minimum": .int(16),
                        "maximum": .int(3840),
                        "description": .string("Breite (Standard 640)"),
                    ]),
                    "height": .object([
                        "type": .string("integer"),
                        "minimum": .int(16),
                        "maximum": .int(2160),
                        "description": .string("Höhe (Standard 360)"),
                    ]),
                    "frames": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(300),
                        "description": .string("Anzahl Frames (Standard 60)"),
                    ]),
                    "fps": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(60),
                        "description": .string("Framerate (Standard 30)"),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "transcode",
            description: "Exportiert eine Datei als MP4 (H.264 oder HEVC)",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Pfad unter .../mac-compute/inbox/"),
                    ]),
                    "preset": .object([
                        "type": .string("string"),
                        "enum": .array([.string("h264"), .string("hevc")]),
                        "description": .string("Codec (Standard h264)"),
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
        return textResult(encoderInfo())

    case "probe":
        guard let raw = params.arguments?["path"]?.stringValue else {
            return textResult("path fehlt", isError: true)
        }
        do {
            return textResult(try await probe(resolveInput(raw)))
        } catch {
            return textResult("\(error)", isError: true)
        }

    case "thumbnail":
        guard let raw = params.arguments?["path"]?.stringValue else {
            return textResult("path fehlt", isError: true)
        }
        let seconds = doubleArg(params.arguments, "at_seconds") ?? 0
        let width = min(max(params.arguments?["width"]?.intValue ?? 640, 16), 4096)
        do {
            return textResult(try await thumbnail(resolveInput(raw), seconds: seconds, width: width))
        } catch {
            return textResult("\(error)", isError: true)
        }

    case "encode":
        let width = min(max(params.arguments?["width"]?.intValue ?? 640, 16), 3840)
        let height = min(max(params.arguments?["height"]?.intValue ?? 360, 16), 2160)
        let frames = min(max(params.arguments?["frames"]?.intValue ?? 60, 1), 300)
        let fps = Int32(min(max(params.arguments?["fps"]?.intValue ?? 30, 1), 60))
        do {
            let directory = Paths.artifacts.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = try await encodeTestVideo(
                width: width,
                height: height,
                frames: frames,
                fps: fps,
                output: directory.appendingPathComponent("hardware.mp4")
            )
            let hardware = result.hardware.map { $0 ? "true" : "false" } ?? "unbekannt"
            return textResult("""
            output: \(result.path.path)
            bytes: \(result.bytes)
            sha256: \(result.sha256)
            hardware: \(hardware)
            frames: \(frames) @ \(fps) fps, \(width)×\(height)
            """)
        } catch {
            return textResult("\(error)", isError: true)
        }

    case "transcode":
        guard let raw = params.arguments?["path"]?.stringValue else {
            return textResult("path fehlt", isError: true)
        }
        let preset = params.arguments?["preset"]?.stringValue ?? "h264"
        do {
            return textResult(try await transcode(resolveInput(raw), preset: preset))
        } catch {
            return textResult("\(error)", isError: true)
        }

    default:
        return textResult("Unbekanntes Tool: \(params.name)", isError: true)
    }
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
