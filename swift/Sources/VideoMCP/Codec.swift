// Codec.swift — Video-Codecs, Container und Bitraten (Schritt 14).
//
// H.264 und HEVC laufen über VideoToolbox (hardwarebeschleunigt) und landen in
// MP4; ProRes 422/4444 rechnet die CPU und braucht MOV. `name` bleibt immer die
// Basis des Dateinamens, die Endung ergibt sich aus dem Codec.

import AVFoundation
import CoreMedia
import Foundation

/// Unterstützte Video-Codecs.
enum VideoCodec: String, Sendable, CaseIterable {
    case h264
    case hevc
    case prores422
    case prores4444

    /// Name für Meldungen, Tool-Antworten und `--codec`.
    var name: String { rawValue }

    /// Endung des Containers, den dieser Codec braucht.
    var fileExtension: String {
        switch self {
        case .h264, .hevc:
            return "mp4"
        case .prores422, .prores4444:
            return "mov"
        }
    }

    /// Container für `AVAssetWriter` und `AVAssetExportSession`.
    var fileType: AVFileType {
        switch self {
        case .h264, .hevc:
            return .mp4
        case .prores422, .prores4444:
            return .mov
        }
    }

    /// Codec-Kennung für den Writer.
    var avCodec: AVVideoCodecType {
        switch self {
        case .h264:
            return .h264
        case .hevc:
            return .hevc
        case .prores422:
            return .proRes422
        case .prores4444:
            return .proRes4444
        }
    }

    /// CoreMedia-Kennung für die Hardware-Abfrage; `nil` bei ProRes.
    var cmCodecType: CMVideoCodecType? {
        switch self {
        case .h264:
            return kCMVideoCodecType_H264
        case .hevc:
            return kCMVideoCodecType_HEVC
        case .prores422, .prores4444:
            return nil
        }
    }

    /// Nur H.264 und HEVC haben einen Hardware-Encoder; ProRes ist Software.
    var usesHardware: Bool {
        cmCodecType != nil
    }

    /// Zielbitrate.
    ///
    /// H.264 und HEVC teilen sich dieselbe pixelbasierte Rechnung wie bisher.
    /// ProRes 422 liegt bei 1080p30 bei rund 880 Mbit/s (≈ 14,15 Bit je Pixel
    /// und Frame), ProRes 4444 beim Vierfachen.
    func bitrate(width: Int, height: Int, fps: Double) -> Int {
        let pixelsPerSecond = Double(width) * Double(height) * max(fps, 1)
        switch self {
        case .h264, .hevc:
            let raw = pixelsPerSecond * 0.12
            return Int(min(max(raw, 2_000_000), 40_000_000))
        case .prores422:
            return Int(max(pixelsPerSecond * 14.15, 10_000_000))
        case .prores4444:
            return Int(max(pixelsPerSecond * 56.6, 40_000_000))
        }
    }

    /// Akzeptiert `h264`, `h.264`, `avc`, `hevc`, `h265`, `prores422`, `prores4444`.
    static func parse(_ raw: String) throws -> VideoCodec {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "h264", "h.264", "avc", "avc1":
            return .h264
        case "hevc", "h265", "h.265":
            return .hevc
        case "prores", "prores422", "prores-422":
            return .prores422
        case "prores4444", "prores-4444":
            return .prores4444
        default:
            throw VideoError(
                "unbekannter Codec: \(raw) (erwartet h264, hevc, prores422, prores4444)"
            )
        }
    }

    /// Aufzählung für Hilfe und `info`.
    static var list: String {
        allCases.map(\.name).joined(separator: ", ")
    }
}
