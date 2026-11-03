// StreamSource.swift — Frames ohne PNG-Umweg aus render-mcp übernehmen.
//
// `render-mcp --sink shm` schreibt rohe BGRA-Frames in eine vorab angelegte
// Ring-Datei. Diese Datei legt video-mcp an (`slots × Framegröße`), render-mcp
// schreibt hinein, video-mcp liest heraus. Die Zeilen auf stdout sind der
// Takt: eine Kopfzeile mit der Geometrie, danach eine Zeile je fertigem Frame.
// Ein Byte auf stdin gibt jeweils einen Platz wieder frei, damit render-mcp
// höchstens `slots` Frames vorausläuft.
//
// Warum: eine PNG-Dekodierung kostet bei 4K rund 20 ms je Frame, das Kopieren
// aus dem Ring unter 1 ms. Gemessen auf einem M2 Pro.

import Darwin
import Foundation

/// Vorgabe für die Zahl gleichzeitig belegter Frames.
///
/// Vier Plätze reichen, damit Rendern und Encodieren überlappen; bei 4K sind
/// das 132 MiB, bei 1080p 33 MiB.
let frameRingSlots = 4

/// Kopfzeile von render-mcp (`{"kind":"frames",…}`).
struct StreamHeader: Decodable, Sendable {
    let kind: String
    let frames: Int
    let width: Int
    let height: Int
    let fps: Double
    let duration: Double
    let pixelFormat: String
    let rowBytes: Int
    let frameBytes: Int
    let slots: Int
}

/// Eine Zeile je geschriebenem Frame.
private struct StreamFrameLine: Decodable {
    let kind: String
    let index: Int
}

/// Signal, dass das installierte render-mcp die Ring-Senke nicht kennt.
///
/// Der Aufrufer fällt dann auf PNG-Frames zurück, statt den Lauf abzubrechen.
struct FrameTransportUnsupported: Error, Sendable {}

/// Laufender Frame-Strom aus render-mcp.
///
/// Die Klasse liest blockierend; sie wird aus der Encoding-Schleife benutzt,
/// die ohnehin synchron arbeitet. `readFrame` und `release` gehören zusammen:
/// erst lesen, dann encodieren, dann freigeben.
final class FrameStream {
    private(set) var header: StreamHeader
    private let process: Process
    private let stdoutHandle: FileHandle
    private let stdinHandle: FileHandle
    private let ringHandle: FileHandle
    private let ringURL: URL
    private let stderrLog: URL
    private let stderrHandle: FileHandle
    private let width: Int
    private let height: Int
    private let manager = FileManager.default
    private var pending = Data()
    private var scratch: [UInt8] = []
    private var closed = false

    /// Startet render-mcp und liest die Kopfzeile.
    ///
    /// `width`/`height` stammen aus der geprüften Szene; sie bestimmen die
    /// Größe der Ring-Datei. Schlägt der Start fehl oder antwortet das Binary
    /// ohne Kopfzeile, wird der Prozess beendet und der Fehler geworfen.
    static func start(
        binary: URL,
        scene: URL,
        width: Int,
        height: Int,
        directory: URL,
        slots: Int = frameRingSlots
    ) throws -> FrameStream {
        let frameBytes = width * 4 * height
        guard width > 0, height > 0, frameBytes > 0 else {
            throw VideoError("Szene ohne gültige Auflösung für den Frame-Ring")
        }
        let manager = FileManager.default
        let ringURL = directory.appendingPathComponent("frames.bin")
        try? manager.removeItem(at: ringURL)
        guard manager.createFile(atPath: ringURL.path, contents: nil) else {
            throw VideoError("Ring-Datei lässt sich nicht anlegen: \(ringURL.path)")
        }
        do {
            let handle = try FileHandle(forUpdating: ringURL)
            try handle.truncate(atOffset: UInt64(frameBytes * slots))
            try handle.close()
        } catch {
            throw VideoError(
                "Ring-Datei lässt sich nicht vorbereiten: \(error.localizedDescription)"
            )
        }

        let stderrLog = directory.appendingPathComponent("render-stderr.log")
        _ = manager.createFile(atPath: stderrLog.path, contents: nil)
        guard let stderrHandle = FileHandle(forWritingAtPath: stderrLog.path) else {
            throw VideoError("Log-Datei lässt sich nicht öffnen: \(stderrLog.path)")
        }

        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--scene", scene.path,
            "--sink", "shm",
            "--shm", ringURL.path,
            "--slots", String(slots),
        ]
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? stderrHandle.close()
            throw VideoError(
                "render-mcp startet nicht (\(binary.path)): \(error.localizedDescription)"
            )
        }
        ChildProcesses.register(process.processIdentifier)

        let ringHandle: FileHandle
        do {
            ringHandle = try FileHandle(forUpdating: ringURL)
        } catch {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            ChildProcesses.unregister(process.processIdentifier)
            throw VideoError(
                "Ring-Datei lässt sich nicht öffnen: \(error.localizedDescription)"
            )
        }

        let stream = FrameStream(
            process: process,
            stdoutHandle: stdoutPipe.fileHandleForReading,
            stdinHandle: stdinPipe.fileHandleForWriting,
            ringHandle: ringHandle,
            ringURL: ringURL,
            stderrLog: stderrLog,
            stderrHandle: stderrHandle,
            width: width,
            height: height,
            slots: slots
        )
        do {
            stream.header = try stream.readHeader()
        } catch {
            let usage = stream.usageError()
            stream.terminate()
            if usage { throw FrameTransportUnsupported() }
            throw error
        }
        return stream
    }

    /// Nur über `start` erzeugen.
    private init(
        process: Process,
        stdoutHandle: FileHandle,
        stdinHandle: FileHandle,
        ringHandle: FileHandle,
        ringURL: URL,
        stderrLog: URL,
        stderrHandle: FileHandle,
        width: Int,
        height: Int,
        slots: Int
    ) {
        self.process = process
        self.stdoutHandle = stdoutHandle
        self.stdinHandle = stdinHandle
        self.ringHandle = ringHandle
        self.ringURL = ringURL
        self.stderrLog = stderrLog
        self.stderrHandle = stderrHandle
        self.width = width
        self.height = height
        header = StreamHeader(
            kind: "frames",
            frames: 0,
            width: width,
            height: height,
            fps: 0,
            duration: 0,
            pixelFormat: "bgra8",
            rowBytes: width * 4,
            frameBytes: width * 4 * height,
            slots: slots
        )
    }

    /// Kopfzeile lesen und gegen die Szene prüfen.
    private func readHeader() throws -> StreamHeader {
        guard let line = try readLine() else {
            throw VideoError(
                "render-mcp liefert keine Kopfzeile: \(errorDetail(from: stderrLog))"
            )
        }
        guard let data = line.data(using: .utf8),
              let streamHeader = try? JSONDecoder().decode(StreamHeader.self, from: data),
              streamHeader.kind == "frames"
        else {
            throw VideoError("render-mcp-Kopfzeile nicht lesbar: \(line)")
        }
        guard streamHeader.pixelFormat == "bgra8" else {
            throw VideoError("unbekanntes Frame-Format: \(streamHeader.pixelFormat)")
        }
        guard streamHeader.width == width, streamHeader.height == height,
              streamHeader.rowBytes == width * 4,
              streamHeader.frameBytes == width * 4 * height
        else {
            throw VideoError(
                "Frame-Geometrie passt nicht zur Szene: "
                    + "\(streamHeader.width)x\(streamHeader.height), "
                    + "\(streamHeader.frameBytes) Byte je Frame"
            )
        }
        guard streamHeader.slots == header.slots else {
            throw VideoError(
                "Ring meldet \(streamHeader.slots) Plätze, angelegt waren \(header.slots)"
            )
        }
        return streamHeader
    }

    /// Index des nächsten fertigen Frames; `nil`, wenn render-mcp fertig ist.
    func nextFrameIndex() throws -> Int? {
        guard let line = try readLine() else { return nil }
        guard let data = line.data(using: .utf8),
              let frame = try? JSONDecoder().decode(StreamFrameLine.self, from: data),
              frame.kind == "frame"
        else {
            throw VideoError("unbekannte Zeile von render-mcp: \(line)")
        }
        return frame.index
    }

    /// Liest die Pixel eines Frames in den Zielpuffer.
    ///
    /// `bytesPerRow` kommt vom Zielpuffer: CVPixelBuffer richtet Zeilen auf
    /// 64 Byte aus, bei Breiten, die nicht auf 16 Pixel fallen, entsteht
    /// Auffüllung. Dann läuft der Umweg über einen Zwischenpuffer und kopiert
    /// Zeile für Zeile.
    func readFrame(
        index: Int,
        into destination: UnsafeMutableRawPointer,
        bytesPerRow: Int
    ) throws {
        let offset = off_t((index % header.slots) * header.frameBytes)
        if bytesPerRow == header.rowBytes {
            try readExactly(into: destination, offset: offset)
            return
        }
        if scratch.count != header.frameBytes {
            scratch = [UInt8](repeating: 0, count: header.frameBytes)
        }
        try scratch.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw VideoError("Zwischenpuffer fehlt bei Frame \(index)")
            }
            try readExactly(into: base, offset: offset)
        }
        guard bytesPerRow > header.rowBytes else {
            throw VideoError(
                "Zielpuffer hat \(bytesPerRow) Byte je Zeile, der Frame braucht \(header.rowBytes)"
            )
        }
        for row in 0..<header.height {
            memcpy(
                destination.advanced(by: row * bytesPerRow),
                scratch.withUnsafeBytes { $0.baseAddress!.advanced(by: row * header.rowBytes) },
                header.rowBytes
            )
        }
    }

    /// Liest `frameBytes` ab `offset` vollständig nach `destination`.
    private func readExactly(into destination: UnsafeMutableRawPointer, offset: off_t) throws {
        var filled = 0
        while filled < header.frameBytes {
            let count = pread(
                ringHandle.fileDescriptor,
                destination.advanced(by: filled),
                header.frameBytes - filled,
                offset + off_t(filled)
            )
            if count <= 0 {
                throw VideoError(
                    "Frame ist nicht lesbar (Status \(count)): \(errorDetail(from: stderrLog))"
                )
            }
            filled += count
        }
    }

    /// Gibt einen Platz für den Renderer frei.
    func release() {
        var byte: UInt8 = 0x66 // "f"
        _ = withUnsafeBytes(of: &byte) { raw in
            Darwin.write(stdinHandle.fileDescriptor, raw.baseAddress, 1)
        }
    }

    /// Wartet auf das Ende von render-mcp und räumt die Ring-Datei ab.
    func finish() throws {
        guard !closed else { return }
        closed = true
        try? stdinHandle.close()
        process.waitUntilExit()
        ChildProcesses.unregister(process.processIdentifier)
        try? stderrHandle.close()
        try? stdoutHandle.close()
        try? ringHandle.close()
        try? manager.removeItem(at: ringURL)
        guard process.terminationStatus == 0 else {
            throw VideoError(
                "render-mcp endet mit Status \(process.terminationStatus): "
                    + errorDetail(from: stderrLog)
            )
        }
    }

    /// Bricht den Lauf ab: SIGTERM, 500 ms Frist, danach SIGKILL.
    func terminate() {
        guard !closed else { return }
        closed = true
        let pid = process.processIdentifier
        if pid > 0 {
            kill(pid, SIGTERM)
            for _ in 0..<5 {
                if !process.isRunning { break }
                usleep(100_000)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
                usleep(50_000)
            }
        }
        process.waitUntilExit()
        ChildProcesses.unregister(pid)
        try? stdinHandle.close()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        try? ringHandle.close()
        try? manager.removeItem(at: ringURL)
    }

    // MARK: - Zeilen lesen

    /// Liest eine Zeile ohne Zeilenende; `nil` am Ende des Stroms.
    private func readLine() throws -> String? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[pending.index(after: newline)...]
                let text = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                return text
            }
            var byte: UInt8 = 0
            let count = Darwin.read(stdoutHandle.fileDescriptor, &byte, 1)
            if count < 0 {
                throw VideoError("stdout von render-mcp ist nicht lesbar (Status \(count))")
            }
            if count == 0 {
                if pending.isEmpty { return nil }
                let text = String(decoding: pending, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                pending.removeAll()
                return text.isEmpty ? nil : text
            }
            pending.append(byte)
        }
    }

    /// Erkennt den Fall „Binary kennt --sink nicht" für den PNG-Rückfall.
    private func usageError() -> Bool {
        let text = (try? String(contentsOf: stderrLog, encoding: .utf8)) ?? ""
        return text.contains("unbekannte Option") || text.contains("unbekannte Senke")
    }
}
