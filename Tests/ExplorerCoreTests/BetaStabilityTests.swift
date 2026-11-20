// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import PDFKit
import CoreText
import Darwin
@testable import ExplorerCore

final class BetaStabilityTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.BetaStability.\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func pdf(_ url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 30, y: 150)
        let string = NSAttributedString(string: "BETA STABILITY 2048", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil)])
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        context.endPDFPage(); context.closePDF()
    }
    private func sources(_ root: URL, count: Int, sameBasename: Bool) throws -> [URL] {
        let template = root.appendingPathComponent("template.pdf"); try pdf(template)
        return try (0..<count).map { index in
            let directory = root.appendingPathComponent("source-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let source = directory.appendingPathComponent(sameBasename ? "Documento 日本語.pdf" : "document-\(index).pdf")
            try FileManager.default.copyItem(at: template, to: source); return source
        }
    }
    private func waitForStagingCleanup(_ directory: URL) async throws {
        for _ in 0..<200 {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if !names.contains(where: { $0.hasPrefix(".my-explorer-pdf-") }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Private staging directories must be removed after workers retire")
    }
    func testFiftyRealExportsWithSameBasenameStayExclusiveOrderedAndReleaseStaging() async throws {
        let root = try fixture(), input = try sources(root, count: 50, sameBasename: true), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let originals = try input.map { try Data(contentsOf: $0) }
        let existing = output.appendingPathComponent("Documento 日本語-OCR.pdf"), sentinel = Data("preexisting file is never replaced".utf8)
        try sentinel.write(to: existing)
        let result = try await SearchablePDFBatchService().exportBatch(.init(sourceURLs: input, destinationDirectoryURL: output))
        XCTAssertEqual(result.items.count, 50)
        XCTAssertEqual(result.items.map(\.state), Array(repeating: .succeeded, count: 50))
        XCTAssertEqual(result.items.map(\.sourceURL), input)
        let urls = try result.items.map { try XCTUnwrap($0.receipt?.destinationURL) }
        XCTAssertEqual(Set(urls.map { Data($0.path.utf8) }).count, 50)
        XCTAssertEqual(urls.first?.lastPathComponent, "Documento 日本語-OCR (2).pdf")
        XCTAssertEqual(urls.last?.lastPathComponent, "Documento 日本語-OCR (51).pdf")
        for url in urls { XCTAssertTrue(try XCTUnwrap(PDFDocument(url: url)).string?.contains("BETA STABILITY 2048") == true) }
        XCTAssertEqual(try input.map { try Data(contentsOf: $0) }, originals)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        try await waitForStagingCleanup(output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 51)
    }
    func testCancelMiddleOfFiftyKeepsSeventeenRealReceiptsAndDoesNotStartLaterSources() async throws {
        let root = try fixture(), input = try sources(root, count: 50, sameBasename: false), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let paused = expectation(description: "eighteenth item reached")
        let writer = BetaPauseWriter(at: 18, entered: { paused.fulfill() })
        let task = Task { try await SearchablePDFBatchService(writer: writer).exportBatch(.init(sourceURLs: input, destinationDirectoryURL: output)) }
        await fulfillment(of: [paused], timeout: 20); task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.items.prefix(17).map(\.state), Array(repeating: .succeeded, count: 17))
        XCTAssertEqual(result.items[17].state, .cancelled)
        XCTAssertEqual(result.items.suffix(32).map(\.state), Array(repeating: .notStarted, count: 32))
        for item in result.items.prefix(17) { XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.receipt?.destinationURL).path)) }
        let calls = await writer.calls; XCTAssertEqual(calls, 18)
        try await waitForStagingCleanup(output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 17)
    }
    func testCollisionRetryRefusesReplacedDestinationDirectory() async throws {
        let root = try fixture(), output = root.appendingPathComponent("chosen"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("input.pdf"); try pdf(source)
        let writer = BetaDirectoryReplacingWriter(original: output, moved: moved)
        let result = try await SearchablePDFBatchService(writer: writer).exportBatch(.init(sourceURLs: [source, root.appendingPathComponent("next.pdf")], destinationDirectoryURL: output))
        XCTAssertEqual(result.items.map(\.state), [.failed, .notStarted])
        XCTAssertEqual(result.items[0].reason, .sourceChanged)
        let calls = await writer.calls; XCTAssertEqual(calls, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }
    func testParentMoveDuringCommitReportsIndeterminateAndPreservesPublishedBytes() throws {
        let root = try fixture(), output = root.appendingPathComponent("chosen"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let control = OCRCancellation(), target = output.appendingPathComponent("result.pdf")
        let destination = try PDFDestination.inspect(target, control: control), lease = try PDFExportLease.acquire()
        let descriptor = try lease.prepare(destination, control: control)
        let bytes = Data("disposable published fixture".utf8)
        try bytes.withUnsafeBytes { buffer in XCTAssertEqual(write(descriptor, buffer.baseAddress, buffer.count), buffer.count); try lease.seal(descriptor) }
        close(descriptor)
        XCTAssertThrowsError(try lease.publish(to: destination, control: control) {
            try FileManager.default.moveItem(at: output, to: moved)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        }) { XCTAssertEqual(($0 as? SearchablePDFFailure)?.reason, .publicationIndeterminate) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("result.pdf")), bytes)
    }
}
private actor BetaPauseWriter: SearchablePDFWriting {
    let position: Int
    let entered: @Sendable () -> Void
    private(set) var calls = 0
    init(at position: Int, entered: @escaping @Sendable () -> Void) { self.position = position; self.entered = entered }
    func export(_ request: SearchablePDFRequest, progress: (@Sendable (OCRProgress) -> Void)?, authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)?) async throws -> SearchablePDFResult {
        calls += 1
        if calls == position { entered(); try await Task.sleep(for: .seconds(60)) }
        return try await SearchablePDFService().export(request, progress: progress, authorize: authorize)
    }
}
private actor BetaDirectoryReplacingWriter: SearchablePDFWriting {
    let original: URL
    let moved: URL
    private(set) var calls = 0
    init(original: URL, moved: URL) { self.original = original; self.moved = moved }
    func export(_ request: SearchablePDFRequest, progress: (@Sendable (OCRProgress) -> Void)?, authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)?) async throws -> SearchablePDFResult {
        calls += 1
        if calls == 1 {
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            throw SearchablePDFFailure(.destinationExists)
        }
        return try await SearchablePDFService().export(request, progress: progress, authorize: authorize)
    }
}
