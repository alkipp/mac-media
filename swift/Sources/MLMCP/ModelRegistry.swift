// ModelRegistry.swift — Modellregister für ml-mcp.
//
// Scannt das Modellverzeichnis rekursiv nach CoreML-Bundles (`.mlmodelc`,
// `.mlpackage`, `.mlmodel`) und liest je Modell Größe, Änderungsdatum sowie
// Version und Autor aus den UserDefined-Metadaten. Das Ergebnis wird 60 s
// gehalten; `refresh` erzwingt einen neuen Scan.
//
// `MLModel` und `MLComputePlan` sind nicht `Sendable`. Sie werden deshalb nur
// innerhalb einzelner Funktionen benutzt und nie über eine Isolationsgrenze
// gereicht; das Register speichert ausschließlich Text, Zahlen und Daten.

import CoreML
import Foundation

/// Modellverzeichnis, aus dem alle Backends lesen (CoreML und llama.cpp).
enum ModelPaths {
    nonisolated static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-compute/models")
}

/// Art eines Eintrags im Modellverzeichnis.
enum ModelKind: String, Sendable {
    case mlmodelc
    case mlpackage
    case mlmodel

    /// Erkennt die Art an der Endung; `nil` für alle anderen Einträge.
    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "mlmodelc":
            self = .mlmodelc
        case "mlpackage":
            self = .mlpackage
        case "mlmodel":
            self = .mlmodel
        default:
            return nil
        }
    }
}

/// Ein Modell im Register. `error` ist gesetzt, wenn das Modell nicht lädt.
struct ModelEntry: Sendable {
    let name: String
    let kind: ModelKind
    let path: String
    let bytes: Int64
    let modified: Date
    let version: String
    let author: String
    let compute: String
    let error: String?
}

/// Ergebnis eines Scans samt Kopfdaten für die Ausgabe.
struct ModelScan: Sendable {
    let directory: String
    let exists: Bool
    let entries: [ModelEntry]
    let devices: [String]
    let duration: Double
}

/// Register mit 60-Sekunden-Cache; der Actor serialisiert die Zugriffe.
actor ModelRegistry {
    private static let lifetime: TimeInterval = 60

    private var cached: ModelScan?
    private var cachedAt = Date.distantPast

    /// Liefert den Cache oder scannt neu; `refresh` übergeht den Cache.
    func scan(refresh: Bool) async -> (scan: ModelScan, fromCache: Bool) {
        let valid = !refresh && Date().timeIntervalSince(cachedAt) < Self.lifetime
        if valid, let hit = cached {
            return (hit, true)
        }
        let scan = await ModelScan.make()
        cached = scan
        cachedAt = Date()
        return (scan, false)
    }
}

/// Einziges Register des Prozesses.
let modelRegistry = ModelRegistry()

extension ModelScan {
    /// Scannt das Verzeichnis und lädt jedes gefundene Modell einmal.
    static func make() async -> ModelScan {
        let started = Date()
        let directory = ModelPaths.directory
        let exists = FileManager.default.fileExists(atPath: directory.path)
        var entries: [ModelEntry] = []
        if exists {
            for url in findModels(in: directory) {
                guard let kind = ModelKind(url: url) else { continue }
                entries.append(await entry(for: url, kind: kind))
            }
        }
        return ModelScan(
            directory: directory.path,
            exists: exists,
            entries: entries,
            devices: availableDevices(),
            duration: Date().timeIntervalSince(started)
        )
    }

    /// Textausgabe des Registers; ein Eintrag belegt mehrere Zeilen.
    func render(fromCache: Bool) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]

        var lines = [
            "verzeichnis: \(directory)\(exists ? "" : " (fehlt)")",
            "modelle: \(entries.count)",
            "compute_geraete: \(devices.isEmpty ? "-" : devices.joined(separator: ", "))",
            String(format: "dauer: %.0f ms", duration * 1000),
            "quelle: \(fromCache ? "cache" : "scan")",
        ]
        if !exists {
            lines.append("hinweis: Modellverzeichnis fehlt; es wird nichts angelegt")
        } else if entries.isEmpty {
            lines.append("hinweis: keine Modelle (.mlmodelc, .mlpackage, .mlmodel) gefunden")
        }
        for entry in entries {
            lines.append("")
            lines.append("- \(entry.name) (\(entry.kind.rawValue))")
            lines.append("  pfad: \(entry.path)")
            lines.append("  bytes: \(entry.bytes) (\(humanBytes(entry.bytes)))")
            lines.append("  geaendert: \(formatter.string(from: entry.modified))")
            if let error = entry.error {
                lines.append("  error: \(error)")
            } else {
                lines.append("  version: \(entry.version)")
                lines.append("  author: \(entry.author)")
                lines.append("  compute: \(entry.compute)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Sammelt Modell-Bundles unterhalb von `directory`, ohne in Bundles zu steigen.
private func findModels(in directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles],
        errorHandler: { _, _ in true }
    ) else {
        return []
    }

    var found: [URL] = []
    for case let url as URL in enumerator {
        guard ModelKind(url: url) != nil else { continue }
        found.append(url)
        // Ein Bundle ist ein Eintrag; Dateien darin sind keine eigenen Modelle.
        enumerator.skipDescendants()
    }
    return found.sorted { $0.path < $1.path }
}

/// Liest Größe, Datum und Metadaten eines Modells; Fehler landen im Eintrag.
private func entry(for url: URL, kind: ModelKind) async -> ModelEntry {
    let (bytes, modified) = sizeAndDate(of: url)
    var version = "-"
    var author = "-"
    var compute = "-"
    var failure: String?

    do {
        let compiled = try await compiledURL(for: url, kind: kind)
        let configuration = MLModelConfiguration()
        // `.all` lässt den Compute-Plan die bevorzugten Geräte melden.
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        let metadata = creatorMetadata(of: model)
        version = metadata["version"] ?? "-"
        author = metadata["author"] ?? "-"
        compute = await plannedDevices(for: compiled)
    } catch {
        failure = errorText(error)
    }

    return ModelEntry(
        name: url.deletingPathExtension().lastPathComponent,
        kind: kind,
        path: url.path,
        bytes: bytes,
        modified: modified,
        version: version,
        author: author,
        compute: compute,
        error: failure
    )
}

/// Kompilierte Fassung eines Modells; `.mlmodelc` ist bereits kompiliert.
private func compiledURL(for url: URL, kind: ModelKind) async throws -> URL {
    switch kind {
    case .mlmodelc:
        return url
    case .mlpackage, .mlmodel:
        // CoreML kompiliert in ein temporäres Verzeichnis. Das ist beim Lesen
        // unkompilierter Modelle unvermeidbar und bleibt CoreML überlassen.
        return try await MLModel.compileModel(at: url)
    }
}

/// UserDefined-Metadaten des Modells (leer, wenn keine gesetzt sind).
private func creatorMetadata(of model: MLModel) -> [String: String] {
    guard let raw = model.modelDescription.metadata[.creatorDefinedKey] as? [String: Any] else {
        return [:]
    }
    var result: [String: String] = [:]
    for (key, value) in raw {
        guard let text = value as? String, !text.isEmpty else {
            continue
        }
        result[key] = text
    }
    return result
}

/// Bevorzugte Compute-Geräte laut Compute-Plan; `-`, wenn nicht ermittelbar.
private func plannedDevices(for compiled: URL) async -> String {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    guard let plan = try? await MLComputePlan.load(
        contentsOf: compiled,
        configuration: configuration
    ) else {
        return "-"
    }

    // Nur neuronale Netze lassen sich Layer für Layer auswerten; ML-Programme
    // liefern an dieser Stelle keinen Gerätebezug.
    guard case let .neuralNetwork(network) = plan.modelStructure else {
        return "-"
    }

    var devices: Set<String> = []
    for layer in network.layers {
        guard let usage = plan.deviceUsage(for: layer) else { continue }
        devices.insert(deviceName(usage.preferred))
    }
    return joinedDevices(devices)
}

/// Summierte Größe und jüngstes Änderungsdatum eines Eintrags.
private func sizeAndDate(of url: URL) -> (bytes: Int64, modified: Date) {
    let keys: Set<URLResourceKey> = [
        .fileSizeKey,
        .isDirectoryKey,
        .contentModificationDateKey,
    ]
    guard let values = try? url.resourceValues(forKeys: keys) else {
        return (0, Date.distantPast)
    }
    let ownDate = values.contentModificationDate ?? Date.distantPast
    guard values.isDirectory == true else {
        return (Int64(values.fileSize ?? 0), ownDate)
    }

    var bytes: Int64 = 0
    var modified = ownDate
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: [],
        errorHandler: { _, _ in true }
    ) else {
        return (0, modified)
    }

    for case let item as URL in enumerator {
        guard let itemValues = try? item.resourceValues(forKeys: keys) else { continue }
        if itemValues.isDirectory == true {
            continue
        }
        bytes += Int64(itemValues.fileSize ?? 0)
        if let date = itemValues.contentModificationDate, date > modified {
            modified = date
        }
    }
    return (bytes, modified)
}

/// Compute-Geräte des Rechners in fester Reihenfolge (cpu, gpu, ane).
private func availableDevices() -> [String] {
    let present = Set(MLComputeDevice.allComputeDevices.map { deviceName($0) })
    return ["cpu", "gpu", "ane"].filter { present.contains($0) }
}

/// Anzeigename eines Compute-Geräts; `ml_info` nennt die ANE `neuralEngine`.
private func deviceName(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu:
        return "cpu"
    case .gpu:
        return "gpu"
    case .neuralEngine:
        return "ane"
    @unknown default:
        return "unbekannt"
    }
}

/// Gerätenamen in fester Reihenfolge, durch Komma getrennt.
private func joinedDevices(_ devices: Set<String>) -> String {
    let names = ["cpu", "gpu", "ane"].filter { devices.contains($0) }
    return names.isEmpty ? "-" : names.joined(separator: ",")
}

/// Fehlerbeschreibung in einer Zeile.
private func errorText(_ error: Error) -> String {
    let text = (error as NSError).localizedDescription
    return text.replacingOccurrences(of: "\n", with: " ")
}

/// Größe als lesbarer Text (B, KiB, MiB, GiB).
private func humanBytes(_ bytes: Int64) -> String {
    guard bytes >= 1024 else { return "\(bytes) B" }
    let units = ["KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes) / 1024
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: "%.1f %@", value, units[unit])
}
