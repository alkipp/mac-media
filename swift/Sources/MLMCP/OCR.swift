// OCR.swift — schnelle Texterkennung für ml-mcp.
//
// Vision erkennt Text ohne eigenes Modell auf ANE/GPU; ein PDF mit Textebene
// wird ohne OCR gelesen, nur Seiten ohne Text werden gerendert und erkannt.
// Seiten laufen gebündelt parallel (Standard vier gleichzeitig), damit ein
// Scan mit 17 Seiten nicht 17-mal Wartezeit kostet.
//
// `PDFDocument` und `CGImage` sind nicht `Sendable`; sie werden deshalb nur
// seriell gelesen bzw. gerendert und über `SendableImage` an die Aufgaben
// gereicht. Ergebnisse sind reine Werte.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// Kleinste Zeichenzahl, ab der eine PDF-Seite als „hat Textebene“ gilt.
let pdfTextThreshold = 40

/// Gerendertes Bild, das eine Isolationsgrenze überqueren darf.
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

/// Eine erkannte Zeile mit Position (normiert, Ursprung unten links).
struct OCRLine: Sendable {
    let text: String
    let confidence: Float
    let box: CGRect
}

/// Ergebnis einer Seite.
struct OCRPageResult: Sendable {
    let index: Int
    let source: String
    let width: Int
    let height: Int
    let ms: Double
    let lines: [OCRLine]

    var text: String { lines.map(\.text).joined(separator: "\n") }
}

/// Eingestellte Erkennung.
struct OCROptions: Sendable {
    var level: VNRequestTextRecognitionLevel = .accurate
    var languages: [String] = ["de-DE", "en-US"]
    var customWords: [String] = []
    var correction = true
    var minConfidence: Float = 0
    var dpi: CGFloat = 200
    var forceOCR = false
}

enum OCRError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case pageRange(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return detail
        case .unreadable(let detail): return detail
        case .pageRange(let detail): return detail
        }
    }
}

// MARK: - Seitenspezifikation

/// Liest „1-5,8,12-“ in nullbasierte Indizes; Reihenfolge bleibt, Doppelte fallen weg.
func parsePageRange(_ spec: String, count: Int) throws -> [Int] {
    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.isEmpty || trimmed == "alle" || trimmed == "all" || trimmed == "1-" {
        return Array(0 ..< count)
    }

    var picked: [Int] = []
    for part in trimmed.split(separator: ",") {
        let piece = part.trimmingCharacters(in: .whitespaces)
        if piece.isEmpty { continue }
        if let dash = piece.firstIndex(of: "-") {
            let left = piece[piece.startIndex ..< dash].trimmingCharacters(in: .whitespaces)
            let right = piece[piece.index(after: dash)...].trimmingCharacters(in: .whitespaces)
            let start = left.isEmpty ? 1 : (Int(left) ?? 0)
            let end = right.isEmpty ? count : (Int(right) ?? 0)
            guard start >= 1, end <= count, start <= end else {
                throw OCRError.pageRange(
                    "Seitenbereich \(piece) passt nicht zu \(count) Seiten"
                )
            }
            picked.append(contentsOf: (start ... end).map { $0 - 1 })
        } else {
            guard let number = Int(piece), number >= 1, number <= count else {
                throw OCRError.pageRange("Seite \(piece) gibt es nicht (\(count) Seiten)")
            }
            picked.append(number - 1)
        }
    }
    guard !picked.isEmpty else {
        throw OCRError.pageRange("Seitenauswahl ist leer: \(spec)")
    }

    var seen = Set<Int>()
    return picked.filter { seen.insert($0).inserted }
}

// MARK: - Erkennung

/// Erkennt Text in einem Bild und sortiert die Zeilen in Leserichtung.
func recognizeText(_ image: CGImage, options: OCROptions) throws -> ([OCRLine], Double) {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = options.level
    request.recognitionLanguages = options.languages
    request.usesLanguageCorrection = options.correction
    request.customWords = options.customWords

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let started = Date()
    try handler.perform([request])
    let ms = Date().timeIntervalSince(started) * 1000

    var lines: [OCRLine] = []
    for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let text = candidate.string.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { continue }
        if candidate.confidence < options.minConfidence { continue }
        lines.append(
            OCRLine(
                text: text,
                confidence: candidate.confidence,
                box: observation.boundingBox
            )
        )
    }
    return (sortLines(lines), ms)
}

/// Fasst Zeilen zu Zeilenbünden zusammen und ordnet sie von oben nach unten,
/// innerhalb eines Bundes von links nach rechts. Toleranz ist die halbe
/// Zeilenhöhe, damit leicht schiefe Scans nicht in Einzelzeichen zerfallen.
func sortLines(_ lines: [OCRLine]) -> [OCRLine] {
    let byY = lines.sorted { $0.box.midY > $1.box.midY }
    var rows: [[OCRLine]] = []
    for line in byY {
        if let last = rows.last, let reference = last.first {
            let tolerance = max(reference.box.height, line.box.height) * 0.5
            if abs(reference.box.midY - line.box.midY) <= tolerance {
                rows[rows.count - 1].append(line)
                continue
            }
        }
        rows.append([line])
    }
    return rows.flatMap { row in row.sorted { $0.box.minX < $1.box.minX } }
}

/// Erkennt eine Seite und liefert Position, Quelle und Dauer.
func ocrPage(_ image: CGImage, index: Int, options: OCROptions) throws -> OCRPageResult {
    let (lines, ms) = try recognizeText(image, options: options)
    return OCRPageResult(
        index: index,
        source: "vision",
        width: image.width,
        height: image.height,
        ms: ms,
        lines: lines
    )
}

// MARK: - PDF

/// Rendert eine PDF-Seite in `dpi`. Seiten ohne Drehung zeichnet ein eigener
/// Kontext pixelgenau; gedrehte Seiten gehen über PDFKit, das die Drehung
/// bereits berücksichtigt.
func renderPage(_ page: PDFPage, dpi: CGFloat) throws -> CGImage {
    let box = page.bounds(for: .mediaBox)
    var scale = dpi / 72
    let longest = max(box.width, box.height) * scale
    let limit: CGFloat = 5000
    if longest > limit { scale *= limit / longest }

    let width = max(1, Int((box.width * scale).rounded()))
    let height = max(1, Int((box.height * scale).rounded()))

    if page.rotation % 360 != 0 {
        let target = NSSize(
            width: page.rotation % 180 == 0 ? box.width * scale : box.height * scale,
            height: page.rotation % 180 == 0 ? box.height * scale : box.width * scale
        )
        let thumbnail = page.thumbnail(of: target, for: .mediaBox)
        guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw OCRError.unreadable("Seite ließ sich nicht rendern") }
        return image
    }

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { throw OCRError.unreadable("Renderkontext fehlt") }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.origin.x, y: -box.origin.y)
    page.draw(with: .mediaBox, to: context)

    guard let image = context.makeImage() else {
        throw OCRError.unreadable("Seite ließ sich nicht rendern")
    }
    return image
}

/// Prüft, ob eine Datei ein PDF ist (Endung oder Kopfzeile).
func isPDF(_ url: URL) -> Bool {
    if url.pathExtension.lowercased() == "pdf" { return true }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let head = handle.readData(ofLength: 5)
    return head == Data("%PDF-".utf8)
}

/// Lädt ein Bild aus einer Datei (PNG, JPEG, TIFF, HEIC, …).
func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw OCRError.unreadable("Datei ist kein lesbares Bild: \(url.lastPathComponent)")
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw OCRError.unreadable("Bild konnte nicht dekodiert werden")
    }
    return image
}

/// Erkennt alle gewählten Seiten. Seiten mit Textebene werden übernommen,
/// der Rest gerendert und gebündelt parallel erkannt.
func runOCR(url: URL, pageSpec: String, options: OCROptions) async throws -> [OCRPageResult] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw OCRError.unreadable("Datei fehlt: \(url.lastPathComponent)")
    }

    guard isPDF(url) else {
        let image = try loadImage(url)
        return [try ocrPage(image, index: 1, options: options)]
    }

    guard let document = PDFDocument(url: url) else {
        throw OCRError.unreadable("PDF ließ sich nicht öffnen: \(url.lastPathComponent)")
    }
    let pages = try parsePageRange(pageSpec, count: document.pageCount)

    var results = [OCRPageResult?](repeating: nil, count: pages.count)
    let batchSize = 4
    var offset = 0

    while offset < pages.count {
        let batch = Array(offset ..< min(offset + batchSize, pages.count))
        var jobs: [(Int, SendableImage)] = []

        // PDFDocument wird nur hier, seriell, gelesen.
        for position in batch {
            let pageIndex = pages[position]
            guard let page = document.page(at: pageIndex) else { continue }
            let box = page.bounds(for: .mediaBox)

            if !options.forceOCR, let text = page.string {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= pdfTextThreshold {
                    results[position] = OCRPageResult(
                        index: pageIndex + 1,
                        source: "pdf-text",
                        width: Int(box.width.rounded()),
                        height: Int(box.height.rounded()),
                        ms: 0,
                        lines: trimmed
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .map { OCRLine(text: $0, confidence: 1, box: .zero) }
                    )
                    continue
                }
            }

            let image = try renderPage(page, dpi: options.dpi)
            jobs.append((position, SendableImage(image: image)))
        }

        let safeOptions = options
        let pageNumbers = pages
        try await withThrowingTaskGroup(of: (Int, OCRPageResult).self) { group in
            for (position, wrapped) in jobs {
                group.addTask {
                    let result = try ocrPage(
                        wrapped.image,
                        index: pageNumbers[position] + 1,
                        options: safeOptions
                    )
                    return (position, result)
                }
            }
            for try await (position, result) in group {
                results[position] = result
            }
        }

        offset += batchSize
    }

    return results.compactMap { $0 }
}

// MARK: - Ausgabe

/// Sprachen, die Vision für eine Erkennungsstufe anbietet (Revision 3).
func supportedOCRLanguages(level: VNRequestTextRecognitionLevel = .accurate) -> [String] {
    let probe = VNRecognizeTextRequest()
    probe.revision = VNRecognizeTextRequestRevision3
    probe.recognitionLevel = level
    return (try? probe.supportedRecognitionLanguages()) ?? []
}

/// Prüft die gewünschten Sprachen gegen die von Vision unterstützten.
func validatedLanguages(
    _ requested: [String],
    level: VNRequestTextRecognitionLevel = .accurate
) throws -> [String] {
    let supported = supportedOCRLanguages(level: level)
    guard !supported.isEmpty else { return requested }
    let normalized = Dictionary(
        supported.map { ($0.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )
    var resolved: [String] = []
    for language in requested {
        if let match = normalized[language.lowercased()] {
            resolved.append(match)
        } else {
            throw OCRError.unsupported(
                "Sprache \(language) kennt Vision nicht. Verfügbar: "
                    + supported.joined(separator: ", ")
            )
        }
    }
    return resolved
}

/// Textausgabe mit Seitenmarkern ab zwei Seiten.
func renderText(_ pages: [OCRPageResult]) -> String {
    let body = pages
        .map { page in
            pages.count > 1 ? "## Seite \(page.index)\n\(page.text)" : page.text
        }
        .joined(separator: "\n\n")
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Kurzfassung für die Dateiausgabe: Pfad, Seiten, Dauer, Quelle.
func renderSummary(
    pages: [OCRPageResult],
    totalMS: Double,
    file: String,
    sandboxPath: String
) -> String {
    let recognized = pages.filter { $0.source == "vision" }
    let textPages = pages.count - recognized.count
    var lines = [
        "Datei: \(file)",
        "Sandbox: \(sandboxPath)",
        "Seiten: \(pages.count) (\(recognized.count) per OCR, \(textPages) aus Textebene)",
        String(format: "Dauer: %.0f ms gesamt, %.0f ms je Seite", totalMS, totalMS / Double(max(pages.count, 1))),
    ]
    if !recognized.isEmpty {
        let perPage = recognized.map(\.ms).reduce(0, +) / Double(recognized.count)
        lines.append(String(format: "Erkennung: %.0f ms je OCR-Seite", perPage))
    }
    return lines.joined(separator: "\n")
}

/// JSON-Struktur für die maschinelle Weiterverarbeitung.
func renderJSON(_ pages: [OCRPageResult], totalMS: Double) -> String {
    let body: [String: Any] = [
        "pages": pages.count,
        "ms": (totalMS * 10).rounded() / 10,
        "result": pages.map { page -> [String: Any] in
            [
                "page": page.index,
                "source": page.source,
                "width": page.width,
                "height": page.height,
                "ms": (page.ms * 10).rounded() / 10,
                "text": page.text,
                "lines": page.lines.map { line -> [String: Any] in
                    [
                        "text": line.text,
                        "confidence": (Double(line.confidence) * 1000).rounded() / 1000,
                        "box": [
                            (Double(line.box.minX) * 10000).rounded() / 10000,
                            (Double(line.box.minY) * 10000).rounded() / 10000,
                            (Double(line.box.width) * 10000).rounded() / 10000,
                            (Double(line.box.height) * 10000).rounded() / 10000,
                        ],
                    ]
                },
            ]
        },
    ]
    if let data = try? JSONSerialization.data(
        withJSONObject: body,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ), let text = String(data: data, encoding: .utf8) {
        return text
    }
    return "{}"
}
