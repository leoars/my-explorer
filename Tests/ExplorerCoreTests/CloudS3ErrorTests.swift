// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class CloudS3ErrorTests: XCTestCase, @unchecked Sendable {
    private func response(_ xml: String, status: Int = 403) -> CloudResponse {
        CloudResponse(statusCode: status, body: Data(xml.utf8))
    }
    func testDocumentedCredentialCodesAreDistinctFromPermissionDenial() {
        for code in ["ExpiredToken", "InvalidToken", "TokenRefreshRequired", "InvalidAccessKeyId", "SignatureDoesNotMatch"] {
            for status in [400, 401, 403] {
                XCTAssertEqual(S3ErrorResponse.reason(for: response("<Error><Code>\(code)</Code><Message>fixture-sensitive</Message></Error>", status: status)), .authenticationRequired)
            }
        }
        XCTAssertEqual(S3ErrorResponse.reason(for: response("<Error><Code>AccessDenied</Code></Error>")), .permissionDenied)
        for status in [200, 302, 404, 412, 500] {
            XCTAssertNil(S3ErrorResponse.reason(for: response("<Error><Code>ExpiredToken</Code></Error>", status: status)))
        }
    }
    func testMalformedUnknownNestedAndOversizedCodesKeepHTTPFallback() {
        let bodies = ["", "<Other><Code>ExpiredToken</Code></Other>", "<Error><Code>Unknown</Code></Error>",
            "<Error><Code>ExpiredToken</Code><Code>AccessDenied</Code></Error>",
            "<Error><Message><Code>ExpiredToken</Code></Message></Error>",
            "<Error><Code>Expired<Other/>Token</Code></Error>",
            "<Error><Code><![CDATA[ExpiredToken]]></Code></Error>",
            "<Error><Code>ExpiredToken</Code>", "<Error><Code>ExpiredToken </Code></Error>",
            "<!DOCTYPE Error [<!ENTITY secret SYSTEM 'file:///fixture-never-read'>]><Error><Code>&secret;</Code></Error>",
            "<Error><Code>" + String(repeating: "A", count: 129) + "</Code></Error>",
            "<Error><Code>ExpiredToken</Code><Message>" + String(repeating: "A", count: 65_536) + "</Message></Error>",
            "<Error><Code>ExpiredToken</Code>" + String(repeating: "<A>", count: 8) + String(repeating: "</A>", count: 8) + "</Error>",
            "<Error><Code>ExpiredToken</Code>" + String(repeating: "<A/>", count: 128) + "</Error>"]
        for body in bodies { XCTAssertNil(S3ErrorResponse.reason(for: response(body))) }
        XCTAssertNil(S3ErrorResponse.reason(for: CloudResponse(statusCode: 403, body: Data([0xff, 0xfe]))))
    }
    func testErrorFileReaderIsBoundedAndRejectsLinks() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("error")
        let bytes = Data(repeating: 65, count: 65_536)
        try bytes.write(to: file)
        XCTAssertEqual(CloudDownloadErrorBody.read(file), bytes)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertTrue(CloudDownloadErrorBody.read(link).isEmpty)
        try (bytes + Data([65])).write(to: file)
        XCTAssertTrue(CloudDownloadErrorBody.read(file).isEmpty)
        XCTAssertTrue(CloudDownloadErrorBody.read(root).isEmpty)
    }
    func testNativeDownloadErrorsAreClassifiedWithoutPublishingOrLeakingDetails() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let client = try client()
        for (key, reason) in [("expired", CloudFailure.Reason.authenticationRequired), ("bad-signature", .authenticationRequired),
                              ("denied", .permissionDenied), ("oversized", .permissionDenied), ("unknown", .permissionDenied)] {
            do {
                _ = try await client.download(key: key, to: root.appendingPathComponent(key))
                XCTFail("Expected classified failure")
            } catch let failure as CloudFailure {
                XCTAssertEqual(failure.reason, reason)
                XCTAssertFalse(failure.detail.contains("fixture-sensitive"))
                XCTAssertFalse(failure.detail.contains("CanonicalRequest"))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    func testNativeMetadataUploadAndDeleteUseS3Mapping() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input")
        try Data("payload".utf8).write(to: source)
        let client = try client()
        do { _ = try await client.list(prefix: "expired"); XCTFail("Expected authentication error") }
        catch let error as CloudFailure { XCTAssertEqual(error.reason, .authenticationRequired); XCTAssertTrue(error.detail.isEmpty) }
        do { _ = try await client.upload(fileURL: source, key: "bad-signature"); XCTFail("Expected authentication error") }
        catch let error as CloudFailure { XCTAssertEqual(error.reason, .authenticationRequired); XCTAssertTrue(error.detail.isEmpty) }
        do { _ = try await client.delete(key: "denied", matchingVersion: "\"fixture\""); XCTFail("Expected permission error") }
        catch let error as CloudFailure { XCTAssertEqual(error.reason, .permissionDenied); XCTAssertTrue(error.detail.isEmpty) }
        XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
    }
    func testOtherProvidersAndBodylessHEADKeepExistingHTTPMapping() async throws {
        let error = response("<Error><Code>ExpiredToken</Code></Error>")
        let azure = try CloudStorageClient(connection: .init(name: "Fixture", provider: .azure, bucket: "container", account: "fixtureaccount"),
            credentials: .init(sasToken: "sv=2023-11-03&sig=fixture"), transport: ErrorResponseTransport(response: error))
        do { _ = try await azure.list(); XCTFail("Expected permission failure") }
        catch let failure as CloudFailure { XCTAssertEqual(failure.reason, .permissionDenied) }
        let s3 = try CloudStorageClient(connection: .init(name: "Fixture", provider: .s3, bucket: "fixture-bucket", region: "us-east-1"),
            credentials: .init(accessKeyID: "FIXTUREACCESS", secretAccessKey: "fixture-secret"),
            transport: ErrorResponseTransport(response: CloudResponse(statusCode: 403)))
        do { _ = try await s3.stat(key: "bodyless-head"); XCTFail("Expected permission failure") }
        catch let failure as CloudFailure { XCTAssertEqual(failure.reason, .permissionDenied) }
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.S3Error.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func client() throws -> CloudStorageClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [S3ErrorURLProtocol.self]
        return try CloudStorageClient(connection: .init(name: "Fixture", provider: .s3, bucket: "fixture-bucket", region: "us-east-1"),
            credentials: .init(accessKeyID: "FIXTUREACCESS", secretAccessKey: "fixture-secret"),
            transport: URLSessionCloudTransport(configuration: config))
    }
}

private struct ErrorResponseTransport: CloudTransport {
    let response: CloudResponse
    func send(_ request: URLRequest) async throws -> CloudResponse { response }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { response }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { response }
}

private final class S3ErrorURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let prefix = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prefix" }?.value
        let name = prefix ?? url.lastPathComponent
        let code = name == "expired" ? "ExpiredToken" : name == "bad-signature" ? "SignatureDoesNotMatch" : name == "unknown" ? "UnknownError" : "AccessDenied"
        let diagnostic = name == "oversized" ? String(repeating: "A", count: 65_537) : "fixture-sensitive"
        let body = Data("<Error><Code>\(code)</Code><Message>\(diagnostic)</Message><CanonicalRequest>fixture-sensitive</CanonicalRequest></Error>".utf8)
        let response = HTTPURLResponse(url: url, statusCode: name == "expired" ? 400 : 403, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
