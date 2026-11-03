// SceneInput.swift — Szene v1 einlesen und für render-mcp bereitstellen.
//
// Gelesen werden nur die Felder, die für das Encoding zählen (version, width,
// height, fps, duration). Alles andere prüft render-mcp selbst.

import Foundation
import MCP

/// Kopfdaten einer Szene v1.
struct SceneHeader: Codable, Sendable {
    let version: Int
    let width: Int
    let height: Int
    let fps: Double
    let duration: Double
}

/// Woher die Szene kommt: als JSON-Objekt im Aufruf oder als Datei.
enum SceneInput: Sendable {
    case object(Data)
    case file(URL)

    /// Liest `scene`/`scene_path` aus den Tool-Argumenten; genau eines ist Pflicht.
    static func from(arguments: [String: Value]) throws -> SceneInput {
        let hasObject: Bool = {
            guard let value = arguments["scene"] else { return false }
            if case .null = value { return false }
            return true
        }()
        let path = arguments["scene_path"]?.stringValue
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPath = !(trimmed?.isEmpty ?? true)

        switch (hasObject, hasPath) {
        case (true, false):
            guard let value = arguments["scene"], case .object = value else {
                throw VideoError("scene muss ein JSON-Objekt sein")
            }
            do {
                return .object(try JSONEncoder().encode(value))
            } catch {
                throw VideoError("scene lässt sich nicht als JSON schreiben: \(error)")
            }

        case (false, true):
            let url = URL(fileURLWithPath: trimmed ?? "").standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VideoError("Szenen-Datei nicht gefunden: \(url.path)")
            }
            return .file(url)

        case (true, true):
            throw VideoError("genau eines von scene und scene_path angeben")

        case (false, false):
            throw VideoError("scene oder scene_path fehlt")
        }
    }

    /// Vollständige Szene als JSON.
    func data() throws -> Data {
        switch self {
        case .object(let data):
            return data
        case .file(let url):
            do {
                return try Data(contentsOf: url)
            } catch {
                throw VideoError("Szenen-Datei nicht lesbar: \(url.lastPathComponent)")
            }
        }
    }

    /// Kopfdaten der Szene; fehlende oder unbrauchbare Felder werden gemeldet.
    func header() throws -> SceneHeader {
        do {
            return try JSONDecoder().decode(SceneHeader.self, from: try data())
        } catch let error as VideoError {
            throw error
        } catch {
            throw VideoError(
                "Szene ohne gültige Kopfdaten (version, width, height, fps, duration): \(error)"
            )
        }
    }

    /// Legt die Szene als `<verzeichnis>/scene.json` ab und liefert den Pfad.
    /// Damit arbeitet render-mcp auf einer unveränderlichen Kopie.
    func materialize(in directory: URL) throws -> URL {
        let target = directory.appendingPathComponent("scene.json")
        try? FileManager.default.removeItem(at: target)
        do {
            try data().write(to: target, options: .atomic)
        } catch {
            throw VideoError("Szene lässt sich nicht nach \(target.path) schreiben")
        }
        return target
    }
}

// MARK: - Quelle eines Hintergrund-Laufs

/// Woher die Szene eines Hintergrund-Laufs kommt: 2D über render-mcp oder 3D
/// über SceneKit.
enum RenderSource: Sendable {
    case flat(SceneInput)
    case threeD(Scene3DInput)

    /// `true` bei einer 3D-Szene.
    var isThreeD: Bool {
        switch self {
        case .flat: return false
        case .threeD: return true
        }
    }

    /// Liest die Quelle aus den Tool-Argumenten; genau eine der vier Angaben
    /// `scene`, `scene_path`, `scene3d` und `scene3d_path` ist Pflicht.
    static func from(arguments: [String: Value]) throws -> RenderSource {
        let hasScene = isGiven(arguments["scene"])
        let hasScene3D = isGiven(arguments["scene3d"])
        let hasScenePath = isPath(arguments["scene_path"])
        let hasScene3DPath = isPath(arguments["scene3d_path"])
        let count = [hasScene, hasScene3D, hasScenePath, hasScene3DPath].filter { $0 }.count

        switch count {
        case 1:
            if hasScene3D || hasScene3DPath {
                return .threeD(try Scene3DInput.from(arguments: arguments))
            }
            return .flat(try SceneInput.from(arguments: arguments))
        case 0:
            throw VideoError("scene, scene_path, scene3d oder scene3d_path fehlt")
        default:
            throw VideoError(
                "genau eines von scene, scene_path, scene3d und scene3d_path angeben"
            )
        }
    }

    /// Gesetztes Argument; `null` zählt als nicht angegeben. Die Typprüfung
    /// übernimmt der jeweilige Einleser.
    private static func isGiven(_ value: Value?) -> Bool {
        guard let value else { return false }
        return !value.isNull
    }

    /// Gesetzter, nicht leerer Pfad.
    private static func isPath(_ value: Value?) -> Bool {
        guard let raw = value?.stringValue else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
