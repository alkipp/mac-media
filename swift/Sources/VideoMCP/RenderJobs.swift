// RenderJobs.swift — Registrierung asynchroner Render-Läufe (Schritt 11).
//
// `render_start` legt einen Lauf an, `render_status` liest Zustand und
// Fortschritt, `render_cancel` setzt das Abbruch-Flag. Höchstens zwei Läufe
// laufen gleichzeitig; jeder Lauf arbeitet in einem eigenen Task und meldet
// seinen Fortschritt an diesen Actor. 2D-Läufe gehen über render-mcp, 3D-Läufe
// über SceneKit. Der synchrone Aufruf `render_video` läuft bewusst nicht über
// diese Registrierung.

import Foundation

/// Zustand eines Laufs.
enum RenderJobState: String, Sendable {
    case running
    case done
    case failed
    case cancelled
}

/// Optionen eines Laufs.
struct RenderOptions: Sendable {
    var codec: VideoCodec = .h264
    var audio: URL?
    var keepFrames: Bool = false
    var output: URL?
    var effects: [EffectSpec] = []
    /// Zeitbudget des Laufs in Sekunden; `nil` heißt Vorgabe aus der Umgebung.
    /// Gilt nur für die 2D-Pipeline mit render-mcp-Subprozess.
    var timeout: TimeInterval?
}

/// Momentaufnahme für `render_status` und `render_cancel`.
struct RenderJobSnapshot: Sendable {
    let id: String
    let state: RenderJobState
    let progress: Double
    let report: RenderReport?
    let error: String?

    /// Klartext; bei `done` dieselben Zeilen wie `render_video`.
    var text: String {
        var lines = [
            "id: \(id)",
            "state: \(state.rawValue)",
            "progress: \(Int(progress.rounded()))",
        ]
        if state == .done, let report {
            lines.append(report.text)
        }
        if state == .failed, let error {
            lines.append("error: \(error)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Actor mit allen Läufen des Prozesses.
actor RenderJobs {
    static let shared = RenderJobs()
    static let maxConcurrent = 2
    /// So viele beendete Läufe bleiben für `render_status` erhalten.
    private static let keepFinished = 16

    private struct Job {
        var state: RenderJobState
        var progress: Double
        var report: RenderReport?
        var error: String?
    }

    private var jobs: [String: Job] = [:]
    private var order: [String] = []

    /// Legt einen Lauf an und startet ihn im Hintergrund.
    ///
    /// `source` entscheidet zwischen der 2D-Pipeline über render-mcp und der
    /// 3D-Pipeline über SceneKit; beide melden Fortschritt an diesen Actor und
    /// lassen sich über `cancel` abbrechen. Wirft, wenn bereits zwei Läufe
    /// aktiv sind.
    func start(source: RenderSource, name: String, options: RenderOptions) throws -> String {
        let running = jobs.values.filter { $0.state == .running }.count
        guard running < Self.maxConcurrent else {
            throw VideoError(
                "zu viele laufende Render-Läufe (\(running)/\(Self.maxConcurrent)) – "
                    + "erst render_status oder render_cancel nutzen"
            )
        }
        prune()

        let id = "render-\(UUID().uuidString.lowercased())"
        jobs[id] = Job(state: .running, progress: 0, report: nil, error: nil)
        order.append(id)

        let registry = RenderJobs.shared
        Task.detached(priority: .userInitiated) {
            do {
                let report: RenderReport
                switch source {
                case .flat(let scene):
                    report = try await renderVideo(
                        scene: scene,
                        name: name,
                        keepFrames: options.keepFrames,
                        output: options.output,
                        codec: options.codec,
                        audio: options.audio,
                        effects: options.effects,
                        progress: { value in
                            await registry.report(id: id, progress: value)
                        },
                        isCancelled: {
                            await registry.isCancelled(id)
                        },
                        timeout: options.timeout
                    )
                case .threeD(let scene):
                    report = try await render3D(
                        scene: scene,
                        name: name,
                        keepFrames: options.keepFrames,
                        output: options.output,
                        codec: options.codec,
                        audio: options.audio,
                        effects: options.effects,
                        progress: { value in
                            await registry.report(id: id, progress: value)
                        },
                        isCancelled: {
                            await registry.isCancelled(id)
                        }
                    )
                }
                await registry.finish(id: id, report: report)
            } catch let cancelled as RenderCancelled {
                await registry.fail(id: id, error: cancelled.description, cancelled: true)
            } catch {
                await registry.fail(id: id, error: "\(error)", cancelled: false)
            }
        }
        return id
    }

    /// Zustand eines Laufs.
    func status(id: String) throws -> RenderJobSnapshot {
        guard let job = jobs[id] else {
            throw VideoError("unbekannte Kennung: \(id)")
        }
        return snapshot(id: id, job: job)
    }

    /// Bittet einen Lauf um Abbruch und meldet sofort `cancelled`.
    ///
    /// Der Hintergrund-Task beendet render-mcp (SIGTERM, dann SIGKILL) und räumt
    /// die Frames ab; die Antwort wartet darauf nicht.
    func cancel(id: String) throws -> RenderJobSnapshot {
        guard var job = jobs[id] else {
            throw VideoError("unbekannte Kennung: \(id)")
        }
        if job.state == .running {
            job.state = .cancelled
        }
        jobs[id] = job
        return snapshot(id: id, job: job)
    }

    /// Fortschritt 0…100 setzen; beendete Läufe bleiben unverändert.
    func report(id: String, progress: Double) {
        guard var job = jobs[id], job.state == .running else { return }
        job.progress = min(max(progress, 0), 100)
        jobs[id] = job
    }

    /// `true`, wenn der Lauf abgebrochen wurde.
    func isCancelled(_ id: String) -> Bool {
        jobs[id]?.state == .cancelled
    }

    /// Lauf erfolgreich beendet.
    func finish(id: String, report: RenderReport) {
        guard var job = jobs[id], job.state == .running else { return }
        job.state = .done
        job.progress = 100
        job.report = report
        jobs[id] = job
    }

    /// Lauf gescheitert oder abgebrochen; `cancelled` gewinnt gegen `failed`.
    func fail(id: String, error: String, cancelled: Bool) {
        guard var job = jobs[id], job.state == .running || job.state == .cancelled else {
            return
        }
        if job.state == .running {
            job.state = cancelled ? .cancelled : .failed
        }
        if job.state == .failed {
            job.error = error
        }
        jobs[id] = job
    }

    private func snapshot(id: String, job: Job) -> RenderJobSnapshot {
        RenderJobSnapshot(
            id: id,
            state: job.state,
            progress: job.progress,
            report: job.report,
            error: job.error
        )
    }

    /// Behält die letzten `keepFinished` beendeten Läufe; laufende bleiben.
    private func prune() {
        let finished = order.filter { jobs[$0]?.state != .running }
        guard finished.count > Self.keepFinished else { return }
        for id in finished.prefix(finished.count - Self.keepFinished) {
            jobs[id] = nil
            order.removeAll { $0 == id }
        }
    }
}
