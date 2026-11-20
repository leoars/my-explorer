// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import CoreText
import XCTest
@testable import ExplorerCore
@testable import ExplorerAutomation

final class AutomationOCRTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL, source: URL, stateURL: URL
        let service: AutomationService
        let reader: OCRFixtureReader
        let grant: AutomationGrant
        func call(_ method: String, _ args: [String: JSONValue] = [:]) async -> AutomationResponse {
            await service.handle(.init(method: method, arguments: .object(args), clientID: grant.id.uuidString, token: "FIXTURE-TOKEN"))
        }
        func start(_ url: URL? = nil) async -> AutomationResponse {
            await call("files.ocr", ["url": .string((url ?? source).absoluteString), "languages": .array([.string("en-US")])])
        }
    }
    private func fixture(operations: Set<String> = ["files.ocr"], paused: Bool = false, text: String = "SECRET OCR DOCUMENT TEXT") async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OCRAutomation.\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let source = allowed.appendingPathComponent("source.png")
        try Data("disposable fake image".utf8).write(to: source)
        let reader = OCRFixtureReader(paused: paused, text: text)
        let files = SharedFileOperations(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) }, ocrReader: reader)
        let stateURL = root.appendingPathComponent("state/state.json")
        let environment = AutomationEnvironment(connections: { [] }, revision: { "fixture" }, authenticate: { _ in }, authenticated: { _ in false }, apply: { _ in }, preferences: { .object([:]) }, updatePreferences: { $0 })
        let service = try AutomationService(files: files, environment: environment, stateURL: stateURL)
        let grant = AutomationGrant(name: "OCR fixture", token: "FIXTURE-TOKEN", expires: Date().addingTimeInterval(60), operations: operations, localRoots: [allowed.path], cloudScopes: [])
        try await service.setEnabled(true); try await service.grant(grant)
        addTeardownBlock {
            await reader.resume()
            await service.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        return .init(root: root, source: source, stateURL: stateURL, service: service, reader: reader, grant: grant)
    }
    private func jobID(_ response: AutomationResponse) throws -> String {
        XCTAssertTrue(response.ok, response.error ?? "request failed")
        return try XCTUnwrap(response.result?["id"]?.stringValue)
    }
    private func terminal(_ fixture: Fixture, id: String) async throws -> JSONValue {
        for _ in 0..<500 {
            let result = await fixture.call("ocr.status", ["jobID": .string(id)])
            XCTAssertTrue(result.ok, result.error ?? "status failed")
            if let value = result.result, let state = value["state"]?.stringValue, !["queued", "running"].contains(state) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AutomationError.busy
    }
    private func waitUntilReading(_ reader: OCRFixtureReader) async throws {
        for _ in 0..<500 {
            if await reader.calls > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AutomationError.busy
    }
    func testLegacyReadGrantCannotStartOCRorDiscoverLanguages() async throws {
        let f = try await fixture(operations: ["read"])
        let denied = await f.start()
        XCTAssertEqual(denied.error, "forbidden")
        let discovery = await f.call("ocr.languages")
        XCTAssertEqual(discovery.error, "forbidden")
        let calls = await f.reader.calls
        XCTAssertEqual(calls, 0)
    }
    func testOutsideSymlinkRecoveryAndRemoteAreRejectedBeforeReader() async throws {
        let f = try await fixture()
        let outside = f.root.appendingPathComponent("outside.png")
        try Data("OUTSIDE CONTENT".utf8).write(to: outside)
        let denied = await f.start(outside)
        XCTAssertEqual(denied.error, "forbidden")
        let link = f.source.deletingLastPathComponent().appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linkedID = try jobID(await f.start(link))
        let linked = try await terminal(f, id: linkedID)
        XCTAssertEqual(linked["state"], .string("failed"))
        XCTAssertEqual(linked["result"], .null)
        let recovery = f.source.deletingLastPathComponent().appendingPathComponent(".my-explorer-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try LocalTransferRecovery.mark(recovery)
        let protected = recovery.appendingPathComponent("private.png")
        try Data("PRIVATE RECOVERY".utf8).write(to: protected)
        let id = try jobID(await f.start(protected))
        let failed = try await terminal(f, id: id)
        XCTAssertEqual(failed["state"], .string("failed"))
        XCTAssertEqual(failed["result"], .null)
        let remote = await f.start(RemoteLocation.url(connectionID: UUID(), key: "image.png"))
        XCTAssertEqual(remote.error, "unsupported")
        let calls = await f.reader.calls
        XCTAssertEqual(calls, 0)
    }
    func testAncestorSymlinkCannotEscapeGrantedRoot() async throws {
        let f = try await fixture()
        let outside = f.root.appendingPathComponent("outside-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("OUTSIDE SECRET".utf8).write(to: outside.appendingPathComponent("image.png"))
        let link = f.source.deletingLastPathComponent().appendingPathComponent("linked-directory", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let id = try jobID(await f.start(link.appendingPathComponent("image.png")))
        let result = try await terminal(f, id: id)
        XCTAssertEqual(result["state"], .string("failed"))
        XCTAssertEqual(result["result"], .null)
        let calls = await f.reader.calls
        XCTAssertEqual(calls, 0)
    }
    func testScopeReductionDuringRecognitionDeniesDeliveryWithoutCancellation() async throws {
        let f = try await fixture(paused: true)
        let id = try jobID(await f.start())
        try await waitUntilReading(f.reader)
        var narrowed = f.grant
        narrowed.localRoots = [f.root.appendingPathComponent("elsewhere").path]
        try await f.service.grant(narrowed)
        await f.reader.resume()
        // Drain the job after the reader returns while the narrower grant is in force.
        for _ in 0..<500 {
            let metadata = await f.call("transfers.status", ["jobID": .string(id)])
            if metadata.result?["state"] == .string("failed") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let forbidden = await f.call("ocr.status", ["jobID": .string(id)])
        XCTAssertEqual(forbidden.error, "forbidden")
        try await f.service.grant(f.grant)
        let result = try await terminal(f, id: id)
        XCTAssertEqual(result["state"], .string("failed"))
        XCTAssertEqual(result["error"], .string("forbidden"))
        XCTAssertEqual(result["result"], .null)
    }
    func testAuthorizedResultIsEphemeralScopedAndWireBounded() async throws {
        let f = try await fixture()
        let id = try jobID(await f.start())
        let result = try await terminal(f, id: id)
        XCTAssertEqual(result["state"], .string("succeeded"))
        XCTAssertEqual(result["resultAvailable"], .bool(true))
        XCTAssertEqual(result["result"]?["pages"]?.arrayValue?.first?["text"], .string("SECRET OCR DOCUMENT TEXT"))
        XCTAssertEqual(result["untrustedDocumentContent"], .bool(true))
        XCTAssertNil(result["result"]?["fullText"])
        XCTAssertLessThan(try AutomationWire.encode(result).count, AutomationWire.maximumMessageBytes)
        XCTAssertFalse(String(decoding: try Data(contentsOf: f.stateURL), as: UTF8.self).contains("SECRET OCR DOCUMENT TEXT"))
        let languages = await f.call("ocr.languages")
        XCTAssertEqual(languages.result?["languages"], .array([.string("en-US"), .string("pt-BR")]))
        var changed = f.grant; changed.operations = ["read"]
        try await f.service.grant(changed)
        let denied = await f.call("ocr.status", ["jobID": .string(id)])
        XCTAssertEqual(denied.error, "forbidden")
        try await f.service.grant(f.grant)
        let restored = await f.call("ocr.status", ["jobID": .string(id)])
        XCTAssertEqual(restored.result?["result"], .null)
    }
    func testRevocationDuringRecognitionNeverReturnsText() async throws {
        let f = try await fixture(paused: true)
        let id = try jobID(await f.start())
        try await waitUntilReading(f.reader)
        try await f.service.revoke(f.grant.id)
        await f.reader.resume()
        let denied = await f.call("ocr.status", ["jobID": .string(id)])
        XCTAssertEqual(denied.error, "unauthenticated")
        await f.service.shutdown()
        XCTAssertFalse(String(decoding: try Data(contentsOf: f.stateURL), as: UTF8.self).contains("SECRET OCR DOCUMENT TEXT"))
    }
    func testCancellationDiscardsLateRecognitionResult() async throws {
        let f = try await fixture(paused: true)
        let id = try jobID(await f.start())
        try await waitUntilReading(f.reader)
        let cancelled = await f.call("ocr.cancel", ["jobID": .string(id)])
        XCTAssertEqual(cancelled.result?["state"], .string("cancelled"))
        await f.reader.resume()
        let result = try await terminal(f, id: id)
        XCTAssertEqual(result["result"], .null)
        XCTAssertEqual(result["state"], .string("cancelled"))
    }
    func testEncodedResultExceedingMCPBudgetFailsWithoutTruncation() async throws {
        let f = try await fixture(text: String(repeating: "\u{0001}", count: 128 * 1024))
        let id = try jobID(await f.start())
        let result = try await terminal(f, id: id)
        XCTAssertEqual(result["state"], .string("failed"))
        XCTAssertEqual(result["error"], .string("limitExceeded"))
        XCTAssertEqual(result["result"], .null)
    }
    func testCommandAndToolSchemasExposeBoundedOCRJobs() throws {
        XCTAssertEqual(AutomationOCRLocation.scopePath("/tmp/a"), "/private/tmp/a")
        XCTAssertEqual(AutomationOCRLocation.scopePath("/private/tmp/a"), "/private/tmp/a")
        XCTAssertEqual(AutomationOCRLocation.scopePath("/tmpfoo/a"), "/tmpfoo/a")
        XCTAssertThrowsError(try AutomationOCRLocation.parse("file:///tmp/a%00.png"))
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let command = try OCRCommand.request(arguments: ["ocr", "file 日本.png", "--language", "pt-BR", "--language", "en-US"], workingDirectory: base)
        XCTAssertEqual(command.method, "files.ocr")
        XCTAssertEqual(command.arguments["languages"], .array([.string("pt-BR"), .string("en-US")]))
        XCTAssertEqual(try OCRCommand.request(arguments: ["ocr", "languages"], workingDirectory: base).method, "ocr.languages")
        XCTAssertThrowsError(try OCRCommand.request(arguments: ["ocr", "status"], workingDirectory: base))
        XCTAssertThrowsError(try OCRCommand.request(arguments: ["ocr", "s3://bucket/key"], workingDirectory: base))
        XCTAssertThrowsError(try OCRCommand.request(arguments: ["ocr", "x.png", "--language"], workingDirectory: base))
        let pages = try OCRCommand.request(arguments: ["ocr", "document.pdf", "--pages", "500:510"], workingDirectory: base)
        XCTAssertEqual(pages.arguments["pageStart"], .number(500))
        XCTAssertEqual(pages.arguments["pageEnd"], .number(510))
        for invalid in ["0:1", "2:1", "1:101", "1-3", "1:1000001"] {
            XCTAssertThrowsError(try OCRCommand.request(arguments: ["ocr", "document.pdf", "--pages", invalid], workingDirectory: base))
        }
        XCTAssertEqual(AutomationToolCatalog.method(forTool: "files_ocr"), "files.ocr")
        XCTAssertFalse(AutomationToolCatalog.validate(method: "files.ocr", arguments: .object(["url": .string("/tmp/a"), "languages": .array(Array(repeating: .string("en-US"), count: 9))])))
        XCTAssertFalse(AutomationToolCatalog.validate(method: "files.ocr", arguments: .object(["url": .string("/tmp/a"), "pageEnd": .number(1_000_001)])))
        XCTAssertFalse(AutomationToolCatalog.validate(method: "files.ocr", arguments: .object(["url": .string("/tmp/a"), "output": .string("/tmp/out.txt")])))
    }
    func testRealPDFThroughSharedFacadeExtractsTextWithoutCloudAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OCRRealFacade.\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("text.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 500, height: 300)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 30, y: 200)
        let text = NSAttributedString(string: "AUTOMATION OCR FIXTURE", attributes: [.init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 20, nil)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
        let files = SharedFileOperations(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) })
        let result = try await files.ocr(.init(url: pdf), authorizeURL: { url in
            guard url.isFileURL, url.lastPathComponent == "text.pdf" else { throw AutomationError.forbidden }
        })
        XCTAssertTrue(result.fullText.contains("AUTOMATION OCR FIXTURE"))
        XCTAssertEqual(result.pages.first?.source, .embeddedText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
    }
}

private actor OCRFixtureReader: OCRReading {
    private var paused: Bool
    private let text: String
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(paused: Bool, text: String) { self.paused = paused; self.text = text }
    func supportedLanguages() async throws -> [String] { ["en-US", "pt-BR"] }
    func recognize(_ request: OCRRequest, progress: (@Sendable (OCRProgress) -> Void)?, authorizeURL: (@Sendable (URL) async throws -> Void)?) async throws -> OCRResult {
        calls += 1
        progress?(.init(stage: .recognizing, completedPages: 0, totalPages: 1))
        if paused { await withCheckedContinuation { continuation = $0 } }
        // Deliberately ignores cancellation and authorization: the shared facade must still gate delivery.
        return .init(pages: [.init(pageNumber: 1, text: text, source: .recognized)])
    }
    func resume() { paused = false; continuation?.resume(); continuation = nil }
}
