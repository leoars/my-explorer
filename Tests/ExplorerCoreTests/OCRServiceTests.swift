// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import CoreText
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin
@testable import ExplorerCore

final class OCRServiceTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.OCRTests.\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func expect<T>(_ reason: OCRFailure.Reason, _ body: () async throws -> T) async {
        do { _ = try await body(); XCTFail("Expected \(reason)") }
        catch let error as OCRFailure { XCTAssertEqual(error.reason, reason) }
        catch { XCTFail("Unexpected \(error)") }
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1400, height: 320, bitsPerComponent: 8, bytesPerRow: 5600,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1400, height: 320))
        draw("MY EXPLORER 2048", context: context, size: 90, x: 60, y: 130)
        return try XCTUnwrap(context.makeImage())
    }
    private func draw(_ text: String, context: CGContext, size: CGFloat, x: CGFloat, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textMatrix = .identity; context.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, context)
    }
    private func writeImage(_ image: CGImage, to url: URL, type: UTType = .png, orientation: Int = 1, count: Int = 1) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, count, nil))
        for _ in 0..<count { CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func pdf(_ url: URL, pages: [String?], copying: Bool = true) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: CFDictionary? = copying ? nil : [kCGPDFContextOwnerPassword: "fixture-owner", kCGPDFContextUserPassword: "", kCGPDFContextAllowsCopying: false] as CFDictionary
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, info))
        let raster = try image()
        for text in pages {
            context.beginPDFPage(nil)
            if let text { draw(text, context: context, size: 32, x: 30, y: 680) }
            else { context.draw(raster, in: CGRect(x: 30, y: 450, width: 552, height: 126)) }
            context.endPDFPage()
        }
        context.closePDF()
    }

    func testRealVisionPNGAndImageOrientationPreserveOriginalBytes() async throws {
        let root = try fixture(), service = OCRService()
        let source = root.appendingPathComponent("text.png")
        let raster = try image(); try writeImage(raster, to: source)
        let before = SHA256.hash(data: try Data(contentsOf: source)), progress = OCRProgressRecorder()
        let result = try await service.recognize(.init(url: source, languages: ["en"]), progress: { progress.add($0) })
        XCTAssertTrue(result.fullText.contains("MY EXPLORER 2048"), result.fullText)
        XCTAssertEqual(result.pages.map(\.source), [.recognized])
        XCTAssertEqual(before, SHA256.hash(data: try Data(contentsOf: source)))
        XCTAssertEqual(progress.values.last?.stage, .completed)
        let rotated = try XCTUnwrap(CGContext(data: nil, width: raster.width, height: raster.height, bitsPerComponent: 8, bytesPerRow: raster.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        rotated.translateBy(x: CGFloat(raster.width), y: CGFloat(raster.height)); rotated.rotate(by: .pi)
        rotated.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        let tiff = root.appendingPathComponent("rotated.tiff")
        try writeImage(try XCTUnwrap(rotated.makeImage()), to: tiff, type: .tiff, orientation: 3)
        let corrected = try await service.recognize(.init(url: tiff, languages: ["en-US"]))
        XCTAssertTrue(corrected.fullText.contains("MY EXPLORER 2048"), corrected.fullText)
    }

    func testPDFTextLayerThenScannedPageAndPageSelection() async throws {
        let root = try fixture(), source = root.appendingPathComponent("mixed.pdf")
        try pdf(source, pages: ["Embedded first page 2048", nil, "Embedded last page"])
        let before = SHA256.hash(data: try Data(contentsOf: source))
        let result = try await OCRService().recognize(.init(url: source, languages: ["en"]))
        XCTAssertEqual(result.pages.map(\.source), [.embeddedText, .recognized, .embeddedText])
        XCTAssertEqual(result.pages.map(\.pageNumber), [1, 2, 3])
        XCTAssertTrue(result.pages[0].text.contains("Embedded first page 2048"))
        XCTAssertTrue(result.pages[1].text.contains("MY EXPLORER 2048"), result.pages[1].text)
        let selected = try await OCRService(limits: .init(maximumPages: 1)).recognize(.init(url: source, pages: 3...3))
        XCTAssertEqual(selected.pages.map(\.pageNumber), [3])
        XCTAssertEqual(selected.pages[0].source, .embeddedText)
        XCTAssertEqual(before, SHA256.hash(data: try Data(contentsOf: source)))
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fullText"), "The wire must not duplicate potentially large page text")
    }

    func testLimitsCorruptInputUnsupportedPagesAndCopyProtectedPDF() async throws {
        let root = try fixture(), source = root.appendingPathComponent("text.pdf")
        try pdf(source, pages: ["A moderately long embedded sentence", "second page"])
        await expect(.limitExceeded) { try await OCRService(limits: .init(maximumOutputBytes: 8)).recognize(.init(url: source)) }
        await expect(.limitExceeded) { try await OCRService(limits: .init(maximumPages: 1)).recognize(.init(url: source)) }
        await expect(.limitExceeded) { try await OCRService(limits: .init(maximumFileBytes: 1)).recognize(.init(url: source)) }
        await expect(.invalidRequest) { try await OCRService().recognize(.init(url: source, pages: 3...3)) }
        let bad = root.appendingPathComponent("bad.png"); try Data("not an image".utf8).write(to: bad)
        await expect(.recognitionFailed) { try await OCRService().recognize(.init(url: bad)) }
        let png = root.appendingPathComponent("large.png"); try writeImage(image(), to: png)
        await expect(.limitExceeded) { try await OCRService(limits: .init(maximumImagePixels: 1)).recognize(.init(url: png)) }
        await expect(.invalidRequest) { try await OCRService().recognize(.init(url: png, pages: 2...2)) }
        let protected = root.appendingPathComponent("protected.pdf"); try pdf(protected, pages: ["Do not extract"], copying: false)
        XCTAssertFalse(try XCTUnwrap(PDFDocument(url: protected)).allowsCopying)
        await expect(.permissionDenied) { try await OCRService().recognize(.init(url: protected)) }
        let multipage = root.appendingPathComponent("multiple.tiff"); try writeImage(image(), to: multipage, type: .tiff, count: 2)
        await expect(.unsupportedType) { try await OCRService().recognize(.init(url: multipage)) }
    }

    func testAuthorizationBeforeSnapshotAndAfterRecognitionRejectsRevocationAndSourceChanges() async throws {
        let root = try fixture(), source = root.appendingPathComponent("text.pdf")
        try pdf(source, pages: ["Only authorized readers"])
        let denied = OCRAuthorizationProbe(denyAt: 2), progress = OCRProgressRecorder()
        await expect(.authorizationDenied) {
            try await OCRService().recognize(.init(url: source), progress: { progress.add($0) }, authorizeURL: { try await denied.check($0) })
        }
        XCTAssertFalse(progress.values.contains { $0.stage == .recognizing || $0.stage == .completed })
        let revoked = OCRAuthorizationProbe(denyAt: 3)
        await expect(.authorizationDenied) { try await OCRService().recognize(.init(url: source), authorizeURL: { try await revoked.check($0) }) }
        let mutation = OCRAuthorizationProbe(mutateAt: 2)
        await expect(.sourceChanged) { try await OCRService().recognize(.init(url: source), authorizeURL: { try await mutation.check($0) }) }
        try pdf(source, pages: ["Original second run"])
        let lateMutation = OCRAuthorizationProbe(mutateAt: 3)
        await expect(.sourceChanged) { try await OCRService().recognize(.init(url: source), authorizeURL: { try await lateMutation.check($0) }) }
    }

    func testUnsafeSourcesRecoveryAndPlaceholderMetadataAreRejectedWithoutRecognition() async throws {
        let root = try fixture(), source = root.appendingPathComponent("text.pdf")
        try pdf(source, pages: ["fixture"])
        let link = root.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await expect(.unavailable) { try await OCRService().recognize(.init(url: link)) }
        await expect(.unsupportedType) { try await OCRService().recognize(.init(url: URL(string: "s3://bucket/file.png")!)) }
        await expect(.invalidRequest) { try await OCRService().recognize(.init(url: URL(string: "file://remote.example" + source.path)!)) }
        let privateRoot = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try LocalTransferRecovery.mark(privateRoot)
        let protected = privateRoot.appendingPathComponent("text.pdf"); try FileManager.default.copyItem(at: source, to: protected)
        await expect(.unavailable) { try await OCRService().recognize(.init(url: protected)) }
        var metadata = stat(); metadata.st_mode = S_IFREG; metadata.st_size = 1; metadata.st_flags = UInt32(SF_DATALESS)
        XCTAssertThrowsError(try OCRSource.checkMetadata(metadata, maximumBytes: 100)) { XCTAssertEqual(($0 as? OCRFailure)?.reason, .needsDownload) }
        metadata.st_flags = 0; metadata.st_size = 101
        XCTAssertThrowsError(try OCRSource.checkMetadata(metadata, maximumBytes: 100)) { XCTAssertEqual(($0 as? OCRFailure)?.reason, .limitExceeded) }
    }

    func testRuntimeLanguagesAndInputMapping() async throws {
        let available = try await OCRService().supportedLanguages()
        XCTAssertTrue(available.contains("en-US"))
        XCTAssertEqual(try OCRService.recognitionLanguages(["pt_BR", "en", "en-US"], supported: ["pt-BR", "en-US"]), ["pt-BR", "en-US"])
        XCTAssertThrowsError(try OCRService.recognitionLanguages(["xx"], supported: available))
        let auto = try OCRService.recognitionLanguages([], supported: available)
        XCTAssertTrue(auto.allSatisfy { available.contains($0) })
        XCTAssertTrue(OCRService.canRecognize(URL(fileURLWithPath: "/fixture/PHOTO.PNG")))
        XCTAssertFalse(OCRService.canRecognize(URL(fileURLWithPath: "/fixture/program.apk")))
    }
}

private final class OCRProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [OCRProgress] = []
    var values: [OCRProgress] { lock.withLock { stored } }
    func add(_ value: OCRProgress) { lock.withLock { stored.append(value) } }
}
private actor OCRAuthorizationProbe {
    private var calls = 0
    private let denyAt: Int?
    private let mutateAt: Int?
    init(denyAt: Int? = nil, mutateAt: Int? = nil) { self.denyAt = denyAt; self.mutateAt = mutateAt }
    func check(_ url: URL) throws {
        calls += 1
        if calls == denyAt { throw OCRFailure(.authorizationDenied) }
        if calls == mutateAt { try Data("changed fixture".utf8).write(to: url) }
    }
}
