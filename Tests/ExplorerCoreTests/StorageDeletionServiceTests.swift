// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ExplorerCore

final class StorageDeletionServiceTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-tests-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func local(_ trash: RecordingTrash = .init(), clock: @escaping @Sendable () -> Date = { Date() },
                       limits: StorageDeletionService.Limits = .init()) -> StorageDeletionService {
        StorageDeletionService(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) }, trash: trash, clock: clock, limits: limits)
    }
    private func expect(_ reason: StorageDeletionFailure.Reason, _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected \(reason)") }
        catch let failure as StorageDeletionFailure { XCTAssertEqual(failure.reason, reason) }
        catch { XCTFail("Unexpected \(error)") }
    }
    func testLocalPlanRequiresRecursionAndAuthorizesEveryDescendant() async throws {
        let directory = try fixture().appendingPathComponent("pasta 日本")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("vazia"), withIntermediateDirectories: true)
        try Data("text".utf8).write(to: directory.appendingPathComponent("á.txt"))
        let trash = RecordingTrash(); let service = local(trash); let authorized = URLRecorder()
        await expect(.recursiveRequired) { _ = try await service.plan(sources: [directory]) }
        let plan = try await service.plan(sources: [directory], recursive: true)
        XCTAssertEqual(plan.itemCount, 3); XCTAssertEqual(plan.schemaVersion, 1)
        let result = try await service.execute(planID: plan.id) { await authorized.add($0); return true }
        XCTAssertEqual(result.completed.map(\.path), [directory.path])
        let checks = await authorized.values; XCTAssertEqual(Set(checks).count, 3)
        let trashed = await trash.values; XCTAssertEqual(trashed.map(\.path), [directory.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "Injected Trash never touches real Trash")
    }
    func testPreviewTamperCannotReplaceStoredSnapshotAndPlanCannotReplay() async throws {
        let root = try fixture(); let file = root.appendingPathComponent("a"); try Data().write(to: file)
        let service = local(); let plan = try await service.plan(sources: [file])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
        json["sources"] = ["file:///"]; json["itemCount"] = 999
        let tampered = try JSONDecoder().decode(StorageDeletionPlan.self, from: JSONSerialization.data(withJSONObject: json))
        let result = try await service.execute(planID: tampered.id) { _ in true }
        XCTAssertEqual(result.completed, [file])
        await expect(.reusedPlan) { _ = try await service.execute(planID: plan.id) { _ in true } }
        await expect(.invalidPlan) { _ = try await service.execute(planID: UUID()) { _ in true } }
    }
    func testExpiredPlanAndConcurrentSingleUse() async throws {
        let file = try fixture().appendingPathComponent("a"); try Data().write(to: file)
        let clock = DeletionClock(); let service = local(clock: { clock.now() })
        let expired = try await service.plan(sources: [file]); clock.advance(301)
        await expect(.expiredPlan) { _ = try await service.execute(planID: expired.id) { _ in true } }
        let plan = try await service.plan(sources: [file]); let gate = DeletionGate()
        let first = Task { try await service.execute(planID: plan.id) { _ in await gate.wait(); return true } }
        await gate.started()
        await expect(.reusedPlan) { _ = try await service.execute(planID: plan.id) { _ in true } }
        await gate.release(); _ = try await first.value
    }
    func testNewChildAndChangedFileAbortBeforeTrash() async throws {
        let directory = try fixture(); let trash = RecordingTrash(); let service = local(trash)
        let plan = try await service.plan(sources: [directory], recursive: true)
        try Data().write(to: directory.appendingPathComponent("new"))
        await expect(.changed) { _ = try await service.execute(planID: plan.id) { _ in true } }
        let file = directory.appendingPathComponent("new"); let second = try await service.plan(sources: [file])
        try Data("changed".utf8).write(to: file)
        await expect(.changed) { _ = try await service.execute(planID: second.id) { _ in true } }
        let values = await trash.values; XCTAssertTrue(values.isEmpty)
    }
    func testAncestorSubstitutionAndSymlinkRefused() async throws {
        let root = try fixture(); let directory = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("file"); try Data().write(to: file)
        let service = local(); let plan = try await service.plan(sources: [file])
        let moved = root.appendingPathComponent("moved"); try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        await expect(.unsafePath) { _ = try await service.execute(planID: plan.id) { _ in true } }
        await expect(.unsafePath) { _ = try await service.plan(sources: [file]) }
        await expect(.unsupportedEntry) { _ = try await service.plan(sources: [directory], recursive: true) }
        await expect(.unsafePath) { _ = try await service.plan(sources: [URL(fileURLWithPath: "/")], recursive: true) }
    }
    func testManySelectedItemsPlanQuicklyWithTheirOwnLimitAndReportProgress() async throws {
        let root = try fixture()
        let files = (0..<12_000).map { root.appendingPathComponent("f\($0).opus") }
        for file in files { XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil)) }
        let trash = RecordingTrash(); let service = local(trash)
        await expect(.limitExceeded) { _ = try await service.plan(sources: files) }
        let start = Date()
        let plan = try await service.plan(sources: files, entryLimit: 20_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "Planning must not compare every item with every other")
        XCTAssertEqual(plan.itemCount, files.count)
        let reports = CountRecorder()
        let result = try await service.execute(planID: plan.id, progress: { done, total in await reports.add(done, total) }) { _ in true }
        XCTAssertEqual(result.completed.count, files.count)
        let seen = await reports.values
        XCTAssertEqual(seen.count, files.count); XCTAssertEqual(seen.last?.0, files.count)
        XCTAssertTrue(seen.allSatisfy { $0.1 == files.count })
        await expect(.limitExceeded) { _ = try await service.plan(sources: Array(files.prefix(3)), entryLimit: 2) }
    }
    func testConcurrentTrashKeepsSameNamesApartAndStopsAfterAFailure() async throws {
        let root = try fixture()
        var files: [URL] = []
        for folder in 0..<6 {
            let directory = root.appendingPathComponent("d\(folder)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in [folder.isMultiple(of: 2) ? "Same.txt" : "SAME.txt", "other\(folder).txt"] {
                let file = directory.appendingPathComponent(name)
                try Data().write(to: file)
                files.append(file)
            }
        }
        let watcher = ConcurrencyTrash(refuse: nil)
        let service = StorageDeletionService(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) }, trash: watcher)
        let plan = try await service.plan(sources: files)
        let journal = LocalTransferService()
        let result = try await service.execute(planID: plan.id, undoHistory: journal) { _ in true }
        XCTAssertEqual(result.completed.count, plan.itemCount)
        let clash = await watcher.sameNameAtOnce, peak = await watcher.peak
        XCTAssertFalse(clash, "Two items of the same name went to the Trash at once")
        XCTAssertGreaterThan(peak, 1, "Items should go to the Trash several at a time")
        _ = try await journal.undo()
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "One undo restores the whole deletion")

        let refused = root.appendingPathComponent("refused"); try Data().write(to: refused)
        let many = (0..<40).map { root.appendingPathComponent("m\($0)") }
        for file in many { try Data().write(to: file) }
        let failing = ConcurrencyTrash(refuse: "refused")
        let second = StorageDeletionService(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) }, trash: failing)
        let all = [refused] + many
        let failingPlan = try await second.plan(sources: all)
        do { _ = try await second.execute(planID: failingPlan.id) { _ in true }; XCTFail("Expected a failure") }
        catch let failure as StorageDeletionFailure {
            let gone = all.filter { !FileManager.default.fileExists(atPath: $0.path) }
            XCTAssertEqual(Set(failure.completed), Set(gone), "Every item reported gone is gone, and only those")
            XCTAssertLessThan(gone.count, many.count, "Nothing new starts after the failure")
        }
    }
    func testOverlapIsFoundInEitherOrderAndForRepeatedItems() async throws {
        let root = try fixture(); let inner = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let file = inner.appendingPathComponent("c"); try Data().write(to: file)
        let sibling = root.appendingPathComponent("a b"); try Data().write(to: sibling)
        let service = local()
        let outer = root.appendingPathComponent("a")
        await expect(.unsafePath) { _ = try await service.plan(sources: [file, outer], recursive: true) }
        await expect(.unsafePath) { _ = try await service.plan(sources: [outer, file], recursive: true) }
        await expect(.unsafePath) { _ = try await service.plan(sources: [file, file]) }
        let fine = try await service.plan(sources: [inner, sibling], recursive: true)
        XCTAssertEqual(fine.itemCount, 3)
    }
    func testLimitsOverlapAndRevocationCoverSubtree() async throws {
        let directory = try fixture(); let file = directory.appendingPathComponent("a"); try Data().write(to: file)
        await expect(.limitExceeded) { _ = try await self.local(limits: .init(entries: 1)).plan(sources: [directory], recursive: true) }
        await expect(.limitExceeded) { _ = try await self.local(limits: .init(depth: 0)).plan(sources: [directory], recursive: true) }
        let trash = RecordingTrash(); let service = local(trash)
        await expect(.unsafePath) { _ = try await service.plan(sources: [directory, file], recursive: true) }
        let plan = try await service.plan(sources: [directory], recursive: true)
        await expect(.notAuthorized) { _ = try await service.execute(planID: plan.id) { $0 != file } }
        let second = try await service.plan(sources: [file])
        await expect(.notAuthorized) { _ = try await service.execute(planID: second.id) { _ in await service.discard(planID: second.id); return true } }
        let values = await trash.values; XCTAssertTrue(values.isEmpty)
    }
    func testCancelledPlanAndExecuteDoNotMutate() async throws {
        let file = try fixture().appendingPathComponent("a"); try Data().write(to: file)
        let trash = RecordingTrash(); let service = local(trash)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await service.plan(sources: [file]) }
        await expect(.cancelled) { _ = try await task.value }
        let plan = try await service.plan(sources: [file])
        let execute = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await service.execute(planID: plan.id) { _ in true } }
        await expect(.cancelled) { _ = try await execute.value }
        let values = await trash.values; XCTAssertTrue(values.isEmpty)
    }
    func testCloudFolderSnapshotsPaginationAndNoSiblingDeletion() async throws {
        let transport = DeletionGCS(["pasta/": "1", "pasta/日本.txt": "2", "pasta/sub/empty/": "3", "pastax/safe": "4"])
        let (service, id) = try remote(transport)
        let source = RemoteLocation.url(connectionID: id, key: "pasta/")
        let plan = try await service.plan(sources: [source], recursive: true)
        XCTAssertEqual(plan.itemCount, 3)
        let result = try await service.execute(planID: plan.id) { _ in true }
        XCTAssertEqual(result.completed.count, 3)
        let entries = await transport.entries; XCTAssertEqual(entries, ["pastax/safe": "4"])
        let deletes = await transport.deletes; XCTAssertEqual(deletes.map(\.1).sorted(), ["1", "2", "3"])
    }
    func testExpectedRemoteVersionsRequireExactMaterialInventory() async throws {
        let transport = DeletionGCS(["folder/": "1", "folder/file": "2", "folder/virtual/child": "3"])
        let (service, id) = try remote(transport)
        func url(_ key: String) -> URL { RemoteLocation.url(connectionID: id, key: key) }
        let expected = [url("folder/"): "1", url("folder/file"): "2", url("folder/virtual/child"): "3"]
        var missing = expected; missing.removeValue(forKey: url("folder/file"))
        var extra = expected; extra[url("folder/extra")] = "4"
        var virtual = expected; virtual[url("folder/virtual/")] = "5"
        var changedMarker = expected; changedMarker[url("folder/")] = "old"
        var otherConnection = expected
        otherConnection.removeValue(forKey: url("folder/file"))
        otherConnection[RemoteLocation.url(connectionID: UUID(), key: "folder/file")] = "2"
        for mapping in [[:], missing, extra, virtual, changedMarker, otherConnection] {
            await expect(.changed) { _ = try await service.plan(sources: [url("folder/")], recursive: true, expectedRemoteVersions: mapping) }
        }
        await expect(.unsafePath) {
            _ = try await service.plan(sources: [url("folder/")], recursive: true, expectedRemoteVersions: [URL(fileURLWithPath: "/fixture"): "1"])
        }
        let plan = try await service.plan(sources: [url("folder/")], recursive: true, expectedRemoteVersions: expected)
        XCTAssertEqual(plan.itemCount, 3)
        let result = try await service.execute(planID: plan.id) { _ in true }
        XCTAssertEqual(Set(result.completed), Set(expected.keys))
    }

    func testExpectedRemoteVersionsRejectChangeBeforePlanAndStillRecheckAtExecute() async throws {
        let transport = DeletionGCS(["file": "2"]), original = "1"
        let (service, id) = try remote(transport)
        let source = RemoteLocation.url(connectionID: id, key: "file")
        await expect(.changed) { _ = try await service.plan(sources: [source], expectedRemoteVersions: [source: original]) }
        let plan = try await service.plan(sources: [source], expectedRemoteVersions: [source: "2"])
        await transport.set("file", "3")
        await expect(.changed) { _ = try await service.execute(planID: plan.id) { _ in true } }
        let deletes = await transport.deletes, entries = await transport.entries
        XCTAssertTrue(deletes.isEmpty)
        XCTAssertEqual(entries, ["file": "3"])
    }

    func testCloudNewChildrenVersionChangeAndAbsentAreNotDeleted() async throws {
        let transport = DeletionGCS(["folder/a": "1"]); let (service, id) = try remote(transport)
        let folder = RemoteLocation.url(connectionID: id, key: "folder/")
        let first = try await service.plan(sources: [folder], recursive: true)
        await transport.set("folder/new", "2")
        await expect(.changed) { _ = try await service.execute(planID: first.id) { _ in true } }
        let file = RemoteLocation.url(connectionID: id, key: "folder/a")
        let second = try await service.plan(sources: [file]); await transport.set("folder/a", "3")
        await expect(.changed) { _ = try await service.execute(planID: second.id) { _ in true } }
        let third = try await service.plan(sources: [file])
        await expect(.changed) { _ = try await service.execute(planID: third.id) { _ in await transport.set("folder/a", "4"); return true } }
        let fourth = try await service.plan(sources: [file])
        await expect(.notFound) { _ = try await service.execute(planID: fourth.id) { _ in await transport.set("folder/a", nil); return true } }
        let remaining = await transport.entries; XCTAssertEqual(remaining["folder/new"], "2")
    }
    func testCloudPartialRevocationAndIndeterminateTimeoutPreserveCompleted() async throws {
        let transport = DeletionGCS(["a": "1", "b": "2"]); let (service, id) = try remote(transport)
        let a = RemoteLocation.url(connectionID: id, key: "a"), b = RemoteLocation.url(connectionID: id, key: "b")
        let plan = try await service.plan(sources: [a,b])
        do { _ = try await service.execute(planID: plan.id) { $0 == a }; XCTFail() }
        catch let error as StorageDeletionFailure { XCTAssertEqual(error.reason, .notAuthorized); XCTAssertEqual(error.completed, [a]) }
        let second = try await service.plan(sources: [b]); await transport.timeoutDelete(true)
        do { _ = try await service.execute(planID: second.id) { _ in true }; XCTFail() }
        catch let error as StorageDeletionFailure { XCTAssertEqual(error.reason, .indeterminate); XCTAssertEqual(error.indeterminate, [b]); XCTAssertTrue(error.completed.isEmpty) }
        let entries = await transport.entries; XCTAssertTrue(entries.isEmpty, "Timeout may follow successful server deletion")
    }
    func testCloudCancellationAfterAcknowledgementReportsPartialAndNoRollback() async throws {
        let transport = DeletionGCS(["a": "1", "b": "2"]); let (service, id) = try remote(transport)
        let a = RemoteLocation.url(connectionID: id, key: "a"), b = RemoteLocation.url(connectionID: id, key: "b")
        let plan = try await service.plan(sources: [a,b]); await transport.cancelAfterDelete(true)
        let task = Task { try await service.execute(planID: plan.id) { _ in true } }
        do { _ = try await task.value; XCTFail() }
        catch let error as StorageDeletionFailure { XCTAssertEqual(error.reason, .cancelled); XCTAssertEqual(error.completed, [a]) }
        let entries = await transport.entries; XCTAssertEqual(entries, ["b": "2"])
    }
    func testRemoteTraversalAndRootRefused() async throws {
        let transport = DeletionGCS(["safe/../outside": "1"]); let (service, id) = try remote(transport)
        await expect(.unsafePath) { _ = try await service.plan(sources: [RemoteLocation.url(connectionID: id)], recursive: true) }
        await expect(.unsafePath) { _ = try await service.plan(sources: [RemoteLocation.url(connectionID: id, key: "safe/")], recursive: true) }
    }
    func testInfiniteEmptyPagesAreBoundedAndRevocationDuringCallbackIsRechecked() async throws {
        let transport = DeletionGCS([:]); await transport.emptyPages(true)
        let connection = CloudConnection(name: "Test", provider: .gcs, bucket: "test-bucket")
        let client = try CloudStorageClient(connection: connection, credentials: .init(accessToken: "test"), transport: transport)
        let service = StorageDeletionService(clientFactory: { _ in client }, limits: .init(entries: 3))
        await expect(.limitExceeded) { _ = try await service.plan(sources: [RemoteLocation.url(connectionID: connection.id, key: "folder/")], recursive: true) }
        let directory = try fixture(); let file = directory.appendingPathComponent("a"); try Data().write(to: file)
        let localService = local(); let plan = try await localService.plan(sources: [directory], recursive: true)
        let counter = DeletionCounter()
        await expect(.notAuthorized) {
            _ = try await localService.execute(planID: plan.id) { _ in await counter.next() <= 2 }
        }
    }
    func testCloudFinalRelistDetectsConcurrentNewChildWithoutDeletingIt() async throws {
        let transport = DeletionGCS(["folder/a": "1"]); let (service, id) = try remote(transport)
        let plan = try await service.plan(sources: [RemoteLocation.url(connectionID: id, key: "folder/")], recursive: true)
        do {
            _ = try await service.execute(planID: plan.id) { _ in await transport.set("folder/new", "2"); return true }
            XCTFail()
        } catch let error as StorageDeletionFailure {
            XCTAssertEqual(error.reason, .changed); XCTAssertEqual(error.completed.count, 1)
        }
        let remaining = await transport.entries; XCTAssertEqual(remaining, ["folder/new": "2"])
    }

    func testLocalAuthorizationMutationIsRejectedAndTrashFailureHasNoFallback() async throws {
        let file = try fixture().appendingPathComponent("a"); try Data("original".utf8).write(to: file)
        let trash = RecordingTrash(); let service = local(trash)
        let plan = try await service.plan(sources: [file])
        await expect(.changed) {
            _ = try await service.execute(planID: plan.id) { _ in try? Data("edited".utf8).write(to: file); return true }
        }
        let values = await trash.values; XCTAssertTrue(values.isEmpty)
        let failing = StorageDeletionService(clientFactory: { _ in throw CloudFailure(.io) }, trash: FailingTrash())
        let second = try await failing.plan(sources: [file])
        await expect(.io) { _ = try await failing.execute(planID: second.id) { _ in true } }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "edited")
    }
    func testChangedConnectionMetadataCannotReuseRemotePlan() async throws {
        let transport = DeletionGCS(["a": "1"])
        let connection = CloudConnection(name: "Test", provider: .gcs, bucket: "first-bucket")
        let factory = DeletionFactory(connection: connection, transport: transport)
        let service = StorageDeletionService(clientFactory: { _ in try await factory.client() })
        let plan = try await service.plan(sources: [RemoteLocation.url(connectionID: connection.id, key: "a")])
        await factory.changeBucket()
        await expect(.changed) { _ = try await service.execute(planID: plan.id) { _ in true } }
        let deletes = await transport.deletes; XCTAssertTrue(deletes.isEmpty)
    }

    private func remote(_ transport: DeletionGCS) throws -> (StorageDeletionService, UUID) {
        let connection = CloudConnection(name: "Test", provider: .gcs, bucket: "test-bucket")
        let client = try CloudStorageClient(connection: connection, credentials: .init(accessToken: "test"), transport: transport)
        return (StorageDeletionService(clientFactory: { _ in client }, trash: RecordingTrash()), connection.id)
    }
}
private actor DeletionCounter { var value = 0; func next() -> Int { value += 1; return value } }
private actor RecordingTrash: StorageTrash {
    var values: [URL] = []
    func trash(_ url: URL) { values.append(url) }
}
private actor URLRecorder { var values: [URL] = []; func add(_ url: URL) { values.append(url) } }
private final class DeletionClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}
private actor DeletionGate {
    var continuation: CheckedContinuation<Void,Never>?
    var waiting = false, released = false
    func wait() async { if released { return }; waiting = true; await withCheckedContinuation { continuation = $0 } }
    func started() async { while !waiting { await Task.yield() } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor DeletionGCS: CloudTransport {
    var entries: [String: String]
    var deletes: [(String,String)] = []
    var timeout = false, cancel = false, endless = false
    init(_ entries: [String: String]) { self.entries = entries }
    func set(_ key: String, _ version: String?) { entries[key] = version }
    func emptyPages(_ value: Bool) { endless = value }
    func timeoutDelete(_ value: Bool) { timeout = value }
    func cancelAfterDelete(_ value: Bool) { cancel = value }
    func send(_ request: URLRequest) async throws -> CloudResponse {
        let url = request.url!, parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let path = parts.percentEncodedPath
        let marker = "/o/"
        if let range = path.range(of: marker) {
            let key = String(path[range.upperBound...]).removingPercentEncoding!
            if request.httpMethod == "DELETE" {
                guard let observed = query["ifGenerationMatch"] else { return .init(statusCode: 400) }
                deletes.append((key, observed))
                guard let actual = entries[key] else { return .init(statusCode: 404) }
                guard actual == observed else { return .init(statusCode: 412) }
                entries.removeValue(forKey: key)
                if timeout { throw URLError(.timedOut) }
                if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                return .init(statusCode: 204)
            }
            guard let version = entries[key] else { return .init(statusCode: 404) }
            return try json(["name": key, "generation": version, "size": "0"])
        }
        if endless { return try json(["kind": "storage#objects", "nextPageToken": String((Int(query["pageToken"] ?? "0") ?? 0) + 1)]) }
        let prefix = query["prefix"] ?? ""
        var items: [[String: String]] = []; var prefixes: Set<String> = []
        for key in entries.keys.sorted() where key.hasPrefix(prefix) {
            let relative = String(key.dropFirst(prefix.count))
            if let slash = relative.firstIndex(of: "/"), relative != "" {
                prefixes.insert(prefix + String(relative[...slash]))
            } else { items.append(["name": key, "generation": entries[key]!, "size": "0"]) }
        }
        // One entry per page exercises continuations including prefix-only pages.
        let records: [(Bool, String)] = items.map { (false, $0["name"]!) } + prefixes.sorted().map { (true, $0) }
        let offset = Int(query["pageToken"] ?? "0") ?? 0
        var body: [String: Any] = ["kind": "storage#objects"]
        if offset < records.count {
            let record = records[offset]
            if record.0 { body["prefixes"] = [record.1] }
            else { body["items"] = [["name": record.1, "generation": entries[record.1]!, "size": "0"]] }
        }
        if offset + 1 < records.count { body["nextPageToken"] = String(offset + 1) }
        return try json(body)
    }
    private func json(_ value: [String: Any]) throws -> CloudResponse { .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: value)) }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
}

private struct FailingTrash: StorageTrash {
    func trash(_ url: URL) async throws { throw CocoaError(.fileWriteNoPermission) }
}
private actor DeletionFactory {
    var connection: CloudConnection
    let transport: DeletionGCS
    init(connection: CloudConnection, transport: DeletionGCS) { self.connection = connection; self.transport = transport }
    func changeBucket() { connection.bucket = "second-bucket" }
    func client() throws -> CloudStorageClient { try .init(connection: connection, credentials: .init(accessToken: "test"), transport: transport) }
}

private actor CountRecorder {
    var values: [(Int, Int)] = []
    func add(_ done: Int, _ total: Int) { values.append((done, total)) }
}

/// Moves items into a folder, slowly, noting how many go at once and whether two share a name.
private actor ConcurrencyTrash: StorageTrash {
    let refuse: String?
    private var names: [String] = []
    private(set) var peak = 0
    private(set) var sameNameAtOnce = false
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("concurrency-trash-\(UUID())")
    init(refuse: String?) { self.refuse = refuse }
    func trash(_ url: URL) async throws { _ = try await trashReturningURL(url) }
    func trashReturningURL(_ url: URL) async throws -> URL? {
        let name = url.lastPathComponent.lowercased()
        if names.contains(name) { sameNameAtOnce = true }
        names.append(name); peak = max(peak, names.count)
        defer { names.remove(at: names.firstIndex(of: name)!) }
        try await Task.sleep(for: .milliseconds(5))
        if url.lastPathComponent == refuse { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
