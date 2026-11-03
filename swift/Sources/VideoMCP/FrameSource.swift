// FrameSource.swift — Frames über das Rust-Backend render-mcp erzeugen.
//
// render-mcp läuft als Subprozess (kein MCP-Client nötig):
//
//   render-mcp --scene <szene.json> --frames-dir <verzeichnis>
//
// Es schreibt frame-0000.png, frame-0001.png … und meldet auf stdout eine
// JSON-Zeile mit frames, width, height, fps, duration und dir.

import Darwin
import Foundation

/// Auffindbares render-mcp samt Herkunft des Pfads.
struct RenderBinary: Sendable {
    let url: URL?
    /// Herkunft bei Fund, sonst der Grund des Fehlschlags.
    let source: String

    /// Zeile für `info`.
    var text: String {
        guard let url else {
            return "nicht gefunden (\(source))"
        }
        return "\(url.path) (gefunden: \(source))"
    }

    /// Reihenfolge: `RENDER_MCP_BIN`, `.../bin/render-mcp`, `PATH`. Ein gesetzter,
    /// aber unbrauchbarer `RENDER_MCP_BIN` wird gemeldet statt still übersprungen.
    static func locate() -> RenderBinary {
        let environment = ProcessInfo.processInfo.environment

        if let raw = environment["RENDER_MCP_BIN"] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let url = URL(fileURLWithPath: trimmed).standardizedFileURL
                if isExecutable(url) {
                    return RenderBinary(url: url, source: "RENDER_MCP_BIN")
                }
                return RenderBinary(
                    url: nil,
                    source: "RENDER_MCP_BIN=\(trimmed) ist nicht ausführbar"
                )
            }
        }

        let bundled = Paths.base.appendingPathComponent("bin/render-mcp")
        if isExecutable(bundled) {
            return RenderBinary(url: bundled, source: "bin/")
        }

        if let found = fromPath("render-mcp") {
            return RenderBinary(url: found, source: "PATH")
        }

        return RenderBinary(
            url: nil,
            source: "RENDER_MCP_BIN, .../bin/render-mcp und PATH ohne Treffer"
        )
    }

    static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Sucht ein ausführbares Programm in `PATH`.
    static func fromPath(_ name: String) -> URL? {
        let entries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
        for entry in entries {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent(name)
            if isExecutable(candidate) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }
}

/// Ergebniszeile von render-mcp; alle Felder sind optional, weil die Szene
/// selbst die Rückfallebene für width, height und fps ist.
struct RenderSummary: Decodable, Sendable {
    let frames: Int?
    let width: Int?
    let height: Int?
    let fps: Double?
    let duration: Double?
    let dir: String?
}

/// Vorgabe des Zeitlimits für einen render-mcp-Lauf in Sekunden.
let renderTimeoutDefault: TimeInterval = 600

/// Zeitlimit aus `RENDER_TIMEOUT_S`; fehlende oder unbrauchbare Werte ergeben
/// 600 s. Nur positive, endliche Zahlen werden übernommen.
func renderTimeoutFromEnvironment() -> TimeInterval {
    guard let raw = ProcessInfo.processInfo.environment["RENDER_TIMEOUT_S"] else {
        return renderTimeoutDefault
    }
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard let value = Double(trimmed), value.isFinite, value > 0 else {
        return renderTimeoutDefault
    }
    return value
}

/// Wirksames Zeitlimit: ein ausdrücklicher Wert hat Vorrang vor der Umgebung.
func resolveRenderTimeout(_ explicit: TimeInterval?) -> TimeInterval {
    guard let explicit, explicit.isFinite, explicit > 0 else {
        return renderTimeoutFromEnvironment()
    }
    return explicit
}

/// Sekunden in Meldungen: `600`, `12.5`.
func timeoutText(_ seconds: TimeInterval) -> String {
    let rounded = seconds.rounded()
    if abs(seconds - rounded) < 0.001, abs(rounded) < 1e15 {
        return String(Int(rounded))
    }
    return String(format: "%.1f", seconds)
}

/// Erzeugt die PNG-Frames und liefert die von render-mcp gemeldeten Werte.
///
/// `progress` meldet den Anteil 0…1 der Renderphase (gezählte Frames im
/// Zielverzeichnis), `isCancelled` wird alle 250 ms gefragt. Bei Abbruch bekommt
/// render-mcp SIGTERM, nach 500 ms SIGKILL, und das Frame-Verzeichnis wird
/// entfernt. `timeout` begrenzt die Laufzeit des Subprozesses in Sekunden
/// (Default aus `RENDER_TIMEOUT_S`, sonst 600); bei Überschreitung wird
/// render-mcp beendet, das Frame-Verzeichnis entfernt und ein `VideoError`
/// geworfen.
func renderFrames(
    binary: URL,
    scene: URL,
    framesDirectory: URL,
    expectedFrames: Int,
    progress: (@Sendable (Double) async -> Void)? = nil,
    isCancelled: (@Sendable () async -> Bool)? = nil,
    timeout: TimeInterval? = nil
) async throws -> RenderSummary {
    // Ein Budget für den gesamten Lauf; die Uhr startet, sobald render-mcp läuft.
    let budget = resolveRenderTimeout(timeout)
    let manager = FileManager.default
    try? manager.removeItem(at: framesDirectory)
    do {
        try manager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
    } catch {
        throw VideoError("Frame-Verzeichnis lässt sich nicht anlegen: \(framesDirectory.path)")
    }

    // stdout und stderr in Dateien: kein Pipe-Puffer kann den Lauf blockieren,
    // und stdout trägt ausschließlich die JSON-Zeile.
    let workspace = framesDirectory.deletingLastPathComponent()
    let stdoutLog = workspace.appendingPathComponent("render-stdout.log")
    let stderrLog = workspace.appendingPathComponent("render-stderr.log")
    _ = manager.createFile(atPath: stdoutLog.path, contents: nil)
    _ = manager.createFile(atPath: stderrLog.path, contents: nil)
    guard let stdoutHandle = FileHandle(forWritingAtPath: stdoutLog.path),
          let stderrHandle = FileHandle(forWritingAtPath: stderrLog.path)
    else {
        throw VideoError("Log-Dateien lassen sich nicht öffnen: \(workspace.path)")
    }
    defer {
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    let process = Process()
    process.executableURL = binary
    process.arguments = ["--scene", scene.path, "--frames-dir", framesDirectory.path]
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    // Der Handler setzt die Marke auch dann, wenn `isRunning` hängt.
    let exitFlag = ExitFlag()
    process.terminationHandler = { _ in exitFlag.mark() }

    do {
        try process.run()
    } catch {
        throw VideoError("render-mcp startet nicht (\(binary.path)): \(error.localizedDescription)")
    }
    let pid = process.processIdentifier
    ChildProcesses.register(pid)
    defer { ChildProcesses.unregister(pid) }

    // Fortschritt der Renderphase: Frames zählen, solange render-mcp läuft.
    let start = Date()
    while process.isRunning && !exitFlag.isDone {
        if await isCancelledNow(isCancelled) {
            await terminateChild(process)
            try? manager.removeItem(at: framesDirectory)
            throw RenderCancelled()
        }
        // Ein gemeinsames Zeitbudget für den ganzen Lauf; erreicht es das Ende,
        // endet render-mcp wie bei einem Abbruch.
        if Date().timeIntervalSince(start) > budget {
            await terminateChild(process)
            try? manager.removeItem(at: framesDirectory)
            throw VideoError(
                "render-mcp überschreitet das Zeitlimit von \(timeoutText(budget)) s"
            )
        }
        let count = frameCount(in: framesDirectory)
        if let progress, expectedFrames > 0 {
            let share = min(Double(count) / Double(expectedFrames), 1)
            await progress(share)
        }
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
        } catch {
            // Abgebrochener Task: wie ein Abbruch behandeln.
            await terminateChild(process)
            try? manager.removeItem(at: framesDirectory)
            throw RenderCancelled()
        }
    }
    process.waitUntilExit()

    // stdout nur zum Auswerten lesen; liegen bleiben soll er nicht.
    let output = (try? Data(contentsOf: stdoutLog)) ?? Data()
    try? manager.removeItem(at: stdoutLog)

    if process.terminationStatus != 0 {
        throw VideoError(
            "render-mcp endet mit Status \(process.terminationStatus): "
                + "\(errorDetail(from: stderrLog))"
        )
    }

    let text = String(data: output, encoding: .utf8) ?? ""
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard let jsonLine = lines.last(where: {
        String($0).trimmingCharacters(in: .whitespaces).hasPrefix("{")
    }) else {
        throw VideoError("render-mcp liefert keine JSON-Zeile auf stdout")
    }
    do {
        return try JSONDecoder().decode(RenderSummary.self, from: Data(jsonLine.utf8))
    } catch {
        throw VideoError("render-mcp-Ausgabe nicht lesbar: \(error)")
    }
}

/// Beendet render-mcp: SIGTERM, 500 ms Frist, danach SIGKILL.
///
/// Eine eigene Prozessgruppe (`kill(-pid, …)`) ist mit `Process` nicht
/// einzurichten; render-mcp startet keine weiteren Kinder, deshalb genügt die
/// PID.
func terminateChild(_ process: Process) async {
    let pid = process.processIdentifier
    if pid > 0 {
        kill(pid, SIGTERM)
        for _ in 0..<5 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    process.waitUntilExit()
}

/// Prozessende-Marke, die der Termination-Handler aus einem anderen Thread setzt.
private final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func mark() {
        lock.lock()
        done = true
        lock.unlock()
    }
}

/// Anzahl der PNG-Frames im Verzeichnis; ein fehlendes Verzeichnis zählt als 0.
func frameCount(in directory: URL) -> Int {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
        return 0
    }
    return entries.filter {
        $0.lowercased().hasPrefix("frame-") && $0.lowercased().hasSuffix(".png")
    }.count
}

/// Fehlerzeile von render-mcp: `{"kind":…,"message":…}` oder die letzten Logzeilen.
func errorDetail(from log: URL) -> String {
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "kein Log" }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    if let last = lines.last, let data = String(last).data(using: .utf8),
       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let message = object["message"] as? String
    {
        let kind = object["kind"] as? String ?? "fehler"
        return "\(message) (\(kind))"
    }
    if lines.isEmpty { return "kein Log" }
    return lines.suffix(6).joined(separator: " | ")
}

/// PNG-Frames eines Laufs in Dateinamen-Reihenfolge.
func frameFiles(in directory: URL) throws -> [URL] {
    let entries: [URL]
    do {
        entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
    } catch {
        throw VideoError("Frame-Verzeichnis nicht lesbar: \(directory.path)")
    }

    let frames = entries
        .filter {
            $0.pathExtension.lowercased() == "png"
                && $0.lastPathComponent.lowercased().hasPrefix("frame-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    guard !frames.isEmpty else {
        throw VideoError("render-mcp hat keine Frames geschrieben: \(directory.path)")
    }
    return frames
}
