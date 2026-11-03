// HardwareEncode.swift — H.264-Encoding über VideoToolbox mit erzwungener
// Hardware-Beschleunigung. Nach dem Lauf meldet die Session, ob der
// Hardware-Encoder tatsächlich verwendet wurde.

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import MCP
import VideoToolbox

/// Ergebnis eines Hardware-Encode-Laufs.
struct HardwareEncodeResult {
    let path: URL
    let bytes: Int
    let sha256: String
    /// `nil`, wenn VideoToolbox keine Auskunft gibt.
    let hardware: Bool?
}

/// Serialisiert das Anhängen der komprimierten Frames an den Writer.
final class EncoderSink: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let lock = NSLock()

    init(input: AVAssetWriterInput) {
        self.input = input
    }

    func append(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }
        input.append(sample)
    }
}

/// Füllt einen Pixelpuffer mit einer Farbe und einem wandernden Kreis.
func fillFrame(_ buffer: CVPixelBuffer, frame: Int, frames: Int) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        return
    }
    let progress = CGFloat(frame) / CGFloat(max(frames - 1, 1))
    context.setFillColor(CGColor(red: progress, green: 0.25, blue: 1 - progress, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    let radius = CGFloat(min(width, height)) / 8
    let x = radius + progress * (CGFloat(width) - 2 * radius)
    context.fillEllipse(in: CGRect(x: x - radius, y: CGFloat(height) / 2 - radius, width: 2 * radius, height: 2 * radius))
}

/// Encodiert ein Testvideo über VTCompressionSession (Hardware erzwungen).
func encodeTestVideo(
    width: Int,
    height: Int,
    frames: Int,
    fps: Int32,
    output: URL
) async throws -> HardwareEncodeResult {
    try? FileManager.default.removeItem(at: output)

    // Passthrough in MP4 braucht einen Format-Hinweis, sonst wirft AVFoundation.
    var formatHint: CMFormatDescription?
    CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: kCMVideoCodecType_H264,
        width: Int32(width),
        height: Int32(height),
        extensions: nil,
        formatDescriptionOut: &formatHint
    )

    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: nil,
        sourceFormatHint: formatHint
    )
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    guard writer.startWriting() else {
        throw MCPError.internalError("Writer startet nicht: \(String(describing: writer.error))")
    }
    writer.startSession(atSourceTime: .zero)

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
        codecType: kCMVideoCodecType_H264,
        encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: attributes as CFDictionary,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &session
    )
    guard status == noErr, let session else {
        throw MCPError.internalError("VTCompressionSessionCreate: \(status)")
    }
    defer { VTCompressionSessionInvalidate(session) }

    guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
        throw MCPError.internalError("kein Pixelpuffer-Pool")
    }

    let sink = EncoderSink(input: input)
    let duration = CMTime(value: 1, timescale: fps)

    for frame in 0..<frames {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixelBuffer = buffer else {
            throw MCPError.internalError("Pixelpuffer fehlt")
        }
        fillFrame(pixelBuffer, frame: frame, frames: frames)

        let time = CMTime(value: CMTimeValue(frame), timescale: fps)
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            sink.append(sampleBuffer)
        }
        if encodeStatus != noErr {
            throw MCPError.internalError("EncodeFrame: \(encodeStatus)")
        }
    }

    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

    var hardwareValue: CFTypeRef?
    let propertyStatus = VTSessionCopyProperty(
        session,
        key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
        allocator: kCFAllocatorDefault,
        valueOut: &hardwareValue
    )
    let hardware = propertyStatus == noErr ? (hardwareValue as? Bool) : nil

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw MCPError.internalError("Writer: \(String(describing: writer.error))")
    }

    let data = try Data(contentsOf: output)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return HardwareEncodeResult(
        path: output,
        bytes: data.count,
        sha256: digest,
        hardware: hardware
    )
}
