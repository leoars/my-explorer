// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import CoreText
import PDFKit
import XCTest
import ExplorerCore
@testable import ExplorerAutomation

final class AutomationPDFBatchTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL, directory: URL, sources: [URL], stateURL: URL
        let service: AutomationService, files: SharedFileOperations
        let writer: BatchFixtureWriter
        let grant: AutomationGrant
        func call(_ method: String, _ arguments: [String: JSONValue] = [:]) async -> AutomationResponse {
            await service.handle(.init(method: method, arguments: .object(arguments), clientID: grant.id.uuidString, token: "BATCH-TEST"))
        }
        func start(sources: [URL]? = nil, directory: URL? = nil) async -> AutomationResponse {
            await call("files.ocr.pdf.batch", ["urls": .array((sources ?? self.sources).map { .string($0.absoluteString) }),
                "destination": .string((directory ?? self.directory).absoluteString)])
        }
    }
    private func fixture(operations: Set<String> = ["files.ocr.pdf"], mode: BatchFixtureWriter.Mode = .normal) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomationPDFBatch.\(UUID())", isDirectory: true)
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        let directory = allowed.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sources = ["one.png", "two.png", "three.png"].map { allowed.appendingPathComponent($0) }
        for source in sources { try Data("DISPOSABLE INPUT".utf8).write(to: source) }
        let writer = BatchFixtureWriter(mode: mode)
        let files = SharedFileOperations(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) },
            searchablePDFBatchWriter: SearchablePDFBatchService(writer: writer))
        let stateURL = root.appendingPathComponent("state/state.json")
        let environment = AutomationEnvironment(connections: { [] }, revision: { "test" }, authenticate: { _ in }, authenticated: { _ in false }, apply: { _ in }, preferences: { .object([:]) }, updatePreferences: { $0 })
        let service = try AutomationService(files: files, environment: environment, stateURL: stateURL)
        let grant = AutomationGrant(name: "Batch fixture", token: "BATCH-TEST", expires: Date().addingTimeInterval(120), operations: operations, localRoots: [allowed.path], cloudScopes: [])
        try await service.setEnabled(true); try await service.grant(grant)
        addTeardownBlock { await writer.resume(); await service.shutdown(); try? FileManager.default.removeItem(at: root) }
        return .init(root: root, directory: directory, sources: sources, stateURL: stateURL, service: service, files: files, writer: writer, grant: grant)
    }
    private func jobID(_ response: AutomationResponse) throws -> String {
        XCTAssertTrue(response.ok, response.error ?? "start failed")
        return try XCTUnwrap(response.result?["id"]?.stringValue)
    }
    private func terminal(_ f: Fixture, _ id: String) async throws -> JSONValue {
        for _ in 0..<600 {
            let response = await f.call("ocr.status", ["jobID": .string(id)])
            XCTAssertTrue(response.ok, response.error ?? "status failed")
            if let result = response.result, let state = result["state"]?.stringValue,
               !["queued", "running", "cancelling"].contains(state) { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AutomationError.busy
    }
    private func paused(_ writer: BatchFixtureWriter) async throws {
        for _ in 0..<600 {
            if await writer.paused { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AutomationError.busy
    }
    func testBatchCommandAndMCPBoundedSchema() throws {
        let command = try OCRCommand.request(arguments: ["ocr", "batch", "one.png", "two.pdf", "--output-directory", "output", "--language", "pt-BR"], workingDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(command.method, "files.ocr.pdf.batch")
        XCTAssertEqual(command.arguments["urls"]?.arrayValue?.count, 2)
        XCTAssertEqual(AutomationToolCatalog.method(forTool: "files_ocr_pdf_batch"), command.method)
        for args in [["ocr", "batch", "one.png"], ["ocr", "batch", "--output-directory", "output"],
                     ["ocr", "batch", "one.png", "--output-directory", "output", "--pages", "1:2"],
                     ["ocr", "batch", "s3://bucket/one.png", "--output-directory", "output"]] {
            XCTAssertThrowsError(try OCRCommand.request(arguments: args, workingDirectory: URL(fileURLWithPath: "/tmp")))
        }
        XCTAssertFalse(AutomationToolCatalog.validate(method: command.method, arguments: .object(["urls": .array(Array(repeating: .string("/tmp/x.png"), count: 51)), "destination": .string("/tmp/output")])))
    }
    func testEveryOriginalSourceAndDestinationNeedsPDFGrant() async throws {
        let legacy = try await fixture(operations: ["read", "copy", "files.ocr"])
        let denied = await legacy.start()
        XCTAssertEqual(denied.error, "forbidden")
        let f = try await fixture()
        let outside = f.root.appendingPathComponent("outside.png")
        try Data("OUTSIDE".utf8).write(to: outside)
        let outsideSource = await f.start(sources: [f.sources[0], outside])
        XCTAssertEqual(outsideSource.error, "forbidden")
        let outsideDestination = await f.start(directory: f.root)
        XCTAssertEqual(outsideDestination.error, "forbidden")
        let calls = await f.writer.calls
        XCTAssertEqual(calls, 0)
    }
    func testGrantItemLimitRejectsBatchBeforeCreatingJobOrCallingWriter() async throws {
        let f = try await fixture()
        var limited = f.grant
        limited.maximumItems = 1
        try await f.service.grant(limited)
        let denied = await f.start(sources: Array(f.sources.prefix(2)))
        XCTAssertEqual(denied.error, "limitExceeded")
        XCTAssertNil(denied.result)
        let calls = await f.writer.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).isEmpty)
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as? [String: Any]
        XCTAssertEqual((persisted?["jobs"] as? [Any])?.count, 0)
    }
    func testMetadataOnlyBatchAndExistingOutputsRemainUntouched() async throws {
        let f = try await fixture()
        let existing = f.directory.appendingPathComponent("one-OCR.pdf")
        try Data("EXISTING".utf8).write(to: existing)
        let id = try jobID(await f.start())
        let result = try await terminal(f, id)
        XCTAssertEqual(result["kind"], .string("ocrPDFBatch"))
        XCTAssertEqual(result["state"], .string("succeeded"))
        XCTAssertEqual(result["completedCount"], .number(3))
        XCTAssertEqual(result["result"]?["items"]?.arrayValue?.count, 3)
        XCTAssertEqual(try Data(contentsOf: existing), Data("EXISTING".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("one-OCR (2).pdf").path))
        let bytes = try AutomationWire.encode(result)
        XCTAssertLessThan(bytes.count, AutomationWire.maximumMessageBytes / 4)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE PDF CONTENT"))
        let persisted = String(decoding: try Data(contentsOf: f.stateURL), as: UTF8.self)
        XCTAssertFalse(persisted.contains("one.png")); XCTAssertFalse(persisted.contains("one-OCR"))
        let cancelled = await f.call("ocr.cancel", ["jobID": .string(id)])
        XCTAssertEqual(cancelled.result?["state"], .string("succeeded"))
    }
    func testFiftyItemReportRemainsBoundedAndScopeReductionHidesAllReceipts() async throws {
        let f = try await fixture()
        let sources = try (0..<50).map { index -> URL in
            let url = f.directory.deletingLastPathComponent().appendingPathComponent("doc-\(index).png")
            try Data("DISPOSABLE INPUT".utf8).write(to: url)
            return url
        }
        let id = try jobID(await f.start(sources: sources))
        let result = try await terminal(f, id)
        XCTAssertEqual(result["state"], .string("succeeded"))
        XCTAssertEqual(result["completedCount"], .number(50))
        XCTAssertEqual(result["result"]?["items"]?.arrayValue?.count, 50)
        let metadata = try AutomationWire.encode(result)
        // MCP returns both structured JSON and JSON encoded as a text block.
        let mcpEnvelope: JSONValue = .object(["structuredContent": result,
            "content": .array([.object(["type": .string("text"), "text": .string(String(decoding: metadata, as: UTF8.self))])])])
        XCTAssertLessThan(try AutomationWire.encode(mcpEnvelope).count, AutomationWire.maximumMessageBytes)
        var narrowed = f.grant
        narrowed.localRoots = [f.root.appendingPathComponent("elsewhere").path]
        try await f.service.grant(narrowed)
        let hidden = await f.call("ocr.status", ["jobID": .string(id)])
        XCTAssertEqual(hidden.error, "forbidden")
        XCTAssertNil(hidden.result)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).count, 50)
    }
    func testCancelPreservesFirstReceiptAndPreventsRemainingOutputs() async throws {
        let f = try await fixture(mode: .pauseSecond)
        let id = try jobID(await f.start())
        try await paused(f.writer)
        let status = await f.call("ocr.cancel", ["jobID": .string(id)])
        XCTAssertEqual(status.result?["state"], .string("cancelling"))
        await f.writer.resume()
        let result = try await terminal(f, id)
        XCTAssertEqual(result["state"], .string("cancelled"))
        XCTAssertEqual(result["completedCount"], .number(1))
        let items = try XCTUnwrap(result["result"]?["items"]?.arrayValue)
        XCTAssertEqual(items.map { $0["state"] }, [.string("succeeded"), .string("cancelled"), .string("notStarted")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("one-OCR.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("two-OCR.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("three-OCR.pdf").path))
    }
    func testGrantUpdateCancelsBatchAfterFinalAuthorizationAndHidesMetadata() async throws {
        let f = try await fixture(mode: .pauseSecond)
        let id = try jobID(await f.start())
        try await paused(f.writer)
        var narrowed = f.grant; narrowed.localRoots = [f.root.appendingPathComponent("elsewhere").path]
        try await f.service.grant(narrowed)
        let hidden = await f.call("ocr.status", ["jobID": .string(id)])
        XCTAssertEqual(hidden.error, "forbidden"); XCTAssertNil(hidden.result)
        await f.writer.resume()
        for _ in 0..<600 {
            if await f.writer.secondReturned { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("two-OCR.pdf").path))
        try await f.service.grant(f.grant)
        let result = try await terminal(f, id)
        XCTAssertEqual(result["state"], .string("cancelled"))
        XCTAssertEqual(result["completedCount"], .number(1))
    }
    func testRevokeStopsBatchWithoutDeletingConfirmedOutput() async throws {
        let f = try await fixture(mode: .pauseSecond)
        _ = try jobID(await f.start())
        try await paused(f.writer)
        try await f.service.revoke(f.grant.id)
        await f.writer.resume(); await f.service.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("one-OCR.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("two-OCR.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("three-OCR.pdf").path))
    }
    func testIndeterminateStopsBatchAndSharedGateCoversEntireBatch() async throws {
        let f = try await fixture(mode: .pauseSecondIndeterminate)
        let id = try jobID(await f.start())
        try await paused(f.writer)
        do {
            _ = try await f.files.searchablePDF(.init(sourceURL: f.sources[0], destinationURL: f.directory.appendingPathComponent("other.pdf")))
            XCTFail("Shared gate must remain occupied between batch items")
        } catch { XCTAssertEqual(error as? AutomationError, .busy) }
        await f.writer.resume()
        let result = try await terminal(f, id)
        XCTAssertEqual(result["state"], .string("needs_input"))
        XCTAssertEqual(result["completedCount"], .number(1))
        XCTAssertEqual(result["error"], .string("publicationIndeterminate"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("three-OCR.pdf").path))
    }
    func testResolvedDestinationOutsideGrantIsRejectedBeforeAnyWriter() async throws {
        let f = try await fixture()
        let outside = f.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let alias = f.directory.deletingLastPathComponent().appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let id = try jobID(await f.start(directory: alias))
        let result = try await terminal(f, id)
        XCTAssertEqual(result["state"], .string("failed"))
        XCTAssertEqual(result["completedCount"], .number(0))
        let calls = await f.writer.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testAggregateMetadataBudgetRejectsBeforeAnyWrite() async throws {
        let f = try await fixture()
        var deep = f.directory
        for _ in 0..<6 { deep.appendPathComponent(String(repeating: "d", count: 100), isDirectory: true) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let sources = (0..<50).map { f.directory.deletingLastPathComponent().appendingPathComponent("source-\($0).png") }
        do {
            _ = try await f.files.searchablePDFBatch(.init(sourceURLs: sources, destinationDirectoryURL: deep),
                authorizeSource: { _ in }, authorizeDestination: { _ in })
            XCTFail("Oversized result must be rejected before publication")
        } catch { XCTAssertEqual(error as? AutomationError, .limitExceeded) }
        let calls = await f.writer.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: deep.path).isEmpty)
    }
    func testTrustedGUIBatchDoesNotInheritAutomationWireBudget() async throws {
        let f = try await fixture()
        var deep = f.directory
        for _ in 0..<6 { deep.appendPathComponent(String(repeating: "d", count: 100), isDirectory: true) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let sources = (0..<50).map { f.directory.deletingLastPathComponent().appendingPathComponent("source-\($0).png") }
        let writer = MetadataOnlyBatchWriter()
        let files = SharedFileOperations(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) }, searchablePDFBatchWriter: writer)
        let result = try await files.searchablePDFBatch(.init(sourceURLs: sources, destinationDirectoryURL: deep))
        XCTAssertEqual(result.items.count, 50)
        let calls = await writer.calls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: deep.path).isEmpty)
    }
    func testRealBatchFacadeProducesTwoSearchablePDFs() async throws {
        let f = try await fixture()
        var sources: [URL] = []
        for index in 1...2 {
            let source = f.directory.deletingLastPathComponent().appendingPathComponent("real-\(index).pdf")
            var rect = CGRect(x: 0, y: 0, width: 400, height: 250)
            let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &rect, nil))
            context.beginPDFPage(nil); context.textPosition = CGPoint(x: 20, y: 160)
            let line = NSAttributedString(string: "BATCH DOCUMENT \(index)", attributes: [.init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)])
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
            context.endPDFPage(); context.closePDF(); sources.append(source)
        }
        let originals = try sources.map { try Data(contentsOf: $0) }
        let files = SharedFileOperations(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) })
        let result = try await files.searchablePDFBatch(.init(sourceURLs: sources, destinationDirectoryURL: f.directory))
        XCTAssertEqual(result.items.count, 2)
        for (index, item) in result.items.enumerated() {
            XCTAssertEqual(item.state, .succeeded)
            let output = try XCTUnwrap(item.receipt?.destinationURL)
            let pdf = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertTrue(pdf.string?.contains("BATCH DOCUMENT \(index + 1)") == true)
            XCTAssertEqual(try Data(contentsOf: sources[index]), originals[index])
        }
    }
}

private actor MetadataOnlyBatchWriter: SearchablePDFBatchWriting {
    private(set) var calls = 0
    func exportBatch(_ request: SearchablePDFBatchRequest, progress: (@Sendable (SearchablePDFBatchProgress) -> Void)?,
                     authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)?) async throws -> SearchablePDFBatchResult {
        calls += 1
        // Exercise the callback too; this fixture never writes PDF bytes or claims publication.
        try await authorize?(request.destinationDirectoryURL.appendingPathComponent("metadata-only.pdf"), .destination)
        return .init(items: request.sourceURLs.map { .init(sourceURL: $0, state: .notStarted, reason: .unavailable) })
    }
}

private actor BatchFixtureWriter: SearchablePDFWriting {
    enum Mode { case normal, pauseSecond, pauseSecondIndeterminate }
    let mode: Mode
    private(set) var calls = 0, paused = false, secondReturned = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(mode: Mode) { self.mode = mode }
    func export(_ request: SearchablePDFRequest, progress: (@Sendable (OCRProgress) -> Void)?,
                authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)?) async throws -> SearchablePDFResult {
        calls += 1
        let second = request.sourceURL.lastPathComponent == "two.png"
        defer { if second { secondReturned = true } }
        try await authorize?(request.sourceURL, .source)
        try await authorize?(request.destinationURL, .destination)
        if FileManager.default.fileExists(atPath: request.destinationURL.path) { throw SearchablePDFFailure(.destinationExists) }
        if second && mode != .normal {
            paused = true
            await withCheckedContinuation { continuation = $0 }
            if mode == .pauseSecondIndeterminate { throw SearchablePDFFailure(.publicationIndeterminate) }
        }
        // This models the atomic gate after the final authorization callback, not reauthorization.
        try Task.checkCancellation()
        try Data("PRIVATE PDF CONTENT".utf8).write(to: request.destinationURL, options: .withoutOverwriting)
        return .init(destinationURL: request.destinationURL, pageCount: 1, recognizedPages: 1, textLayerPages: 0)
    }
    func resume() { continuation?.resume(); continuation = nil; paused = false }
}
