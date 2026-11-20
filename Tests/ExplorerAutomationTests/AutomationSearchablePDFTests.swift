// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import CoreText
import PDFKit
import XCTest
import ExplorerCore
@testable import ExplorerAutomation

final class AutomationSearchablePDFTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL, source: URL, destination: URL, stateURL: URL
        let service: AutomationService
        let writer: SearchablePDFFixtureWriter
        let grant: AutomationGrant
        func call(_ method: String, _ arguments: [String: JSONValue] = [:]) async -> AutomationResponse {
            await service.handle(.init(method: method, arguments: .object(arguments), clientID: grant.id.uuidString, token: "PDF-FIXTURE-TOKEN"))
        }
        func start(destination: URL? = nil) async -> AutomationResponse {
            await call("files.ocr.pdf", ["url": .string(source.absoluteString), "destination": .string((destination ?? self.destination).absoluteString)])
        }
    }
    private func fixture(operations: Set<String> = ["files.ocr.pdf"], mode: SearchablePDFFixtureWriter.Mode = .normal) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFAutomation.\(UUID())", isDirectory: true)
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let source = allowed.appendingPathComponent("image.png"), destination = allowed.appendingPathComponent("new.pdf")
        try Data("DISPOSABLE IMAGE INPUT".utf8).write(to: source)
        let writer = SearchablePDFFixtureWriter(mode: mode)
        let files = SharedFileOperations(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) }, searchablePDFWriter: writer)
        let stateURL = root.appendingPathComponent("state/state.json")
        let environment = AutomationEnvironment(connections: { [] }, revision: { "fixture" }, authenticate: { _ in }, authenticated: { _ in false }, apply: { _ in }, preferences: { .object([:]) }, updatePreferences: { $0 })
        let service = try AutomationService(files: files, environment: environment, stateURL: stateURL)
        let grant = AutomationGrant(name: "PDF fixture", token: "PDF-FIXTURE-TOKEN", expires: Date().addingTimeInterval(120), operations: operations, localRoots: [allowed.path], cloudScopes: [])
        try await service.setEnabled(true); try await service.grant(grant)
        addTeardownBlock { await writer.resume(); await service.shutdown(); try? FileManager.default.removeItem(at: root) }
        return .init(root: root, source: source, destination: destination, stateURL: stateURL, service: service, writer: writer, grant: grant)
    }
    private func id(_ response: AutomationResponse) throws -> String {
        XCTAssertTrue(response.ok, response.error ?? "start failed")
        return try XCTUnwrap(response.result?["id"]?.stringValue)
    }
    private func terminal(_ f: Fixture, id: String) async throws -> JSONValue {
        for _ in 0..<600 {
            let response = await f.call("ocr.status", ["jobID": .string(id)])
            XCTAssertTrue(response.ok, response.error ?? "status failed")
            if let result = response.result, let state = result["state"]?.stringValue,
               !["queued", "running", "cancelling"].contains(state) { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AutomationError.busy
    }
    private func waitForPause(_ writer: SearchablePDFFixtureWriter) async throws {
        for _ in 0..<600 {
            if await writer.isPaused { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AutomationError.busy
    }
    func testExistingOCRReadAndCopyGrantsDoNotAuthorizePDFWrite() async throws {
        let f = try await fixture(operations: ["read", "copy", "files.ocr"])
        let denied = await f.start()
        XCTAssertEqual(denied.error, "forbidden")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        let calls = await f.writer.calls
        XCTAssertEqual(calls, 0)
    }
    func testMetadataOnlyResultAndCompletedCancelRetainPublishedFile() async throws {
        let f = try await fixture()
        let job = try id(await f.start())
        let result = try await terminal(f, id: job)
        XCTAssertEqual(result["state"], .string("succeeded"))
        XCTAssertEqual(result["kind"], .string("ocrPDF"))
        XCTAssertEqual(result["completedCount"], .number(1))
        XCTAssertEqual(result["result"]?["pageCount"], .number(1))
        XCTAssertEqual(result["result"]?["destinationURL"], .string(f.destination.absoluteString))
        XCTAssertNil(result["result"]?["fullText"])
        XCTAssertNil(result["result"]?["data"])
        XCTAssertFalse(String(decoding: try AutomationWire.encode(result), as: UTF8.self).contains("PRIVATE PDF PAYLOAD"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: f.stateURL), as: UTF8.self).contains("PRIVATE PDF PAYLOAD"))
        let cancelled = await f.call("ocr.cancel", ["jobID": .string(job)])
        XCTAssertEqual(cancelled.result?["state"], .string("succeeded"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.path))
        XCTAssertEqual(try Data(contentsOf: f.source), Data("DISPOSABLE IMAGE INPUT".utf8))
    }
    func testOutsideAndSymlinkDestinationNeverReachWriter() async throws {
        let f = try await fixture()
        let outside = f.root.appendingPathComponent("outside.pdf")
        let denied = await f.start(destination: outside)
        XCTAssertEqual(denied.error, "forbidden")
        try Data("EXISTING OUTSIDE".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.destination, withDestinationURL: outside)
        let first = try id(await f.start())
        let failure = try await terminal(f, id: first)
        XCTAssertEqual(failure["state"], .string("failed"))
        XCTAssertEqual(try Data(contentsOf: outside), Data("EXISTING OUTSIDE".utf8))
        try FileManager.default.removeItem(at: f.destination)
        let externalDirectory = f.root.appendingPathComponent("external-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        let alias = f.source.deletingLastPathComponent().appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: externalDirectory)
        let second = try id(await f.start(destination: alias.appendingPathComponent("new.pdf")))
        let failure2 = try await terminal(f, id: second)
        XCTAssertEqual(failure2["state"], .string("failed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalDirectory.appendingPathComponent("new.pdf").path))
        let calls = await f.writer.calls
        XCTAssertEqual(calls, 0)
    }
    func testExistingDestinationIsNeverReplaced() async throws {
        let f = try await fixture()
        try Data("ORIGINAL PDF".utf8).write(to: f.destination)
        let job = try id(await f.start())
        let result = try await terminal(f, id: job)
        XCTAssertEqual(result["state"], .string("failed"))
        XCTAssertEqual(result["error"], .string("destinationExists"))
        XCTAssertEqual(try Data(contentsOf: f.destination), Data("ORIGINAL PDF".utf8))
    }
    func testCancelBeforePublicationPreventsLateFile() async throws {
        let f = try await fixture(mode: .paused)
        let job = try id(await f.start())
        try await waitForPause(f.writer)
        let cancelled = await f.call("ocr.cancel", ["jobID": .string(job)])
        XCTAssertEqual(cancelled.result?["state"], .string("cancelling"))
        await f.writer.resume()
        let result = try await terminal(f, id: job)
        XCTAssertEqual(result["state"], .string("cancelled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
    }
    func testRevocationBeforePublicationPreventsLateFile() async throws {
        let f = try await fixture(mode: .paused)
        _ = try id(await f.start())
        try await waitForPause(f.writer)
        try await f.service.revoke(f.grant.id)
        await f.writer.resume()
        await f.service.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        let calls = await f.writer.calls
        XCTAssertEqual(calls, 1)
    }
    func testConfirmedReceiptWinsOverCancellationAfterPublication() async throws {
        let f = try await fixture(mode: .publishedThenPaused)
        let job = try id(await f.start())
        try await waitForPause(f.writer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.path))
        _ = await f.call("ocr.cancel", ["jobID": .string(job)])
        await f.writer.resume()
        let result = try await terminal(f, id: job)
        XCTAssertEqual(result["state"], .string("succeeded"))
        XCTAssertEqual(result["completedCount"], .number(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.path))
    }
    func testScopeReductionBeforePublicationDeniesWriteAndMetadata() async throws {
        let f = try await fixture(mode: .paused)
        let job = try id(await f.start())
        try await waitForPause(f.writer)
        var narrowed = f.grant
        narrowed.localRoots = [f.root.appendingPathComponent("elsewhere").path]
        try await f.service.grant(narrowed)
        let denied = await f.call("ocr.status", ["jobID": .string(job)])
        XCTAssertEqual(denied.error, "forbidden")
        XCTAssertNil(denied.result)
        await f.writer.resume()
        // The request reauthorizes after the suspended writer resumes.
        for _ in 0..<600 {
            if await f.writer.hasReturned { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        try await f.service.grant(f.grant)
        let result = try await terminal(f, id: job)
        XCTAssertEqual(result["state"], .string("cancelled"))
        XCTAssertEqual(result["result"], .null)
    }
    func testGrantReductionAfterFinalAuthorizationCancelsBeforePublicationGate() async throws {
        let f = try await fixture(mode: .authorizedThenPaused)
        let job = try id(await f.start())
        try await waitForPause(f.writer)
        var narrowed = f.grant
        narrowed.localRoots = [f.root.appendingPathComponent("elsewhere").path]
        try await f.service.grant(narrowed)
        await f.writer.resume()
        for _ in 0..<600 {
            if await f.writer.hasReturned { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let returned = await f.writer.hasReturned
        XCTAssertTrue(returned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        try await f.service.grant(f.grant)
        let result = try await terminal(f, id: job)
        XCTAssertEqual(result["state"], .string("cancelled"))
        XCTAssertEqual(result["result"], .null)
    }
    func testIndeterminatePublicationIsNotReportedAsCancelled() async throws {
        let f = try await fixture(mode: .indeterminate)
        let job = try id(await f.start())
        let result = try await terminal(f, id: job)
        XCTAssertEqual(result["state"], .string("needs_input"))
        XCTAssertEqual(result["error"], .string("publicationIndeterminate"))
    }
    func testPDFCommandRequiresExplicitOutputAndRejectsRanges() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let command = try OCRCommand.request(arguments: ["ocr", "pdf", "image.png", "--output", "new.pdf", "--language", "pt-BR"], workingDirectory: root)
        XCTAssertEqual(command.method, "files.ocr.pdf")
        XCTAssertNotNil(command.arguments["destination"]?.stringValue)
        XCTAssertEqual(AutomationToolCatalog.method(forTool: "files_ocr_pdf"), "files.ocr.pdf")
        XCTAssertThrowsError(try OCRCommand.request(arguments: ["ocr", "pdf", "image.png"], workingDirectory: root))
        XCTAssertThrowsError(try OCRCommand.request(arguments: ["ocr", "pdf", "in.pdf", "--output", "new.pdf", "--pages", "1:2"], workingDirectory: root))
        XCTAssertThrowsError(try OCRCommand.request(arguments: ["ocr", "pdf", "in.pdf", "--output", "s3://bucket/out.pdf"], workingDirectory: root))
        XCTAssertFalse(AutomationToolCatalog.validate(method: "files.ocr.pdf", arguments: .object(["url": .string("/tmp/a.pdf"), "destination": .string("/tmp/b.pdf"), "overwrite": .bool(true)])))
    }
    func testRealPDFExportThroughSharedServicePreservesPageAndText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFSharedReal.\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf"), destination = root.appendingPathComponent("searchable.pdf")
        var box = CGRect(x: 0, y: 0, width: 500, height: 300)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 30, y: 200)
        let line = NSAttributedString(string: "SEARCHABLE PDF AUTOMATION FIXTURE", attributes: [.init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)])
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        context.endPDFPage(); context.closePDF()
        let original = try Data(contentsOf: source)
        let files = SharedFileOperations(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) })
        let result = try await files.searchablePDF(.init(sourceURL: source, destinationURL: destination),
            authorizeSource: { url in guard url.lastPathComponent == "source.pdf" else { throw AutomationError.forbidden } },
            authorizeDestination: { url in guard url.lastPathComponent == "searchable.pdf" else { throw AutomationError.forbidden } })
        XCTAssertEqual(result.pageCount, 1)
        let document = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertTrue(document.string?.contains("SEARCHABLE PDF AUTOMATION FIXTURE") == true)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 500, height: 300))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}

private actor SearchablePDFFixtureWriter: SearchablePDFWriting {
    enum Mode { case normal, paused, authorizedThenPaused, publishedThenPaused, indeterminate }
    let mode: Mode
    private(set) var calls = 0
    private(set) var isPaused = false
    private(set) var hasReturned = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(mode: Mode) { self.mode = mode }
    func export(_ request: SearchablePDFRequest, progress: (@Sendable (OCRProgress) -> Void)?,
                authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)?) async throws -> SearchablePDFResult {
        calls += 1
        defer { hasReturned = true }
        try await authorize?(request.sourceURL, .source)
        try await authorize?(request.destinationURL, .destination)
        if mode == .indeterminate { throw SearchablePDFFailure(.publicationIndeterminate) }
        if mode == .publishedThenPaused {
            try Data("PRIVATE PDF PAYLOAD".utf8).write(to: request.destinationURL, options: .withoutOverwriting)
        }
        if mode == .paused || mode == .authorizedThenPaused || mode == .publishedThenPaused {
            isPaused = true
            await withCheckedContinuation { continuation = $0 }
        }
        if mode != .publishedThenPaused {
            if mode != .authorizedThenPaused {
                try await authorize?(request.sourceURL, .source)
                try await authorize?(request.destinationURL, .destination)
            }
            try Task.checkCancellation()
            try Data("PRIVATE PDF PAYLOAD".utf8).write(to: request.destinationURL, options: .withoutOverwriting)
        }
        return .init(destinationURL: request.destinationURL, pageCount: 1, recognizedPages: 1, textLayerPages: 0)
    }
    func resume() { continuation?.resume(); continuation = nil; isPaused = false }
}
