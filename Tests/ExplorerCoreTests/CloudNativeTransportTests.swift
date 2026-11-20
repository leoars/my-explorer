// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class CloudNativeTransportTests: XCTestCase, @unchecked Sendable {
    private func transport() -> URLSessionCloudTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudFixtureURLProtocol.self]
        return URLSessionCloudTransport(configuration: configuration)
    }

    func testMetadataAndFileBackedTransferDelegateLifecycleWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.NativeCloud.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = transport()
        let request = URLRequest(url: URL(string: "https://fixture.invalid/payload")!)
        let metadata = try await transport.send(request)
        XCTAssertEqual(metadata.statusCode, 200)
        XCTAssertEqual(metadata.body, Data("payload".utf8))
        let destination = root.appendingPathComponent("download")
        let download = try await transport.download(request, to: destination)
        XCTAssertEqual(download.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
        var uploadRequest = request
        uploadRequest.httpMethod = "PUT"
        let uploaded = try await transport.upload(uploadRequest, fileURL: destination)
        XCTAssertEqual(uploaded.statusCode, 200)
        XCTAssertEqual(uploaded.body, Data("payload".utf8))
    }

    func testNativeMetadataLimitRejectsOversizedResponse() async {
        do {
            _ = try await transport().send(URLRequest(url: URL(string: "https://fixture.invalid/oversized")!))
            XCTFail("Expected bounded metadata failure")
        } catch let error as CloudFailure { XCTAssertEqual(error.reason, .malformedResponse) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testNativeCancellationFinishesContinuationWithoutNetwork() async throws {
        let task = Task { try await transport().send(URLRequest(url: URL(string: "https://fixture.invalid/suspended")!)) }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch let error as CloudFailure { XCTAssertEqual(error.reason, .cancelled) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testNativeRedirectDelegateStopsCredentialRequestBeforeOtherHost() async {
        var request = URLRequest(url: URL(string: "https://fixture.invalid/redirect")!)
        request.setValue("Bearer fixture-secret", forHTTPHeaderField: "Authorization")
        do { _ = try await transport().send(request); XCTFail("Expected redirect rejection") }
        catch let error as CloudFailure { XCTAssertEqual(error.reason, .insecureTransport) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

/// Intercepts every request in the injected session, so these tests cannot reach a server.
private final class CloudFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "other.invalid" { XCTFail("Cross-host redirect reached the transport") }
        if url.path == "/redirect" {
            let target = URL(string: "https://other.invalid/payload")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        if url.path == "/suspended" { return }
        let body = url.path == "/oversized" ? Data(repeating: 65, count: 17 * 1024 * 1024) : Data("payload".utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
