// Effects.swift — Bild-Effekte über CoreImage (Schritt 17).
//
// Die Effekte werden in der angegebenen Reihenfolge auf jeden Frame angewandt,
// bevor er in den Encoder geht. Ohne Effekte entsteht keine Effekt-Kette: der
// Frame geht unverändert in den Pixelpuffer, damit der Golden-Test byte-gleiche
// Ergebnisse sieht.
//
// Erlaubt sind (unbekannte Felder und unplausible Werte werden abgelehnt):
//   {"type": "blur", "radius": 8.0}
//   {"type": "bloom", "intensity": 0.6, "radius": 10.0}
//   {"type": "color", "saturation": 1.1, "contrast": 1.05, "brightness": 0.0}
//   {"type": "vignette", "intensity": 0.6, "radius": 1.5}
//
// Ein `CIContext` mit Metal-Device wird einmal je Lauf angelegt; die Ausdehnung
// der Kette wird auf die Frame-Größe zugeschnitten (Blur und Bloom wachsen).

import CoreGraphics
import CoreImage
import Foundation
import MCP
import Metal

/// Ein geprüfter Effekt; die Reihenfolge im Array ist die Anwendungsreihenfolge.
enum EffectSpec: Sendable {
    case blur(radius: Double)
    case bloom(intensity: Double, radius: Double)
    case color(saturation: Double, contrast: Double, brightness: Double)
    case vignette(intensity: Double, radius: Double)

    /// Name für Fehlermeldungen.
    var typeName: String {
        switch self {
        case .blur: return "blur"
        case .bloom: return "bloom"
        case .color: return "color"
        case .vignette: return "vignette"
        }
    }

    /// CoreImage-Filter der Kette.
    var filterName: String {
        switch self {
        case .blur: return "CIGaussianBlur"
        case .bloom: return "CIBloom"
        case .color: return "CIColorControls"
        case .vignette: return "CIVignette"
        }
    }

    /// Filterparameter ohne `inputImage`.
    var parameters: [String: Any] {
        switch self {
        case .blur(let radius):
            return ["inputRadius": radius]
        case .bloom(let intensity, let radius):
            return ["inputIntensity": intensity, "inputRadius": radius]
        case .color(let saturation, let contrast, let brightness):
            return [
                "inputSaturation": saturation,
                "inputContrast": contrast,
                "inputBrightness": brightness,
            ]
        case .vignette(let intensity, let radius):
            return ["inputIntensity": intensity, "inputRadius": radius]
        }
    }
}

// MARK: - Grenzen der Effektwerte

/// Grenzen, außerhalb derer ein Effekt abgelehnt wird.
private let effectRadiusRange = 0.0...1000.0
private let effectIntensityRange = 0.0...100.0
private let effectSaturationRange = 0.0...10.0
private let effectContrastRange = 0.0...10.0
private let effectBrightnessRange = -1.0...1.0

// MARK: - Prüfen der Tool-Argumente

extension EffectSpec {
    /// Liest `effects` aus den Tool-Argumenten; fehlt das Feld, gibt es keine.
    static func list(in arguments: [String: Value]) throws -> [EffectSpec] {
        guard let raw = arguments["effects"], !raw.isNull else { return [] }
        guard let values = raw.arrayValue else {
            throw VideoError("effects muss ein JSON-Array sein")
        }
        return try values.enumerated().map { index, value in
            try parse(value, at: index)
        }
    }

    /// Prüft einen einzelnen Effekt; `index` steht in jeder Meldung.
    static func parse(_ value: Value, at index: Int) throws -> EffectSpec {
        let path = "effects[\(index)]"
        guard let object = value.objectValue else {
            throw VideoError("\(path) muss ein JSON-Objekt sein")
        }
        guard let type = object["type"]?.stringValue else {
            throw VideoError("\(path).type fehlt (erwartet blur, bloom, color, vignette)")
        }

        switch type {
        case "blur":
            try rejectUnknown(object, path: path, allowed: ["type", "radius"])
            let radius = try number(object, key: "radius", path: path, fallback: nil)
            try check("\(path).radius", radius, in: effectRadiusRange)
            return .blur(radius: radius)

        case "bloom":
            try rejectUnknown(object, path: path, allowed: ["type", "intensity", "radius"])
            let intensity = try number(object, key: "intensity", path: path, fallback: nil)
            let radius = try number(object, key: "radius", path: path, fallback: 10.0)
            try check("\(path).intensity", intensity, in: effectIntensityRange)
            try check("\(path).radius", radius, in: effectRadiusRange)
            return .bloom(intensity: intensity, radius: radius)

        case "color":
            try rejectUnknown(
                object,
                path: path,
                allowed: ["type", "saturation", "contrast", "brightness"]
            )
            let saturation = try number(object, key: "saturation", path: path, fallback: 1.0)
            let contrast = try number(object, key: "contrast", path: path, fallback: 1.0)
            let brightness = try number(object, key: "brightness", path: path, fallback: 0.0)
            try check("\(path).saturation", saturation, in: effectSaturationRange)
            try check("\(path).contrast", contrast, in: effectContrastRange)
            try check("\(path).brightness", brightness, in: effectBrightnessRange)
            return .color(
                saturation: saturation,
                contrast: contrast,
                brightness: brightness
            )

        case "vignette":
            try rejectUnknown(object, path: path, allowed: ["type", "intensity", "radius"])
            let intensity = try number(object, key: "intensity", path: path, fallback: nil)
            let radius = try number(object, key: "radius", path: path, fallback: 1.5)
            try check("\(path).intensity", intensity, in: effectIntensityRange)
            try check("\(path).radius", radius, in: effectRadiusRange)
            return .vignette(intensity: intensity, radius: radius)

        default:
            throw VideoError(
                "\(path).type ist unbekannt: \(type) "
                    + "(erwartet blur, bloom, color, vignette)"
            )
        }
    }

    /// Lehnt Felder ab, die zu diesem Effekt nicht gehören.
    private static func rejectUnknown(
        _ object: [String: Value],
        path: String,
        allowed: Set<String>
    ) throws {
        for key in object.keys.sorted() where !allowed.contains(key) {
            throw VideoError("\(path) hat ein unbekanntes Feld: \(key)")
        }
    }

    /// Zahl aus dem Argument; `fallback` gilt nur, wenn das Feld ganz fehlt.
    private static func number(
        _ object: [String: Value],
        key: String,
        path: String,
        fallback: Double?
    ) throws -> Double {
        guard let value = object[key] else {
            guard let fallback else {
                throw VideoError("\(path).\(key) fehlt")
            }
            return fallback
        }
        let number: Double
        if let double = value.doubleValue {
            number = double
        } else if let integer = value.intValue {
            number = Double(integer)
        } else {
            throw VideoError("\(path).\(key) muss eine Zahl sein")
        }
        guard number.isFinite else {
            throw VideoError("\(path).\(key) muss eine endliche Zahl sein")
        }
        return number
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

// MARK: - Anwenden auf Frames

/// Effekt-Kette mit einem gemeinsamen `CIContext` (Metal, sonst CPU).
///
/// Der Kontext wird einmal je Lauf angelegt und für alle Frames benutzt. Die
/// Klasse wird nur lokal in `encodeFrames` gehalten; sie ist deshalb nicht
/// `Sendable`.
final class EffectChain {
    let specs: [EffectSpec]

    private let context: CIContext
    private let colorSpace: CGColorSpace

    init(specs: [EffectSpec]) {
        self.specs = specs
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// Wendet die Kette in Reihenfolge an und schneidet auf `bounds` zu.
    func apply(to image: CGImage) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var current = CIImage(cgImage: image, options: [.colorSpace: colorSpace])

        for spec in specs {
            var parameters = spec.parameters
            parameters[kCIInputImageKey] = current
            guard let filter = CIFilter(name: spec.filterName, parameters: parameters) else {
                throw VideoError("Effekt \(spec.typeName) ist nicht verfügbar")
            }
            guard let output = filter.outputImage else {
                throw VideoError("Effekt \(spec.typeName) liefert kein Bild")
            }
            current = output
        }

        guard let result = context.createCGImage(
            current.cropped(to: bounds),
            from: bounds,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw VideoError(
                "Effekt-Kette liefert kein Bild (\(image.width)x\(image.height))"
            )
        }
        return result
    }

    /// Wendet die Kette auf einen Pixelpuffer an und schreibt das Ergebnis in
    /// einen zweiten Puffer.
    ///
    /// Der Weg bleibt auf der GPU: Bild und Ziel sind `CVPixelBuffer` mit
    /// Metal-Freigabe, `CIContext` rendert direkt hinein. Das ersetzt die Kette
    /// `CGImage` → Filter → `CGImage`, die je Frame über den Hauptspeicher
    /// läuft.
    func apply(to source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetWidth(destination) == width,
              CVPixelBufferGetHeight(destination) == height
        else {
            throw VideoError("Effekt-Ziel hat eine andere Größe als der Frame")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var current = CIImage(cvPixelBuffer: source)

        for spec in specs {
            var parameters = spec.parameters
            parameters[kCIInputImageKey] = current
            guard let filter = CIFilter(name: spec.filterName, parameters: parameters) else {
                throw VideoError("Effekt \(spec.typeName) ist nicht verfügbar")
            }
            guard let output = filter.outputImage else {
                throw VideoError("Effekt \(spec.typeName) liefert kein Bild")
            }
            current = output
        }

        context.render(
            current.cropped(to: bounds),
            to: destination,
            bounds: bounds,
            colorSpace: colorSpace
        )
    }
}
