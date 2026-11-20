// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ExplorerCore

final class CloudPaginationTests: XCTestCase, @unchecked Sendable {
    private func connection(_ provider: CloudProvider) -> CloudConnection {
        CloudConnection(name: "Fixture", provider: provider, bucket: "fixture-bucket", region: "us-east-1", account: "fixtureaccount")
    }
    private var credentials: CloudCredentials {
        CloudCredentials(accessKeyID: "FIXTUREACCESS", secretAccessKey: "fixture-secret",
                         sasToken: "sv=2023-11-03&sig=fixture", accessToken: "fixture-token")
    }
    private func query(_ request: URLRequest, _ name: String) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }

    func testSmallPagesKeepDefaultsAndOpaqueTokensForEveryAdapter() throws {
        let s3 = try S3CloudBackend(connection: connection(.s3), credentials: credentials)
        let azure = try AzureCloudBackend(connection: connection(.azure), credentials: credentials)
        let gcs = try GCSCloudBackend(connection: connection(.gcs), credentials: credentials)
        XCTAssertEqual(query(try s3.listRequest(prefix: "", continuationToken: nil), "max-keys"), "1000")
        XCTAssertEqual(query(try azure.listRequest(prefix: "", continuationToken: nil), "maxresults"), "1000")
        XCTAssertEqual(query(try gcs.listRequest(prefix: "", continuationToken: nil), "maxResults"), "1000")
        let adapters: [(any CloudProviderBackend, String, String)] = [(s3, "max-keys", "continuation-token"),
            (azure, "maxresults", "marker"), (gcs, "maxResults", "pageToken")]
        for (backend, countName, tokenName) in adapters {
            let request = try backend.listRequest(prefix: "fixture/日本語 +/", continuationToken: "opaque+/= &日本", pageSize: 2)
            XCTAssertEqual(query(request, countName), "2")
            XCTAssertEqual(query(request, tokenName), "opaque+/= &日本")
            XCTAssertEqual(query(request, "prefix"), "fixture/日本語 +/")
        }
    }

    func testInvalidPageSizesAreRejectedBeforeTransport() async throws {
        for provider in CloudProvider.allCases {
            let transport = PaginationTransport()
            let client = try CloudStorageClient(connection: connection(provider), credentials: credentials, transport: transport)
            for size in [Int.min, -1, 0, 1001, Int.max] {
                do { _ = try await client.list(prefix: "fixture/", pageSize: size); XCTFail("Accepted invalid page size") }
                catch let error as CloudFailure { XCTAssertEqual(error.reason, .invalidConfiguration) }
            }
            let calls = await transport.requests
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testS3ClientFollowsSmallPagesWithoutChangingPrefixOrToken() async throws {
        let transport = PaginationTransport()
        let client = try CloudStorageClient(connection: connection(.s3), credentials: credentials, transport: transport)
        let first = try await client.list(prefix: "fixture/", pageSize: 2)
        XCTAssertEqual(first.objects.map(\.key), ["fixture/one", "fixture/two"])
        XCTAssertEqual(first.nextToken, "opaque+/=&")
        let last = try await client.list(prefix: "fixture/", continuationToken: first.nextToken, pageSize: 2)
        XCTAssertEqual(last.objects.map(\.key), ["fixture/three"])
        XCTAssertNil(last.nextToken)
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { query($0, "max-keys") == "2" && query($0, "prefix") == "fixture/" })
        XCTAssertEqual(query(calls[1], "continuation-token"), "opaque+/=&")
        XCTAssertNotNil(calls[1].value(forHTTPHeaderField: "Authorization"))
    }

    func testOptionalConditionalReadPreservesOtherProviderDefaults() throws {
        let azure = try AzureCloudBackend(connection: connection(.azure), credentials: credentials)
        let gcs = try GCSCloudBackend(connection: connection(.gcs), credentials: credentials)
        XCTAssertNil(try azure.downloadRequest(key: "object").value(forHTTPHeaderField: "If-Match"))
        XCTAssertNil(query(try gcs.downloadRequest(key: "object"), "ifGenerationMatch"))
        XCTAssertEqual(try azure.downloadRequest(key: "object", matchingVersion: "\"etag\"").value(forHTTPHeaderField: "If-Match"), "\"etag\"")
        XCTAssertEqual(query(try gcs.downloadRequest(key: "object", matchingVersion: "123"), "ifGenerationMatch"), "123")
        XCTAssertThrowsError(try azure.downloadRequest(key: "object", matchingVersion: "*"))
        XCTAssertThrowsError(try gcs.downloadRequest(key: "object", matchingVersion: "0"))
    }
}

private actor PaginationTransport: CloudTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> CloudResponse {
        requests.append(request)
        let names = requests.count == 1 ? ["one", "two"] : ["three"]
        let objects = names.map { "<Contents><Key>fixture/\($0)</Key><Size>1</Size><ETag>\"etag-\($0)\"</ETag></Contents>" }.joined()
        let tail = requests.count == 1 ? "<IsTruncated>true</IsTruncated><NextContinuationToken>opaque+/=&amp;</NextContinuationToken>" : "<IsTruncated>false</IsTruncated>"
        return CloudResponse(statusCode: 200, body: Data(("<ListBucketResult>" + objects + tail + "</ListBucketResult>").utf8))
    }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
}
