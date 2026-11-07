// Analyze.swift — image understanding for ml-mcp.
//
// Two engines are combined, because neither is exact on its own:
//
//   Vision       local detectors on ANE/GPU: scene labels, salient objects,
//                rectangles, text, barcodes, animals, people, faces,
//                aesthetics and lens smudge. Fast and measurable, but it
//                only names broad categories and cannot describe details.
//   Foundation   the on-device model of macOS 27: it reads the image as an
//   Models       attachment and returns a short report in natural language.
//                It understands detail and context, but it invents brands
//                when a logo is too small, so every claim stays a claim.
//
// The result therefore separates what was measured (boxes, confidence,
// pixels) from what was interpreted (the narrative). Boxes are normalised
// with a top-left origin in *display* space — the EXIF orientation is
// applied before anything looks at the pixels, otherwise every coordinate
// describes a rotated image.

import CoreGraphics
import Foundation
import ImageIO
import Vision

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Longest edge used for analysis. Larger images cost latency without gain:
/// the model downsamples internally, and Vision works on the scaled result.
let analyzeMaxPixel = 2048

/// Upper bound for the object list in the narrative; keeps the prompt inside
/// the on-device context window.
let analyzeMaxObjects = 10

// MARK: - Model

/// One recognised scene label.
struct SceneLabel: Codable, Sendable {
    let label: String
    let confidence: Double
}

/// A detection with a box, normalised to the analysed image, top-left origin.
struct DetectedBox: Codable, Sendable {
    let label: String
    let confidence: Double
    /// One of: saliency, rectangle, animal, person, face, barcode, object.
    let source: String
    let box: CGRect
}

/// A recognised text line.
struct TextLine: Codable, Sendable {
    let text: String
    let confidence: Double
    let box: CGRect
}

/// Image facts taken from the file itself.
struct ImageMetadata: Codable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    var sourceWidth: Int
    var sourceHeight: Int
    var orientation: Int
    var format: String?
    var bytes: Int
    var make: String?
    var model: String?
    var lens: String?
    var taken: String?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
}

/// One object as described by the on-device model.
struct SceneItem: Codable, Sendable {
    let name: String
    let position: String
    let details: String
}

/// The narrative part of the result.
struct Narrative: Codable, Sendable {
    var summary: String
    var objects: [SceneItem]
    var visibleText: [String]
}

/// Everything the analysis found.
struct AnalysisResult: Codable, Sendable {
    var image: ImageMetadata
    var workingWidth: Int
    var workingHeight: Int
    /// Cropped region in normalised top-left coordinates, if one was given.
    var region: CGRect?
    var scene: [SceneLabel]
    var boxes: [DetectedBox]
    var text: [TextLine]
    var aesthetics: Double?
    var isUtility: Bool?
    var smudgeConfidence: Double?
    var narrative: Narrative?
    var answer: String?
    var timingsMS: [String: Double]
    var notes: [String]
}

// MARK: - Options

/// Detail level of the narrative.
enum AnalyzeDetail: String, Sendable {
    /// One sentence, no object list.
    case brief
    /// Summary plus object list from the model.
    case normal
    /// Normal plus one extra pass per detected box, so each box carries a name.
    case objects
}

/// Input for one analysis run.
struct AnalyzeOptions: Sendable {
    var region: CGRect?
    var question: String?
    var detail: AnalyzeDetail = .normal
    var language = "de"
    var runVision = true
    var maxLabels = 12
}

// MARK: - Errors

enum AnalyzeError: LocalizedError {
    case unreadable(String)
    case regionOutOfBounds(String)
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return detail
        case .regionOutOfBounds(let detail): return detail
        case .modelUnavailable(let detail): return detail
        }
    }
}

// MARK: - Loading

/// Reads the EXIF orientation of the first image in a file.
func imageOrientation(_ source: CGImageSource) -> CGImagePropertyOrientation {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let raw = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
    return CGImagePropertyOrientation(rawValue: raw) ?? .up
}

/// Reads the facts the file carries about itself.
func readMetadata(_ url: URL, source: CGImageSource, format: String?) -> ImageMetadata {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

    var metadata = ImageMetadata(
        pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
        pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
        sourceWidth: 0,
        sourceHeight: 0,
        orientation: Int(imageOrientation(source).rawValue),
        format: format,
        bytes: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0,
        make: tiff[kCGImagePropertyTIFFMake] as? String,
        model: tiff[kCGImagePropertyTIFFModel] as? String,
        lens: exif[kCGImagePropertyExifLensModel] as? String,
        taken: exif[kCGImagePropertyExifDateTimeOriginal] as? String,
        latitude: nil,
        longitude: nil,
        altitude: nil
    )

    // Display dimensions: a photo stored sideways swaps width and height.
    let swapsAxes = [5, 6, 7, 8].contains(metadata.orientation)
    metadata.sourceWidth = metadata.pixelWidth
    metadata.sourceHeight = metadata.pixelHeight
    if swapsAxes {
        swap(&metadata.pixelWidth, &metadata.pixelHeight)
    }

    if let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
       let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
        let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        metadata.latitude = latitudeRef == "S" ? -latitude : latitude
        metadata.longitude = longitudeRef == "W" ? -longitude : longitude
        metadata.altitude = gps[kCGImagePropertyGPSAltitude] as? Double
    }
    return metadata
}

/// Loads an image upright and scaled down to `maxPixel` on the longest edge.
///
/// `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnail
/// WithTransform` is the only reliable way: a plain decode returns the stored
/// pixels, which for a portrait iPhone photo are 90° rotated.
func loadUpright(_ url: URL, maxPixel: Int) throws -> (CGImage, ImageMetadata) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw AnalyzeError.unreadable("Datei ist kein lesbares Bild: \(url.lastPathComponent)")
    }
    let type = CGImageSourceGetType(source) as String?
    let metadata = readMetadata(url, source: source, format: type)

    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw AnalyzeError.unreadable("Bild konnte nicht dekodiert werden: \(url.lastPathComponent)")
    }
    return (image, metadata)
}

/// Crops a normalised region (top-left origin) out of an upright image.
func cropImage(_ image: CGImage, region: CGRect) throws -> CGImage {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let rect = CGRect(
        x: (region.minX * width).rounded(),
        y: (region.minY * height).rounded(),
        width: max(1, (region.width * width).rounded()),
        height: max(1, (region.height * height).rounded())
    ).intersection(CGRect(x: 0, y: 0, width: width, height: height))

    guard !rect.isNull, rect.width >= 8, rect.height >= 8 else {
        throw AnalyzeError.regionOutOfBounds("Region ist zu klein oder liegt außerhalb")
    }
    guard let cropped = image.cropping(to: rect) else {
        throw AnalyzeError.regionOutOfBounds("Region ließ sich nicht ausschneiden")
    }
    return cropped
}

// MARK: - Vision

/// Result of the detector pass.
struct VisionFindings: Sendable {
    var scene: [SceneLabel] = []
    var boxes: [DetectedBox] = []
    var text: [TextLine] = []
    var aesthetics: Double?
    var isUtility: Bool?
    var smudgeConfidence: Double?
    var timingsMS: [String: Double] = [:]
    var notes: [String] = []
}

/// Converts a Vision box (bottom-left origin) into display space (top-left).
func displayBox(_ box: CGRect) -> CGRect {
    CGRect(
        x: box.minX,
        y: 1 - box.maxY,
        width: box.width,
        height: box.height
    ).standardized
}

/// Runs the local detectors. Each request fails on its own: a missing model
/// on one detector must not lose the rest of the analysis.
func runVision(_ image: CGImage, options: AnalyzeOptions) async -> VisionFindings {
    var findings = VisionFindings()
    guard options.runVision else { return findings }

    func timed<T>(_ name: String, _ work: () async throws -> T) async -> T? {
        let started = Date()
        defer { findings.timingsMS[name] = Date().timeIntervalSince(started) * 1000 }
        do {
            return try await work()
        } catch {
            findings.notes.append("\(name) fehlgeschlagen: \(error.localizedDescription)")
            return nil
        }
    }

    let classifications = await timed("classify") { () -> [ClassificationObservation] in
        try await ClassifyImageRequest().perform(on: image)
    }
    if let classifications {
        findings.scene = classifications
            .sorted { $0.confidence > $1.confidence }
            .prefix(options.maxLabels)
            .map { SceneLabel(label: $0.identifier, confidence: Double($0.confidence)) }
    }

    let saliency = await timed("saliency") { () -> SaliencyImageObservation in
        try await GenerateObjectnessBasedSaliencyImageRequest().perform(on: image)
    }
    if let saliency {
        for object in saliency.salientObjects {
            findings.boxes.append(
                DetectedBox(
                    label: "salient object",
                    confidence: Double(object.confidence),
                    source: "saliency",
                    box: displayBox(object.boundingBox.cgRect)
                )
            )
        }
    }

    let rectangles = await timed("rectangles") { () -> [RectangleObservation] in
        var request = DetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.minimumSize = 0.04
        request.minimumConfidence = 0.5
        request.maximumObservations = 8
        request.quadratureToleranceDegrees = 30
        return try await request.perform(on: image)
    }
    if let rectangles {
        for rectangle in rectangles {
            findings.boxes.append(
                DetectedBox(
                    label: "rectangle",
                    confidence: Double(rectangle.confidence),
                    source: "rectangle",
                    box: displayBox(rectangle.boundingBox.cgRect)
                )
            )
        }
    }

    let barcodes = await timed("barcodes") { () -> [BarcodeObservation] in
        try await DetectBarcodesRequest().perform(on: image)
    }
    if let barcodes {
        for barcode in barcodes {
            let payload = barcode.payloadString ?? ""
            findings.boxes.append(
                DetectedBox(
                    label: payload.isEmpty ? String(describing: barcode.symbology) : payload,
                    confidence: Double(barcode.confidence),
                    source: "barcode",
                    box: displayBox(barcode.boundingBox.cgRect)
                )
            )
        }
    }

    let animals = await timed("animals") { () -> [RecognizedObjectObservation] in
        try await RecognizeAnimalsRequest().perform(on: image)
    }
    if let animals {
        for animal in animals {
            let name = animal.labels.max { $0.confidence < $1.confidence }?.identifier ?? "animal"
            findings.boxes.append(
                DetectedBox(
                    label: name,
                    confidence: Double(animal.confidence),
                    source: "animal",
                    box: displayBox(animal.boundingBox.cgRect)
                )
            )
        }
    }

    let people = await timed("people") { () -> [HumanObservation] in
        try await DetectHumanRectanglesRequest().perform(on: image)
    }
    if let people {
        for person in people {
            findings.boxes.append(
                DetectedBox(
                    label: person.isUpperBodyOnly ? "person (upper body)" : "person",
                    confidence: Double(person.confidence),
                    source: "person",
                    box: displayBox(person.boundingBox.cgRect)
                )
            )
        }
    }

    let faces = await timed("faces") { () -> [FaceObservation] in
        try await DetectFaceRectanglesRequest().perform(on: image)
    }
    if let faces {
        for (index, face) in faces.enumerated() {
            findings.boxes.append(
                DetectedBox(
                    label: "face \(index + 1)",
                    confidence: Double(face.confidence),
                    source: "face",
                    box: displayBox(face.boundingBox.cgRect)
                )
            )
        }
    }

    let aesthetics = await timed("aesthetics") { () -> ImageAestheticsScoresObservation in
        try await CalculateImageAestheticsScoresRequest().perform(on: image)
    }
    if let aesthetics {
        findings.aesthetics = Double(aesthetics.overallScore)
        findings.isUtility = aesthetics.isUtility
    }

    let smudge = await timed("smudge") { () -> SmudgeObservation in
        try await DetectLensSmudgeRequest().perform(on: image)
    }
    if let smudge {
        findings.smudgeConfidence = Double(smudge.confidence)
    }

    let text = await timed("text") { () -> [RecognizedTextObservation] in
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        return try await request.perform(on: image)
    }
    if let text {
        findings.text = text
            .map {
                TextLine(
                    text: $0.transcript,
                    confidence: Double($0.confidence),
                    box: displayBox($0.boundingBox.cgRect)
                )
            }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.box.minY < $1.box.minY }
    }
    return findings
}

// MARK: - Foundation model

#if canImport(FoundationModels)
    /// Instructions that keep the model on the visible evidence.
    ///
    /// A rigid output schema invites invention — measured on 2026-11-07: the
    /// same image produced "power supply with a red button and a light-bulb
    /// logo" through `@Generable`, while a free answer named the correct
    /// brand. The fixed layout below is therefore requested in the prompt and
    /// parsed afterwards, not enforced by a schema.
    func analyzeInstructions(_ language: String) -> String {
        if language == "de" {
            return """
            Du bist ein technischer Bildanalyst. Beschreibe ausschließlich, was \
            sichtbar ist. Nenne Marke und Gerätetyp nur, wenn sie lesbar oder \
            eindeutig erkennbar sind, sonst schreib „Marke nicht lesbar“. \
            Nenne Anschlüsse, Tasten und Anzeigen nur, wenn du sie klar \
            erkennst; ein Logo ist keine Taste. Antworte auf Deutsch.
            """
        }
        return """
        You are a technical image analyst. Describe only what is visible. Name \
        a brand or device type only when it is legible or unambiguous, \
        otherwise write "brand not legible". Do not invent buttons, displays or \
        labels. Answer in English.
        """
    }

    /// Prompt text as a value, so the caller reads the same wording everywhere.
    func analyzePromptBlock(_ options: AnalyzeOptions) -> String {
        var text = ""
        if let region = options.region {
            text += options.language == "de"
                ? "Der Ausschnitt zeigt den Bereich ab \(Int(region.minX * 100)) % / \(Int(region.minY * 100)) %, Größe \(Int(region.width * 100)) % × \(Int(region.height * 100)) % des Originalbildes. "
                : "The crop covers \(Int(region.minX * 100)) % / \(Int(region.minY * 100)) % of the original, size \(Int(region.width * 100)) % × \(Int(region.height * 100)) %. "
        }
        switch options.detail {
        case .brief:
            text += options.language == "de"
                ? "Was zeigt das Bild? Antworte in einem Satz."
                : "What does the image show? Answer in one sentence."
        case .normal, .objects:
            text += options.language == "de"
                ? """
                Antworte in genau diesem Aufbau, ohne Einleitung:
                Zusammenfassung: ein Satz, welches Gerät oder welche Situation zu sehen ist.
                Dann je Gegenstand eine Zeile: - Name | Position | sichtbare Details (Farbe, Material, Bauform, Anschlüsse, Kabel, Beschriftung).
                Lass weg, was du nicht erkennst, statt „keine“ zu schreiben.
                Zum Schluss eine Zeile: Text: alle klar lesbaren Zeichenketten, sonst „keiner“.
                """
                : """
                Reply in exactly this layout, without a preamble:
                Summary: one sentence naming the device or situation.
                Then one line per object: - name | position | visible detail (colour, material, shape, connectors, cables, lettering).
                Leave out what you cannot see instead of writing "none".
                Finally one line: Text: every clearly legible character string, otherwise "none".
                """
        }
        if let question = options.question, !question.isEmpty {
            text += options.language == "de" ? " Beantworte außerdem: \(question)" : " Also answer: \(question)"
        }
        return text
    }

    /// Parses the fixed layout back into a narrative. Anything that does not
    /// match ends up in the summary instead of being dropped.
    func parseNarrative(_ text: String) -> Narrative {
        var summaryParts: [String] = []
        var objects: [SceneItem] = []
        var visibleText: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let lower = line.lowercased()
            let bare = lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if bare == "keiner" || bare == "keine" || bare == "none" { continue }
            if lower.hasPrefix("zusammenfassung:") || lower.hasPrefix("summary:") {
                let value = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { summaryParts.append(value) }
                continue
            }
            if lower.hasPrefix("text:") {
                let value = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, value.lowercased() != "keiner", value.lowercased() != "none" {
                    visibleText.append(value)
                }
                continue
            }
            if line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if let item = parseSceneItem(body), item.name.lowercased() != "text" {
                    objects.append(item)
                } else if !body.isEmpty {
                    summaryParts.append(body)
                }
                continue
            }
            summaryParts.append(line)
        }

        return Narrative(
            summary: summaryParts.joined(separator: " "),
            objects: Array(objects.prefix(analyzeMaxObjects)),
            visibleText: visibleText
        )
    }

    /// Splits "- name | position | details" into its three fields; the older
    /// "name (position): details" layout stays supported.
    func parseSceneItem(_ body: String) -> SceneItem? {
        var name = body
        var position = ""
        var details = ""

        let pipes = body.components(separatedBy: "|")
        if pipes.count >= 2 {
            name = pipes[0]
            position = pipes[1]
            details = pipes.dropFirst(2).joined(separator: "|")
            name = name.trimmingCharacters(in: .whitespaces)
            position = position.trimmingCharacters(in: .whitespaces)
            details = details.trimmingCharacters(in: .whitespaces)
        } else {
            if let colon = body.range(of: ":") {
                name = String(body[body.startIndex ..< colon.lowerBound])
                details = String(body[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
                position = String(name[name.index(after: open) ..< close])
                    .trimmingCharacters(in: .whitespaces)
                name = String(name[name.startIndex ..< open])
            }
            name = name.trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty else { return nil }
        return SceneItem(name: name, position: position, details: details)
    }

    /// Names every text claim the model makes that the OCR pass did not read.
    ///
    /// A 3B on-device model invents lettering when a logo is small (measured:
    /// "u", "10" on a picture without text). Comparing its quotes with the
    /// Vision result turns that into a warning instead of a silent error.
    func unsupportedTextClaims(_ narrative: Narrative, ocrText: [TextLine]) -> [String] {
        let read = ocrText.map(\.text).joined(separator: " ").lowercased()
        return narrative.visibleText.filter { claim in
            let needle = claim.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard needle.count >= 2 else { return false }
            return !read.contains(needle)
        }
    }

    /// Runs the narrative pass. Returns nil when the on-device model is off.
    @available(macOS 27.0, *)
    func runModel(
        image: CGImage,
        options: AnalyzeOptions
    ) async -> (narrative: Narrative?, answer: String?, note: String?, ms: Double) {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return (nil, nil, "Sprachmodell nicht verfügbar: \(model.availability)", 0)
        }

        let started = Date()
        let session = LanguageModelSession(instructions: analyzeInstructions(options.language))
        var narrative: Narrative?
        do {
            let response = try await session.respond(
                to: Prompt {
                    analyzePromptBlock(options)
                    Attachment(image, orientation: .up)
                }
            )
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            narrative = options.detail == .brief
                ? Narrative(summary: content, objects: [], visibleText: [])
                : parseNarrative(content)
        } catch {
            return (nil, nil, "Sprachmodell ohne Ergebnis: \(error.localizedDescription)", 0)
        }

        // A separate, short question keeps the answer out of the report.
        var answer: String?
        if let question = options.question, !question.isEmpty {
            do {
                let response = try await session.respond(
                    to: Prompt {
                        question
                        Attachment(image, orientation: .up)
                    }
                )
                answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return (narrative, nil, "Frage ohne Antwort: \(error.localizedDescription)", 0)
            }
        }
        return (narrative, answer, nil, Date().timeIntervalSince(started) * 1000)
    }

    /// Names a single box by cropping it and asking for the object alone.
    ///
    /// Only boxes large enough to carry an object are labelled: a 4 % × 4 %
    /// crop of a power strip produced "graffiti spray can by POG" on
    /// 2026-11-07. Rectangles are structural parts (a logo plate, a socket),
    /// not objects, so they keep their geometric label.
    @available(macOS 27.0, *)
    func labelBoxes(
        image: CGImage,
        boxes: [DetectedBox],
        language: String
    ) async -> [DetectedBox] {
        guard SystemLanguageModel.default.isAvailable else { return boxes }
        var result = boxes
        let candidates = result.indices.filter { index in
            let box = result[index]
            let area = box.box.width * box.box.height
            let source = ["saliency", "animal", "person", "face"]
            return area >= 0.03 && area <= 0.95 && source.contains(box.source)
        }.prefix(4)

        for index in candidates {
            let box = result[index]
            // Margin around the box, so the object is not cut at its edge.
            let padded = box.box.insetBy(dx: -0.02, dy: -0.02)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let crop = try? cropImage(image, region: padded) else { continue }
            let question = language == "de"
                ? "Welcher Gegenstand ist auf diesem Ausschnitt zu sehen? Nenne ihn in zwei bis fünf Wörtern, mit Marke und Typ wenn lesbar. Zeigt der Ausschnitt keinen klaren Gegenstand, antworte nur: unklar."
                : "Which object is in this crop? Name it in two to five words, with brand and type when legible. If the crop shows no clear object, answer only: unclear."
            let session = LanguageModelSession()
            guard let response = try? await session.respond(
                to: Prompt {
                    question
                    Attachment(crop, orientation: .up)
                }
            ) else { continue }

            let label = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !label.lowercased().hasPrefix("unklar"),
                  !label.lowercased().hasPrefix("unclear")
            else { continue }
            result[index] = DetectedBox(
                label: label,
                confidence: box.confidence,
                source: box.source,
                box: box.box
            )
        }
        return result
    }
#endif

// MARK: - Entry point

/// Analyses one image: facts from the file, detections from Vision, meaning
/// from the on-device model.
func analyzeImage(url: URL, options: AnalyzeOptions) async throws -> AnalysisResult {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw AnalyzeError.unreadable("Datei fehlt: \(url.lastPathComponent)")
    }

    let (full, metadata) = try loadUpright(url, maxPixel: analyzeMaxPixel)
    var image = full

    if let region = options.region {
        image = try cropImage(full, region: region)
    }

    var result = AnalysisResult(
        image: metadata,
        workingWidth: image.width,
        workingHeight: image.height,
        region: options.region,
        scene: [],
        boxes: [],
        text: [],
        aesthetics: nil,
        isUtility: nil,
        smudgeConfidence: nil,
        narrative: nil,
        answer: nil,
        timingsMS: [:],
        notes: []
    )

    let findings = await runVision(image, options: options)
    result.scene = findings.scene
    result.boxes = findings.boxes
    result.text = findings.text
    result.aesthetics = findings.aesthetics
    result.isUtility = findings.isUtility
    result.smudgeConfidence = findings.smudgeConfidence
    result.timingsMS.merge(findings.timingsMS) { _, new in new }
    result.notes.append(contentsOf: findings.notes)

    #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let model = await runModel(image: image, options: options)
            result.timingsMS["model"] = model.ms
            result.narrative = model.narrative
            result.answer = model.answer
            if let note = model.note { result.notes.append(note) }

            if let narrative = result.narrative {
                let unsupported = unsupportedTextClaims(narrative, ocrText: result.text)
                if !unsupported.isEmpty {
                    result.notes.append(
                        "Modell nennt Text, den die Texterkennung nicht liest: "
                            + unsupported.prefix(4).joined(separator: ", ")
                    )
                }
            }

            if options.detail == .objects, !result.boxes.isEmpty {
                let labelStart = Date()
                let labeled = await labelBoxes(
                    image: image,
                    boxes: result.boxes,
                    language: options.language
                )
                result.boxes = labeled
                result.timingsMS["box labels"] = Date().timeIntervalSince(labelStart) * 1000
            }
        } else {
            result.notes.append("Sprachmodell braucht macOS 27")
        }
    #else
        result.notes.append("FoundationModels ist im SDK nicht vorhanden")
    #endif

    if let aesthetics = result.aesthetics, aesthetics < 0.3, result.region == nil {
        result.notes.append("Bildqualität niedrig (Ästhetik \(formatScore(aesthetics)))")
    }
    if let smudge = result.smudgeConfidence, smudge > 0.5 {
        result.notes.append("Objektiv verschmutzt (Konfidenz \(formatScore(smudge)))")
    }
    return result
}

// MARK: - Rendering

/// Two decimals for scores.
func formatScore(_ value: Double) -> String {
    String(format: "%.2f", value)
}

/// Box as percentages in display space, e.g. "x 12 % y 8 % w 40 % h 30 %".
func formatBox(_ box: CGRect) -> String {
    String(
        format: "x %.0f %% y %.0f %% w %.0f %% h %.0f %%",
        box.minX * 100,
        box.minY * 100,
        box.width * 100,
        box.height * 100
    )
}

/// Renders the analysis as text for the tool result.
func renderAnalysis(_ result: AnalysisResult, question: String?) -> String {
    var lines: [String] = []
    let image = result.image
    lines.append(
        "Bild: \(image.pixelWidth)×\(image.pixelHeight)"
            + " (Quelle \(image.sourceWidth)×\(image.sourceHeight), Orientierung \(image.orientation))"
            + ", \(image.format ?? "unbekannt"), \(String(format: "%.2f", Double(image.bytes) / 1_048_576)) MB"
    )
    lines.append("Arbeitsgröße: \(result.workingWidth)×\(result.workingHeight)")
    if let region = result.region {
        lines.append("Ausschnitt: \(formatBox(region))")
    }
    let camera = [image.make, image.model, image.lens].compactMap { $0 }.joined(separator: ", ")
    if !camera.isEmpty { lines.append("Kamera: \(camera)") }
    if let taken = image.taken { lines.append("Aufnahme: \(taken)") }
    if let latitude = image.latitude, let longitude = image.longitude {
        let altitude = image.altitude.map { String(format: ", %.0f m", $0) } ?? ""
        lines.append(String(format: "Ort: %.5f, %.5f%@", latitude, longitude, altitude))
    }

    if !result.scene.isEmpty {
        lines.append("Szene: " + result.scene.prefix(8).map {
            "\($0.label) \(formatScore($0.confidence))"
        }.joined(separator: ", "))
    }

    if !result.boxes.isEmpty {
        lines.append("Erkannte Flächen:")
        for box in result.boxes.prefix(10) {
            lines.append(
                "  \(box.source) \(formatScore(box.confidence)) — \(box.label) — \(formatBox(box.box))"
            )
        }
    }

    if !result.text.isEmpty {
        lines.append("Text im Bild:")
        for line in result.text.prefix(20) {
            lines.append("  \(formatScore(line.confidence)) \(line.text)")
        }
    } else {
        lines.append("Text im Bild: keiner")
    }

    var technical: [String] = []
    if let aesthetics = result.aesthetics {
        technical.append("Ästhetik \(formatScore(aesthetics))")
    }
    if let utility = result.isUtility {
        technical.append("Gebrauchsbild: \(utility ? "ja" : "nein")")
    }
    if let smudge = result.smudgeConfidence {
        technical.append("Objektivschmutz \(formatScore(smudge))")
    }
    if !technical.isEmpty { lines.append("Technik: " + technical.joined(separator: ", ")) }

    if let narrative = result.narrative {
        lines.append("")
        lines.append("Deutung: \(narrative.summary)")
        if !narrative.objects.isEmpty {
            for item in narrative.objects {
                lines.append("  - \(item.name) (\(item.position)): \(item.details)")
            }
        }
        if !narrative.visibleText.isEmpty {
            lines.append("  Lesbarer Text laut Modell: \(narrative.visibleText.joined(separator: " | "))")
        }
    }

    if let answer = result.answer, !answer.isEmpty {
        lines.append("")
        lines.append("Antwort: \(answer)")
    }

    let total = result.timingsMS.values.reduce(0, +)
    let timings = result.timingsMS.sorted { $0.key < $1.key }
        .map { "\($0.key) \(String(format: "%.0f", $0.value)) ms" }
        .joined(separator: ", ")
    lines.append("")
    lines.append("Dauer: \(String(format: "%.1f", total)) ms (\(timings))")

    if !result.notes.isEmpty {
        lines.append("Hinweise: " + result.notes.joined(separator: "; "))
    }
    return lines.joined(separator: "\n")
}

/// Renders the analysis as JSON, for machine use.
func renderAnalysisJSON(_ result: AnalysisResult) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    return String(decoding: data, as: UTF8.self)
}
