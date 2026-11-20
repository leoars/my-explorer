// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import PDFKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import ExplorerCore

final class SearchablePDFTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.SearchablePDF.\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func draw(_ text: String, _ context: CGContext, x: CGFloat = 40, y: CGFloat = 120, size: CGFloat = 65) {
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textMatrix = .identity; context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    private func raster() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1100, height: 300, bitsPerComponent: 8, bytesPerRow: 4400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1100, height: 300))
        draw("MY EXPLORER 2048", context)
        return try XCTUnwrap(context.makeImage())
    }
    private func image(_ url: URL, orientation: Int = 1) throws {
        var image = try raster()
        if orientation == 3 {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 1100, height: 300, bitsPerComponent: 8, bytesPerRow: 4400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.translateBy(x: 1100, y: 300); ctx.rotate(by: .pi); ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1100, height: 300)); image = try XCTUnwrap(ctx.makeImage())
        }
        if orientation == 6 || orientation == 8 {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 300, height: 1100, bitsPerComponent: 8, bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            if orientation == 6 { ctx.translateBy(x: 300, y: 0); ctx.rotate(by: .pi / 2) }
            else { ctx.translateBy(x: 0, y: 1100); ctx.rotate(by: -.pi / 2) }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1100, height: 300)); image = try XCTUnwrap(ctx.makeImage())
        }
        let type = orientation == 1 ? UTType.png : .tiff
        let target = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(target))
    }
    private func pdf(_ url: URL, mixed: Bool = true, rotate: Bool = false) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(try raster(), in: CGRect(x: 35, y: 410, width: 550, height: 150))
        context.setStrokeColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)); context.setLineWidth(3)
        context.stroke(CGRect(x: 30, y: 60, width: 500, height: 650)); context.endPDFPage()
        if mixed {
            context.beginPDFPage(nil); draw("Original Unicode Café 日本語 한국어", context, x: 20, y: 690, size: 24); context.endPDFPage()
        }
        context.closePDF()
        if rotate {
            let document = try XCTUnwrap(PDFDocument(url: url)), page = try XCTUnwrap(document.page(at: 0))
            page.setBounds(CGRect(x: 20, y: 40, width: 570, height: 700), for: .cropBox); page.rotation = 90
            XCTAssertTrue(document.write(to: url))
        }
    }
    private func pixels(_ page: PDFPage) throws -> Data {
        let reference = try XCTUnwrap(page.pageRef), crop = reference.getBoxRect(.cropBox)
        let swapped = abs(reference.rotationAngle) % 180 == 90
        let width = swapped ? crop.height : crop.width, height = swapped ? crop.width : crop.height
        let scale = 700 / max(width, height), w = Int((width * scale).rounded()), h = Int((height * scale).rounded())
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(reference)
        return Data(bytes: try XCTUnwrap(context.data), count: w * h * 4)
    }
    private func compare(_ first: PDFPage, _ second: PDFPage, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try pixels(first), b = try pixels(second)
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        guard a.count == b.count else { return }
        let difference = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        XCTAssertLessThan(difference, 0.7, "Mean channel difference \(difference)", file: file, line: line)
    }
    private func expect<T>(_ reason: SearchablePDFFailure.Reason, _ body: () async throws -> T) async {
        do { _ = try await body(); XCTFail("Expected \(reason)") }
        catch let error as SearchablePDFFailure { XCTAssertEqual(error.reason, reason) }
        catch { XCTFail("Unexpected \(error)") }
    }
    func testRealImageSearchableUnicodeNameAndEXIFPreserveOriginal() async throws {
        let root = try fixture(), source = root.appendingPathComponent("Imagem 日本語.png"), output = root.appendingPathComponent("Pesquisável.pdf")
        try image(source); let before = try Data(contentsOf: source)
        let result = try await SearchablePDFService().export(.init(sourceURL: source, destinationURL: output, languages: ["en"]))
        XCTAssertEqual(result.recognizedPages, 1); XCTAssertEqual(result.textLayerPages, 0)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: output)).string?.contains("MY EXPLORER 2048") == true)
        XCTAssertEqual(before, try Data(contentsOf: source))
        let rotated = root.appendingPathComponent("exif.tiff"), rotatedOutput = root.appendingPathComponent("exif.pdf")
        try image(rotated, orientation: 3)
        _ = try await SearchablePDFService().export(.init(sourceURL: rotated, destinationURL: rotatedOutput, languages: ["en"]))
        let document = try XCTUnwrap(PDFDocument(url: rotatedOutput))
        XCTAssertTrue(document.string?.contains("MY EXPLORER 2048") == true)
        try compare(XCTUnwrap(PDFDocument(url: output)?.page(at: 0)), XCTUnwrap(document.page(at: 0)))
        try artifacts([source, output, rotated, rotatedOutput])
    }
    func testMixedPDFRotationCropVectorsTextLayerNoDuplicationAndPixelEquality() async throws {
        let root = try fixture(), source = root.appendingPathComponent("rotation-unicode-input.pdf"), output = root.appendingPathComponent("rotation-unicode-searchable.pdf")
        try pdf(source, rotate: true); let before = try Data(contentsOf: source)
        let result = try await SearchablePDFService().export(.init(sourceURL: source, destinationURL: output, languages: ["en"]))
        XCTAssertEqual(result.pageCount, 2); XCTAssertEqual(result.recognizedPages, 1); XCTAssertEqual(result.textLayerPages, 1)
        let original = try XCTUnwrap(PDFDocument(url: source)), generated = try XCTUnwrap(PDFDocument(url: output))
        for index in 0..<2 { try compare(XCTUnwrap(original.page(at: index)), XCTUnwrap(generated.page(at: index))) }
        XCTAssertTrue(generated.page(at: 0)?.string?.contains("MY EXPLORER 2048") == true, generated.page(at: 0)?.string ?? "nil")
        XCTAssertEqual(generated.page(at: 0)?.rotation, 0)
        XCTAssertEqual(generated.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 700, height: 570))
        XCTAssertEqual(generated.page(at: 1)?.string, original.page(at: 1)?.string)
        XCTAssertTrue(generated.page(at: 1)?.string?.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: " ", with: "").contains("日本語") == true, generated.page(at: 1)?.string ?? "nil")
        XCTAssertTrue(generated.page(at: 1)?.string?.contains("한국어") == true)
        XCTAssertEqual(before, try Data(contentsOf: source))
        try artifacts([source, output])
    }
    func testTextOnlyExportPreservesSearchSelectionCropRotationAndHonorsAssemblyQuota() async throws {
        let root = try fixture(), source = root.appendingPathComponent("text.pdf"), output = root.appendingPathComponent("out.pdf")
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        draw("日本語", context, x: 90, y: 400, size: 32)
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 270
        page.setBounds(CGRect(x: 25, y: 20, width: 540, height: 690), for: .cropBox)
        XCTAssertTrue(document.write(to: source))
        let original = try XCTUnwrap(PDFDocument(url: source)), before = try XCTUnwrap(original.page(at: 0))
        let text = try XCTUnwrap(before.string)
        let bounds = try XCTUnwrap(original.findString(text, withOptions: []).first).bounds(for: before)
        let request = SearchablePDFRequest(sourceURL: source, destinationURL: output)
        // This covers the final page-copy writer with a quota larger than an empty Quartz PDF.
        await expect(.limitExceeded) { try await SearchablePDFService(maximumOutputBytes: 2048).export(request) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let result = try await SearchablePDFService().export(request)
        XCTAssertEqual(result.recognizedPages, 0)
        let exported = try XCTUnwrap(PDFDocument(url: output)), after = try XCTUnwrap(exported.page(at: 0))
        XCTAssertEqual(after.string, text)
        XCTAssertEqual(after.rotation, before.rotation)
        XCTAssertEqual(after.bounds(for: .cropBox), before.bounds(for: .cropBox))
        XCTAssertEqual(try XCTUnwrap(exported.findString(text, withOptions: []).first).bounds(for: after), bounds)
        try compare(before, after)
    }
    func testInvisibleCoreTextUnicodeIsExtractableAndNeverChangesVisiblePixels() throws {
        let root = try fixture(), first = root.appendingPathComponent("blank.pdf"), second = root.appendingPathComponent("unicode.pdf")
        let text = "Café português Español Français Deutsch Italiano 日本語 한국어"
        for (url, hidden) in [(first, false), (second, true)] {
            var bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
            let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil)); context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 10, y: 20, width: 770, height: 350))
            if hidden { try PDFSearchableRenderer.drawText(.init(text: text, box: CGRect(x: 0.05, y: 0.3, width: 0.9, height: 0.1)), in: bounds, context: context) }
            context.endPDFPage(); context.closePDF()
        }
        let document = try XCTUnwrap(PDFDocument(url: second)), extracted = try XCTUnwrap(document.string)
        for word in text.split(separator: " ") { XCTAssertTrue(extracted.contains(word), "Missing \(word): \(extracted)") }
        try compare(XCTUnwrap(PDFDocument(url: first)?.page(at: 0)), XCTUnwrap(document.page(at: 0)))
        let selected = try XCTUnwrap(document.findString("日本語", withOptions: []).first)
        let selectionBounds = selected.bounds(for: try XCTUnwrap(document.page(at: 0)))
        XCTAssertGreaterThan(selectionBounds.width, 0)
        XCTAssertGreaterThanOrEqual(selectionBounds.minX, 30)
        XCTAssertGreaterThanOrEqual(selectionBounds.minY, 110)
        XCTAssertLessThanOrEqual(selectionBounds.maxY, 170)
        try artifacts([first, second])
    }
    func testRemainingPDFRotationsAndEXIFOrientationsSearchSelectionsMatchVisibleText() async throws {
        let root = try fixture()
        for rotation in [180, 270] {
            let source = root.appendingPathComponent("rotation-\(rotation).pdf"), output = root.appendingPathComponent("rotation-\(rotation)-searchable.pdf")
            try pdf(source, mixed: false)
            let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
            page.rotation = rotation; page.setBounds(CGRect(x: 20, y: 40, width: 570, height: 700), for: .cropBox)
            XCTAssertTrue(document.write(to: source))
            _ = try await SearchablePDFService().export(.init(sourceURL: source, destinationURL: output, languages: ["en"]))
            let generated = try XCTUnwrap(PDFDocument(url: output)), generatedPage = try XCTUnwrap(generated.page(at: 0))
            try compare(XCTUnwrap(PDFDocument(url: source)?.page(at: 0)), generatedPage)
            let selection = try XCTUnwrap(generated.findString("MY EXPLORER 2048", withOptions: []).first)
            let selectionBounds = selection.bounds(for: generatedPage)
            XCTAssertGreaterThan(selectionBounds.width, 0); XCTAssertGreaterThan(selectionBounds.height, 0)
            XCTAssertTrue(generatedPage.bounds(for: .mediaBox).insetBy(dx: -1, dy: -1).contains(selectionBounds))
            try artifacts([source, output])
        }
        let source = root.appendingPathComponent("upright.png"), output = root.appendingPathComponent("upright.pdf")
        try image(source); _ = try await SearchablePDFService().export(.init(sourceURL: source, destinationURL: output, languages: ["en"]))
        let upright = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        for orientation in [6, 8] {
            let source = root.appendingPathComponent("exif-\(orientation).tiff"), output = root.appendingPathComponent("exif-\(orientation).pdf")
            try image(source, orientation: orientation)
            _ = try await SearchablePDFService().export(.init(sourceURL: source, destinationURL: output, languages: ["en"]))
            let document = try XCTUnwrap(PDFDocument(url: output)), page = try XCTUnwrap(document.page(at: 0))
            try compare(upright, page)
            let selection = try XCTUnwrap(document.findString("MY EXPLORER 2048", withOptions: []).first)
            let bounds = selection.bounds(for: page)
            XCTAssertTrue(CGRect(x: 30, y: 90, width: 900, height: 120).contains(bounds), "Selection \(bounds) must match visible ink")
            try artifacts([source, output])
        }
    }
    func testExclusiveDestinationQuotaProtectedComplexAndPageLimits() async throws {
        let root = try fixture(), source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("out.pdf")
        try pdf(source)
        let request = SearchablePDFRequest(sourceURL: source, destinationURL: output)
        await expect(.limitExceeded) { try await SearchablePDFService(maximumOutputBytes: 128).export(request) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        await expect(.limitExceeded) { try await SearchablePDFService(limits: .init(maximumPages: 1)).export(request) }
        try Data("existing destination".utf8).write(to: output)
        await expect(.destinationExists) { try await SearchablePDFService().export(request) }
        XCTAssertEqual(try Data(contentsOf: output), Data("existing destination".utf8))
        try FileManager.default.removeItem(at: output)
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 40, height: 40), forType: .text, withProperties: nil))
        XCTAssertTrue(document.write(to: source))
        await expect(.unsupportedDocument) { try await SearchablePDFService().export(request) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        page.removeAnnotation(try XCTUnwrap(page.annotations.first))
        let form = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 120, height: 20), forType: .widget, withProperties: nil)
        form.widgetFieldType = .text; form.fieldName = "FixtureField"; form.widgetStringValue = "Fixture value"
        page.addAnnotation(form); XCTAssertTrue(document.write(to: source))
        await expect(.unsupportedDocument) { try await SearchablePDFService().export(request) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let encrypted = root.appendingPathComponent("encrypted.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let encryptedContext = try XCTUnwrap(CGContext(encrypted as CFURL, mediaBox: &box,
            [kCGPDFContextOwnerPassword: "fixture-owner", kCGPDFContextUserPassword: "", kCGPDFContextAllowsCopying: false] as CFDictionary))
        encryptedContext.beginPDFPage(nil); draw("Protected", encryptedContext); encryptedContext.endPDFPage(); encryptedContext.closePDF()
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: encrypted)).isEncrypted)
        await expect(.unsupportedDocument) { try await SearchablePDFService().export(.init(sourceURL: encrypted, destinationURL: output)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testAuthorizationMutationAndDestinationRaceNeverPublish() async throws {
        let root = try fixture(), source = root.appendingPathComponent("source.pdf"), output = root.appendingPathComponent("out.pdf")
        try pdf(source, mixed: false)
        let request = SearchablePDFRequest(sourceURL: source, destinationURL: output, languages: ["en"])
        let denied = PDFTestAuthorization { _, role, _ in if role == .destination { throw SearchablePDFFailure(.authorizationDenied) } }
        await expect(.authorizationDenied) { try await SearchablePDFService().export(request, authorize: { try await denied.check($0, $1) }) }
        let revoked = PDFTestAuthorization { _, _, count in if count == 5 { throw SearchablePDFFailure(.authorizationDenied) } }
        await expect(.authorizationDenied) { try await SearchablePDFService().export(request, authorize: { try await revoked.check($0, $1) }) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let mutation = PDFTestAuthorization { url, role, count in if count == 5, role == .source { try Data("changed original".utf8).write(to: url) } }
        await expect(.sourceChanged) { try await SearchablePDFService().export(request, authorize: { try await mutation.check($0, $1) }) }
        try pdf(source, mixed: false)
        let collision = PDFTestAuthorization { url, role, count in if count == 7, role == .destination { try Data("racing destination".utf8).write(to: url) } }
        await expect(.destinationExists) { try await SearchablePDFService().export(request, authorize: { try await collision.check($0, $1) }) }
        XCTAssertEqual(try Data(contentsOf: output), Data("racing destination".utf8))
    }
    func testDestinationPreflightRejectsUnsafeAndResolvesAncestorForAuthorization() async throws {
        let root = try fixture(), link = root.appendingPathComponent("link")
        let outside = try fixture(); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let target = link.appendingPathComponent("new.pdf")
        let resolved = try await SearchablePDFService.validatedDestinationURL(target)
        XCTAssertEqual(resolved, outside.appendingPathComponent("new.pdf"))
        await expect(.invalidRequest) { try await SearchablePDFService.validatedDestinationURL(URL(string: "file://remote/tmp/out.pdf")!) }
        let protected = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); try LocalTransferRecovery.mark(protected)
        await expect(.permissionDenied) { try await SearchablePDFService.validatedDestinationURL(protected.appendingPathComponent("out.pdf")) }
    }
    private func artifacts(_ urls: [URL]) throws {
        guard ProcessInfo.processInfo.environment["MY_EXPLORER_PDF_TEST_ARTIFACTS"] == "1" else { return }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/previews/searchable-pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in urls { let target = directory.appendingPathComponent(url.lastPathComponent); if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }; try FileManager.default.copyItem(at: url, to: target) }
    }
}
private actor PDFTestAuthorization {
    let action: @Sendable (URL, SearchablePDFLocationRole, Int) throws -> Void
    var count = 0
    init(_ action: @escaping @Sendable (URL, SearchablePDFLocationRole, Int) throws -> Void) { self.action = action }
    func check(_ url: URL, _ role: SearchablePDFLocationRole) throws { count += 1; try action(url, role, count) }
}
