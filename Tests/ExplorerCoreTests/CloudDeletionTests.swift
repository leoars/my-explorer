// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ExplorerCore

final class CloudDeletionTests: XCTestCase, @unchecked Sendable {
    func testProviderConditionsAndNoHistoricalVersionOrSnapshotFlags() throws {
        let s3 = try S3CloudBackend(connection: .init(name: "S3", provider: .s3, bucket: "test-bucket", region: "us-east-1"), credentials: .init(accessKeyID: "TEST", secretAccessKey: "SECRET"))
        let s3request = try s3.deleteRequest(key: "a 日本/#?.txt", matchingVersion: "\"etag\"")
        XCTAssertEqual(s3request.httpMethod, "DELETE")
        XCTAssertEqual(s3request.value(forHTTPHeaderField: "If-Match"), "\"etag\"")
        XCTAssertTrue(s3request.value(forHTTPHeaderField: "Authorization")!.contains("if-match"))
        XCTAssertNil(s3request.url?.query)
        let azure = try AzureCloudBackend(connection: .init(name: "Azure", provider: .azure, bucket: "test-container", account: "testaccount"), credentials: .init(sasToken: "sv=2023-11-03&sig=a%2Bb%2Fc%3D"))
        let azureRequest = try azure.deleteRequest(key: "a 日本/#?.txt", matchingVersion: "\"etag\"")
        XCTAssertEqual(azureRequest.httpMethod, "DELETE")
        XCTAssertEqual(azureRequest.value(forHTTPHeaderField: "If-Match"), "\"etag\"")
        XCTAssertNil(azureRequest.value(forHTTPHeaderField: "x-ms-delete-snapshots"))
        XCTAssertEqual(URLComponents(url: azureRequest.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "sv=2023-11-03&sig=a%2Bb%2Fc%3D")
        let gcs = try GCSCloudBackend(connection: .init(name: "GCS", provider: .gcs, bucket: "test-bucket"), credentials: .init(accessToken: "test"))
        let gcsRequest = try gcs.deleteRequest(key: "a 日本/#?.txt", matchingVersion: "123")
        XCTAssertEqual(gcsRequest.httpMethod, "DELETE")
        XCTAssertEqual(URLComponents(url: gcsRequest.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "ifGenerationMatch", value: "123")])
        for value in ["*", "", " * ", "one,two", "bad\r\nheader"] {
            XCTAssertThrowsError(try s3.deleteRequest(key: "key", matchingVersion: value))
            XCTAssertThrowsError(try azure.deleteRequest(key: "key", matchingVersion: value))
            XCTAssertThrowsError(try gcs.deleteRequest(key: "key", matchingVersion: value))
        }
        XCTAssertThrowsError(try AzureCloudBackend(connection: .init(name: "Azure", provider: .azure, bucket: "test-container", account: "testaccount"), credentials: .init(sasToken: "sig=a&deletetype=permanent")))
    }
    func testAcknowledgementAbsenceChangedAndTimeoutRemainDistinct() async throws {
        for (status, expected): (Int, CloudDeletionOutcome) in [(204,.acknowledged),(202,.acknowledged),(404,.absent),(412,.changed),(503,.indeterminate)] {
            let transport = DeleteResponseTransport(status: status)
            let client = try CloudStorageClient(connection: .init(name: "GCS", provider: .gcs, bucket: "test-bucket"), credentials: .init(accessToken: "test"), transport: transport)
            let outcome = try await client.delete(key: "key", matchingVersion: "123")
            XCTAssertEqual(outcome, expected)
        }
        for (status, reason): (Int, CloudFailure.Reason) in [(401,.authenticationRequired),(403,.permissionDenied),(409,.conflict),(302,.insecureTransport)] {
            let client = try CloudStorageClient(connection: .init(name: "GCS", provider: .gcs, bucket: "test-bucket"), credentials: .init(accessToken: "test"), transport: DeleteResponseTransport(status: status))
            do { _ = try await client.delete(key: "key", matchingVersion: "1"); XCTFail() }
            catch let failure as CloudFailure { XCTAssertEqual(failure.reason, reason) }
        }
    }
}
private struct DeleteResponseTransport: CloudTransport {
    let status: Int
    func send(_ request: URLRequest) async throws -> CloudResponse { .init(statusCode: status) }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
}
