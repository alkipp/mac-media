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

final class RecognizeTests: XCTestCase {    /// Zeichnet Text in ein Bild und prüft, dass Vision ihn zurückliest.
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

// MARK: - Bilddeutung

final class OrientationTests: XCTestCase {
    /// Ein Foto mit EXIF-Orientierung 6 liegt quer im Speicher. Die Analyse
    /// muss es aufrichten, sonst beschreibt jede Koordinate ein gedrehtes Bild.
    func testGedrehtesFotoWirdAufgerichtet() throws {
        let image = try solidImage(width: 400, height: 200)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orientierung-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw XCTSkip("JPEG-Ziel fehlt")
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: 6] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("JPEG ließ sich nicht schreiben")
        }

        let (upright, metadata) = try loadUpright(url, maxPixel: 1024)
        XCTAssertEqual(metadata.orientation, 6)
        XCTAssertEqual(metadata.sourceWidth, 400)
        XCTAssertEqual(upright.width, 200)
        XCTAssertEqual(upright.height, 400)
        XCTAssertEqual(metadata.pixelWidth, 200)
        XCTAssertEqual(metadata.pixelHeight, 400)
    }

    /// Vision liefert den Ursprung unten links, die Ausgabe oben links.
    func testBoundingBoxWirdGespiegelt() {
        let flipped = displayBox(CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1))
        XCTAssertEqual(flipped.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(flipped.minY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(flipped.height, 0.1, accuracy: 0.0001)
    }

    func testFormatBoxZeigtProzent() {
        let text = formatBox(CGRect(x: 0.115, y: 0.18, width: 0.85, height: 0.78))
        XCTAssertEqual(text, "x 12 % y 18 % w 85 % h 78 %")
    }

    func testAusserhalbDesBildesWirft() {
        let image = try? solidImage(width: 100, height: 100)
        guard let image else { return XCTFail("Bild fehlt") }
        XCTAssertThrowsError(
            try cropImage(image, region: CGRect(x: 0.95, y: 0.95, width: 0.2, height: 0.2))
        )
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw XCTSkip("Kontext fehlt") }
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw XCTSkip("Bild fehlt") }
        return image
    }
}

final class NarrativeTests: XCTestCase {
    /// Das Modell soll ein festes Layout liefern; die Auswertung darf daran
    /// nicht zerbrechen, wenn es leicht abweicht.
    func testLayoutMitTrennernWirdGelesen() {
        let report = """
        Zusammenfassung: Ein Gerät hängt an einer Wand.
        - Ubiquiti Switch | Oberseite | weißes Gehäuse, vier Ports
        - Steckdosenleiste | unten rechts | schwarz, gelbe Kabel
        Text: keiner
        """
        let narrative = parseNarrative(report)
        XCTAssertEqual(narrative.summary, "Ein Gerät hängt an einer Wand.")
        XCTAssertEqual(narrative.objects.count, 2)
        XCTAssertEqual(narrative.objects[0].name, "Ubiquiti Switch")
        XCTAssertEqual(narrative.objects[0].position, "Oberseite")
        XCTAssertEqual(narrative.objects[0].details, "weißes Gehäuse, vier Ports")
        XCTAssertTrue(narrative.visibleText.isEmpty)
    }

    /// Das ältere Format „Name (Position): Details“ bleibt lesbar.
    func testLayoutMitKlammernWirdGelesen() {
        let item = parseSceneItem("Steckdose (links unten): grau, zwei Kontakte")
        XCTAssertEqual(item?.name, "Steckdose")
        XCTAssertEqual(item?.position, "links unten")
        XCTAssertEqual(item?.details, "grau, zwei Kontakte")
    }

    /// Zeilen ohne Muster dürfen nicht verschwinden.
    func testUnbekannteZeileLandetInDerZusammenfassung() {
        let narrative = parseNarrative("Ein weißes Gerät an der Wand.")
        XCTAssertEqual(narrative.summary, "Ein weißes Gerät an der Wand.")
        XCTAssertTrue(narrative.objects.isEmpty)
    }

    func testTextZeileWirdUebernommen() {
        let narrative = parseNarrative("Zusammenfassung: Schild.\nText: Notausgang, Ebene 2")
        XCTAssertEqual(narrative.visibleText, ["Notausgang, Ebene 2"])
    }

    /// Erfundener Text fällt auf, gelesener nicht.
    func testErfundenerTextWirdErkannt() {
        let narrative = Narrative(
            summary: "Gerät an der Wand.",
            objects: [],
            visibleText: ["Ubiquiti"]
        )
        let read = [TextLine(text: "Notausgang", confidence: 1, box: .zero)]
        XCTAssertEqual(unsupportedTextClaims(narrative, ocrText: read), ["Ubiquiti"])

        let matching = Narrative(summary: "", objects: [], visibleText: ["Notausgang"])
        XCTAssertTrue(unsupportedTextClaims(matching, ocrText: read).isEmpty)
    }
}

final class OcrOrientationTests: XCTestCase {
    /// Ein Foto im Hochformat liegt quer im Speicher: die Pixel sind um 90°
    /// gedreht, die EXIF-Orientierung sagt, wie sie zurückzudrehen sind.
    /// `ml_ocr` muss das anwenden – sonst liegen alle Boxen aus `format=json`
    /// im gedrehten Raster.
    func testGedrehtesFotoWirdGelesen() async throws {
        let languages = supportedOCRLanguages()
        try XCTSkipIf(languages.isEmpty, "Vision-Texterkennung fehlt in dieser Umgebung")

        let upright = try drawText("Kapitel 4")
        let stored = try rotateQuarterTurn(upright)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-orientierung-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { throw XCTSkip("JPEG-Ziel fehlt") }
        CGImageDestinationAddImage(
            destination, stored, [kCGImagePropertyOrientation: 6] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("JPEG ließ sich nicht schreiben")
        }

        // Der Lader muss die Anzeigepixel liefern: 600 × 200, nicht 200 × 600.
        let loaded = try loadImage(url)
        XCTAssertEqual(loaded.width, 600, "Breite nicht aufgerichtet")
        XCTAssertEqual(loaded.height, 200, "Höhe nicht aufgerichtet")

        var options = OCROptions()
        options.languages = try validatedLanguages(["de-DE"])
        let pages = try await runOCR(url: url, pageSpec: "1-", options: options)

        guard let page = pages.first else { return XCTFail("keine Seite") }
        XCTAssertEqual(page.width, 600)
        XCTAssertEqual(page.height, 200)
        XCTAssertTrue(
            page.text.lowercased().contains("kapitel"),
            "Erkennung lieferte: \(page.text)"
        )
    }

    /// Dreht ein Bild um eine Vierteldrehung – so liegt ein Hochformatfoto im
    /// Speicher.
    private func rotateQuarterTurn(_ image: CGImage) throws -> CGImage {
        let width = image.height
        let height = image.width
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw XCTSkip("Kontext fehlt") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -.pi / 2)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2,
                y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        guard let rotated = context.makeImage() else { throw XCTSkip("Drehung fehlgeschlagen") }
        return rotated
    }

    private func drawText(_ value: String) throws -> CGImage {
        let width = 600, height = 200
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw XCTSkip("Renderkontext fehlt") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let attributed = NSAttributedString(
            string: value,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        guard let image = context.makeImage() else { throw XCTSkip("Bild fehlt") }
        return image
    }
}
