// Probe.swift — MP4-Dateien für `--probe` und Abnahmen auswerten.

import AVFoundation
import CoreMedia
import Foundation

/// Vier-Zeichen-Codec als Text.
func fourCC(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}

/// Codec-Name, wie ihn die Meldungen verwenden.
///
/// ProRes wird nach Profil unterschieden: `prores422` für 422/HQ/LT/Proxy,
/// `prores4444` für 4444. Unbekannte Codes erscheinen als Vier-Zeichen-Code.
func codecName(_ code: FourCharCode) -> String {
    switch code {
    case kCMVideoCodecType_H264:
        return "h264"
    case kCMVideoCodecType_HEVC:
        return "hevc"
    case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
        kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy:
        return "prores422"
    case kCMVideoCodecType_AppleProRes4444:
        return "prores4444"
    default:
        return fourCC(code).trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// Zählt Videoframes über einen Passthrough-Reader. Rückfallebene, wenn die
/// Framerate der Spur fehlt.
func countFrames(_ asset: AVURLAsset, track: AVAssetTrack) -> Int {
    guard let reader = try? AVAssetReader(asset: asset) else { return 0 }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(output) else { return 0 }
    reader.add(output)
    guard reader.startReading() else { return 0 }

    var count = 0
    while let sample = output.copyNextSampleBuffer() {
        count += max(CMSampleBufferGetNumSamples(sample), 1)
    }
    reader.cancelReading()
    return count
}

/// Dauer, Auflösung, Framerate, Codec und geschätzte Framezahl.
func probeText(_ url: URL) async throws -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw VideoError("Datei nicht gefunden: \(url.path)")
    }

    let asset = AVURLAsset(url: url)
    let loaded = try await asset.load(.duration)
    let duration = loaded.seconds.isFinite && loaded.seconds > 0 ? loaded.seconds : 0

    var lines = [
        "file: \(url.lastPathComponent)",
        "duration: \(Format.seconds(duration)) s",
        "extension: \(url.pathExtension.lowercased())",
    ]

    let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
    var audioLine = "audio: nein"
    if let audioTrack = audioTracks.first {
        let formats = (try? await audioTrack.load(.formatDescriptions)) ?? []
        if let format = formats.first {
            let subtype = codecName(CMFormatDescriptionGetMediaSubType(format))
            audioLine = "audio: ja (\(subtype))"
        }
    }
    lines.append(audioLine)

    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else {
        lines.append("resolution: keine Videospur")
        return lines.joined(separator: "\n")
    }

    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let display = size.applying(transform)
    let width = Int(abs(display.width).rounded())
    let height = Int(abs(display.height).rounded())
    lines.append("resolution: \(width)x\(height)")

    var fps = try await track.load(.nominalFrameRate)
    var frames = Int((duration * Double(fps)).rounded())
    if fps <= 0 || frames <= 0 {
        let counted = countFrames(asset, track: track)
        if counted > 0 {
            frames = counted
            if duration > 0 { fps = Float(Double(counted) / duration) }
        }
    }
    lines.append("fps: \(Format.fps(Double(fps)))")
    lines.append("frames: \(frames) (geschätzt)")

    let formats = try await track.load(.formatDescriptions)
    let codec = formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
    lines.append("codec: \(codec)")

    return lines.joined(separator: "\n")
}
