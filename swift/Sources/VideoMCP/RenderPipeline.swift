// RenderPipeline.swift — Szene rendern, Frames encodieren, Ton muxen.

import CoreVideo
import Foundation

/// Ergebnis eines Render-Laufs.
struct RenderReport: Sendable {
    let video: URL
    let frames: Int
    let width: Int
    let height: Int
    let fps: Double
    let duration: Double
    let hardware: Bool?
    let codec: VideoCodec
    let audio: AudioReport?
    let directory: URL
    let framesKept: Bool
    /// Zahl der angewandten Effekte; 0 heißt ohne Effekte.
    let effects: Int
    /// Zahl der 3D-Objekte; `nil` bei der 2D-Pipeline.
    let objects: Int?
    /// Wie die Frames zum Encoder kamen: `shm` (Ring), `direct` (3D im Prozess)
    /// oder `png` (Dateien).
    let transport: String

    /// Klartext für die Tools und für `--render`/`--render3d`.
    var text: String {
        var lines = [
            "video: \(video.path)",
            "frames: \(frames)",
            "duration: \(Format.seconds(duration))",
            "resolution: \(width)x\(height)@\(Format.fps(fps))",
            "codec: \(codec.name)",
            "hardware: \(hardwareText)",
            "transport: \(transport)",
        ]
        if let objects {
            lines.append("objects: \(objects)")
            lines.append("scene: 3d")
        }
        if let audio {
            lines.append(audio.text)
        }
        lines.append("effects: \(effects)")
        lines.append("dir: \(directory.path)")
        if framesKept {
            let kept = directory.appendingPathComponent("frames")
            lines.append("frames_dir: \(kept.path)")
        }
        return lines.joined(separator: "\n")
    }

    /// `true`/`false`, wenn VideoToolbox Auskunft gibt, sonst `unbekannt`.
    private var hardwareText: String {
        guard let hardware else { return "unbekannt" }
        return hardware ? "true" : "false"
    }
}

/// Bildet einen Fortschritt 0…1 auf den Bereich `from`…`to` ab.
func progressMapper(
    _ progress: (@Sendable (Double) async -> Void)?,
    from: Double,
    to: Double
) -> (@Sendable (Double) async -> Void)? {
    guard let progress else { return nil }
    return { share in
        let clamped = min(max(share, 0), 1)
        await progress(from + (to - from) * clamped)
    }
}

/// Zielpfad mit der Endung des Codecs; der Name bleibt die Basis.
func outputURL(_ target: URL, codec: VideoCodec) -> URL {
    if target.pathExtension.lowercased() == codec.fileExtension {
        return target
    }
    return target.deletingPathExtension().appendingPathExtension(codec.fileExtension)
}

/// Vollständiger Lauf: Szene → Frames über render-mcp → Video → ggf. Ton.
///
/// Arbeitsverzeichnis ist `<artifacts>/<uuid>/`; ohne `output` landet das Video
/// als `<name>.<endung>` daneben, mit `output` am angegebenen Pfad (die Endung
/// folgt dem Codec). `progress` meldet 0…100, `isCancelled` wird laufend
/// gefragt; ein Abbruch wirft `RenderCancelled` und räumt die Frames ab.
/// `timeout` ist das gemeinsame Zeitbudget des gesamten Laufs in Sekunden
/// (Default aus `RENDER_TIMEOUT_S`, sonst 600) und wird an render-mcp
/// weitergereicht; einen eigenen Encoding-Timeout gibt es nicht.
func renderVideo(
    scene: SceneInput,
    name: String,
    keepFrames: Bool,
    output: URL?,
    codec: VideoCodec = .h264,
    audio: URL? = nil,
    effects: [EffectSpec] = [],
    progress: (@Sendable (Double) async -> Void)? = nil,
    isCancelled: (@Sendable () async -> Bool)? = nil,
    timeout: TimeInterval? = nil
) async throws -> RenderReport {
    // Am Einstieg einmal auflösen: Rendern und Encoding teilen sich das Budget.
    let budget = resolveRenderTimeout(timeout)
    let header = try scene.header()
    guard header.version == 1 else {
        throw VideoError("Szene-Version \(header.version) wird nicht unterstützt (erwartet 1)")
    }

    // Eine defekte Audiodatei soll vor dem Rendern auffallen, nicht danach.
    var audioSource: AudioSource?
    if let audio {
        audioSource = try await validateAudioSource(audio)
    }

    let binary = RenderBinary.locate()
    guard let renderMcp = binary.url else {
        throw VideoError("render-mcp nicht gefunden (\(binary.source))")
    }

    Paths.prepare()
    let directory = Paths.artifacts.appendingPathComponent(UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        throw VideoError("Arbeitsverzeichnis lässt sich nicht anlegen: \(directory.path)")
    }

    let sceneFile = try scene.materialize(in: directory)
    let framesDirectory = directory.appendingPathComponent("frames")
    let expected = max(Int((header.duration * header.fps).rounded()), 1)

    let video = outputURL(
        output ?? directory.appendingPathComponent("\(safeName(name)).\(codec.fileExtension)"),
        codec: codec
    )
    // Mit Ton entsteht das Video erst ohne Tonspur und wird danach gemuxt.
    let encodeTarget = audioSource == nil
        ? video
        : directory.appendingPathComponent("video-only.\(codec.fileExtension)")

    do {
        let stage: EncodeStage
        if keepFrames {
            // Wer die Frames behalten will, braucht sie als Dateien.
            stage = try await encodeFromFiles(
                binary: renderMcp,
                scene: sceneFile,
                framesDirectory: framesDirectory,
                expected: expected,
                header: header,
                codec: codec,
                output: encodeTarget,
                effects: effects,
                progress: progress,
                isCancelled: isCancelled,
                budget: budget
            )
        } else {
            stage = try await encodeTwoPhase(
                binary: renderMcp,
                scene: sceneFile,
                framesDirectory: framesDirectory,
                directory: directory,
                expected: expected,
                header: header,
                codec: codec,
                output: encodeTarget,
                effects: effects,
                progress: progress,
                isCancelled: isCancelled,
                budget: budget
            )
        }

        let fps = stage.fps
        var audioReport: AudioReport?
        if let audioSource {
            audioReport = try await muxAudio(
                video: encodeTarget,
                source: audioSource,
                output: video,
                fileType: codec.fileType,
                fps: fps
            )
            if encodeTarget != video {
                try? FileManager.default.removeItem(at: encodeTarget)
            }
        }

        if !keepFrames {
            try? FileManager.default.removeItem(at: framesDirectory)
        }
        removeEmptyLog(in: directory)
        if let progress {
            await progress(100)
        }

        return RenderReport(
            video: video,
            frames: stage.frames,
            width: stage.width,
            height: stage.height,
            fps: fps,
            duration: Double(stage.frames) / fps,
            hardware: stage.hardware,
            codec: codec,
            audio: audioReport,
            directory: directory,
            framesKept: keepFrames,
            effects: effects.count,
            objects: nil,
            transport: stage.transport
        )
    } catch {
        if error is RenderCancelled {
            try? FileManager.default.removeItem(at: framesDirectory)
            try? FileManager.default.removeItem(at: video)
            if encodeTarget != video {
                try? FileManager.default.removeItem(at: encodeTarget)
            }
        }
        throw error
    }
}

/// Vollständiger 3D-Lauf: SceneKit-Frames → Video → ggf. Ton.
///
/// Arbeitsverzeichnis ist `<artifacts>/<uuid>/`; die geprüfte Szene liegt als
/// `scene3d.json` daneben. Fortschritt und Abbruch verhalten sich wie bei
/// `renderVideo`: 0–40 % Frames, 40–95 % Encoding, 100 % am Ende. Ein
/// Subprozess-Zeitlimit wie bei render-mcp gibt es hier nicht, weil SceneKit im
/// eigenen Prozess rendert.
func render3D(
    scene source: Scene3DInput,
    name: String,
    keepFrames: Bool,
    output: URL?,
    codec: VideoCodec = .h264,
    audio: URL? = nil,
    effects: [EffectSpec] = [],
    progress: (@Sendable (Double) async -> Void)? = nil,
    isCancelled: (@Sendable () async -> Bool)? = nil
) async throws -> RenderReport {
    let scene = try source.decoded()

    // Eine defekte Audiodatei soll vor dem Rendern auffallen, nicht danach.
    var audioSource: AudioSource?
    if let audio {
        audioSource = try await validateAudioSource(audio)
    }

    Paths.prepare()
    let directory = Paths.artifacts.appendingPathComponent(UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        throw VideoError("Arbeitsverzeichnis lässt sich nicht anlegen: \(directory.path)")
    }

    _ = try source.materialize(in: directory)
    let framesDirectory = directory.appendingPathComponent("frames")

    let video = outputURL(
        output ?? directory.appendingPathComponent("\(safeName(name)).\(codec.fileExtension)"),
        codec: codec
    )
    let encodeTarget = audioSource == nil
        ? video
        : directory.appendingPathComponent("video-only.\(codec.fileExtension)")

    do {
        let stage: EncodeStage
        if keepFrames {
            // Wer die Frames behalten will, bekommt sie als PNG.
            let expected = try await render3DFrames(
                scene,
                into: framesDirectory,
                progress: progressMapper(progress, from: 0, to: 40),
                isCancelled: isCancelled
            )
            if await isCancelledNow(isCancelled) {
                throw RenderCancelled()
            }

            let frames = try frameFiles(in: framesDirectory)
            if frames.count != expected {
                throw VideoError(
                    "3D-Render meldet \(expected) Frames, im Verzeichnis liegen \(frames.count)"
                )
            }

            let encoded = try await encodeFrames(
                frames,
                width: scene.width,
                height: scene.height,
                fps: scene.fps,
                codec: codec,
                output: encodeTarget,
                effects: effects,
                progress: progressMapper(progress, from: 40, to: 95),
                isCancelled: isCancelled
            )
            stage = EncodeStage(
                frames: encoded.frames,
                width: scene.width,
                height: scene.height,
                fps: scene.fps,
                hardware: encoded.hardware,
                transport: "png"
            )
        } else {
            stage = try await encodeFromScene3D(
                scene,
                codec: codec,
                output: encodeTarget,
                effects: effects,
                progress: progress,
                isCancelled: isCancelled
            )
        }

        var audioReport: AudioReport?
        if let audioSource {
            audioReport = try await muxAudio(
                video: encodeTarget,
                source: audioSource,
                output: video,
                fileType: codec.fileType,
                fps: scene.fps
            )
            if encodeTarget != video {
                try? FileManager.default.removeItem(at: encodeTarget)
            }
        }

        if !keepFrames {
            try? FileManager.default.removeItem(at: framesDirectory)
        }
        removeEmptyLog(in: directory)
        if let progress {
            await progress(100)
        }

        return RenderReport(
            video: video,
            frames: stage.frames,
            width: scene.width,
            height: scene.height,
            fps: scene.fps,
            duration: Double(stage.frames) / scene.fps,
            hardware: stage.hardware,
            codec: codec,
            audio: audioReport,
            directory: directory,
            framesKept: keepFrames,
            effects: effects.count,
            objects: scene.objects.count,
            transport: stage.transport
        )
    } catch {
        if error is RenderCancelled {
            try? FileManager.default.removeItem(at: framesDirectory)
            try? FileManager.default.removeItem(at: video)
            if encodeTarget != video {
                try? FileManager.default.removeItem(at: encodeTarget)
            }
        }
        throw error
    }
}

/// Rendert eine 3D-Szene und encodiert im selben Durchlauf.
///
/// SceneKit liefert je Frame ein `CGImage`; es geht direkt in einen Puffer des
/// Encoders, ohne PNG-Datei dazwischen. Das spart Encode, Schreiben, Lesen und
/// Dekodieren je Frame.
func encodeFromScene3D(
    _ scene: Scene3D,
    codec: VideoCodec,
    output: URL,
    effects: [EffectSpec],
    progress: (@Sendable (Double) async -> Void)?,
    isCancelled: (@Sendable () async -> Bool)?
) async throws -> EncodeStage {
    let writer = try VideoWriter(
        width: scene.width,
        height: scene.height,
        fps: scene.fps,
        codec: codec,
        output: output
    )
    let chain = effects.isEmpty ? nil : EffectChain(specs: effects)
    var frames = 0
    do {
        try await render3DLoop(
            scene,
            progress: progressMapper(progress, from: 0, to: 95),
            isCancelled: isCancelled
        ) { index, image, _ in
            try await writer.waitUntilReady()
            let buffer = try writer.makeBuffer()
            let source = try chain?.apply(to: image) ?? image
            try drawFrame(source, into: buffer)
            try writer.append(buffer, index: index)
            frames = index + 1
        }
        try await writer.finish()
    } catch {
        writer.cancel()
        throw error
    }
    return EncodeStage(
        frames: frames,
        width: scene.width,
        height: scene.height,
        fps: scene.fps,
        hardware: writer.hardware,
        transport: "direct"
    )
}

/// Ergebnis der Frame- und Encoding-Phase, bevor Ton und Bericht entstehen.
struct EncodeStage: Sendable {
    let frames: Int
    let width: Int
    let height: Int
    let fps: Double
    let hardware: Bool?
    /// `shm` für den Ring, `direct` für 3D ohne Datei, `png` für den Dateiweg.
    let transport: String
}

/// Wie die Frames vom Renderer zum Encoder kommen.
enum FrameTransport: String, Sendable {
    /// Ring-Datei, ohne PNG-Dekodierung (Default).
    case shared = "shm"
    /// PNG-Dateien im Arbeitsverzeichnis.
    case png

    /// `VIDEO_FRAME_TRANSPORT=shm|png`; alles andere heißt „automatisch".
    static func resolve() -> FrameTransport {
        let raw = ProcessInfo.processInfo.environment["VIDEO_FRAME_TRANSPORT"] ?? ""
        return raw.lowercased() == "png" ? .png : .shared
    }
}

/// Zweiwege-Variante: Ring-Puffer versuchen, sonst auf PNG zurückfallen.
///
/// Ein älteres render-mcp ohne `--sink` wird erkannt (`FrameTransportUnsupported`)
/// und über den Dateiweg bedient, damit ein gemischter Stand nicht scheitert.
func encodeTwoPhase(
    binary: URL,
    scene: URL,
    framesDirectory: URL,
    directory: URL,
    expected: Int,
    header: SceneHeader,
    codec: VideoCodec,
    output: URL,
    effects: [EffectSpec],
    progress: (@Sendable (Double) async -> Void)?,
    isCancelled: (@Sendable () async -> Bool)?,
    budget: TimeInterval
) async throws -> EncodeStage {
    if FrameTransport.resolve() == .shared {
        do {
            return try await encodeFromRing(
                binary: binary,
                scene: scene,
                directory: directory,
                header: header,
                codec: codec,
                output: output,
                effects: effects,
                progress: progressMapper(progress, from: 0, to: 95),
                isCancelled: isCancelled,
                budget: budget
            )
        } catch is FrameTransportUnsupported {
            // Älteres Binary: der Dateiweg übernimmt.
        }
    }
    return try await encodeFromFiles(
        binary: binary,
        scene: scene,
        framesDirectory: framesDirectory,
        expected: expected,
        header: header,
        codec: codec,
        output: output,
        effects: effects,
        progress: progress,
        isCancelled: isCancelled,
        budget: budget
    )
}

/// Rendert über render-mcp in PNG-Dateien und encodiert sie danach.
func encodeFromFiles(
    binary: URL,
    scene: URL,
    framesDirectory: URL,
    expected: Int,
    header: SceneHeader,
    codec: VideoCodec,
    output: URL,
    effects: [EffectSpec],
    progress: (@Sendable (Double) async -> Void)?,
    isCancelled: (@Sendable () async -> Bool)?,
    budget: TimeInterval
) async throws -> EncodeStage {
    let summary = try await renderFrames(
        binary: binary,
        scene: scene,
        framesDirectory: framesDirectory,
        expectedFrames: expected,
        progress: progressMapper(progress, from: 0, to: 40),
        isCancelled: isCancelled,
        timeout: budget
    )

    let frames = try frameFiles(in: framesDirectory)
    if let reported = summary.frames, reported != frames.count {
        throw VideoError(
            "render-mcp meldet \(reported) Frames, im Verzeichnis liegen \(frames.count)"
        )
    }

    let width = summary.width ?? header.width
    let height = summary.height ?? header.height
    let fps = summary.fps ?? header.fps
    guard width > 0, height > 0, fps > 0 else {
        throw VideoError("Szene ohne gültige Auflösung oder Framerate")
    }
    if await isCancelledNow(isCancelled) {
        throw RenderCancelled()
    }

    let encoded = try await encodeFrames(
        frames,
        width: width,
        height: height,
        fps: fps,
        codec: codec,
        output: output,
        effects: effects,
        progress: progressMapper(progress, from: 40, to: 95),
        isCancelled: isCancelled
    )
    return EncodeStage(
        frames: encoded.frames,
        width: width,
        height: height,
        fps: fps,
        hardware: encoded.hardware,
        transport: "png"
    )
}

/// Rendert und encodiert gleichzeitig: render-mcp schreibt in den Ring, der
/// Encoder liest heraus.
///
/// Der Ring enthält rohe BGRA-Frames, deshalb entfällt die PNG-Dekodierung
/// (bei 4K rund 20 ms je Frame). Rendern und Encodieren überlappen, weil
/// render-mcp bis zu vier Frames vorausläuft; die Wandzeit ist damit das
/// Maximum beider Phasen statt ihrer Summe.
func encodeFromRing(
    binary: URL,
    scene: URL,
    directory: URL,
    header: SceneHeader,
    codec: VideoCodec,
    output: URL,
    effects: [EffectSpec],
    progress: (@Sendable (Double) async -> Void)?,
    isCancelled: (@Sendable () async -> Bool)?,
    budget: TimeInterval
) async throws -> EncodeStage {
    let stream = try FrameStream.start(
        binary: binary,
        scene: scene,
        width: header.width,
        height: header.height,
        directory: directory
    )

    let writer: VideoWriter
    do {
        writer = try VideoWriter(
            width: stream.header.width,
            height: stream.header.height,
            fps: stream.header.fps,
            codec: codec,
            output: output
        )
    } catch {
        stream.terminate()
        throw error
    }

    // Ohne Effekte wandert der Puffer unverändert in den Encoder.
    let chain = effects.isEmpty ? nil : EffectChain(specs: effects)
    let started = Date()
    var index = 0

    do {
        while let frameIndex = try stream.nextFrameIndex() {
            guard frameIndex == index else {
                throw VideoError(
                    "Frame-Reihenfolge gestört: erwartet \(index), gemeldet \(frameIndex)"
                )
            }
            if await isCancelledNow(isCancelled) {
                throw RenderCancelled()
            }
            if Date().timeIntervalSince(started) > budget {
                throw VideoError(
                    "Render-Lauf überschreitet das Zeitlimit von \(timeoutText(budget)) s"
                )
            }

            try await writer.waitUntilReady()
            let source = try writer.makeBuffer()
            CVPixelBufferLockBaseAddress(source, [])
            guard let base = CVPixelBufferGetBaseAddress(source) else {
                CVPixelBufferUnlockBaseAddress(source, [])
                throw VideoError("Pixelpuffer ohne Basisadresse bei Frame \(index)")
            }
            do {
                try stream.readFrame(
                    index: index,
                    into: base,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(source)
                )
            } catch {
                CVPixelBufferUnlockBaseAddress(source, [])
                throw error
            }
            CVPixelBufferUnlockBaseAddress(source, [])

            let frame: CVPixelBuffer
            if let chain {
                let target = try writer.makeBuffer()
                try chain.apply(to: source, into: target)
                frame = target
            } else {
                frame = source
            }
            try writer.append(frame, index: index)
            stream.release()
            index += 1

            if let progress, stream.header.frames > 0 {
                let share = min(Double(index) / Double(stream.header.frames), 1)
                await progress(share)
            }
        }
    } catch {
        stream.terminate()
        writer.cancel()
        throw error
    }

    do {
        try stream.finish()
        try await writer.finish()
    } catch {
        writer.cancel()
        throw error
    }

    guard index == stream.header.frames else {
        throw VideoError(
            "render-mcp meldet \(stream.header.frames) Frames, gelesen wurden \(index)"
        )
    }

    return EncodeStage(
        frames: index,
        width: stream.header.width,
        height: stream.header.height,
        fps: stream.header.fps,
        hardware: writer.hardware,
        transport: "shm"
    )
}

/// Entfernt die stderr-/stdout-Logs, wenn render-mcp nichts gemeldet hat.
func removeEmptyLog(in directory: URL) {
    for name in ["render-stderr.log", "render-stdout.log"] {
        let log = directory.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: log.path),
              let size = attributes[.size] as? NSNumber, size.intValue == 0
        else { continue }
        try? FileManager.default.removeItem(at: log)
    }
}
