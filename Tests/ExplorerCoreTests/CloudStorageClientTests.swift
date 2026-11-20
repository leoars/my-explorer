// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class CloudStorageClientTests: XCTestCase, @unchecked Sendable {
    private func client(_ transport: any CloudTransport) throws -> CloudStorageClient {
        try CloudStorageClient(connection: CloudConnection(name: "Fixture", provider: .gcs, bucket: "fixture-bucket"),
                               credentials: CloudCredentials(accessToken: "fixture-token"), transport: transport)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.CloudTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func assertFailure<T: Sendable>(_ reason: CloudFailure.Reason, file: StaticString = #filePath, line: UInt = #line,
                                            _ operation: @Sendable () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected \(reason)", file: file, line: line) }
        catch let failure as CloudFailure { XCTAssertEqual(failure.reason, reason, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
    private func assertClean(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".my-explorer-cloud-") }, file: file, line: line)
    }

    func testStatusMappingAndNullableStatNeverHidePermissionFailures() async throws {
        let cases: [(Int, CloudFailure.Reason)] = [(401, .authenticationRequired), (403, .permissionDenied),
            (409, .conflict), (412, .preconditionFailed), (429, .rateLimited), (503, .serviceUnavailable), (302, .insecureTransport)]
        for (status, reason) in cases {
            let transport = RecordingCloudTransport(responses: [CloudResponse(statusCode: status)])
            let client = try client(transport)
            await assertFailure(reason) { try await client.stat(key: "file.txt") }
        }
        let missing = try client(RecordingCloudTransport(responses: [CloudResponse(statusCode: 404)]))
        let result = try await missing.stat(key: "missing")
        XCTAssertNil(result)
    }

    func testPaginationCarriesOpaqueTokenWithoutLooping() async throws {
        let first = Data(#"{"kind":"storage#objects","items":[{"name":"folder/one","size":"1","generation":"17"}],"nextPageToken":"opaque+/=日本"}"#.utf8)
        let last = Data(#"{"kind":"storage#objects","items":[{"name":"folder/two","size":"2","generation":"18"}]}"#.utf8)
        let transport = RecordingCloudTransport(responses: [CloudResponse(statusCode: 200, body: first), CloudResponse(statusCode: 200, body: last)])
        let client = try client(transport)
        let page1 = try await client.list(prefix: "folder/")
        let page2 = try await client.list(prefix: "folder/", continuationToken: page1.nextToken)
        XCTAssertEqual(page1.objects.map(\.key), ["folder/one"])
        XCTAssertEqual(page2.objects.map(\.key), ["folder/two"])
        XCTAssertNil(page2.nextToken)
        let requests = await transport.requests
        let query = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "pageToken" }?.value, "opaque+/=日本")
        let loop = try self.client(RecordingCloudTransport(responses: [CloudResponse(statusCode: 200, body: first)]))
        await assertFailure(.malformedResponse) { try await loop.list(prefix: "folder/", continuationToken: "opaque+/=日本") }
    }

    func testUploadUsesFileBackedTransportAndExplicitNoClobberOrVersionCondition() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("payload".utf8).write(to: source)
        let response = CloudResponse(statusCode: 200, body: Data(#"{"name":"a #+日本.txt","size":"7","generation":"19"}"#.utf8))
        let transport = RecordingCloudTransport(responses: [response, response])
        let client = try client(transport)
        let progress = ProgressRecorder()
        _ = try await client.upload(fileURL: source, key: "a #+日本.txt", progress: { progress.append($0) })
        _ = try await client.upload(fileURL: source, key: "a #+日本.txt", condition: .matches("18"))
        let requests = await transport.requests, files = await transport.uploads
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0 != source && !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil && $0.httpBodyStream == nil })
        let conditions = requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ifGenerationMatch" }?.value }
        XCTAssertEqual(conditions, ["0", "18"])
        XCTAssertEqual(progress.values.first?.completedBytes, 0)
        XCTAssertEqual(progress.values.last?.completedBytes, 7)
        XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
    }

    func testDownloadsPublishOnlyCompleteResponsesAndNeverOverwrite() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        let transport = RecordingCloudTransport(responses: [CloudResponse(statusCode: 200, headers: ["content-length": "7"])], downloadBody: Data("payload".utf8))
        let client = try client(transport)
        _ = try await client.download(key: "object", to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
        await assertFailure(.localConflict) { try await client.download(key: "object", to: destination) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        try assertClean(root)
        let partial = try self.client(RecordingCloudTransport(responses: [CloudResponse(statusCode: 200, headers: ["Content-Length": "20"])], downloadBody: Data("short".utf8)))
        let missing = root.appendingPathComponent("incomplete")
        await assertFailure(.malformedResponse) { try await partial.download(key: "object", to: missing) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try assertClean(root)
    }

    func testLateLocalConflictAndServerFailureCleanPrivateStaging() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        let conflict = RecordingCloudTransport(responses: [CloudResponse(statusCode: 200)], downloadBody: Data("remote".utf8), lateConflict: destination)
        let client = try client(conflict)
        await assertFailure(.localConflict) { try await client.download(key: "object", to: destination) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing")
        let forbidden = try self.client(RecordingCloudTransport(responses: [CloudResponse(statusCode: 403)], downloadBody: Data("error body".utf8)))
        await assertFailure(.permissionDenied) { try await forbidden.download(key: "object", to: root.appendingPathComponent("forbidden")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
        try assertClean(root)
    }

    func testCancellationAfterPartialDownloadLeavesNoDestination() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("cancelled")
        let transport = RecordingCloudTransport(responses: [], downloadBody: Data("partial".utf8), suspendDownload: true)
        let client = try client(transport)
        let task = Task { try await client.download(key: "object", to: destination) }
        for _ in 0..<200 {
            if await transport.startedDownload { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await transport.startedDownload
        XCTAssertTrue(started)
        task.cancel()
        await assertFailure(.cancelled) { try await task.value }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertClean(root)
    }

    func testConnectionEncodingExcludesCredentialsAndRedirectPolicyRejectsLeaks() throws {
        let connection = CloudConnection(name: "Remote", provider: .azure, bucket: "container", account: "account123")
        let data = try JSONEncoder().encode(connection)
        XCTAssertEqual(try JSONDecoder().decode(CloudConnection.self, from: data), connection)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("sasToken")); XCTAssertFalse(json.contains("accessToken")); XCTAssertFalse(json.contains("secretAccessKey"))
        let original = URL(string: "https://storage.googleapis.com/a?token=secret")!
        XCTAssertTrue(CloudRedirectPolicy.allows(from: original, to: URL(string: "https://storage.googleapis.com/b")))
        for destination in ["http://storage.googleapis.com/b", "https://evil.example/b", "https://storage.googleapis.com.evil.example/b", "https://storage.googleapis.com:8443/b", "https://user:password@storage.googleapis.com/b"] {
            XCTAssertFalse(CloudRedirectPolicy.allows(from: original, to: URL(string: destination)))
        }
    }

    func testNativeTransportRejectsHTTPBeforeConnecting() async {
        await assertFailure(.insecureTransport) { try await URLSessionCloudTransport().send(URLRequest(url: URL(string: "http://localhost:1/never")!)) }
    }

    func testUploadCancellationPropagatesWithoutChangingLocalSource() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("original".utf8).write(to: source)
        let transport = RecordingCloudTransport(responses: [], suspendUpload: true)
        let client = try client(transport)
        let task = Task { try await client.upload(fileURL: source, key: "object") }
        for _ in 0..<200 {
            if await !transport.uploads.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let uploads = await transport.uploads
        XCTAssertEqual(uploads.count, 1)
        XCTAssertNotEqual(uploads.first, source)
        task.cancel()
        await assertFailure(.cancelled) { try await task.value }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        try assertClean(root)
    }

    func testPartialOrEncodedBodiesCannotBePublishedAsOriginalObjects() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for response in [CloudResponse(statusCode: 206), CloudResponse(statusCode: 200, headers: ["Content-Encoding": "gzip"])] {
            let client = try client(RecordingCloudTransport(responses: [response], downloadBody: Data("modified bytes".utf8)))
            let destination = root.appendingPathComponent("unsafe")
            await assertFailure(.malformedResponse) { try await client.download(key: "object", to: destination) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            try assertClean(root)
        }
    }
}

private actor RecordingCloudTransport: CloudTransport {
    private var responses: [CloudResponse]
    private let downloadBody: Data
    private let lateConflict: URL?
    private let suspendDownload: Bool
    private let suspendUpload: Bool
    private(set) var requests: [URLRequest] = []
    private(set) var uploads: [URL] = []
    private(set) var startedDownload = false
    init(responses: [CloudResponse], downloadBody: Data = Data(), lateConflict: URL? = nil,
         suspendDownload: Bool = false, suspendUpload: Bool = false) {
        self.responses = responses; self.downloadBody = downloadBody; self.lateConflict = lateConflict; self.suspendDownload = suspendDownload
        self.suspendUpload = suspendUpload
    }
    private func next() throws -> CloudResponse {
        guard !responses.isEmpty else { throw CloudFailure(.io, detail: "Fixture exhausted") }
        return responses.removeFirst()
    }
    func send(_ request: URLRequest) async throws -> CloudResponse { requests.append(request); return try next() }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        requests.append(request); uploads.append(fileURL)
        progress?(CloudTransferProgress(completedBytes: 3, totalBytes: 7))
        if suspendUpload { try await Task.sleep(for: .seconds(30)) }
        return try next()
    }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        requests.append(request)
        try downloadBody.write(to: fileURL)
        startedDownload = true
        if let lateConflict { try Data("existing".utf8).write(to: lateConflict) }
        if suspendDownload { try await Task.sleep(for: .seconds(30)) }
        return try next()
    }
}
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CloudTransferProgress] = []
    func append(_ value: CloudTransferProgress) { lock.withLock { stored.append(value) } }
    var values: [CloudTransferProgress] { lock.withLock { stored } }
}
