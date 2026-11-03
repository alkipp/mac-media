// Encoder.swift — PNG-Frames über AVAssetWriter schreiben.
//
// H.264 und HEVC bekommen die VideoToolbox-Spezifikation für den
// Hardware-Encoder; ProRes rechnet die CPU. Die Pixel laufen über einen
// `AVAssetWriterInputPixelBufferAdaptor` in BGRA-Puffer.
//
// Der Fortschritt der Encoding-Phase wird als Anteil 0…1 gemeldet; die globale
// Einordnung (40–95 %) macht `RenderPipeline.swift`.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// Ergebnis eines Encoding-Laufs.
struct EncodeReport: Sendable {
    let frames: Int
    /// `nil`, wenn sich die Hardware-Nutzung nicht ermitteln lässt.
    let hardware: Bool?
}

/// Ausgabeeinstellungen des Writers.
///
/// `hardware` setzt die VideoToolbox-Spezifikation; sie gilt nur für H.264 und
/// HEVC. `bitrate` lässt sich abschalten, wenn der Writer die Kombination aus
/// Codec und Bitrate nicht annimmt.
func videoSettings(
    codec: VideoCodec,
    width: Int,
    height: Int,
    fps: Double,
    hardware: Bool = true,
    bitrate: Bool = true
) -> [String: Any] {
    var compression: [String: Any] = [
        AVVideoExpectedSourceFrameRateKey: max(Int(fps.rounded()), 1)
    ]
    if bitrate {
        compression[AVVideoAverageBitRateKey] = codec.bitrate(
            width: width,
            height: height,
            fps: fps
        )
    }
    switch codec {
    case .h264:
        compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        compression[AVVideoMaxKeyFrameIntervalKey] = max(Int(fps.rounded()) * 2, 2)
        compression[AVVideoAllowFrameReorderingKey] = false
    case .hevc:
        compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        compression[AVVideoMaxKeyFrameIntervalKey] = max(Int(fps.rounded()) * 2, 2)
        compression[AVVideoAllowFrameReorderingKey] = false
    case .prores422, .prores4444:
        // ProRes bringt Profil und Datenrate selbst mit; keine GOP-Vorgaben.
        break
    }

    let color: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
    var settings: [String: Any] = [
        AVVideoCodecKey: codec.avCodec,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: compression,
        AVVideoColorPropertiesKey: color,
    ]
    if hardware, codec.usesHardware {
        settings[AVVideoEncoderSpecificationKey] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
        ]
    }
    return settings
}

/// Einstellungen in absteigender Ausführlichkeit: mit Hardware-Vorgabe, ohne
/// Hardware-Vorgabe und zuletzt ohne Bitrate.
func settingsCandidates(
    codec: VideoCodec,
    width: Int,
    height: Int,
    fps: Double
) -> [(settings: [String: Any], hardware: Bool)] {
    var candidates: [(settings: [String: Any], hardware: Bool)] = []
    if codec.usesHardware {
        candidates.append((
            settings: videoSettings(
                codec: codec,
                width: width,
                height: height,
                fps: fps,
                hardware: true
            ),
            hardware: true
        ))
        candidates.append((
            settings: videoSettings(
                codec: codec,
                width: width,
                height: height,
                fps: fps,
                hardware: false
            ),
            hardware: false
        ))
    } else {
        candidates.append((
            settings: videoSettings(
                codec: codec,
                width: width,
                height: height,
                fps: fps,
                hardware: false
            ),
            hardware: false
        ))
    }
    candidates.append((
        settings: videoSettings(
            codec: codec,
            width: width,
            height: height,
            fps: fps,
            hardware: false,
            bitrate: false
        ),
        hardware: false
    ))
    return candidates
}

/// Text zur Fehlerursache eines Writers.
func writerErrorText(_ writer: AVAssetWriter) -> String {
    if let error = writer.error {
        return error.localizedDescription
    }
    return "Status \(writer.status.rawValue)"
}

/// Lädt ein PNG als `CGImage`.
func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw VideoError("PNG nicht lesbar: \(url.lastPathComponent)")
    }
    return image
}

/// Zeichnet das Bild bildfüllend in einen BGRA-Pixelpuffer.
func drawFrame(_ image: CGImage, into buffer: CVPixelBuffer) throws {
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw VideoError("Pixelpuffer lässt sich nicht sperren")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let context = CGContext(
              data: base,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                  | CGBitmapInfo.byteOrder32Little.rawValue
          )
    else {
        throw VideoError("Pixelpuffer lässt sich nicht beschreiben")
    }
    // Frames kommen in Szenengröße; abweichende PNGs werden skaliert.
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

/// Fragt VideoToolbox, ob sie für diese Parameter den Hardware-Encoder nimmt.
///
/// `AVAssetWriter` legt den benutzten Encoder nicht offen. Der Writer erhält die
/// Hardware-Vorgabe über die Encoder-Spezifikation; ob VideoToolbox sie für
/// dieselbe Auflösung und Framerate einlöst, beantwortet eine kurze Sitzung mit
/// zwei Frames, deren Ausgabe verworfen wird.
func hardwareSelection(codec: VideoCodec, width: Int, height: Int, fps: Double) -> Bool? {
    guard let codecType = codec.cmCodecType else { return nil }
    let specification: [String: Any] = [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
    ]
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]

    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: Int32(width),
        height: Int32(height),
        codecType: codecType,
        encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: attributes as CFDictionary,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &session
    )
    guard status == noErr, let session else { return nil }
    defer { VTCompressionSessionInvalidate(session) }

    var buffer: CVPixelBuffer?
    let bufferStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary,
        &buffer
    )
    guard bufferStatus == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

    for frame in 0..<2 {
        let time = CMTime(seconds: Double(frame) / max(fps, 1), preferredTimescale: 60000)
        // Ausgabe wird verworfen; es zählt nur, welchen Encoder VideoToolbox wählt.
        _ = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { _, _, _ in }
    }
    _ = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

    var value: CFTypeRef?
    let propertyStatus = VTSessionCopyProperty(
        session,
        key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
        allocator: kCFAllocatorDefault,
        valueOut: &value
    )
    guard propertyStatus == noErr else { return nil }
    return value as? Bool
}

/// Schreibt Frames über `AVAssetWriter`; gemeinsam genutzt von der PNG-Pipeline
/// (3D) und der Ring-Pipeline (2D).
///
/// Der Writer wird einmal angelegt und nimmt Frames über den Pixelpuffer-Pool
/// entgegen. `append` erwartet fortlaufende Indizes ab 0; `finish` schließt die
/// Datei ab, `cancel` verwirft sie.
final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Double
    private let timescale: CMTimeScale = 60000
    private let output: URL

    /// Ob VideoToolbox den Hardware-Encoder nimmt; `nil` heißt unbekannt.
    let hardware: Bool?
    let width: Int
    let height: Int

    init(width: Int, height: Int, fps: Double, codec: VideoCodec, output: URL) throws {
        guard width > 0, height > 0, fps > 0 else {
            throw VideoError("Szene ohne gültige Auflösung oder Framerate")
        }
        try? FileManager.default.removeItem(at: output)
        let target = output.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw VideoError("Zielverzeichnis lässt sich nicht anlegen: \(target.path)")
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: codec.fileType)
        } catch {
            throw VideoError(
                "AVAssetWriter lässt sich nicht anlegen: \(error.localizedDescription)"
            )
        }

        let candidates = settingsCandidates(codec: codec, width: width, height: height, fps: fps)
        guard let chosen = candidates.first(where: {
            writer.canApply(outputSettings: $0.settings, forMediaType: .video)
        }) else {
            throw VideoError("AVAssetWriter nimmt die Einstellungen für \(codec.name) nicht an")
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: chosen.settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )

        guard writer.canAdd(input) else {
            throw VideoError("AVAssetWriter nimmt die Video-Spur nicht an")
        }
        writer.add(input)

        // ProRes ist Software; bei H.264/HEVC entscheidet VideoToolbox.
        let hardware: Bool?
        if codec.usesHardware {
            hardware = chosen.hardware
                ? hardwareSelection(codec: codec, width: width, height: height, fps: fps)
                : nil
        } else {
            hardware = false
        }

        guard writer.startWriting() else {
            throw VideoError("AVAssetWriter startet nicht: \(writerErrorText(writer))")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.hardware = hardware
        self.width = width
        self.height = height
        self.fps = fps
        self.output = output
    }

    /// Ein leerer Puffer aus dem Pool des Writers.
    func makeBuffer() throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw VideoError("kein Pixelpuffer-Pool für \(width)x\(height)")
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw VideoError("Pixelpuffer fehlt (Status \(status))")
        }
        return buffer
    }

    /// Wartet, bis der Writer den nächsten Frame annimmt.
    func waitUntilReady() async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing {
                throw VideoError("AVAssetWriter bricht ab: \(writerErrorText(writer))")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Hängt einen Puffer mit der Zeitachse `index / fps` an.
    func append(_ buffer: CVPixelBuffer, index: Int) throws {
        let time = CMTime(seconds: Double(index) / fps, preferredTimescale: timescale)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw VideoError(
                "Frame \(index) lässt sich nicht anhängen: \(writerErrorText(writer))"
            )
        }
    }

    /// Schließt die Datei ab.
    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoError("AVAssetWriter bricht ab: \(writerErrorText(writer))")
        }
    }

    /// Verwirft den Lauf und entfernt die halbe Datei.
    func cancel() {
        input.markAsFinished()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: output)
    }
}

/// Schreibt die PNG-Frames im gewählten Codec nach `output`.
///
/// `effects` wird in Reihenfolge auf jeden Frame angewandt, bevor er in den
/// Pixelpuffer geht; ohne Effekte bleibt der Frame unverändert. `progress`
/// meldet den Anteil 0…1 der Encoding-Phase, `isCancelled` wird vor jedem Frame
/// gefragt. Bei Abbruch wird der Writer verworfen und die Datei entfernt.
func encodeFrames(
    _ frames: [URL],
    width: Int,
    height: Int,
    fps: Double,
    codec: VideoCodec,
    output: URL,
    effects: [EffectSpec] = [],
    progress: (@Sendable (Double) async -> Void)? = nil,
    isCancelled: (@Sendable () async -> Bool)? = nil
) async throws -> EncodeReport {
    guard !frames.isEmpty else {
        throw VideoError("keine Frames zum Encodieren")
    }
    let writer = try VideoWriter(
        width: width,
        height: height,
        fps: fps,
        codec: codec,
        output: output
    )

    // Ohne Effekte entsteht keine Kette: der Frame bleibt byte-gleich.
    let chain = effects.isEmpty ? nil : EffectChain(specs: effects)

    do {
        for (index, file) in frames.enumerated() {
            if await isCancelledNow(isCancelled) {
                writer.cancel()
                throw RenderCancelled()
            }
            try await writer.waitUntilReady()

            let picked = try writer.makeBuffer()
            let loaded = try loadImage(file)
            let image = try chain?.apply(to: loaded) ?? loaded
            try drawFrame(image, into: picked)
            try writer.append(picked, index: index)

            if let progress {
                await progress(Double(index + 1) / Double(frames.count))
            }
        }
    } catch {
        if error is RenderCancelled {
            throw error
        }
        writer.cancel()
        throw error
    }

    try await writer.finish()
    return EncodeReport(frames: frames.count, hardware: writer.hardware)
}
