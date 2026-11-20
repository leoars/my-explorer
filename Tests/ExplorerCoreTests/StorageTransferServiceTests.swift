// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class StorageTransferServiceTests: XCTestCase, @unchecked Sendable {
    func testAuthorizationRevocationBetweenUploadsKeepsOnlyCompletedItems() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try file(first, "first"); try file(second, "second")
        let cloud = MemoryGCS(), transfer = try service(cloud)
        await expect(.authorizationDenied, completed: 1) {
            try await transfer.copy(sources: [first, second], to: self.remote(), resolveConflict: { _ in .cancel },
                                    authorize: { source, destination, replacing in
                XCTAssertFalse(replacing)
                XCTAssertEqual(RemoteLocation.parse(destination)?.key, source.lastPathComponent)
                if source == second { throw TransferAuthorizationFixture.denied }
            })
        }
        let stored = await cloud.snapshot()
        XCTAssertEqual(stored["first.txt"], Data("first".utf8))
        XCTAssertNil(stored["second.txt"])
    }

    func testRevocationAfterDownloadPreventsPublishAndCleansStaging() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let destination = root.appendingPathComponent("file.txt")
        try file(destination, "keep local")
        let cloud = MemoryGCS(); await cloud.seed("file.txt", "cloud")
        let transfer = try service(cloud), gate = TransferAuthorizationGate()
        await expect(.authorizationDenied) {
            try await transfer.copy(sources: [self.remote("file.txt")], to: root, resolveConflict: { _ in .replace },
                                    authorize: { _, target, replacing in
                XCTAssertEqual(target.path, destination.path)
                XCTAssertTrue(replacing)
                try await gate.allowFirstOnly()
            })
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep local")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["file.txt"])
    }

    func testAuthorizationCoversDirectoryCreationAndResolvedKeepBothTarget() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let cloud = MemoryGCS(); await cloud.seed("folder/child.txt", "cloud")
        let transfer = try service(cloud)
        await expect(.authorizationDenied) {
            try await transfer.copy(sources: [self.remote("folder/")], to: root, resolveConflict: { _ in .cancel },
                                    authorize: { _, _, _ in throw TransferAuthorizationFixture.denied })
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let source = root.appendingPathComponent("file.txt"); try file(source, "new")
        await cloud.seed("file.txt", "old")
        await expect(.authorizationDenied) {
            try await transfer.copy(sources: [source], to: self.remote(), resolveConflict: { _ in .keepBoth },
                                    authorize: { _, target, replacing in
                XCTAssertEqual(RemoteLocation.parse(target)?.key, "file (2).txt")
                XCTAssertFalse(replacing)
                throw TransferAuthorizationFixture.denied
            })
        }
        let stored = await cloud.snapshot()
        XCTAssertNil(stored["file (2).txt"])
        XCTAssertEqual(stored["file.txt"], Data("old".utf8))
    }

    private let connection = CloudConnection(name: "Fixture", provider: .gcs, bucket: "test-bucket")
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.StorageTransferTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func cleanup(_ root: URL) { try? FileManager.default.removeItem(at: root) }
    private func directory(_ path: URL) throws { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    private func file(_ path: URL, _ contents: String) throws { try Data(contents.utf8).write(to: path) }
    private func remote(_ key: String = "") -> URL { RemoteLocation.url(connectionID: connection.id, key: key) }
    private func service(_ transport: MemoryGCS, entries: Int = 10_000, depth: Int = 64) throws -> StorageTransferService {
        let client = try CloudStorageClient(connection: connection, credentials: CloudCredentials(accessToken: "fixture-token"), transport: transport)
        let id = connection.id
        return StorageTransferService(clientFactory: { requested in
            guard requested == id else { throw CloudFailure(.invalidConfiguration) }
            return client
        }, limits: .init(entries: entries, depth: depth))
    }
    private func expect<T: Sendable>(_ reason: StorageTransferFailure.Reason, completed: Int = 0,
                                    file: StaticString = #filePath, line: UInt = #line,
                                    _ operation: @Sendable () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected \(reason)", file: file, line: line) }
        catch let failure as StorageTransferFailure {
            XCTAssertTrue(failure.reason == reason, "Unexpected reason \(failure.reason)", file: file, line: line)
            XCTAssertEqual(failure.completedCount, completed, file: file, line: line)
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    func testLocalFolderUploadsUnicodeHierarchyAndEmptyMarkersUsingAbsentConditions() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("Ação 日本語")
        try directory(source.appendingPathComponent("nested")); try directory(source.appendingPathComponent("empty"))
        try file(source.appendingPathComponent("é + %.txt"), "top")
        try file(source.appendingPathComponent("nested/한국어.txt"), "child")
        let cloud = MemoryGCS(), transfer = try service(cloud)
        let progress = TransferProgressRecorder()
        let result = try await transfer.copy(sources: [source], to: remote("destination/"), resolveConflict: { _ in .cancel },
                                             progress: { progress.record($0) })
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(RemoteLocation.parse(result[0])?.key.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "destination/Ação 日本語")
        let objects = await cloud.snapshot()
        XCTAssertEqual(objects["destination/Ação 日本語/é + %.txt"], Data("top".utf8))
        XCTAssertEqual(objects["destination/Ação 日本語/nested/한국어.txt"], Data("child".utf8))
        XCTAssertEqual(objects["destination/Ação 日本語/empty/"], Data())
        let conditions = await cloud.conditions()
        XCTAssertFalse(conditions.isEmpty)
        XCTAssertTrue(conditions.allSatisfy { $0.condition == "0" })
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("nested/한국어.txt"), encoding: .utf8), "child")
        XCTAssertEqual(progress.snapshot().last?.completedItems, 5)
        XCTAssertEqual(progress.snapshot().last?.totalItems, 5)
        XCTAssertTrue(progress.snapshot().allSatisfy { $0.completedItems >= 0 && $0.completedItems <= $0.totalItems })
        let skippedProgress = TransferProgressRecorder()
        let skipped = try await transfer.copy(sources: [source], to: remote("destination/"), resolveConflict: { _ in .skip },
                                              progress: { skippedProgress.record($0) })
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(skippedProgress.snapshot().last?.completedItems, 5)
        XCTAssertEqual(skippedProgress.snapshot().last?.totalItems, 5)
        XCTAssertNil(skippedProgress.snapshot().last?.currentDestination)
        let afterSkip = await cloud.conditions()
        XCTAssertEqual(afterSkip.count, conditions.count)
    }

    func testCloudFolderDownloadsAllPagesHierarchyAndEmptyDirectories() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let cloud = MemoryGCS(pageSize: 1)
        await cloud.seed("folder 日本語/é + %.txt", "top")
        await cloud.seed("folder 日本語/nested/a.txt", "A")
        await cloud.seed("folder 日本語/nested/b.txt", "B")
        await cloud.seed("folder 日本語/empty/", "")
        let transfer = try service(cloud)
        let result = try await transfer.copy(sources: [remote("folder 日本語/")], to: root, resolveConflict: { _ in .cancel })
        XCTAssertEqual(result.count, 1)
        let downloaded = root.appendingPathComponent("folder 日本語")
        XCTAssertEqual(try String(contentsOf: downloaded.appendingPathComponent("é + %.txt"), encoding: .utf8), "top")
        XCTAssertEqual(try String(contentsOf: downloaded.appendingPathComponent("nested/a.txt"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: downloaded.appendingPathComponent("nested/b.txt"), encoding: .utf8), "B")
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.appendingPathComponent("empty").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let pages = await cloud.requestedPageTokens()
        XCTAssertTrue(pages.contains { $0 != nil })
        let stored = await cloud.snapshot()
        XCTAssertEqual(stored.count, 4)
    }

    func testUploadReplaceUsesObservedGenerationAndKeepBothPreservesExistingObject() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("report.txt")
        try file(source, "new")
        let cloud = MemoryGCS()
        await cloud.seed("report.txt", "old", generation: 7)
        let transfer = try service(cloud)
        _ = try await transfer.copy(sources: [source], to: remote(), resolveConflict: { conflict in
            XCTAssertEqual(conflict.source.path, source.path)
            XCTAssertEqual(RemoteLocation.parse(conflict.destination)?.key, "report.txt")
            XCTAssertFalse(conflict.isDirectory)
            return .replace
        })
        let replaced = await cloud.snapshot(), conditions = await cloud.conditions()
        XCTAssertEqual(replaced["report.txt"], Data("new".utf8))
        XCTAssertEqual(conditions.last?.condition, "7")
        try file(source, "keep both")
        let result = try await transfer.copy(sources: [source], to: remote(), resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(result.count, 1)
        let addedKey = try XCTUnwrap(RemoteLocation.parse(result[0])?.key)
        XCTAssertNotEqual(addedKey, "report.txt")
        let after = await cloud.snapshot()
        XCTAssertEqual(after["report.txt"], Data("new".utf8))
        XCTAssertEqual(after[addedKey], Data("keep both".utf8))
        let finalConditions = await cloud.conditions()
        XCTAssertEqual(finalConditions.last?.condition, "0")
    }

    func testUploadSkipAndCancelDoNotOverwrite() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("file.txt")
        try file(source, "source")
        let cloud = MemoryGCS(); await cloud.seed("file.txt", "existing")
        let transfer = try service(cloud)
        let skipped = try await transfer.copy(sources: [source], to: remote(), resolveConflict: { _ in .skip })
        XCTAssertTrue(skipped.isEmpty)
        await expect(.cancelled) { try await transfer.copy(sources: [source], to: self.remote(), resolveConflict: { _ in .cancel }) }
        let after = await cloud.snapshot(), conditions = await cloud.conditions()
        XCTAssertEqual(after["file.txt"], Data("existing".utf8))
        XCTAssertTrue(conditions.isEmpty)
    }

    func testChangedRemoteConflictIsNotRetriedUnconditionally() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("file.txt")
        try file(source, "source")
        let cloud = MemoryGCS(); await cloud.seed("file.txt", "observed", generation: 4)
        let transfer = try service(cloud)
        await expect(.conflictChanged) {
            try await transfer.copy(sources: [source], to: self.remote(), resolveConflict: { _ in
                await cloud.seed("file.txt", "changed concurrently", generation: 5)
                return .replace
            })
        }
        let after = await cloud.snapshot()
        XCTAssertEqual(after["file.txt"], Data("changed concurrently".utf8))
        let conditions = await cloud.conditions()
        XCTAssertEqual(conditions.map(\.condition), ["4"])
    }

    func testDownloadConflictChoicesPreserveOrReplaceOnlyAfterChoice() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let cloud = MemoryGCS(); await cloud.seed("report.txt", "cloud")
        let transfer = try service(cloud), source = remote("report.txt"), target = root.appendingPathComponent("report.txt")
        try file(target, "local")
        let skipped = try await transfer.copy(sources: [source], to: root, resolveConflict: { _ in .skip })
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "local")
        let kept = try await transfer.copy(sources: [source], to: root, resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(kept.count, 1)
        XCTAssertNotEqual(kept[0].path, target.path)
        XCTAssertEqual(try String(contentsOf: kept[0], encoding: .utf8), "cloud")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "local")
        _ = try await transfer.copy(sources: [source], to: root, resolveConflict: { _ in .replace })
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "cloud")
    }

    func testUploadReceiptsIncludeMaterialMarkersBeforeNextAuthorization() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("folder")
        try directory(source); try file(source.appendingPathComponent("child.txt"), "content")
        let cloud = MemoryGCS(), transfer = try service(cloud), recorder = UploadReceiptRecorder()
        _ = try await transfer.copy(sources: [source], to: remote(), resolveConflict: { _ in .cancel },
                                    authorize: { _, destination, _ in await recorder.authorize(destination) },
                                    onUploadConfirmed: { destination, object in await recorder.confirm(destination, object) })
        let receipts = await recorder.objects, events = await recorder.events
        XCTAssertEqual(Set(receipts.keys), [remote("folder/"), remote("folder/child.txt")])
        XCTAssertEqual(receipts[remote("folder/")]?.version, "1")
        XCTAssertTrue(receipts[remote("folder/")]?.isDirectory == true)
        XCTAssertEqual(receipts[remote("folder/child.txt")]?.size, 7)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "receipt:folder/")), try XCTUnwrap(events.firstIndex(of: "authorize:folder/child.txt")))
        let repeated = UploadReceiptRecorder()
        _ = try await transfer.copy(sources: [source], to: remote(), resolveConflict: { _ in .replace },
                                    onUploadConfirmed: { destination, object in await repeated.confirm(destination, object) })
        let merged = await repeated.objects
        XCTAssertNil(merged[remote("folder/")], "A merged directory is not a new PUT receipt")
        XCTAssertEqual(merged[remote("folder/child.txt")]?.version, "2")
    }

    func testUploadReceiptUsesOriginalResponseNotLaterHead() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("file.txt"); try file(source, "content")
        let cloud = MemoryGCS(), transfer = try service(cloud), recorder = UploadReceiptRecorder()
        await cloud.configureUploadResponse(cancel: false, replace: true)
        _ = try await transfer.copy(sources: [source], to: remote(), resolveConflict: { _ in .cancel },
                                    onUploadConfirmed: { destination, object in await recorder.confirm(destination, object) })
        let receipt = await recorder.objects[remote("file.txt")], generations = await cloud.generations()
        XCTAssertEqual(receipt?.version, "1")
        XCTAssertEqual(generations["file.txt"], 101)
    }

    func testCancellationAfterConfirmedPutStillRecordsReceiptAndCompletion() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try file(first, "one"); try file(second, "two")
        let cloud = MemoryGCS(), transfer = try service(cloud), recorder = UploadReceiptRecorder()
        await cloud.configureUploadResponse(cancel: true, replace: false)
        let task = Task {
            try await transfer.copy(sources: [first, second], to: self.remote(), resolveConflict: { _ in .cancel },
                                    onUploadConfirmed: { destination, object in await recorder.confirm(destination, object) })
        }
        await expect(.cancelled, completed: 1) { try await task.value }
        let receipts = await recorder.objects, stored = await cloud.snapshot()
        XCTAssertEqual(receipts[remote("first.txt")]?.version, "1")
        XCTAssertEqual(stored["first.txt"], Data("one".utf8))
        XCTAssertNil(stored["second.txt"])
        XCTAssertEqual(receipts.count, 1)
    }

    func testChangedRemoteSourceDuringConflictNeverPublishesNewGeneration() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let cloud = MemoryGCS(); await cloud.seed("report.txt", "observed", generation: 4)
        let transfer = try service(cloud), target = root.appendingPathComponent("report.txt")
        try file(target, "keep local")
        await expect(.conflictChanged) {
            try await transfer.copy(sources: [self.remote("report.txt")], to: root, resolveConflict: { _ in
                await cloud.seed("report.txt", "changed remotely", generation: 5)
                return .replace
            })
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep local")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["report.txt"])
    }

    func testChangedLocalDestinationIsPreservedAndDownloadStagingIsRemoved() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let cloud = MemoryGCS(); await cloud.seed("report.txt", "cloud replacement")
        let transfer = try service(cloud), target = root.appendingPathComponent("report.txt")
        try file(target, "observed")
        await expect(.conflictChanged) {
            try await transfer.copy(sources: [self.remote("report.txt")], to: root, resolveConflict: { conflict in
                do { try Data("concurrent local edit".utf8).write(to: conflict.destination) }
                catch { XCTFail("Fixture mutation failed: \(error)") }
                return .replace
            })
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "concurrent local edit")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["report.txt"])
        let after = await cloud.snapshot()
        XCTAssertEqual(after["report.txt"], Data("cloud replacement".utf8))
    }

    func testTraversalAndListingOutsideRequestedPrefixAreRejected() async throws {
        let root = try fixture(); defer { cleanup(root) }
        for maliciousKey in ["folder/../escape.txt", "outside/leak.txt", "folder/a\\b.txt", "folder/C:escape.txt"] {
            let destination = root.appendingPathComponent(UUID().uuidString)
            try directory(destination)
            let cloud = MemoryGCS()
            await cloud.seed(maliciousKey, "untrusted")
            await cloud.forceListing(keys: [maliciousKey])
            let transfer = try service(cloud)
            await expect(.unsafePath) { try await transfer.copy(sources: [self.remote("folder/")], to: destination, resolveConflict: { _ in .cancel }) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
        }
    }

    func testSymbolicLinkSourcesAndDestinationsAreRejected() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let real = root.appendingPathComponent("real.txt"), sourceLink = root.appendingPathComponent("link.txt")
        try file(real, "local")
        try FileManager.default.createSymbolicLink(atPath: sourceLink.path, withDestinationPath: real.path)
        let cloud = MemoryGCS(), transfer = try service(cloud)
        await expect(.unsupportedEntry) { try await transfer.copy(sources: [sourceLink], to: self.remote(), resolveConflict: { _ in .replace }) }
        let stored = await cloud.snapshot()
        XCTAssertTrue(stored.isEmpty)
        await cloud.seed("download.txt", "cloud")
        let destination = root.appendingPathComponent("destination")
        try directory(destination)
        let unsafeTarget = destination.appendingPathComponent("download.txt")
        try FileManager.default.createSymbolicLink(atPath: unsafeTarget.path, withDestinationPath: real.path)
        await expect(.unsafePath) { try await transfer.copy(sources: [self.remote("download.txt")], to: destination, resolveConflict: { _ in .replace }) }
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "local")
    }

    func testEntryAndDepthLimitsPreventUnboundedRecursion() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("folder")
        try directory(source.appendingPathComponent("nested/deeper"))
        try file(source.appendingPathComponent("a.txt"), "a")
        try file(source.appendingPathComponent("b.txt"), "b")
        let cloud = MemoryGCS()
        let entryLimited = try service(cloud, entries: 1)
        await expect(.limitExceeded) { try await entryLimited.copy(sources: [source], to: self.remote(), resolveConflict: { _ in .cancel }) }
        let depthLimited = try service(cloud, depth: 1)
        await expect(.limitExceeded) { try await depthLimited.copy(sources: [source], to: self.remote(), resolveConflict: { _ in .cancel }) }
        let stored = await cloud.snapshot()
        XCTAssertTrue(stored.isEmpty)
    }

    func testCancellationAfterFirstPublicationReportsPartialCompletionWithoutRollback() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let first = root.appendingPathComponent("a.txt"), second = root.appendingPathComponent("b.txt")
        try file(first, "first"); try file(second, "second")
        let cloud = MemoryGCS(); await cloud.seed("b.txt", "existing")
        let transfer = try service(cloud)
        await expect(.cancelled, completed: 1) {
            try await transfer.copy(sources: [first, second], to: self.remote(), resolveConflict: { _ in .cancel })
        }
        let after = await cloud.snapshot()
        XCTAssertEqual(after["a.txt"], Data("first".utf8))
        XCTAssertEqual(after["b.txt"], Data("existing".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}

private enum TransferAuthorizationFixture: Error { case denied }
private actor TransferAuthorizationGate {
    private var count = 0
    func allowFirstOnly() throws {
        count += 1
        if count > 1 { throw TransferAuthorizationFixture.denied }
    }
}

private final class TransferProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StorageTransferProgress] = []
    func record(_ value: StorageTransferProgress) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }
    func snapshot() -> [StorageTransferProgress] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// In-memory GCS JSON API, exercising the real provider and client without network access.
private actor MemoryGCS: CloudTransport {
    struct Stored { let data: Data; let generation: Int }
    struct Condition: Sendable { let key: String; let condition: String? }
    private var objects: [String: Stored] = [:]
    private var uploadConditions: [Condition] = []
    private var pageTokens: [String?] = []
    private var listingOverride: [String]?
    private var cancelConfirmedUpload = false
    private var replaceConfirmedUpload = false
    func configureUploadResponse(cancel: Bool, replace: Bool) { cancelConfirmedUpload = cancel; replaceConfirmedUpload = replace }
    func generations() -> [String: Int] { objects.mapValues(\.generation) }
    private let pageSize: Int
    init(pageSize: Int = 2) { self.pageSize = pageSize }
    func seed(_ key: String, _ text: String, generation: Int = 1) { objects[key] = Stored(data: Data(text.utf8), generation: generation) }
    func snapshot() -> [String: Data] { objects.mapValues(\.data) }
    func conditions() -> [Condition] { uploadConditions }
    func requestedPageTokens() -> [String?] { pageTokens }
    func forceListing(keys: [String]) { listingOverride = keys }

    func send(_ request: URLRequest) async throws -> CloudResponse {
        try Task.checkCancellation()
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, value in value })
        if let key = objectKey(components) {
            guard let object = objects[key] else { return CloudResponse(statusCode: 404) }
            return try json(metadata(key, object))
        }
        let prefix = query["prefix"] ?? "", token = query["pageToken"]
        pageTokens.append(token)
        let all = listingOverride ?? objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
        var prefixes = Set<String>(), keys: [String] = []
        for key in all {
            if listingOverride != nil { keys.append(key); continue }
            let suffix = String(key.dropFirst(prefix.count))
            if let slash = suffix.firstIndex(of: "/") {
                prefixes.insert(prefix + suffix[...slash])
            } else { keys.append(key) }
        }
        let rows = (prefixes.map { (true, $0) } + keys.map { (false, $0) }).sorted { $0.1 < $1.1 }
        let start = token.flatMap(Int.init) ?? 0
        guard start <= rows.count else { return CloudResponse(statusCode: 400) }
        let end = min(start + pageSize, rows.count), page = Array(rows[start..<end])
        var value: [String: Any] = ["kind": "storage#objects",
                                    "prefixes": page.filter(\.0).map(\.1),
                                    "items": page.filter { !$0.0 }.compactMap { key in objects[key.1].map { metadata(key.1, $0) } }]
        if end < rows.count { value["nextPageToken"] = String(end) }
        return try json(value)
    }

    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        try Task.checkCancellation()
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, value in value })
        guard request.httpMethod == "POST", let key = query["name"] else { return CloudResponse(statusCode: 400) }
        let condition = query["ifGenerationMatch"]
        uploadConditions.append(Condition(key: key, condition: condition))
        guard let condition else { return CloudResponse(statusCode: 412) }
        if condition == "0" {
            guard objects[key] == nil else { return CloudResponse(statusCode: 412) }
        } else {
            guard objects[key].map({ String($0.generation) == condition }) == true else { return CloudResponse(statusCode: 412) }
        }
        let data = try Data(contentsOf: fileURL)
        let object = Stored(data: data, generation: (objects[key]?.generation ?? 0) + 1)
        objects[key] = object
        if replaceConfirmedUpload { objects[key] = Stored(data: Data("concurrent".utf8), generation: object.generation + 100) }
        if cancelConfirmedUpload { withUnsafeCurrentTask { $0?.cancel() } }
        progress?(CloudTransferProgress(completedBytes: Int64(data.count), totalBytes: Int64(data.count)))
        return try json(metadata(key, object))
    }

    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        try Task.checkCancellation()
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        guard let key = objectKey(components), let object = objects[key] else { return CloudResponse(statusCode: 404) }
        guard components.queryItems?.contains(where: { $0.name == "alt" && $0.value == "media" }) == true else { return CloudResponse(statusCode: 400) }
        let expected = components.queryItems?.first { $0.name == "ifGenerationMatch" }?.value
        guard expected == String(object.generation) else { return CloudResponse(statusCode: 412) }
        try object.data.write(to: fileURL, options: .withoutOverwriting)
        progress?(CloudTransferProgress(completedBytes: Int64(object.data.count), totalBytes: Int64(object.data.count)))
        return CloudResponse(statusCode: 200, headers: ["Content-Length": String(object.data.count), "x-goog-generation": String(object.generation)])
    }
    private func objectKey(_ components: URLComponents) -> String? {
        guard let range = components.percentEncodedPath.range(of: "/o/") else { return nil }
        return String(components.percentEncodedPath[range.upperBound...]).removingPercentEncoding
    }
    private func metadata(_ key: String, _ object: Stored) -> [String: Any] {
        ["kind": "storage#object", "name": key, "size": String(object.data.count), "generation": String(object.generation),
         "updated": "2026-11-15T00:00:00Z"]
    }
    private func json(_ value: [String: Any]) throws -> CloudResponse {
        CloudResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: value))
    }
}

private actor UploadReceiptRecorder {
    var objects: [URL: CloudObject] = [:]
    var events: [String] = []
    func authorize(_ destination: URL) { events.append("authorize:" + (RemoteLocation.parse(destination)?.key ?? "")) }
    func confirm(_ destination: URL, _ object: CloudObject) {
        events.append("receipt:" + object.key)
        objects[destination] = object
    }
}
