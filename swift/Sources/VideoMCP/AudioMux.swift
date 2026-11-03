// AudioMux.swift — Audiospur an das fertige Video muxen (Schritt 12).
//
// Das Video wird zuerst ohne Ton encodiert und danach mit dem Ton in einer
// `AVMutableComposition` zusammengeführt. Beide Spuren starten bei 0; das Audio
// endet mit der kürzeren Spur, das Video bleibt führend (kein Loop). Der Export
// versucht zuerst Passthrough und fällt sonst auf `HighestQuality` zurück, das
// den Ton nach AAC wandelt.

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Geprüfte Audioquelle.
struct AudioSource: Sendable {
    let url: URL
    let duration: Double
}

/// Ergebnis des Muxens.
struct AudioReport: Sendable {
    /// Verwendete Audiodatei.
    let source: URL
    /// Differenz der Startzeiten von Video und Audio in Millisekunden.
    let offsetMs: Double
    /// Dauer eines Frames in Millisekunden.
    let frameMs: Double
    /// Übernommene Audiodauer in Sekunden.
    let duration: Double

    /// Meldung für das Tool: Pfad und die geprüfte Synchronität.
    var text: String {
        let offsetValue = offsetMs.isFinite ? offsetMs : 0
        let frameValue = frameMs.isFinite ? frameMs : 0
        let offset = String(format: "%.1f", offsetValue)
        let frame = String(format: "%.1f", frameValue)
        let limit = offsetValue <= frameValue ? "<= 1 Frame" : "> 1 Frame"
        return """
        audio: \(source.path)
        av_sync: \(offset) ms (\(limit) = \(frame) ms)
        """
    }
}

/// Prüft eine Audiodatei, bevor gerendert wird.
///
/// Fehlende oder defekte Dateien führen zu einem klaren Fehler; stilles
/// Ignorieren gibt es nicht.
func validateAudioSource(_ url: URL) async throws -> AudioSource {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw VideoError("Audiodatei nicht gefunden: \(url.path)")
    }
    let asset = AVURLAsset(url: url)

    let tracks: [AVAssetTrack]
    do {
        tracks = try await asset.loadTracks(withMediaType: .audio)
    } catch {
        throw VideoError(
            "Audiodatei nicht lesbar (\(url.lastPathComponent)): \(error.localizedDescription)"
        )
    }
    guard let track = tracks.first else {
        throw VideoError("Audiodatei ohne Tonspur: \(url.lastPathComponent)")
    }

    let formats: [CMFormatDescription]
    let duration: CMTime
    do {
        formats = try await track.load(.formatDescriptions)
        duration = try await asset.load(.duration)
    } catch {
        throw VideoError(
            "Audiodatei nicht lesbar (\(url.lastPathComponent)): \(error.localizedDescription)"
        )
    }
    guard !formats.isEmpty else {
        throw VideoError("Audiodatei ohne lesbares Tonformat: \(url.lastPathComponent)")
    }
    guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
        throw VideoError("Audiodatei ohne gültige Dauer: \(url.lastPathComponent)")
    }
    return AudioSource(url: url, duration: duration.seconds)
}

/// Legt Video und Ton in einer Komposition zusammen und exportiert sie.
func muxAudio(
    video: URL,
    source: AudioSource,
    output: URL,
    fileType: AVFileType,
    fps: Double
) async throws -> AudioReport {
    let videoAsset = AVURLAsset(url: video)
    let audioAsset = AVURLAsset(url: source.url)

    let videoTracks: [AVAssetTrack]
    let audioTracks: [AVAssetTrack]
    do {
        videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    } catch {
        throw VideoError("Spuren lassen sich nicht lesen: \(error.localizedDescription)")
    }
    guard let sourceVideo = videoTracks.first else {
        throw VideoError("fertiges Video ohne Videospur: \(video.lastPathComponent)")
    }
    guard let sourceAudio = audioTracks.first else {
        throw VideoError("Audiodatei ohne Tonspur: \(source.url.lastPathComponent)")
    }

    let videoDuration: CMTime
    let audioDuration: CMTime
    let transform: CGAffineTransform
    do {
        videoDuration = try await videoAsset.load(.duration)
        audioDuration = try await audioAsset.load(.duration)
        transform = try await sourceVideo.load(.preferredTransform)
    } catch {
        throw VideoError("Spurdaten nicht lesbar: \(error.localizedDescription)")
    }
    guard videoDuration.isValid, videoDuration.seconds > 0 else {
        throw VideoError("fertiges Video ohne gültige Dauer: \(video.lastPathComponent)")
    }
    guard audioDuration.isValid, audioDuration.seconds > 0 else {
        throw VideoError("Audiodatei ohne gültige Dauer: \(source.url.lastPathComponent)")
    }

    // Das Audio endet mit der kürzeren Spur; das Video bleibt vollständig.
    let audioLength = audioDuration < videoDuration ? audioDuration : videoDuration

    let composition = AVMutableComposition()
    let videoTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
    )
    let audioTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
    )
    guard let videoTrack, let audioTrack else {
        throw VideoError("Komposition lässt sich nicht anlegen")
    }

    do {
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideo,
            at: .zero
        )
        try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: audioLength),
            of: sourceAudio,
            at: .zero
        )
    } catch {
        throw VideoError("Spuren lassen sich nicht übernehmen: \(error.localizedDescription)")
    }
    videoTrack.preferredTransform = transform

    try await exportComposition(composition, to: output, as: fileType)

    // Startzeiten im Ergebnis messen; die Komposition dient als Rückfallebene.
    var offsetMs = abs(
        videoTrack.timeRange.start.seconds - audioTrack.timeRange.start.seconds
    ) * 1000
    let exported = AVURLAsset(url: output)
    let exportedVideo = (try? await exported.loadTracks(withMediaType: .video)) ?? []
    let exportedAudio = (try? await exported.loadTracks(withMediaType: .audio)) ?? []
    if let videoStart = exportedVideo.first?.timeRange.start.seconds,
       let audioStart = exportedAudio.first?.timeRange.start.seconds,
       videoStart.isFinite, audioStart.isFinite
    {
        offsetMs = abs(videoStart - audioStart) * 1000
    }

    return AudioReport(
        source: source.url,
        offsetMs: offsetMs,
        frameMs: fps > 0 ? 1000 / fps : 0,
        duration: audioLength.seconds
    )
}

/// Exportiert die Komposition: erst Passthrough, sonst neu encodiert.
func exportComposition(
    _ composition: AVMutableComposition,
    to output: URL,
    as fileType: AVFileType
) async throws {
    do {
        try await runExport(
            composition,
            to: output,
            as: fileType,
            preset: AVAssetExportPresetPassthrough
        )
    } catch {
        let passthrough = "\(error)"
        try? FileManager.default.removeItem(at: output)
        do {
            try await runExport(
                composition,
                to: output,
                as: fileType,
                preset: AVAssetExportPresetHighestQuality
            )
        } catch {
            throw VideoError(
                "Audio lässt sich nicht muxen: \(error) (Passthrough: \(passthrough))"
            )
        }
    }
}

/// Ein Exportversuch mit festem Preset.
private func runExport(
    _ composition: AVMutableComposition,
    to output: URL,
    as fileType: AVFileType,
    preset: String
) async throws {
    guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
        throw VideoError("Export-Sitzung nicht verfügbar (\(preset))")
    }

    let directory = output.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        throw VideoError("Zielverzeichnis lässt sich nicht anlegen: \(directory.path)")
    }
    // Ein vorhandenes Ziel lehnt der Export ab.
    try? FileManager.default.removeItem(at: output)

    try await session.export(to: output, as: fileType)
}
