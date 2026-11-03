// Scene3D.swift — 3D-Szene (Schritt 16): striktes JSON, SceneKit-Aufbau und
// Offscreen-Rendering über Metal.
//
// Beispiel:
// {
//   "version": 1,
//   "width": 1920, "height": 1080, "fps": 30, "duration": 3.0,
//   "background": "#101218",
//   "camera": {"position": [0, 1.5, 6], "target": [0, 0, 0], "fov": 50,
//              "orbit": {"degrees": 90, "axis": "y"}},
//   "light": {"position": [4, 6, 4], "intensity": 1000, "color": "#FFFFFF"},
//   "objects": [
//     {"type": "box", "position": [0, 0, 0], "size": [1.4, 1.4, 1.4],
//      "color": "#5B8DEF", "rotation": [0, 0.6, 0]},
//     {"type": "sphere", "position": [2.2, 0, 0], "radius": 0.8, "color": "#4FA37A"},
//     {"type": "plane", "position": [0, -1.2, 0], "size": [12, 12], "color": "#20242C"}
//   ]
// }
//
// Regeln: `version` 1, Kanten 16–8192, 1–120 fps, Dauer 0,01–600 s, höchstens
// 512 Objekte, Farben als `#RRGGBB`. Unbekannte Felder, fehlende Pflichtfelder
// und unplausible Werte werden abgelehnt. `rotation` ist Bogenmaß
// (SceneKit-Konvention); eine `plane` liegt als Boden in der XZ-Ebene und wird
// mit `rotation` zusätzlich gedreht.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MCP
import Metal
import SceneKit

// MARK: - Modell

/// Punkt oder Richtung im Raum.
struct Vector3D: Sendable {
    var x: Double
    var y: Double
    var z: Double
}

/// Farbe mit sRGB-Anteilen 0…1.
struct Color3D: Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

/// Achse, um die die Kamera kreist.
enum OrbitAxis: String, Sendable {
    case x
    case y
    case z
}

/// Gleichmäßige Kamerafahrt um `target` über die Gesamtdauer.
struct CameraOrbit: Sendable {
    var degrees: Double
    var axis: OrbitAxis
}

struct Camera3D: Sendable {
    var position: Vector3D
    var target: Vector3D
    var fov: Double
    var orbit: CameraOrbit?
    /// Kamerafahrt: Stützpunkte mit Zeit, Position und Ziel.
    var path: [CameraKey]?
}

/// Ein Stützpunkt der Kamerafahrt.
struct CameraKey: Sendable {
    var time: Double
    var position: Vector3D
    var target: Vector3D
}

struct Light3D: Sendable {
    var position: Vector3D
    var intensity: Double
    var color: Color3D
}

/// Lichtquelle der Szene (mehrere möglich).
struct SceneLight: Sendable {
    var kind: String
    var position: Vector3D
    var target: Vector3D?
    var intensity: Double
    var color: Color3D
    var castsShadow: Bool
}

/// Geometrie eines Objekts samt ihrer Maße.
enum ObjectGeometry3D: Sendable {
    case box(size: Vector3D)
    case sphere(radius: Double)
    case plane(width: Double, height: Double)
    case text(value: String, size: Double)
}

struct Object3D: Sendable {
    var geometry: ObjectGeometry3D
    var position: Vector3D
    var rotation: Vector3D
    var color: Color3D
    /// Material leuchtet selbst (LEDs, Displays).
    var emissive: Bool = false
    /// Text dreht sich immer zur Kamera.
    var billboard: Bool = false
    /// PBR-Werte; gesetzt schaltet das Material auf `.physicallyBased`.
    var roughness: Double?
    var metalness: Double?
    var emissiveIntensity: Double = 1
}

/// Geprüfte 3D-Szene.
struct Scene3D: Sendable {
    var width: Int
    var height: Int
    var fps: Double
    var duration: Double
    var background: Color3D
    var camera: Camera3D
    var light: Light3D
    /// Zusätzliches Umgebungslicht, damit Schatten nicht schwarz absaufen.
    var ambient: Light3D?
    /// Mehrere Lichtquellen; ersetzt `light`/`ambient`, wenn nicht leer.
    var lights: [SceneLight]?
    var objects: [Object3D]
}

// MARK: - Einlesen und strikt prüfen

extension Scene3D {
    /// Grenzen wie bei der 2D-Szene.
    private static let widthRange = 16.0...8192.0
    private static let fpsRange = 1.0...120.0
    private static let durationRange = 0.01...600.0
    private static let fovRange = 1.0...179.0
    private static let sizeRange = 0.0001...1000.0
    private static let maximalObjects = 512
    private static let degreesRange = -3600.0...3600.0

    /// Liest und prüft die Szene aus JSON.
    static func decode(_ data: Data) throws -> Scene3D {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw VideoError("3D-Szene ist kein gültiges JSON: \(error.localizedDescription)")
        }
        guard let root = raw as? [String: Any] else {
            throw VideoError("3D-Szene muss ein JSON-Objekt sein")
        }
        try rejectUnknown(
            root,
            path: "3D-Szene",
            allowed: [
                "version", "width", "height", "fps", "duration", "background",
                "camera", "light", "ambient", "lights", "objects",
            ]
        )

        let version = try integer(root["version"], path: "version")
        guard version == 1 else {
            throw VideoError(
                "3D-Szene: Version \(version) wird nicht unterstützt (erwartet 1)"
            )
        }

        let width = try integer(root["width"], path: "width")
        let height = try integer(root["height"], path: "height")
        try check("width", Double(width), in: widthRange)
        try check("height", Double(height), in: widthRange)

        let fps = try number(root["fps"], path: "fps")
        try check("fps", fps, in: fpsRange)

        let duration = try number(root["duration"], path: "duration")
        try check("duration", duration, in: durationRange)

        // Ohne `background` bleibt der Hintergrund schwarz.
        let background: Color3D
        if let rawBackground = root["background"] {
            background = try color(rawBackground, path: "background")
        } else {
            background = Color3D(red: 0, green: 0, blue: 0)
        }

        let camera = try camera3D(root["camera"])
        let light = try light3D(root["light"])
        let ambient = try root["ambient"].map { try ambient3D($0) }
        let lights = try lights3D(root["lights"])
        let objects = try objects3D(root["objects"])

        return Scene3D(
            width: width,
            height: height,
            fps: fps,
            duration: duration,
            background: background,
            camera: camera,
            light: light,
            ambient: ambient,
            lights: lights,
            objects: objects
        )
    }

    /// Mehrere Lichtquellen; leer oder fehlend nutzt `light`/`ambient`.
    private static func lights3D(_ value: Any?) throws -> [SceneLight]? {
        guard let value else { return nil }
        guard let entries = value as? [Any], !entries.isEmpty, entries.count <= 12 else {
            throw VideoError("lights muss ein Array mit 1 bis 12 Einträgen sein")
        }
        var result: [SceneLight] = []
        for (index, entry) in entries.enumerated() {
            let path = "lights[\(index)]"
            let object = try parseObject(
                entry,
                path: path,
                allowed: ["type", "position", "target", "intensity", "color", "castsShadow"]
            )
            guard let kind = object["type"] as? String,
                  ["omni", "directional", "spot", "ambient"].contains(kind) else {
                throw VideoError("\(path).type muss omni, directional, spot oder ambient sein")
            }
            let position = try vector3(object["position"], path: "\(path).position")
            let target = try object["target"].map { try vector3($0, path: "\(path).target") }
            let intensity = try number(object["intensity"], path: "\(path).intensity")
            try check("\(path).intensity", intensity, in: 0.0...1_000_000.0)
            let color = try color(object["color"], path: "\(path).color")
            let castsShadow = (object["castsShadow"] as? NSNumber)?.boolValue ?? false
            result.append(
                SceneLight(
                    kind: kind,
                    position: position,
                    target: target,
                    intensity: intensity,
                    color: color,
                    castsShadow: castsShadow
                )
            )
        }
        return result
    }

    private static func ambient3D(_ value: Any) throws -> Light3D {
        let object = try parseObject(
            value,
            path: "ambient",
            allowed: ["intensity", "color"]
        )
        let intensity = try number(object["intensity"], path: "ambient.intensity")
        try check("ambient.intensity", intensity, in: 0.0...1_000_000.0)
        let color = try color(object["color"], path: "ambient.color")
        return Light3D(position: Vector3D(x: 0, y: 0, z: 0), intensity: intensity, color: color)
    }

    private static func camera3D(_ value: Any?) throws -> Camera3D {
        let object = try parseObject(
            value,
            path: "camera",
            allowed: ["position", "target", "fov", "orbit", "path"]
        )
        let position = try vector3(object["position"], path: "camera.position")
        let target = try vector3(object["target"], path: "camera.target")
        let fov = try number(object["fov"], path: "camera.fov")
        try check("camera.fov", fov, in: fovRange)

        let offset = Vector3D(
            x: position.x - target.x,
            y: position.y - target.y,
            z: position.z - target.z
        )
        guard abs(offset.x) + abs(offset.y) + abs(offset.z) > 0.0001 else {
            throw VideoError("camera.position und camera.target dürfen nicht gleich sein")
        }

        var orbit: CameraOrbit?
        if let rawOrbit = object["orbit"] {
            let orbitObject = try parseObject(
                rawOrbit,
                path: "camera.orbit",
                allowed: ["degrees", "axis"]
            )
            let degrees = try number(orbitObject["degrees"], path: "camera.orbit.degrees")
            try check("camera.orbit.degrees", degrees, in: degreesRange)
            let axisName = orbitObject["axis"] as? String ?? "y"
            guard let axis = OrbitAxis(rawValue: axisName) else {
                throw VideoError("camera.orbit.axis muss x, y oder z sein: \(axisName)")
            }
            orbit = CameraOrbit(degrees: degrees, axis: axis)
        }

        var path: [CameraKey]?
        if let rawPath = object["path"] {
            guard let entries = rawPath as? [Any], entries.count >= 2, entries.count <= 64 else {
                throw VideoError("camera.path braucht 2 bis 64 Stützpunkte")
            }
            var keys: [CameraKey] = []
            var lastTime = -1.0
            for (index, entry) in entries.enumerated() {
                let keyPath = "camera.path[\(index)]"
                let key = try parseObject(
                    entry,
                    path: keyPath,
                    allowed: ["t", "position", "target"]
                )
                let time = try number(key["t"], path: "\(keyPath).t")
                try check("\(keyPath).t", time, in: 0.0...600.0)
                guard time >= lastTime else {
                    throw VideoError("\(keyPath).t muss aufsteigend sein")
                }
                lastTime = time
                keys.append(
                    CameraKey(
                        time: time,
                        position: try vector3(key["position"], path: "\(keyPath).position"),
                        target: try vector3(key["target"], path: "\(keyPath).target")
                    )
                )
            }
            path = keys
        }

        return Camera3D(position: position, target: target, fov: fov, orbit: orbit, path: path)
    }

    private static func light3D(_ value: Any?) throws -> Light3D {
        let object = try parseObject(
            value,
            path: "light",
            allowed: ["position", "intensity", "color"]
        )
        let position = try vector3(object["position"], path: "light.position")
        let intensity = try number(object["intensity"], path: "light.intensity")
        try check("light.intensity", intensity, in: 0.0...1_000_000.0)
        let color = try color(object["color"], path: "light.color")
        return Light3D(position: position, intensity: intensity, color: color)
    }

    private static func objects3D(_ value: Any?) throws -> [Object3D] {
        guard let value else {
            throw VideoError("objects fehlt")
        }
        guard let entries = value as? [Any] else {
            throw VideoError("objects muss ein Array sein")
        }
        guard !entries.isEmpty else {
            throw VideoError("objects ist leer")
        }
        guard entries.count <= maximalObjects else {
            throw VideoError(
                "objects hat zu viele Einträge (maximal \(maximalObjects)): \(entries.count)"
            )
        }
        return try entries.enumerated().map { index, entry in
            try object3D(entry, path: "objects[\(index)]")
        }
    }

    private static func object3D(_ value: Any?, path: String) throws -> Object3D {
        guard let value else {
            throw VideoError("\(path) fehlt")
        }
        guard let object = value as? [String: Any] else {
            throw VideoError("\(path) muss ein JSON-Objekt sein")
        }
        guard let type = object["type"] as? String else {
            throw VideoError("\(path).type fehlt (erwartet box, sphere, plane, text)")
        }

        let position = try vector3(object["position"], path: "\(path).position")
        let rotation: Vector3D
        if let rawRotation = object["rotation"] {
            rotation = try vector3(rawRotation, path: "\(path).rotation")
        } else {
            rotation = Vector3D(x: 0, y: 0, z: 0)
        }
        let color: Color3D
        if let rawColor = object["color"] {
            color = try Scene3D.color(rawColor, path: "\(path).color")
        } else {
            color = Color3D(red: 1, green: 1, blue: 1)
        }

        let roughness: Double?
        if let raw = object["roughness"] {
            let value = try Scene3D.number(raw, path: "\(path).roughness")
            try Scene3D.check("\(path).roughness", value, in: 0.0...1.0)
            roughness = value
        } else {
            roughness = nil
        }
        let metalness: Double?
        if let raw = object["metalness"] {
            let value = try Scene3D.number(raw, path: "\(path).metalness")
            try Scene3D.check("\(path).metalness", value, in: 0.0...1.0)
            metalness = value
        } else {
            metalness = nil
        }
        let emissiveIntensity: Double
        if let raw = object["emissiveIntensity"] {
            emissiveIntensity = try Scene3D.number(raw, path: "\(path).emissiveIntensity")
            try Scene3D.check("\(path).emissiveIntensity", emissiveIntensity, in: 0.0...20.0)
        } else {
            emissiveIntensity = 1
        }

        let geometry: ObjectGeometry3D
        let emissive = try Scene3D.boolean(object["emissive"], path: "\(path).emissive", fallback: false)
        let billboard = try Scene3D.boolean(object["billboard"], path: "\(path).billboard", fallback: false)
        switch type {
        case "box":
            try rejectUnknown(
                object,
                path: path,
                allowed: ["type", "position", "size", "color", "rotation", "emissive", "roughness", "metalness", "emissiveIntensity"]
            )
            let size = try vector3(object["size"], path: "\(path).size")
            try check("\(path).size[0]", size.x, in: sizeRange)
            try check("\(path).size[1]", size.y, in: sizeRange)
            try check("\(path).size[2]", size.z, in: sizeRange)
            geometry = .box(size: size)

        case "sphere":
            try rejectUnknown(
                object,
                path: path,
                allowed: ["type", "position", "radius", "color", "rotation", "emissive", "roughness", "metalness", "emissiveIntensity"]
            )
            let radius = try number(object["radius"], path: "\(path).radius")
            try check("\(path).radius", radius, in: sizeRange)
            geometry = .sphere(radius: radius)

        case "plane":
            try rejectUnknown(
                object,
                path: path,
                allowed: ["type", "position", "size", "color", "rotation", "emissive", "roughness", "metalness", "emissiveIntensity"]
            )
            let size = try numbers(object["size"], path: "\(path).size", count: 2)
            try check("\(path).size[0]", size[0], in: sizeRange)
            try check("\(path).size[1]", size[1], in: sizeRange)
            geometry = .plane(width: size[0], height: size[1])

        case "text":
            try rejectUnknown(
                object,
                path: path,
                allowed: [
                    "type", "text", "position", "size", "color", "rotation",
                    "emissive", "billboard", "roughness", "metalness", "emissiveIntensity",
                ]
            )
            guard let text = object["text"] as? String, !text.isEmpty, text.count <= 80 else {
                throw VideoError("\(path).text muss 1 bis 80 Zeichen haben")
            }
            let size = try number(object["size"], path: "\(path).size")
            try check("\(path).size", size, in: 0.05...20.0)
            geometry = .text(value: text, size: size)

        default:
            throw VideoError(
                "\(path).type ist unbekannt: \(type) (erwartet box, sphere, plane, text)"
            )
        }

        return Object3D(
            geometry: geometry,
            position: position,
            rotation: rotation,
            color: color,
            emissive: emissive,
            billboard: billboard,
            roughness: roughness,
            metalness: metalness,
            emissiveIntensity: emissiveIntensity
        )
    }

    // MARK: Hilfsfunktionen für die Prüfung

    /// JSON-Objekt mit ausschließlich erlaubten Feldern.
    private static func parseObject(
        _ value: Any?,
        path: String,
        allowed: Set<String>
    ) throws -> [String: Any] {
        guard let value else {
            throw VideoError("\(path) fehlt")
        }
        guard let object = value as? [String: Any] else {
            throw VideoError("\(path) muss ein JSON-Objekt sein")
        }
        try rejectUnknown(object, path: path, allowed: allowed)
        return object
    }

    private static func rejectUnknown(
        _ object: [String: Any],
        path: String,
        allowed: Set<String>
    ) throws {
        for key in object.keys.sorted() where !allowed.contains(key) {
            throw VideoError("\(path) hat ein unbekanntes Feld: \(key)")
        }
    }

    /// Drei Zahlen (Punkt oder Richtung).
    private static func vector3(_ value: Any?, path: String) throws -> Vector3D {
        let values = try numbers(value, path: path, count: 3)
        return Vector3D(x: values[0], y: values[1], z: values[2])
    }

    /// Genau `count` Zahlen.
    private static func numbers(_ value: Any?, path: String, count: Int) throws -> [Double] {
        guard let value else {
            throw VideoError("\(path) fehlt")
        }
        guard let entries = value as? [Any] else {
            throw VideoError("\(path) muss ein Array aus \(count) Zahlen sein")
        }
        guard entries.count == count else {
            throw VideoError(
                "\(path) braucht genau \(count) Zahlen, gefunden: \(entries.count)"
            )
        }
        return try entries.enumerated().map { index, entry in
            try number(entry, path: "\(path)[\(index)]")
        }
    }

    /// Eine Zahl; Wahrheitswerte und Text werden abgelehnt.
    private static func number(_ value: Any?, path: String) throws -> Double {
        guard let value else {
            throw VideoError("\(path) fehlt")
        }
        if let boxed = value as? NSNumber, CFGetTypeID(boxed) == CFBooleanGetTypeID() {
            throw VideoError("\(path) muss eine Zahl sein")
        }
        let result: Double
        if let double = value as? Double {
            result = double
        } else if let integer = value as? Int {
            result = Double(integer)
        } else {
            throw VideoError("\(path) muss eine Zahl sein")
        }
        guard result.isFinite else {
            throw VideoError("\(path) muss eine endliche Zahl sein")
        }
        return result
    }

    /// Wahrheitswert; NSNumber darf hier nicht als Zahl durchgehen.
    private static func boolean(_ value: Any?, path: String, fallback: Bool) throws -> Bool {
        guard let value else { return fallback }
        if let boxed = value as? NSNumber, CFGetTypeID(boxed) == CFBooleanGetTypeID() {
            return boxed.boolValue
        }
        throw VideoError("\(path) muss true oder false sein")
    }

    /// Eine ganze Zahl ohne Nachkommaanteil.
    private static func integer(_ value: Any?, path: String) throws -> Int {
        let result = try number(value, path: path)
        guard result == result.rounded(),
              result >= Double(Int32.min), result <= Double(Int32.max)
        else {
            throw VideoError("\(path) muss eine ganze Zahl sein")
        }
        return Int(result)
    }

    /// Farbe im Format `#RRGGBB`.
    private static func color(_ value: Any?, path: String) throws -> Color3D {
        guard let value else {
            throw VideoError("\(path) fehlt")
        }
        guard let text = value as? String else {
            throw VideoError("\(path) muss eine Farbe als \"#RRGGBB\" sein")
        }
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6,
              hex.allSatisfy({ $0.isHexDigit }),
              let code = UInt32(hex, radix: 16)
        else {
            throw VideoError("\(path) ist keine Farbe im Format \"#RRGGBB\": \(text)")
        }
        return Color3D(
            red: Double((code >> 16) & 0xff) / 255,
            green: Double((code >> 8) & 0xff) / 255,
            blue: Double(code & 0xff) / 255
        )
    }

    /// Bereichsprüfung mit lesbarer Grenze.
    private static func check(
        _ name: String,
        _ value: Double,
        in range: ClosedRange<Double>
    ) throws {
        guard range.contains(value) else {
            throw VideoError(
                "\(name) liegt außerhalb von \(text(range.lowerBound))…"
                    + "\(text(range.upperBound)): \(text(value))"
            )
        }
    }

    /// Zahl in Meldungen ohne überflüssige Nullen.
    private static func text(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

// MARK: - Herkunft der Szene

/// Woher die 3D-Szene kommt: als JSON-Objekt im Aufruf oder als Datei.
enum Scene3DInput: Sendable {
    case object(Data)
    case file(URL)

    /// Liest `scene3d`/`scene3d_path`; genau eines ist Pflicht.
    static func from(arguments: [String: Value]) throws -> Scene3DInput {
        let hasObject: Bool = {
            guard let value = arguments["scene3d"] else { return false }
            if case .null = value { return false }
            return true
        }()
        let path = arguments["scene3d_path"]?.stringValue
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPath = !(trimmed?.isEmpty ?? true)

        switch (hasObject, hasPath) {
        case (true, false):
            guard let value = arguments["scene3d"], case .object = value else {
                throw VideoError("scene3d muss ein JSON-Objekt sein")
            }
            do {
                return .object(try JSONEncoder().encode(value))
            } catch {
                throw VideoError("scene3d lässt sich nicht als JSON schreiben: \(error)")
            }

        case (false, true):
            let url = URL(fileURLWithPath: trimmed ?? "").standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VideoError("3D-Szenen-Datei nicht gefunden: \(url.path)")
            }
            return .file(url)

        case (true, true):
            throw VideoError("genau eines von scene3d und scene3d_path angeben")

        case (false, false):
            throw VideoError("scene3d oder scene3d_path fehlt")
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
                throw VideoError("3D-Szenen-Datei nicht lesbar: \(url.lastPathComponent)")
            }
        }
    }

    /// Geprüfte Szene.
    func decoded() throws -> Scene3D {
        try Scene3D.decode(try data())
    }

    /// Legt die Szene als `<verzeichnis>/scene3d.json` ab.
    func materialize(in directory: URL) throws -> URL {
        let target = directory.appendingPathComponent("scene3d.json")
        try? FileManager.default.removeItem(at: target)
        do {
            try data().write(to: target, options: .atomic)
        } catch {
            throw VideoError("3D-Szene lässt sich nicht nach \(target.path) schreiben")
        }
        return target
    }
}

// MARK: - SceneKit und Metal

/// SceneKit-Objekte einer geprüften Szene.
private struct Scene3DGraph {
    let scene: SCNScene
    let camera: SCNNode
}

/// Rendert die Szene als `frame-000000.png`, `frame-000001.png` … und liefert
/// die Framezahl. `progress` meldet den Anteil 0…1, `isCancelled` wird vor jedem
/// Frame gefragt; bei Abbruch wird das Frame-Verzeichnis entfernt.
func render3DFrames(
    _ scene: Scene3D,
    into framesDirectory: URL,
    progress: (@Sendable (Double) async -> Void)? = nil,
    isCancelled: (@Sendable () async -> Bool)? = nil
) async throws -> Int {
    let manager = FileManager.default
    try? manager.removeItem(at: framesDirectory)
    do {
        try manager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
    } catch {
        throw VideoError("Frame-Verzeichnis lässt sich nicht anlegen: \(framesDirectory.path)")
    }
    do {
        try await render3DLoop(
            scene,
            progress: progress,
            isCancelled: isCancelled
        ) { index, image, _ in
            // Sechs Stellen: bei 600 s und 120 fps sind es 72000 Frames, und die
            // lexikografische Sortierung in `frameFiles` bleibt damit korrekt.
            let name = String(format: "frame-%06ld.png", index)
            try writePNG(image, to: framesDirectory.appendingPathComponent(name))
        }
    } catch {
        try? manager.removeItem(at: framesDirectory)
        throw error
    }
    return max(Int((scene.duration * scene.fps).rounded()), 1)
}

/// Rendert die Szene Frame für Frame und gibt jeden Frame weiter, ohne ihn auf
/// Platte zu schreiben.
///
/// Der Encoder hängt direkt am Renderer: kein PNG, keine Zwischendatei. `onFrame`
/// bekommt Index, Bild und Gesamtzahl und wird im selben Task aufgerufen, kann
/// also gefahrlos einen Encoder-Puffer befüllen.
func render3DLoop(
    _ scene: Scene3D,
    progress: (@Sendable (Double) async -> Void)? = nil,
    isCancelled: (@Sendable () async -> Bool)? = nil,
    onFrame: (Int, CGImage, Int) async throws -> Void
) async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw VideoError("kein Metal-Gerät für das 3D-Rendering")
    }
    // `init(device:options:)` ist nicht fehlbar; ohne Gerät greift die Prüfung oben.
    let renderer = SCNRenderer(device: device, options: nil)

    let graph = makeScene3DGraph(scene)
    renderer.scene = graph.scene
    renderer.pointOfView = graph.camera

    let total = max(Int((scene.duration * scene.fps).rounded()), 1)
    let size = CGSize(width: CGFloat(scene.width), height: CGFloat(scene.height))

    for index in 0..<total {
        if await isCancelledNow(isCancelled) {
            throw RenderCancelled()
        }
        let time = Double(index) / scene.fps
        placeCamera3D(graph.camera, for: scene, at: time)
        let snapshot = renderer.snapshot(
            atTime: time,
            with: size,
            antialiasingMode: .multisampling4X
        )
        let image = try cgImage(
            from: snapshot,
            width: scene.width,
            height: scene.height,
            index: index
        )
        try await onFrame(index, image, total)
        if let progress {
            await progress(Double(index + 1) / Double(total))
        }
    }
}

/// Baut Szene, Licht und Kamera aus der geprüften Beschreibung.
private func makeScene3DGraph(_ scene: Scene3D) -> Scene3DGraph {
    let root = SCNScene()
    root.background.contents = nsColor(scene.background)

    if let lights = scene.lights, !lights.isEmpty {
        for spec in lights {
            let light = SCNLight()
            switch spec.kind {
            case "directional": light.type = .directional
            case "spot": light.type = .spot
            case "ambient": light.type = .ambient
            default: light.type = .omni
            }
            light.color = nsColor(spec.color)
            light.intensity = CGFloat(spec.intensity)
            light.castsShadow = spec.castsShadow
            if spec.castsShadow {
                light.shadowRadius = 4
            }
            let node = SCNNode()
            node.light = light
            node.position = scnVector(spec.position)
            if let target = spec.target {
                node.look(
                    at: scnVector(target),
                    up: SCNVector3(x: 0, y: 1, z: 0),
                    localFront: SCNNode.localFront
                )
            }
            root.rootNode.addChildNode(node)
        }
    } else {
        let light = SCNLight()
        light.type = .omni
        light.color = nsColor(scene.light.color)
        light.intensity = CGFloat(scene.light.intensity)
        light.castsShadow = false
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = scnVector(scene.light.position)
        root.rootNode.addChildNode(lightNode)

        if let ambient = scene.ambient {
            let ambientLight = SCNLight()
            ambientLight.type = .ambient
            ambientLight.color = nsColor(ambient.color)
            ambientLight.intensity = CGFloat(ambient.intensity)
            let ambientNode = SCNNode()
            ambientNode.light = ambientLight
            root.rootNode.addChildNode(ambientNode)
        }
    }

    let camera = SCNCamera()
    camera.fieldOfView = CGFloat(scene.camera.fov)
    camera.zNear = 0.1
    camera.zFar = 1000
    camera.wantsHDR = false
    camera.wantsExposureAdaptation = false
    let cameraNode = SCNNode()
    cameraNode.camera = camera
    cameraNode.position = scnVector(scene.camera.position)
    cameraNode.look(
        at: scnVector(scene.camera.target),
        up: SCNVector3(x: 0, y: 1, z: 0),
        localFront: SCNNode.localFront
    )
    root.rootNode.addChildNode(cameraNode)

    for object in scene.objects {
        root.rootNode.addChildNode(makeNode3D(object))
    }
    return Scene3DGraph(scene: root, camera: cameraNode)
}

/// Ein Objekt als SCNNode mit Blinn-Material.
private func makeNode3D(_ object: Object3D) -> SCNNode {
    let geometry: SCNGeometry
    var baseRotation = Vector3D(x: 0, y: 0, z: 0)

    switch object.geometry {
    case .box(let size):
        geometry = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: 0
        )

    case .sphere(let radius):
        let sphere = SCNSphere(radius: CGFloat(radius))
        sphere.segmentCount = 64
        geometry = sphere

    case .plane(let width, let height):
        geometry = SCNPlane(width: CGFloat(width), height: CGFloat(height))
        // Eine Ebene liegt als Boden in der XZ-Ebene; die Normale zeigt nach oben.
        baseRotation = Vector3D(x: -Double.pi / 2, y: 0, z: 0)

    case .text(let value, let size):
        let text = SCNText(string: value, extrusionDepth: 0)
        text.font = labelFont(size: CGFloat(size))
        text.flatness = 0.15
        text.isWrapped = false
        geometry = text
    }

    let material = SCNMaterial()
    if object.roughness != nil || object.metalness != nil {
        material.lightingModel = .physicallyBased
        material.diffuse.contents = nsColor(object.color)
        material.metalness.contents = NSNumber(value: object.metalness ?? 0.0)
        material.roughness.contents = NSNumber(value: object.roughness ?? 0.5)
    } else {
        material.lightingModel = .blinn
        material.diffuse.contents = nsColor(object.color)
    }
    material.isDoubleSided = true
    if object.emissive {
        material.emission.contents = nsColor(object.color)
        material.emission.intensity = CGFloat(object.emissiveIntensity)
    }
    geometry.materials = [material]

    let node = SCNNode(geometry: geometry)
    node.position = scnVector(object.position)
    node.eulerAngles = SCNVector3(
        x: CGFloat(baseRotation.x + object.rotation.x),
        y: CGFloat(baseRotation.y + object.rotation.y),
        z: CGFloat(baseRotation.z + object.rotation.z)
    )
    if case .text = object.geometry {
        // SCNText ist linksbündig und auf der Grundlinie; für Beschriftungen
        // ist der Mittelpunkt praktischer.
        let bounds = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(
            (bounds.min.x + bounds.max.x) / 2,
            (bounds.min.y + bounds.max.y) / 2,
            (bounds.min.z + bounds.max.z) / 2
        )
    }
    if object.billboard {
        node.constraints = [SCNBillboardConstraint()]
    }
    return node
}

/// Setzt die Kamera für `time`; ohne `orbit` bleibt sie stehen.
private func placeCamera3D(_ node: SCNNode, for scene: Scene3D, at time: Double) {
    if let path = scene.camera.path, path.count >= 2 {
        let clamped = min(max(time, 0), scene.duration)
        var start = path[0]
        var end = path[path.count - 1]
        for index in 0..<(path.count - 1) {
            if clamped >= path[index].time && clamped <= path[index + 1].time {
                start = path[index]
                end = path[index + 1]
                break
            }
        }
        let span = max(end.time - start.time, 0.0001)
        var fraction = min(max((clamped - start.time) / span, 0), 1)
        fraction = fraction * fraction * (3 - 2 * fraction)
        node.position = scnVector(lerpVector(start.position, end.position, fraction))
        let focus = lerpVector(start.target, end.target, fraction)
        node.look(
            at: scnVector(focus),
            up: SCNVector3(x: 0, y: 1, z: 0),
            localFront: SCNNode.localFront
        )
        return
    }

    let target = scene.camera.target
    var offset = Vector3D(
        x: scene.camera.position.x - target.x,
        y: scene.camera.position.y - target.y,
        z: scene.camera.position.z - target.z
    )

    if let orbit = scene.camera.orbit, scene.duration > 0 {
        let fraction = min(max(time / scene.duration, 0), 1)
        let angle = orbit.degrees * Double.pi / 180 * fraction
        offset = rotate3D(offset, around: orbit.axis, by: angle)
    }

    node.position = scnVector(
        Vector3D(
            x: target.x + offset.x,
            y: target.y + offset.y,
            z: target.z + offset.z
        )
    )
    node.look(
        at: scnVector(target),
        up: SCNVector3(x: 0, y: 1, z: 0),
        localFront: SCNNode.localFront
    )
}

/// Lineare Interpolation zwischen zwei Punkten.
private func lerpVector(_ a: Vector3D, _ b: Vector3D, _ t: Double) -> Vector3D {
    Vector3D(
        x: a.x + (b.x - a.x) * t,
        y: a.y + (b.y - a.y) * t,
        z: a.z + (b.z - a.z) * t
    )
}

/// Dreht einen Vektor um eine Achse (Rechtssystem, Bogenmaß).
private func rotate3D(_ vector: Vector3D, around axis: OrbitAxis, by angle: Double) -> Vector3D {
    let cosine = cos(angle)
    let sine = sin(angle)
    switch axis {
    case .x:
        return Vector3D(
            x: vector.x,
            y: vector.y * cosine - vector.z * sine,
            z: vector.y * sine + vector.z * cosine
        )
    case .y:
        return Vector3D(
            x: vector.x * cosine + vector.z * sine,
            y: vector.y,
            z: -vector.x * sine + vector.z * cosine
        )
    case .z:
        return Vector3D(
            x: vector.x * cosine - vector.y * sine,
            y: vector.x * sine + vector.y * cosine,
            z: vector.z
        )
    }
}

/// SCNVector3 aus der geprüften Szene.
private func scnVector(_ vector: Vector3D) -> SCNVector3 {
    SCNVector3(x: CGFloat(vector.x), y: CGFloat(vector.y), z: CGFloat(vector.z))
}

/// Lädt die gebündelte Schrift einmal pro Prozess (für 3D-Beschriftungen).
private let bundledLabelFont: Bool = {
    let font = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("assets/fonts/PT_Sans-Web-Regular.ttf")
    guard FileManager.default.fileExists(atPath: font.path) else {
        FileHandle.standardError.write(Data("Scene3D: Schrift fehlt (\(font.path))\n".utf8))
        return false
    }
    var error: Unmanaged<CFError>?
    let registered = CTFontManagerRegisterFontsForURL(font as CFURL, .process, &error)
    if !registered {
        FileHandle.standardError.write(Data("Scene3D: Schrift nicht registrierbar\n".utf8))
    }
    return registered
}()

/// Schrift für 3D-Text: gebündelte PT Sans, sonst Systemschrift.
private func labelFont(size: CGFloat) -> NSFont {
    _ = bundledLabelFont
    return NSFont(name: "PTSans-Regular", size: size)
        ?? NSFont.systemFont(ofSize: size)
}

/// NSColor (sRGB) aus der geprüften Farbe; Anteile werden begrenzt.
private func nsColor(_ color: Color3D) -> NSColor {
    NSColor(
        srgbRed: CGFloat(min(max(color.red, 0), 1)),
        green: CGFloat(min(max(color.green, 0), 1)),
        blue: CGFloat(min(max(color.blue, 0), 1)),
        alpha: 1
    )
}

/// NSImage des Snapshots als CGImage in Zielgröße.
///
/// `snapshot(atTime:with:)` liefert Punkte; auf Retina-Displays kann das
/// CGImage größer sein. Dann wird auf die Frame-Größe skaliert.
private func cgImage(
    from image: NSImage,
    width: Int,
    height: Int,
    index: Int
) throws -> CGImage {
    var proposed = CGRect(x: 0, y: 0, width: width, height: height)
    guard let raw = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
        throw VideoError("SceneKit liefert kein Bild für Frame \(index)")
    }
    if raw.width == width, raw.height == height {
        return raw
    }
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw VideoError("Frame \(index) lässt sich nicht skalieren")
    }
    context.interpolationQuality = .high
    context.draw(raw, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else {
        throw VideoError("Frame \(index) lässt sich nicht skalieren")
    }
    return scaled
}

/// Schreibt ein CGImage als PNG.
private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        throw VideoError("PNG lässt sich nicht anlegen: \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw VideoError("PNG lässt sich nicht schreiben: \(url.lastPathComponent)")
    }
}
