// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import PDFKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import ExplorerCore

final class SearchablePDFBatchTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.PDFBatch.\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func pdf(_ url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); draw(context); context.endPDFPage(); context.closePDF()
    }
    private func draw(_ context: CGContext) {
        let string = NSAttributedString(string: "MY EXPLORER 2048", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 36, nil)])
        context.textPosition = CGPoint(x: 30, y: 120); CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    private func png(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 300)); draw(context)
        let target = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(target, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(target))
    }
    func testRealMixedBatchContinuesPastCorruptAndPreservesExistingFilesAndSources() async throws {
        let root = try fixture(), directory = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let image = root.appendingPathComponent("Café 日本語.png"), document = root.appendingPathComponent("Café 日本語.pdf"), corrupt = root.appendingPathComponent("bad.pdf")
        try png(image); try pdf(document); try Data("not PDF".utf8).write(to: corrupt)
        let original = try [image, document, corrupt].map { try Data(contentsOf: $0) }
        let existing = directory.appendingPathComponent("Café 日本語-OCR.pdf"), sentinel = Data("leave existing alone".utf8)
        try sentinel.write(to: existing)
        let progress = PDFBatchProgressProbe(), authorizations = PDFBatchAuthorizationProbe()
        let result = try await SearchablePDFBatchService().exportBatch(.init(sourceURLs: [image, corrupt, document], destinationDirectoryURL: directory, languages: ["en"]),
            progress: { progress.append($0) }, authorize: { try await authorizations.record($0, $1) })
        XCTAssertEqual(result.items.map(\.state), [.succeeded, .failed, .succeeded])
        XCTAssertEqual(result.items.map(\.sourceURL), [image, corrupt, document])
        XCTAssertEqual(result.items[0].destinationURL?.lastPathComponent, "Café 日本語-OCR (2).pdf")
        XCTAssertEqual(result.items[2].destinationURL?.lastPathComponent, "Café 日本語-OCR (3).pdf")
        for index in [0, 2] {
            let url = try XCTUnwrap(result.items[index].destinationURL)
            XCTAssertTrue(try XCTUnwrap(PDFDocument(url: url)).string?.contains("MY EXPLORER 2048") == true)
            XCTAssertEqual(result.items[index].receipt?.pageCount, 1)
        }
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try [image, document, corrupt].map { try Data(contentsOf: $0) }, original)
        XCTAssertEqual(progress.values.last?.completedResults, result.items)
        XCTAssertTrue(progress.values.contains { $0.index == 3 && $0.completedResults.count == 2 })
        let calls = await authorizations.values
        XCTAssertEqual(calls.first?.0, directory); XCTAssertEqual(calls.first?.1, .destination)
        XCTAssertTrue(calls.contains { $0.0 == image && $0.1 == .source })
        XCTAssertTrue(calls.contains { $0.0 == result.items[2].destinationURL && $0.1 == .destination })
    }
    func testCancellationAfterConfirmedReceiptPreservesItAndDoesNotStartNext() async throws {
        let root = try fixture(), entered = expectation(description: "export entered"), gate = PDFBatchGate()
        let writer = PDFBatchFakeWriter { request, _, _ in
            entered.fulfill(); await gate.wait()
            return .init(destinationURL: request.destinationURL, pageCount: 1, recognizedPages: 1, textLayerPages: 0)
        }
        let sources = ["one.png", "two.png", "three.pdf"].map { root.appendingPathComponent($0) }, progress = PDFBatchProgressProbe()
        let task = Task { try await SearchablePDFBatchService(writer: writer).exportBatch(.init(sourceURLs: sources, destinationDirectoryURL: root), progress: { progress.append($0) }) }
        await fulfillment(of: [entered], timeout: 2); task.cancel(); await gate.open()
        let result = try await task.value
        XCTAssertEqual(result.items.map(\.state), [.succeeded, .notStarted, .notStarted])
        XCTAssertNotNil(result.items[0].receipt); XCTAssertEqual(result.items[1].reason, .cancelled)
        XCTAssertEqual(progress.values.last?.completedResults, result.items)
        let count = await writer.count; XCTAssertEqual(count, 1)
    }
    func testCancellationBeforePublicationReportsCurrentAndLeavesRemainingUntouched() async throws {
        let root = try fixture(), entered = expectation(description: "export entered")
        let writer = PDFBatchFakeWriter { _, _, _ in entered.fulfill(); try await Task.sleep(for: .seconds(30)); throw CancellationError() }
        let sources = [root.appendingPathComponent("one.png"), root.appendingPathComponent("two.png")]
        let task = Task { try await SearchablePDFBatchService(writer: writer).exportBatch(.init(sourceURLs: sources, destinationDirectoryURL: root)) }
        await fulfillment(of: [entered], timeout: 2); task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.items.map(\.state), [.cancelled, .notStarted]); XCTAssertTrue(result.items.allSatisfy { $0.receipt == nil })
        let count = await writer.count; XCTAssertEqual(count, 1)
    }
    func testIndeterminateBusyAndTimeoutStopWithoutRetryButUnsupportedContinues() async throws {
        let root = try fixture(), sources = [root.appendingPathComponent("one.png"), root.appendingPathComponent("two.png")]
        for reason in [SearchablePDFFailure.Reason.publicationIndeterminate, .busy, .timedOut, .unsupportedType] {
            let writer = PDFBatchFakeWriter { _, _, _ in throw SearchablePDFFailure(reason) }
            let result = try await SearchablePDFBatchService(writer: writer).exportBatch(.init(sourceURLs: sources, destinationDirectoryURL: root))
            XCTAssertEqual(result.items[0].state, reason == .publicationIndeterminate ? .needsInput : .failed)
            XCTAssertEqual(result.items[1].state, reason == .unsupportedType ? .failed : .notStarted)
            let count = await writer.count; XCTAssertEqual(count, reason == .unsupportedType ? 2 : 1)
        }
    }
    func testAuthorizationRevokedAfterFirstRealSuccessStopsAndKeepsReceipt() async throws {
        let root = try fixture(), sources = ["one.pdf", "two.pdf", "three.pdf"].map { root.appendingPathComponent($0) }
        for source in sources { try pdf(source) }
        let result = try await SearchablePDFBatchService().exportBatch(.init(sourceURLs: sources, destinationDirectoryURL: root), authorize: { url, role in
            if role == .source, url == sources[1] { throw SearchablePDFFailure(.authorizationDenied) }
        })
        XCTAssertEqual(result.items.map(\.state), [.succeeded, .failed, .notStarted])
        XCTAssertEqual(result.items[1].reason, .authorizationDenied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.items[0].destinationURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("two-OCR.pdf").path))
    }
    func testCollisionRetriesAreBoundedAndNeverRetryOtherFailures() async throws {
        let root = try fixture(), source = root.appendingPathComponent("file.png")
        let writer = PDFBatchFakeWriter { _, _, _ in throw SearchablePDFFailure(.destinationExists) }
        let result = try await SearchablePDFBatchService(writer: writer).exportBatch(.init(sourceURLs: [source], destinationDirectoryURL: root))
        let count = await writer.count; XCTAssertEqual(count, 100)
        XCTAssertEqual(result.items[0].reason, .destinationExists)
        XCTAssertEqual(result.items[0].destinationURL?.lastPathComponent, "file-OCR (100).pdf")
    }
    func testValidationRejectsDuplicateBytesButKeepsCanonicallyEquivalentNamesDistinct() async throws {
        let root = try fixture()
        let prefix = root.absoluteString + (root.absoluteString.hasSuffix("/") ? "" : "/")
        let nfc = try XCTUnwrap(URL(string: prefix + "Caf%C3%A9.png")), nfd = try XCTUnwrap(URL(string: prefix + "Cafe%CC%81.png"))
        let writer = PDFBatchFakeWriter { request, _, _ in .init(destinationURL: request.destinationURL, pageCount: 1, recognizedPages: 1, textLayerPages: 0) }
        let service = SearchablePDFBatchService(writer: writer)
        let result = try await service.exportBatch(.init(sourceURLs: [nfc, nfd], destinationDirectoryURL: root))
        XCTAssertEqual(result.items.count, 2); XCTAssertEqual(result.items.map(\.state), [.succeeded, .succeeded])
        XCTAssertNotEqual(Data(result.items[0].sourceURL.path.utf8), Data(result.items[1].sourceURL.path.utf8))
        XCTAssertNotEqual(Data(try XCTUnwrap(result.items[0].destinationURL).path.utf8), Data(try XCTUnwrap(result.items[1].destinationURL).path.utf8))
        for sources in [[], [nfc, nfc], (0..<51).map { root.appendingPathComponent("\($0).png") }] {
            do { _ = try await service.exportBatch(.init(sourceURLs: sources, destinationDirectoryURL: root)); XCTFail("Invalid batch accepted") }
            catch { XCTAssertEqual((error as? SearchablePDFFailure)?.reason, .invalidRequest) }
        }
        let traversal = URL(fileURLWithPath: root.path + "/child/../Café.png")
        do { _ = try await service.exportBatch(.init(sourceURLs: [nfd, traversal], destinationDirectoryURL: root)); XCTFail("Duplicate lexical path accepted") }
        catch { XCTAssertEqual((error as? SearchablePDFFailure)?.reason, .invalidRequest) }
        let encodedSeparator = try XCTUnwrap(URL(string: prefix + "nested%2Fname.png"))
        let actualDirectory = root.appendingPathComponent("nested").appendingPathComponent("name.png")
        XCTAssertNotEqual(Data(encodedSeparator.path.utf8), Data(actualDirectory.path.utf8))
        let distinct = try await service.exportBatch(.init(sourceURLs: [encodedSeparator, actualDirectory], destinationDirectoryURL: root))
        XCTAssertEqual(distinct.items.map(\.state), [.succeeded, .succeeded])
        let literalPercentName = root.appendingPathComponent("nested%2Fname.png")
        XCTAssertEqual(Data(encodedSeparator.path.utf8), Data(literalPercentName.path.utf8))
        do { _ = try await service.exportBatch(.init(sourceURLs: [encodedSeparator, literalPercentName], destinationDirectoryURL: root)); XCTFail("Same filesystem path accepted twice") }
        catch { XCTAssertEqual((error as? SearchablePDFFailure)?.reason, .invalidRequest) }
        let long = root.appendingPathComponent(String(repeating: "🎨e\u{301}", count: 100) + ".png")
        for attempt in [1, 2, 100] {
            let name = SearchablePDFBatchService.destinationName(for: long, attempt: attempt)
            XCTAssertLessThanOrEqual(name.utf8.count, 255); XCTAssertTrue(name.hasSuffix(".pdf"))
            XCTAssertEqual(String(data: Data(name.utf8), encoding: .utf8), name)
        }
    }
    func testDirectoryAuthorizationHappensBeforeMetadataAndNoWriterRunsWhenDenied() async throws {
        let root = try fixture(), writer = PDFBatchFakeWriter { request, _, _ in .init(destinationURL: request.destinationURL, pageCount: 1, recognizedPages: 1, textLayerPages: 0) }
        let missing = root.appendingPathComponent("missing-directory")
        let result = try await SearchablePDFBatchService(writer: writer).exportBatch(.init(sourceURLs: [root.appendingPathComponent("one.png")], destinationDirectoryURL: missing), authorize: { _, _ in throw SearchablePDFFailure(.authorizationDenied) })
        XCTAssertEqual(result.items[0].state, .notStarted); XCTAssertEqual(result.items[0].reason, .authorizationDenied)
        let count = await writer.count; XCTAssertEqual(count, 0)
    }
}
private actor PDFBatchFakeWriter: SearchablePDFWriting {
    typealias Action = @Sendable (SearchablePDFRequest, (@Sendable (OCRProgress) -> Void)?, (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)?) async throws -> SearchablePDFResult
    let action: Action
    private(set) var count = 0
    init(_ action: @escaping Action) { self.action = action }
    func export(_ request: SearchablePDFRequest, progress: (@Sendable (OCRProgress) -> Void)?, authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)?) async throws -> SearchablePDFResult {
        count += 1; return try await action(request, progress, authorize)
    }
}
private actor PDFBatchGate {
    private var isOpen = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { if isOpen { return }; await withCheckedContinuation { waiting = $0 } }
    func open() { isOpen = true; waiting?.resume(); waiting = nil }
}
private final class PDFBatchProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SearchablePDFBatchProgress] = []
    var values: [SearchablePDFBatchProgress] { lock.withLock { storage } }
    func append(_ value: SearchablePDFBatchProgress) { lock.withLock { storage.append(value) } }
}
private actor PDFBatchAuthorizationProbe {
    private(set) var values: [(URL, SearchablePDFLocationRole)] = []
    func record(_ url: URL, _ role: SearchablePDFLocationRole) { values.append((url, role)) }
}
