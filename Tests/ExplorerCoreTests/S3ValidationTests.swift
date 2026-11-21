// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import XCTest
@testable import ExplorerCore

final class S3ValidationTests: XCTestCase, @unchecked Sendable {
    private func client(_ transport: S3ValidationTransport) throws -> CloudStorageClient {
        try CloudStorageClient(connection: .init(name: "SECRET-CONNECTION-NAME", provider: .s3,
                                                bucket: "secret-bucket", region: "us-east-1"),
                               credentials: .init(accessKeyID: "PRIVATEACCESS", secretAccessKey: "SECRET-CREDENTIAL"),
                               transport: transport)
    }
    func testS3DeleteAndUndoPreservesReplacementAndRestoresOriginalBytes() async throws {
        let transport = S3ValidationTransport()
        let client = try client(transport)
        let key = "outside/preexisting.txt"
        let original = RemoteLocation.url(connectionID: client.connection.id, key: key)
        let service = StorageDeletionService(clientFactory: { _ in client })
        let history = LocalTransferService()
        let plan = try await service.plan(sources: [original], recursive: false)
        let result = try await service.execute(planID: plan.id, undoHistory: history) { _ in true }
        XCTAssertEqual(result.completed, [original])
        let afterDelete = await transport.objects
        XCTAssertNil(afterDelete[key])
        let requests = await transport.records.filter { ["GET", "DELETE"].contains($0.method) }
        XCTAssertEqual(requests.map(\.method), ["GET", "DELETE"])
        XCTAssertEqual(requests.map(\.condition), ["\"outside\"", "\"outside\""])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let replacement = Data("replacement".utf8)
        try replacement.write(to: file)
        _ = try await client.upload(fileURL: file, key: key)
        do {
            _ = try await history.undo(resolveTrashConflict: { _ in .cancel })
            XCTFail("Cancel must keep the recovery record and both objects")
        } catch { }
        let afterCancel = await transport.objects
        XCTAssertEqual(afterCancel[key]?.data, replacement)
        XCTAssertEqual(afterCancel.count, 1)
        let restored = try await history.undo(resolveTrashConflict: { _ in .keepBoth })
        let contents = await transport.objects
        XCTAssertEqual(contents[key]?.data, replacement)
        let copy = try XCTUnwrap(contents.first { $0.key != key })
        XCTAssertTrue(copy.key.hasPrefix("outside/"))
        XCTAssertEqual(copy.value.data, Data("untouched".utf8))
        XCTAssertTrue(restored.contains(RemoteLocation.url(connectionID: client.connection.id, key: copy.key)))
        let lastPut = await transport.records.last { $0.method == "PUT" }
        XCTAssertEqual(lastPut?.condition, "*")
        let kind = await history.undoKind
        XCTAssertNil(kind)
    }

    func testFailedS3UndoBackupLeavesOriginalAndDoesNotDelete() async throws {
        let transport = S3ValidationTransport(mode: .downloadFailure)
        let client = try client(transport)
        let original = RemoteLocation.url(connectionID: client.connection.id, key: "outside/preexisting.txt")
        let service = StorageDeletionService(clientFactory: { _ in client })
        let history = LocalTransferService()
        let plan = try await service.plan(sources: [original], recursive: false)
        do {
            _ = try await service.execute(planID: plan.id, undoHistory: history) { _ in true }
            XCTFail("An unbacked object must remain intact")
        } catch { }
        let requests = await transport.records
        XCTAssertTrue(requests.contains { $0.method == "GET" })
        XCTAssertFalse(requests.contains { $0.method == "DELETE" })
        let originalData = await transport.objects["outside/preexisting.txt"]?.data
        XCTAssertEqual(originalData, Data("untouched".utf8))
        let kind = await history.undoKind
        XCTAssertNil(kind)
    }

    func testBaselineRoundTripsPaginationAndSharedFolderDownload() async throws {
        let transport = S3ValidationTransport()
        let runner = S3ValidationRunner(client: try client(transport))
        let report = await runner.run()
        XCTAssertFalse(report.failed, "\(report.steps)")
        XCTAssertEqual(report.prefix, runner.prefix)
        XCTAssertEqual(report.runID, runner.runID)
        XCTAssertEqual(report.steps.filter { $0.status == .passed }.count, 16)
        XCTAssertTrue(report.steps.filter { $0.status == .deferred }.isEmpty)
        XCTAssertTrue(report.residualKeys.isEmpty)
        XCTAssertGreaterThan(report.listPages.count, 1)
        XCTAssertTrue(report.listPages.allSatisfy { $0.objectCount <= 2 && $0.unknownKeyCount == 0 && $0.outOfScopeCount == 0 })
        let objects = await transport.objects
        XCTAssertEqual(Set(objects.keys), ["outside/preexisting.txt"])
        let requests = await transport.records
        XCTAssertTrue(requests.allSatisfy { $0.key.hasPrefix(report.prefix) })
        XCTAssertTrue(requests.filter { $0.method == "DELETE" }.allSatisfy { $0.condition != nil && $0.condition != "*" })
        XCTAssertGreaterThan(requests.filter { $0.method == "LIST" && $0.pageSize == 2 }.count, 1)
        let encoded = try JSONEncoder().encode(report)
        let text = String(decoding: encoded, as: UTF8.self)
        for secret in ["PRIVATEACCESS", "SECRET-CREDENTIAL", "secret-bucket", "SECRET-CONNECTION-NAME", "https://"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertFalse(try JSONDecoder().decode(S3ValidationReport.self, from: encoded).failed)
    }
    func testListingDiagnosticsNeverExposeUnknownServerKeys() async throws {
        let transport = S3ValidationTransport(mode: .unknownListKey)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        XCTAssertEqual(report.steps.first { $0.status == .failed }?.reason, .listingOutOfScope)
        XCTAssertEqual(report.listPages.first?.unknownKeyCount, 1)
        XCTAssertEqual(report.listPages.first?.outOfScopeCount, 1)
        XCTAssertEqual(report.listPages.first?.knownFixtures, [])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("PRIVATE-SERVER-SECRET"))
        XCTAssertTrue(report.residualKeys.isEmpty)
    }
    func testListingDiagnosesSpacesAsPlusWithoutPublishingUnknownKeys() async throws {
        let transport = S3ValidationTransport(mode: .spacesAsPlusList)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        XCTAssertEqual(report.steps.first { $0.status == .failed }?.reason, .listingMissingFixture)
        XCTAssertEqual(report.listPages.flatMap(\.fixtureSpellingDiagnostics), [.spacesAsPlus])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("Olá+日本語"))
        XCTAssertTrue(report.residualKeys.isEmpty)
    }
    func testMalformedListingHasDistinctSafeReason() async throws {
        let transport = S3ValidationTransport(mode: .malformedList)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        XCTAssertEqual(report.steps.first { $0.status == .failed }?.reason, .listingMalformedResponse)
        XCTAssertTrue(report.listPages.isEmpty)
        XCTAssertTrue(report.residualKeys.isEmpty)
    }
    func testFailureCleansOnlyConfirmedWritesAndKeepsPreexistingObject() async throws {
        let transport = S3ValidationTransport(mode: .downloadFailure)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        XCTAssertTrue(report.failed)
        XCTAssertTrue(report.residualKeys.isEmpty)
        XCTAssertEqual(report.cleanup.count, 1)
        XCTAssertEqual(report.cleanup.first?.status, .acknowledged)
        let objects = await transport.objects
        XCTAssertEqual(Set(objects.keys), ["outside/preexisting.txt"])
    }
    func testUnknownUploadOutcomeRemainsResidualWithoutAdoptingHEAD() async throws {
        let transport = S3ValidationTransport(mode: .unknownUpload)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        XCTAssertTrue(report.failed)
        XCTAssertEqual(report.residualKeys, [report.prefix + "binary.bin"])
        XCTAssertEqual(report.cleanup.first?.status, .residualUnknown)
        let records = await transport.records
        XCTAssertEqual(records.map(\.method), ["PUT"])
        let objects = await transport.objects
        XCTAssertNotNil(objects[report.prefix + "binary.bin"])
    }
    func testCollisionNeverDeletesPreexistingKeyInsideFreshPrefix() async throws {
        let transport = S3ValidationTransport(mode: .collision)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        XCTAssertTrue(report.failed)
        XCTAssertTrue(report.cleanup.isEmpty)
        let records = await transport.records
        XCTAssertFalse(records.contains { $0.method == "DELETE" })
        let objects = await transport.objects
        XCTAssertEqual(objects[report.prefix + "binary.bin"]?.data, Data("preexisting collision".utf8))
    }
    func testChangedVersionDuringFailureIsPreserved() async throws {
        let transport = S3ValidationTransport(mode: .changedBeforeCleanup)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        XCTAssertTrue(report.failed)
        XCTAssertEqual(report.cleanup.first?.status, .preserved)
        XCTAssertEqual(report.cleanup.first?.reason, .changedVersion)
        XCTAssertEqual(report.residualKeys, [report.prefix + "binary.bin"])
        let objects = await transport.objects
        XCTAssertEqual(objects[report.prefix + "binary.bin"]?.data, Data("external edit".utf8))
    }
    func testTimeoutReturnsPromptlyAndDiscardsLateUploadOwnership() async throws {
        let transport = S3ValidationTransport(mode: .slowUpload)
        let runner = S3ValidationRunner(client: try client(transport), operationTimeout: .milliseconds(30))
        let start = ContinuousClock.now
        let report = await runner.run()
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
        XCTAssertTrue(report.failed)
        XCTAssertEqual(report.steps.first?.reason, .timedOut)
        XCTAssertEqual(report.residualKeys.count, 1)
        try await Task.sleep(for: .milliseconds(300))
        let records = await transport.records
        XCTAssertFalse(records.contains { $0.method == "DELETE" })
    }
    func testCancelledValidationStillCleansConfirmedWrites() async throws {
        let transport = S3ValidationTransport(mode: .downloadCancellation)
        let runner = S3ValidationRunner(client: try client(transport))
        let task = Task { await runner.run() }
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await transport.records.contains { $0.method == "GET" }), ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(5))
        }
        let beganDownload = await transport.records.contains { $0.method == "GET" }
        XCTAssertTrue(beganDownload)
        task.cancel()
        let report = await task.value
        XCTAssertEqual(report.status, .cancelled)
        XCTAssertEqual(report.cleanup.first?.status, .acknowledged)
        XCTAssertTrue(report.residualKeys.isEmpty)
    }
    func testSharedUploadUnknownOutcomeKeepsOnlyUnreceiptedKeyResidual() async throws {
        let transport = S3ValidationTransport(mode: .sharedUnknownUpload)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        let unknown = report.prefix + "shared-folder/child.txt"
        XCTAssertEqual(report.steps.first { $0.status == .failed }?.id, "sharedFolderUpload")
        XCTAssertEqual(report.residualKeys, [unknown])
        let records = await transport.records
        XCTAssertFalse(records.contains { $0.method == "DELETE" && $0.key == unknown })
        let objects = await transport.objects
        XCTAssertEqual(Set(objects.keys), ["outside/preexisting.txt", unknown])
    }
    func testIndeterminateDirectDeleteIsNotRetriedByCleanup() async throws {
        let transport = S3ValidationTransport(mode: .unknownDelete)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        let key = report.prefix + "binary.bin"
        XCTAssertEqual(report.steps.first { $0.status == .failed }?.id, "conditionalDelete")
        XCTAssertEqual(report.residualKeys, [key])
        let records = await transport.records.filter { $0.method == "DELETE" && $0.key == key }
        XCTAssertEqual(records.count, 2) // One intentional stale probe and one dispatched current-version delete.
        XCTAssertEqual(report.cleanup.first { $0.key == key }?.status, .residualUnknown)
    }
    func testIndeterminateSharedDeleteIsNotRetriedByCleanup() async throws {
        let transport = S3ValidationTransport(mode: .sharedDeleteUnknown)
        let report = await S3ValidationRunner(client: try client(transport)).run()
        let key = report.prefix + "shared-folder/child.txt"
        XCTAssertEqual(report.steps.first { $0.status == .failed }?.id, "sharedDeletion")
        XCTAssertEqual(report.residualKeys, [key])
        let records = await transport.records.filter { $0.method == "DELETE" && $0.key == key }
        XCTAssertEqual(records.count, 1)
    }
    func testLocalRunIDPathIsNeverTouchedOrRemoved() async throws {
        let id = UUID()
        let preexisting = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.S3Validation.\(id.uuidString)")
        try FileManager.default.createDirectory(at: preexisting, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: preexisting) }
        let sentinel = preexisting.appendingPathComponent("personal-sentinel.txt")
        try Data("preserve me".utf8).write(to: sentinel)
        let transport = S3ValidationTransport(mode: .downloadFailure)
        _ = await S3ValidationRunner(client: try client(transport), runID: id).run()
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve me".utf8))
    }
    func testNonS3ClientIsRejectedWithoutTransport() async throws {
        let transport = S3ValidationTransport()
        let client = try CloudStorageClient(connection: .init(name: "GCP", provider: .gcs, bucket: "fixture-bucket"),
                                             credentials: .init(accessToken: "TOKEN"), transport: transport)
        let report = await S3ValidationRunner(client: client).run()
        XCTAssertEqual(report.steps.first?.reason, .unsupportedProvider)
        let records = await transport.records
        XCTAssertTrue(records.isEmpty)
    }
}

private actor S3ValidationTransport: CloudTransport {
    enum Mode { case normal, downloadFailure, unknownUpload, collision, changedBeforeCleanup, slowUpload, downloadCancellation, unknownListKey, malformedList, sharedUnknownUpload, unknownDelete, sharedDeleteUnknown, spacesAsPlusList }
    struct Object: Sendable { let data: Data; let version: String }
    struct Record: Sendable { let method: String; let key: String; let condition: String?; var pageSize: Int? = nil }
    let mode: Mode
    var objects: [String: Object] = ["outside/preexisting.txt": .init(data: Data("untouched".utf8), version: "\"outside\"")]
    var records: [Record] = []
    var generation = 0
    init(mode: Mode = .normal) { self.mode = mode }
    private func key(_ request: URLRequest) -> String {
        String(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath.dropFirst()).removingPercentEncoding!
    }
    func send(_ request: URLRequest) async throws -> CloudResponse {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        if let prefix = query.first(where: { $0.name == "prefix" })?.value {
            let size = Int(query.first(where: { $0.name == "max-keys" })?.value ?? "1000")!
            records.append(.init(method: "LIST", key: prefix, condition: nil, pageSize: size))
            if mode == .unknownListKey {
                return .init(statusCode: 200, body: Data("<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>PRIVATE-SERVER-SECRET</Key><Size>0</Size></Contents></ListBucketResult>".utf8))
            }
            if mode == .malformedList { return .init(statusCode: 200, body: Data("malformed PRIVATE-SERVER-SECRET".utf8)) }
            let offset = Int(query.first(where: { $0.name == "continuation-token" })?.value ?? "0")!
            var children: Set<String> = []
            for object in objects.keys where object.hasPrefix(prefix) {
                let tail = String(object.dropFirst(prefix.count))
                if tail.isEmpty { children.insert(object); continue }
                if let slash = tail.firstIndex(of: "/") { children.insert(prefix + tail[...slash]) }
                else { children.insert(object) }
            }
            let all = children.sorted()
            let selected = Array(all.dropFirst(offset).prefix(size))
            let more = offset + selected.count < all.count
            var xml = "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>\(more)</IsTruncated>"
            if more { xml += "<NextContinuationToken>\(offset + selected.count)</NextContinuationToken>" }
            for child in selected {
                let listed = mode == .spacesAsPlusList ? child.replacingOccurrences(of: " ", with: "+") : child
                let encoded = S3SignatureV4.encode(listed, preservingSlashes: true).replacingOccurrences(of: "%20", with: "+")
                if child.hasSuffix("/"), child != prefix {
                    xml += "<CommonPrefixes><Prefix>\(encoded)</Prefix></CommonPrefixes>"
                } else {
                    xml += "<Contents><Key>\(encoded)</Key><Size>\(objects[child]!.data.count)</Size></Contents>"
                }
            }
            xml += "</ListBucketResult>"
            return .init(statusCode: 200, body: Data(xml.utf8))
        }
        let key = key(request), method = request.httpMethod!
        let condition = request.value(forHTTPHeaderField: "If-Match")
        records.append(.init(method: method, key: key, condition: condition))
        guard let object = objects[key] else { return .init(statusCode: 404) }
        if method == "HEAD" { return .init(statusCode: 200, headers: headers(object)) }
        if method == "DELETE" {
            guard condition == object.version else { return .init(statusCode: 412) }
            objects.removeValue(forKey: key)
            if mode == .unknownDelete && key.hasSuffix("/binary.bin") ||
                mode == .sharedDeleteUnknown && key.hasSuffix("/shared-folder/child.txt") {
                throw CloudFailure(.io)
            }
            return .init(statusCode: 204)
        }
        throw CloudFailure(.io)
    }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        let key = key(request)
        records.append(.init(method: "PUT", key: key,
                             condition: request.value(forHTTPHeaderField: "If-Match") ?? request.value(forHTTPHeaderField: "If-None-Match")))
        if mode == .collision, generation == 0 {
            objects[key] = .init(data: Data("preexisting collision".utf8), version: "\"collision\"")
        }
        if request.value(forHTTPHeaderField: "If-None-Match") == "*", objects[key] != nil { return .init(statusCode: 412) }
        if let condition = request.value(forHTTPHeaderField: "If-Match"), objects[key]?.version != condition { return .init(statusCode: 412) }
        let bytes = try Data(contentsOf: fileURL)
        generation += 1
        let object = Object(data: bytes, version: "\"generation-\(generation)\"")
        objects[key] = object
        if mode == .unknownUpload || mode == .sharedUnknownUpload && key.hasSuffix("/shared-folder/child.txt") {
            throw CloudFailure(.io, detail: "SECRET RAW RESPONSE")
        }
        if mode == .slowUpload {
            // Deliberately ignore task cancellation to exercise the runner's independent deadline.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { continuation.resume() }
            }
        }
        return .init(statusCode: 200, headers: headers(object))
    }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        let key = key(request)
        records.append(.init(method: "GET", key: key, condition: request.value(forHTTPHeaderField: "If-Match")))
        if mode == .changedBeforeCleanup {
            objects[key] = .init(data: Data("external edit".utf8), version: "\"external\"")
            throw CloudFailure(.io)
        }
        if mode == .downloadFailure { throw CloudFailure(.io) }
        if mode == .downloadCancellation { try await Task.sleep(for: .seconds(60)) }
        guard let object = objects[key] else { return .init(statusCode: 404) }
        if let version = request.value(forHTTPHeaderField: "If-Match"), object.version != version { return .init(statusCode: 412) }
        if key.hasSuffix("/cancellation.bin") {
            try object.data.prefix(64 * 1024).write(to: fileURL)
            progress?(.init(completedBytes: 64 * 1024, totalBytes: Int64(object.data.count)))
            try await Task.sleep(for: .milliseconds(20))
            try Task.checkCancellation()
        }
        try object.data.write(to: fileURL)
        return .init(statusCode: 200, headers: headers(object))
    }
    private func headers(_ object: Object) -> [String: String] {
        ["ETag": object.version, "Content-Length": String(object.data.count),
         "x-amz-checksum-sha256": Data(SHA256.hash(data: object.data)).base64EncodedString()]
    }
}
