// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import XCTest
@testable import ExplorerCore

final class S3UploadCancellationValidationTests: XCTestCase, @unchecked Sendable {
    private func runner(_ transport: CancellationUploadTransport, timeout: Duration = .seconds(15)) throws -> S3ValidationRunner {
        let client = try CloudStorageClient(connection: .init(name: "SENSITIVE NAME", provider: .s3,
                                                               bucket: "private-fixture-bucket", region: "us-east-1"),
                                            credentials: .init(accessKeyID: "FIXTUREACCESS", secretAccessKey: "PRIVATESECRET"),
                                            transport: transport)
        return S3ValidationRunner(client: client, operationTimeout: timeout)
    }
    func testPartialNativeProgressCancelsWithoutDeletingUnconfirmedWrite() async throws {
        let transport = CancellationUploadTransport(mode: .cancelled)
        let runner = try runner(transport)
        let report = await runner.runUploadCancellation()
        XCTAssertEqual(report.prefix, runner.prefix)
        XCTAssertEqual(report.key, runner.prefix + "upload-cancellation.bin")
        XCTAssertTrue(report.cancellationRequested)
        XCTAssertTrue(report.cancellationObserved)
        XCTAssertEqual(report.cancellationRequestedAtBytes, 65_536)
        XCTAssertEqual(report.remoteOutcome, .indeterminate)
        XCTAssertEqual(report.residualKeys, [report.key])
        XCTAssertTrue(report.failed)
        XCTAssertEqual(report.expectedByteCount, 16 * 1024 * 1024)
        let observedHash = await transport.observedSHA256
        XCTAssertEqual(report.expectedSHA256, observedHash)
        let records = await transport.methods
        XCTAssertEqual(records, ["PUT"])
        let serialized = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for value in ["PRIVATESECRET", "FIXTUREACCESS", "SENSITIVE NAME", "private-fixture-bucket", "https://"] {
            XCTAssertFalse(serialized.contains(value))
        }
    }
    func testConfirmedReceiptAfterCancellationAllowsOnlyConditionalCleanup() async throws {
        let transport = CancellationUploadTransport(mode: .confirmed)
        let report = await (try runner(transport)).runUploadCancellation()
        XCTAssertTrue(report.cancellationRequested)
        XCTAssertFalse(report.cancellationObserved)
        XCTAssertEqual(report.remoteOutcome, .confirmed)
        XCTAssertFalse(report.failed)
        XCTAssertEqual(report.cleanup.first?.status, .acknowledged)
        XCTAssertTrue(report.residualKeys.isEmpty)
        let conditions = await transport.deleteConditions
        XCTAssertEqual(conditions, ["\"original-receipt\""])
    }
    func testChangedObjectAfterReceiptIsPreserved() async throws {
        let transport = CancellationUploadTransport(mode: .changed)
        let report = await (try runner(transport)).runUploadCancellation()
        XCTAssertEqual(report.remoteOutcome, .confirmed)
        XCTAssertEqual(report.cleanup.first?.status, .preserved)
        XCTAssertEqual(report.residualKeys, [report.key])
        let conditions = await transport.deleteConditions
        XCTAssertEqual(conditions, ["\"original-receipt\""])
    }
    func testOnlySyntheticFinalProgressDoesNotClaimInFlightCancellation() async throws {
        let transport = CancellationUploadTransport(mode: .noPartialProgress)
        let report = await (try runner(transport)).runUploadCancellation()
        XCTAssertFalse(report.cancellationRequested)
        XCTAssertEqual(report.cancellationRequestedAtBytes, 0)
        XCTAssertFalse(report.cancellationObserved)
        XCTAssertEqual(report.reason, .unexpectedOutcome)
        XCTAssertEqual(report.remoteOutcome, .confirmed)
        XCTAssertTrue(report.failed)
        XCTAssertTrue(report.residualKeys.isEmpty)
    }
    func testLateReceiptAfterDeadlineDoesNotTriggerUnreportedCleanup() async throws {
        let transport = CancellationUploadTransport(mode: .slow)
        let report = await (try runner(transport, timeout: .milliseconds(100))).runUploadCancellation()
        XCTAssertEqual(report.reason, .timedOut)
        XCTAssertEqual(report.remoteOutcome, .indeterminate)
        XCTAssertEqual(report.residualKeys, [report.key])
        try await Task.sleep(for: .milliseconds(400))
        let records = await transport.methods
        XCTAssertFalse(records.contains("DELETE"))
    }
    func testCollisionNeverDeletesAnExistingFixtureKey() async throws {
        let transport = CancellationUploadTransport(mode: .collision)
        let report = await (try runner(transport)).runUploadCancellation()
        XCTAssertEqual(report.remoteOutcome, .rejected)
        XCTAssertEqual(report.reason, .conflict)
        XCTAssertTrue(report.cleanup.isEmpty)
        XCTAssertTrue(report.residualKeys.isEmpty)
        let records = await transport.methods
        XCTAssertEqual(records, ["PUT"])
    }
}

private actor CancellationUploadTransport: CloudTransport {
    enum Mode { case cancelled, confirmed, changed, noPartialProgress, slow, collision }
    let mode: Mode
    var methods: [String] = []
    var deleteConditions: [String] = []
    var observedSHA256: String?
    init(mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> CloudResponse {
        methods.append(request.httpMethod ?? "")
        guard request.httpMethod == "DELETE" else { throw CloudFailure(.io) }
        deleteConditions.append(request.value(forHTTPHeaderField: "If-Match") ?? "")
        return .init(statusCode: mode == .changed ? 412 : 204)
    }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        methods.append("PUT")
        guard request.value(forHTTPHeaderField: "If-None-Match") == "*" else { throw CloudFailure(.invalidConfiguration) }
        if mode == .collision { return .init(statusCode: 412) }
        let data = try Data(contentsOf: fileURL)
        observedSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if mode != .noPartialProgress {
            progress?(.init(completedBytes: 65_536, totalBytes: Int64(data.count)))
        }
        if mode == .cancelled { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation() }
        if mode == .slow {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume() }
            }
        }
        // The confirmed modes deliberately return an authoritative response despite concurrent cancellation.
        return .init(statusCode: 200, headers: ["ETag": "\"original-receipt\"",
                                               "x-amz-checksum-sha256": Data(SHA256.hash(data: data)).base64EncodedString()])
    }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        throw CloudFailure(.io)
    }
}
