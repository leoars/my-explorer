// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class StorageDeletionInventoryTests: XCTestCase, @unchecked Sendable {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    func testInventoryIgnoresEnumerationOrderAndSortsByUTF8Bytes() {
        let objects = [
            CloudObject(key: "prefix/Pasta + 日本語/", size: 0, modified: instant, isDirectory: true, version: "marker"),
            CloudObject(key: "prefix/Pasta + 日本語/vazia/", size: 0, modified: instant, isDirectory: true, version: "empty"),
            CloudObject(key: "prefix/Pasta + 日本語/child.json", size: 91, modified: instant.addingTimeInterval(1), version: "child"),
            CloudObject(key: "prefix/Ola\u{301} 日本語 + % # &.txt", size: 13, modified: instant.addingTimeInterval(2), version: "text")
        ]
        let byteOrder = objects.map { Data($0.key.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        for _ in 0..<1000 {
            let shuffled = objects.shuffled()
            XCTAssertTrue(DeletionRemoteInventory.matches(objects, shuffled))
            XCTAssertEqual(DeletionRemoteInventory.ordered(shuffled).map { Data($0.key.utf8) }, byteOrder)
            XCTAssertEqual(DeletionRemoteInventory.ordered(shuffled, descending: true).map { Data($0.key.utf8) }, Array(byteOrder.reversed()))
        }
        XCTAssertTrue(DeletionRemoteInventory.matches([], []))
    }

    func testEveryMetadataDifferenceAndDuplicateExactIdentityIsRejected() {
        let original = CloudObject(key: "file", size: 12, modified: instant, version: "version")
        let variants = [
            CloudObject(key: "other", size: 12, modified: instant, version: "version"),
            CloudObject(key: "file", size: 13, modified: instant, version: "version"),
            CloudObject(key: "file", size: nil, modified: instant, version: "version"),
            CloudObject(key: "file", size: 12, modified: instant.addingTimeInterval(1), version: "version"),
            CloudObject(key: "file", size: 12, modified: nil, version: "version"),
            CloudObject(key: "file", size: 12, modified: instant, isDirectory: true, version: "version"),
            CloudObject(key: "file", size: 12, modified: instant, version: "changed"),
            CloudObject(key: "file", size: 12, modified: instant, version: nil)
        ]
        for changed in variants { XCTAssertFalse(DeletionRemoteInventory.matches([original], [changed])) }
        XCTAssertFalse(DeletionRemoteInventory.matches([original], []))
        XCTAssertFalse(DeletionRemoteInventory.matches([], [original]))
        XCTAssertFalse(DeletionRemoteInventory.matches([original, original], [original, original]))
    }

    func testCanonicallyEquivalentKeysStayDistinctEvenWithIdenticalMetadata() {
        let nfc = CloudObject(key: "folder/Olá.txt", size: 7, modified: instant, version: "same-etag")
        let nfd = CloudObject(key: "folder/Ola\u{301}.txt", size: 7, modified: instant, version: "same-etag")
        XCTAssertEqual(nfc.key, nfd.key, "Swift String uses canonical equivalence")
        XCTAssertNotEqual(Data(nfc.key.utf8), Data(nfd.key.utf8))
        XCTAssertTrue(DeletionRemoteInventory.matches([nfc, nfd], [nfd, nfc]))
        XCTAssertFalse(DeletionRemoteInventory.matches([nfd], [nfc]))
        XCTAssertFalse(DeletionRemoteInventory.matches([nfc, nfd], [nfc]))
        XCTAssertFalse(DeletionRemoteInventory.matches([nfc, nfd], [nfc, nfc]))
        XCTAssertEqual(DeletionRemoteInventory.ordered([nfc, nfd]).map { Data($0.key.utf8) },
                       DeletionRemoteInventory.ordered([nfd, nfc]).map { Data($0.key.utf8) })
    }

    func testDeletionInventoryPreservesBothUnicodeByteIdentitiesAcrossListAndHead() async throws {
        let keys = ["folder/", "folder/Olá.txt", "folder/Ola\u{301}.txt"]
        let transport = ByteIdentityS3(keys: keys)
        let connection = CloudConnection(name: "Fixture", provider: .s3, bucket: "fixture-bucket")
        let client = try CloudStorageClient(connection: connection, credentials: CloudCredentials(accessKeyID: "FIXTURE", secretAccessKey: "fixture"), transport: transport)
        let service = StorageDeletionService(clientFactory: { _ in client })
        let source = RemoteLocation.url(connectionID: connection.id, key: "folder/")
        let cancelled = try await service.plan(sources: [source], recursive: true)
        await service.discard(planID: cancelled.id)
        let plan = try await service.plan(sources: [source], recursive: true)
        XCTAssertEqual(plan.itemCount, 3)
        let result = try await service.execute(planID: plan.id) { _ in true }
        XCTAssertEqual(result.completed.count, 3)
        let deleted = await transport.deleted
        XCTAssertEqual(Set(deleted), Set(keys.map { Data($0.utf8) }))
        XCTAssertEqual(deleted, keys.map { Data($0.utf8) }.sorted { $1.lexicographicallyPrecedes($0) })
    }
}

private actor ByteIdentityS3: CloudTransport {
    private var keys: Set<Data>
    private(set) var deleted: [Data] = []
    init(keys: [String]) { self.keys = Set(keys.map { Data($0.utf8) }) }
    func send(_ request: URLRequest) async throws -> CloudResponse {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let key = String(components.path.dropFirst()), identity = Data(key.utf8)
        if request.httpMethod == "HEAD" {
            guard keys.contains(identity) else { return CloudResponse(statusCode: 404) }
            return CloudResponse(statusCode: 200, headers: ["Content-Length": "7", "ETag": "\"same-etag\"", "Last-Modified": "Tue, 14 Nov 2023 22:13:20 GMT"])
        }
        if request.httpMethod == "DELETE" {
            guard request.value(forHTTPHeaderField: "If-Match") == "\"same-etag\"" else { return CloudResponse(statusCode: 412) }
            guard keys.remove(identity) != nil else { return CloudResponse(statusCode: 404) }
            deleted.append(identity)
            return CloudResponse(statusCode: 204)
        }
        let prefix = components.queryItems?.first { $0.name == "prefix" }?.value ?? ""
        let contents = keys.filter { $0.starts(with: prefix.utf8) }.shuffled().map { bytes in
            let encoded = S3SignatureV4.encode(String(decoding: bytes, as: UTF8.self))
            return "<Contents><Key>\(encoded)</Key><Size>7</Size><ETag>&quot;same-etag&quot;</ETag></Contents>"
        }.joined()
        let xml = "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>\(contents)</ListBucketResult>"
        return CloudResponse(statusCode: 200, body: Data(xml.utf8))
    }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
}
