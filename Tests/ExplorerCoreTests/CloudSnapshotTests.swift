// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import ExplorerCore

final class CloudSnapshotTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.CloudSnapshotTests.\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func client(_ transport: any CloudTransport) throws -> CloudStorageClient {
        try CloudStorageClient(connection: CloudConnection(name: "Fixture", provider: .s3, bucket: "fixture-bucket"),
                               credentials: CloudCredentials(accessKeyID: "FIXTURE", secretAccessKey: "fixture-secret"), transport: transport)
    }
    private func failure<T: Sendable>(_ reason: CloudFailure.Reason, _ body: () async throws -> T) async {
        do { _ = try await body(); XCTFail("Expected \(reason)") }
        catch let error as CloudFailure { XCTAssertEqual(error.reason, reason) }
        catch { XCTFail("Unexpected \(error)") }
    }
    func testStreamingSnapshotPreservesBytesAndPrivatePermissions() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ação 日本語.bin")
        let bytes = Data((0..<(3 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let snapshot = try CloudUploadSnapshot.make(source: source, maximumBytes: Int64(bytes.count))
        defer { snapshot.remove() }
        XCTAssertEqual(try Data(contentsOf: snapshot.payload), bytes)
        XCTAssertEqual(snapshot.integrity.size, Int64(bytes.count))
        XCTAssertEqual(snapshot.integrity.sha256Base64, Data(SHA256.hash(data: bytes)).base64EncodedString())
        var directoryInfo = Darwin.stat(), fileInfo = Darwin.stat()
        XCTAssertEqual(lstat(snapshot.directory.path, &directoryInfo), 0)
        XCTAssertEqual(lstat(snapshot.payload.path, &fileInfo), 0)
        XCTAssertEqual(directoryInfo.st_mode & 0o777, 0o700)
        XCTAssertEqual(fileInfo.st_mode & 0o777, 0o600)
        try Data("changed afterward".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: snapshot.payload), bytes)
    }
    func testSnapshotRejectsSymlinkDirectoriesOversizeAndConcurrentEdits() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), link = root.appendingPathComponent("link")
        let bytes = Data(repeating: 7, count: 2 * 1024 * 1024)
        try bytes.write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try CloudUploadSnapshot.make(source: link, maximumBytes: 10_000_000))
        XCTAssertThrowsError(try CloudUploadSnapshot.make(source: root, maximumBytes: 10_000_000))
        XCTAssertThrowsError(try CloudUploadSnapshot.make(source: source, maximumBytes: 1))
        for unsafe in [URL(string: source.absoluteString + "%00suffix")!, URL(string: "file://remote.example" + source.path)!] {
            XCTAssertThrowsError(try CloudUploadSnapshot.make(source: unsafe, maximumBytes: 10_000_000))
        }
        for mutation in 0..<2 {
            try bytes.write(to: source)
            XCTAssertThrowsError(try CloudUploadSnapshot.make(source: source, maximumBytes: 10_000_000, stagingParent: root, afterChunk: { count in
                if count == 1024 * 1024 {
                    if mutation == 0 {
                        let handle = try FileHandle(forWritingTo: source); defer { try? handle.close() }
                        try handle.seek(toOffset: 0); try handle.write(contentsOf: Data([9]))
                    } else {
                        try FileManager.default.removeItem(at: source)
                        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: link)
                    }
                }
            })) { error in XCTAssertEqual((error as? CloudFailure)?.reason, .localConflict) }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".my-explorer-upload-") })
            if mutation == 1 { try FileManager.default.removeItem(at: source) }
        }
    }
    func testSnapshotCancellationCleansPrivateCopy() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data(repeating: 4, count: 2 * 1024 * 1024).write(to: source)
        let task = Task.detached {
            try CloudUploadSnapshot.make(source: source, maximumBytes: 10_000_000, stagingParent: root, afterChunk: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await failure(.cancelled) { try await task.value }
        XCTAssertEqual(try Data(contentsOf: source).count, 2 * 1024 * 1024)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
    }
    func testUploadSendsSnapshotAndSignedChecksumEvenIfSourceIsReplaced() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original")
        let bytes = Data("immutable bytes".utf8)
        try bytes.write(to: source)
        let transport = SnapshotFixtureTransport(body: bytes, original: source)
        _ = try await client(transport).upload(fileURL: source, key: "é + %/東京.bin")
        let recorded = await transport.recorded
        let request = try XCTUnwrap(recorded?.0), payload = try XCTUnwrap(recorded?.1)
        XCTAssertNotEqual(payload, source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        let hash = Data(SHA256.hash(data: bytes))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-checksum-sha256"), hash.base64EncodedString())
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), hash.map { String(format: "%02x", $0) }.joined())
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-checksum-sha256") == true)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "replacement")
    }
    func testDownloadPinsVersionChecksChecksumAndDoesNotPublishFailures() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("complete payload".utf8), hash = Data(SHA256.hash(data: Data("complete payload".utf8))).base64EncodedString()
        for (index, response) in [
            CloudResponse(statusCode: 412),
            CloudResponse(statusCode: 200, headers: ["ETag": "\"different\""]),
            CloudResponse(statusCode: 200, headers: ["ETag": "\"expected\"", "x-amz-checksum-sha256": Data(repeating: 0, count: 32).base64EncodedString()]),
            CloudResponse(statusCode: 200, headers: ["ETag": "\"expected\"", "x-amz-checksum-sha256": hash, "Content-Length": "999"])
        ].enumerated() {
            let destination = root.appendingPathComponent("failed-\(index)")
            let transport = SnapshotFixtureTransport(body: bytes, response: response)
            await failure(index < 2 ? .preconditionFailed : .malformedResponse) {
                try await client(transport).download(key: "object", to: destination, matchingVersion: "\"expected\"")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let request = await transport.recorded?.0
            XCTAssertEqual(request?.value(forHTTPHeaderField: "If-Match"), "\"expected\"")
            XCTAssertTrue(request?.value(forHTTPHeaderField: "Authorization")?.contains("if-match") == true)
        }
        for composite in [false, true] {
            let destination = root.appendingPathComponent(composite ? "composite" : "verified")
            let response = CloudResponse(statusCode: 200, headers: ["ETag": "\"expected\"", "Content-Length": String(bytes.count),
                "x-amz-checksum-sha256": composite ? hash + "-2" : hash, "x-amz-checksum-type": composite ? "COMPOSITE" : "FULL_OBJECT"])
            _ = try await client(SnapshotFixtureTransport(body: bytes, response: response)).download(key: "object", to: destination, matchingVersion: "\"expected\"")
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".my-explorer-cloud-") })
    }
    func testDownloadRejectsMalformedLocalURLsBeforeTransport() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        let transport = SnapshotFixtureTransport(body: Data())
        for unsafe in [URL(string: destination.absoluteString + "%00suffix")!, URL(string: "file://remote.example" + destination.path)!] {
            await failure(.io) { try await client(transport).download(key: "object", to: unsafe) }
        }
        let recorded = await transport.recorded
        XCTAssertNil(recorded)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testWhitespaceWildcardAndETagListsCannotWeakenPreconditions() throws {
        let backend = try S3CloudBackend(connection: CloudConnection(name: "Fixture", provider: .s3, bucket: "fixture-bucket"), credentials: CloudCredentials(accessKeyID: "FIXTURE", secretAccessKey: "fixture"))
        for value in ["*", " * ", "\"one\",\"two\"", "\"one\" ", "\"one\"\n"] {
            XCTAssertThrowsError(try backend.uploadRequest(key: "object", condition: .matches(value)))
            XCTAssertThrowsError(try backend.downloadRequest(key: "object", matchingVersion: value))
            XCTAssertThrowsError(try backend.deleteRequest(key: "object", matchingVersion: value))
        }
    }
}

private actor SnapshotFixtureTransport: CloudTransport {
    let body: Data
    let original: URL?
    let response: CloudResponse
    var recorded: (URLRequest, URL)?
    init(body: Data, original: URL? = nil, response: CloudResponse = CloudResponse(statusCode: 200, headers: ["ETag": "\"version\""])) {
        self.body = body; self.original = original; self.response = response
    }
    func send(_ request: URLRequest) async throws -> CloudResponse { throw CloudFailure(.io) }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        recorded = (request, fileURL)
        if let original { try Data("replacement".utf8).write(to: original) }
        XCTAssertEqual(try Data(contentsOf: fileURL), body)
        return response
    }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        recorded = (request, fileURL); try body.write(to: fileURL)
        return response
    }
}
