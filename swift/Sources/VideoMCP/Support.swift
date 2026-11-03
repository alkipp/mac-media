// Support.swift — Pfade, Formatierung und Statuszeilen für video-mcp.
//
// Dieselben Verzeichnisse wie media-mcp: Eingaben unter
// ~/Library/Application Support/mac-compute/inbox/, Ausgaben unter
// .../artifacts/<uuid>/.

import AVFoundation
import Foundation
import MCP
import VideoToolbox

enum Paths {
    static let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-compute")
    static let inbox = base.appendingPathComponent("inbox")
    static let artifacts = base.appendingPathComponent("artifacts")

    /// Legt `inbox/` und `artifacts/` an. Fehlt das Schreibrecht, startet das
    /// Backend trotzdem und meldet den Fehler erst beim Zugriff.
    static func prepare() {
        for url in [inbox, artifacts] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

/// Fehler mit deutscher Meldung; `description` geht direkt an den Nutzer.
struct VideoError: Error, CustomStringConvertible, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }

    /// Damit `localizedDescription` in AVFoundation-Meldungen lesbar bleibt.
    var errorDescription: String? { message }
}

/// Abbruch eines Laufs (`render_cancel` oder Signal an das Backend).
struct RenderCancelled: Error, Sendable, CustomStringConvertible {
    var description: String { "Lauf abgebrochen" }
}

/// Fragt den Abbruch-Flag ab; ohne Flag gilt der Lauf als nicht abgebrochen.
func isCancelledNow(_ check: (@Sendable () async -> Bool)?) async -> Bool {
    guard let check else { return false }
    return await check()
}

/// Ergebnis mit einem Textblock.
func textResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
}

/// Meldung auf stderr; stdout bleibt der Nutzlast vorbehalten.
func writeError(_ message: String) {
    FileHandle.standardError.write(Data("video-mcp: \(message)\n".utf8))
}

/// Zahlendarstellung in Meldungen.
enum Format {
    /// Framerate ohne überflüssige Nachkommastellen: `30`, `29.97`.
    static func fps(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        if abs(value - value.rounded()) < 0.001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }

    /// Dauer in Sekunden mit einer Nachkommastelle.
    static func seconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0.0" }
        return String(format: "%.1f", value)
    }
}

/// Dateiname ohne Pfadanteile und Sonderzeichen; leer wird zu `video`.
func safeName(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    var cleaned = ""
    for scalar in raw.unicodeScalars {
        if allowed.contains(scalar) {
            cleaned.unicodeScalars.append(scalar)
        } else {
            cleaned.append("-")
        }
    }
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    let limited = String(trimmed.prefix(64))
    return limited.isEmpty ? "video" : limited
}

/// `true`, wenn der Codec-Name zu den Video-Encodern gehört, die hier zählen.
func isVideoCodec(_ codec: String) -> Bool {
    let name = codec.lowercased()
    return name.contains("h.264") || name.contains("hevc") || name.contains("prores")
}

/// Video-Encoder mit Hardware-Kennzeichen.
func encoderInfo() -> String {
    var list: CFArray?
    guard VTCopyVideoEncoderList(nil, &list) == noErr,
          let encoders = list as? [[String: Any]]
    else {
        return "VideoToolbox: keine Encoder gemeldet"
    }

    var lines = ["encoder (hardware):"]
    var hardware = 0
    for encoder in encoders {
        let name = encoder[kVTVideoEncoderList_EncoderName as String] as? String ?? "?"
        let codec = encoder[kVTVideoEncoderList_CodecName as String] as? String ?? "?"
        guard isVideoCodec(codec) else { continue }
        let accelerated =
            (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue
            ?? false
        if accelerated { hardware += 1 }
        lines.append("- \(codec) / \(name) (hardware: \(accelerated))")
    }
    if lines.count == 1 {
        return "VideoToolbox: keine Video-Encoder gemeldet"
    }
    lines.append("hardware-encoder: \(hardware)")
    return lines.joined(separator: "\n")
}

/// Prüft, ob AVAssetWriter H.264 in MP4 schreiben kann. Es wird nur eine
/// Writer-Instanz geprüft; eine Datei entsteht dabei nicht.
func assetWriterStatus() -> String {
    let target = FileManager.default.temporaryDirectory
        .appendingPathComponent("video-mcp-check-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: target) }

    do {
        let writer = try AVAssetWriter(outputURL: target, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            return "verfügbar, H.264 nach MP4 wird abgelehnt"
        }
        return "verfügbar (H.264/HEVC → MP4, ProRes → MOV, Hardware bevorzugt)"
    } catch {
        return "nicht verfügbar (\(error.localizedDescription))"
    }
}

/// Version des Backends; erscheint im Handschlag und in `video_info`.
let videoBackendVersion = "0.4.0"

/// Zustand des Backends für den ersten Handschlag.
func info() -> String {
    let render = RenderBinary.locate()
    return """
    backend: video-mcp \(videoBackendVersion)
    avfoundation: verfügbar
    assetwriter: \(assetWriterStatus())
    codecs: \(VideoCodec.list)
    render-mcp: \(render.text)
    timeout_s: \(timeoutText(renderTimeoutFromEnvironment()))
    scene3d: SceneKit + Metal (render_3d)
    effects: blur, bloom, color, vignette
    inbox: \(Paths.inbox.path)
    artifacts: \(Paths.artifacts.path)
    \(encoderInfo())
    """
}
