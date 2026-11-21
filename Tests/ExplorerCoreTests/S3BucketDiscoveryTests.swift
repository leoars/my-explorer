// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ExplorerCore

final class S3BucketDiscoveryTests: XCTestCase, @unchecked Sendable {
    private var credentials: CloudCredentials {
        CloudCredentials(accessKeyID: "EXAMPLEKEY", secretAccessKey: "example-secret", sessionToken: "example-token")
    }

    func testPagesPerAccountAndProbesPerRegionWithSignedRequests() async throws {
        let transport = DiscoveryTransport { request in
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-security-token"), "example-token")
            let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            if value("max-buckets") != nil {
                XCTAssertEqual(url.host, "s3.us-east-1.amazonaws.com")
                XCTAssertTrue(auth.contains("/us-east-1/s3/aws4_request"))
                if let token = value("continuation-token") {
                    XCTAssertEqual(token, "more+/=")
                    return .page([("bucket.ok", "eu-west-1"), ("offline-bucket", "us-east-1")])
                }
                return .page([("bucket.ok", "eu-west-1"), ("denied-bucket", "us-east-1")], token: "more+/=")
            }
            XCTAssertEqual(value("list-type"), "2")
            XCTAssertEqual(value("max-keys"), "1")
            if url.host == "s3.eu-west-1.amazonaws.com" {
                XCTAssertEqual(url.path, "/bucket.ok")
                XCTAssertTrue(auth.contains("/eu-west-1/s3/aws4_request"))
                return .emptyListing
            }
            return CloudResponse(statusCode: url.host?.hasPrefix("denied-bucket.") == true ? 403 : 503)
        }
        let result = try await S3BucketDiscovery(transport: transport).discover(credentials: credentials, region: "us-east-1")
        XCTAssertEqual(result.buckets, [.init(name: "bucket.ok", region: "eu-west-1")])
        XCTAssertTrue(result.isPartial)
        let calls = await transport.count
        XCTAssertEqual(calls, 5)
    }

    func testRegionHintGetsNewSignatureAndLocationNeverReceivesKeys() async throws {
        let transport = DiscoveryTransport { request in
            switch request.url?.host {
            case "s3.us-east-1.amazonaws.com":
                return .page([("from-old-region", nil)])
            case "from-old-region.s3.us-east-1.amazonaws.com":
                return CloudResponse(statusCode: 301, headers: ["x-amz-bucket-region": "us-west-2", "Location": "https://example.invalid/"])
            case "from-old-region.s3.us-west-2.amazonaws.com":
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("/us-west-2/s3/aws4_request"))
                return .emptyListing
            default:
                XCTFail("Unexpected destination"); throw CloudFailure(.io)
            }
        }
        let result = try await S3BucketDiscovery(transport: transport).discover(credentials: credentials, region: "us-east-1")
        XCTAssertEqual(result.buckets, [.init(name: "from-old-region", region: "us-west-2")])
        XCTAssertFalse(result.isPartial)
    }

    func testDenialAndExpiredTokenRemainDistinctFromNoBuckets() async throws {
        for (response, reason) in [(CloudResponse(statusCode: 403), CloudFailure.Reason.permissionDenied),
                                   (CloudResponse(statusCode: 403, body: Data("<Error><Code>ExpiredToken</Code></Error>".utf8)), .authenticationRequired)] {
            do {
                _ = try await S3BucketDiscovery(transport: DiscoveryTransport { _ in response }).discover(credentials: credentials, region: "us-east-1")
                XCTFail("Expected rejection")
            } catch let failure as CloudFailure { XCTAssertEqual(failure.reason, reason) }
        }
        let empty = try await S3BucketDiscovery(transport: DiscoveryTransport { _ in .page([]) }).discover(credentials: credentials, region: "us-east-1")
        XCTAssertTrue(empty.buckets.isEmpty)
        XCTAssertFalse(empty.isPartial)
    }

    func testCyclicPaginationPreservesVerifiedResultsAndCancellationStopsDiscovery() async throws {
        let transport = DiscoveryTransport { request in
            if request.url?.host == "s3.us-east-1.amazonaws.com" { return .page([("verified-bucket", nil)], token: "repeated") }
            return .emptyListing
        }
        let result = try await S3BucketDiscovery(transport: transport).discover(credentials: credentials, region: "us-east-1")
        XCTAssertEqual(result.buckets.count, 1)
        XCTAssertTrue(result.isPartial)
        let slowTransport = DiscoveryTransport { _ in
            try await Task.sleep(for: .seconds(60))
            return .page([])
        }
        let credentials = self.credentials
        let task = Task { try await S3BucketDiscovery(transport: slowTransport).discover(credentials: credentials, region: "us-east-1") }
        while await slowTransport.count == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
    }

    func testInvalidRegionAndMalformedPageAreRejectedBeforeProbing() async throws {
        let transport = DiscoveryTransport { _ in CloudResponse(statusCode: 200, body: Data("<Malformed/>".utf8)) }
        for (region, reason) in [("us-east-1.invalid", CloudFailure.Reason.invalidConfiguration), ("us-east-1", .malformedResponse)] {
            do {
                _ = try await S3BucketDiscovery(transport: transport).discover(credentials: credentials, region: region)
                XCTFail("Expected rejection")
            } catch let failure as CloudFailure { XCTAssertEqual(failure.reason, reason) }
        }
        let calls = await transport.count
        XCTAssertEqual(calls, 1)
    }
}

private extension CloudResponse {
    static func page(_ buckets: [(String, String?)], token: String? = nil) -> Self {
        let entries = buckets.map { name, region in "<Bucket><Name>" + name + "</Name>" + (region.map { "<BucketRegion>" + $0 + "</BucketRegion>" } ?? "") + "</Bucket>" }.joined()
        let next = token.map { "<ContinuationToken>" + $0 + "</ContinuationToken>" } ?? ""
        return Self(statusCode: 200, body: Data(("<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Buckets>" + entries + "</Buckets>" + next + "</ListAllMyBucketsResult>").utf8))
    }
    static var emptyListing: Self {
        Self(statusCode: 200, body: Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
    }
}

private actor DiscoveryTransport: CloudTransport {
    private(set) var count = 0
    let handler: @Sendable (URLRequest) async throws -> CloudResponse
    init(_ handler: @escaping @Sendable (URLRequest) async throws -> CloudResponse) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> CloudResponse { count += 1; return try await handler(request) }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
}
