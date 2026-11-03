// MLMCPTests — Prüfungen für Seitenauswahl, Zeilenordnung und Erkennung.

import CoreGraphics
import CoreText
import Foundation
import XCTest
import Vision

@testable import MLMCP

final class PageRangeTests: XCTestCase {
    func testAlleSpaltenOhneAngabe() throws {
        XCTAssertEqual(try parsePageRange("", count: 3), [0, 1, 2])
        XCTAssertEqual(try parsePageRange("1-", count: 3), [0, 1, 2])
        XCTAssertEqual(try parsePageRange("alle", count: 3), [0, 1, 2])
    }

    func testBereicheUndEinzelseiten() throws {
        XCTAssertEqual(try parsePageRange("1-3", count: 5), [0, 1, 2])
        XCTAssertEqual(try parsePageRange("5,2", count: 5), [4, 1])
        XCTAssertEqual(try parsePageRange("3-", count: 5), [2, 3, 4])
        XCTAssertEqual(try parsePageRange("-2", count: 5), [0, 1])
    }

    func testDoppelteSeitenNurEinmal() throws {
        XCTAssertEqual(try parsePageRange("2,2,2-3", count: 5), [1, 2])
    }

    func testUngueltigeAngabenWerfen() {
        XCTAssertThrowsError(try parsePageRange("0-2", count: 5))
        XCTAssertThrowsError(try parsePageRange("4-2", count: 5))
        XCTAssertThrowsError(try parsePageRange("9", count: 5))
        XCTAssertThrowsError(try parsePageRange("abc", count: 5))
    }
}

final class LineOrderTests: XCTestCase {
    /// Zwei Spalten, zwei Zeilen: die Ausgabe muss zeilenweise lesen, nicht
    /// spaltenweise.
    func testZeilenWerdenVonObenNachUntenGelesen() {
        let lines = [
            OCRLine(text: "unten links", confidence: 1, box: CGRect(x: 0.05, y: 0.10, width: 0.3, height: 0.02)),
            OCRLine(text: "oben rechts", confidence: 1, box: CGRect(x: 0.55, y: 0.80, width: 0.3, height: 0.02)),
            OCRLine(text: "oben links", confidence: 1, box: CGRect(x: 0.05, y: 0.80, width: 0.3, height: 0.02)),
            OCRLine(text: "unten rechts", confidence: 1, box: CGRect(x: 0.55, y: 0.10, width: 0.3, height: 0.02)),
        ]
        let sorted = sortLines(lines).map(\.text)
        XCTAssertEqual(sorted, ["oben links", "oben rechts", "unten links", "unten rechts"])
    }

    /// Leicht schiefe Zeilen (Höhendifferenz kleiner als die halbe Zeilenhöhe)
    /// bleiben in einer Zeile.
    func testLeichteSchiefeBleibtEineZeile() {
        let lines = [
            OCRLine(text: "rechts", confidence: 1, box: CGRect(x: 0.5, y: 0.800, width: 0.2, height: 0.02)),
            OCRLine(text: "links", confidence: 1, box: CGRect(x: 0.1, y: 0.804, width: 0.2, height: 0.02)),
        ]
        XCTAssertEqual(sortLines(lines).map(\.text), ["links", "rechts"])
    }
}

final class OutputTests: XCTestCase {
    func testSeitenmarkerErstAbZweiSeiten() {
        let one = [OCRPageResult(index: 1, source: "vision", width: 10, height: 10, ms: 1, lines: [
            OCRLine(text: "nur eine Seite", confidence: 1, box: .zero),
        ])]
        XCTAssertEqual(renderText(one), "nur eine Seite")

        let two = one + [OCRPageResult(index: 2, source: "vision", width: 10, height: 10, ms: 1, lines: [
            OCRLine(text: "zweite Seite", confidence: 1, box: .zero),
        ])]
        let text = renderText(two)
        XCTAssertTrue(text.contains("## Seite 1"))
        XCTAssertTrue(text.contains("## Seite 2"))
    }
}

final class RecognizeTests: XCTestCase {
    /// Zeichnet Text in ein Bild und prüft, dass Vision ihn zurückliest.
    func testGedruckterTextWirdErkannt() throws {
        let languages = supportedOCRLanguages()
        try XCTSkipIf(languages.isEmpty, "Vision-Texterkennung fehlt in dieser Umgebung")

        let image = try drawText("Kapitel 4")
        var options = OCROptions()
        options.languages = try validatedLanguages(["de-DE"])

        let (lines, _) = try recognizeText(image, options: options)
        let text = lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(
            text.lowercased().contains("kapitel"),
            "Erkennung lieferte: \(text)"
        )
    }

    /// Baut ein 600 × 200-Pixel-Bild mit einer Textzeile.
    private func drawText(_ value: String) throws -> CGImage {
        let width = 600
        let height = 200
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw XCTSkip("Renderkontext fehlt")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]
        let attributed = NSAttributedString(string: value, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw XCTSkip("Bild ließ sich nicht erzeugen")
        }
        return image
    }
}
