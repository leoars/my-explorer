// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import ExplorerCore
@testable import ExplorerAutomation

final class SharedFilesTests: XCTestCase, @unchecked Sendable {
    func testFacadeCopiesShareMutationGateAcrossCopyEditAndDeletion() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination"), source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("fixture".utf8).write(to: source)
        let (service, _) = try files(), otherOwner = service, pause = SharedMutationPause()
        let operation = Task {
            try await service.copy([source], to: destination, resolveConflict: { _ in .cancel }, authorize: { _, _, _ in await pause.pauseOnce() })
        }
        await pause.waitUntilEntered()
        defer { Task { await pause.release() } }
        do { _ = try await otherOwner.rename(source, to: "changed.txt"); XCTFail("Concurrent edit accepted") }
        catch let error as AutomationError { XCTAssertEqual(error, .busy) }
        let deletion = StorageDeletionService(clientFactory: service.clientFactory)
        let plan = try await deletion.plan(sources: [source])
        do { _ = try await otherOwner.executeDeletion(planID: plan.id, using: deletion, authorizationCheck: { _ in true }); XCTFail("Concurrent deletion accepted") }
        catch let error as AutomationError { XCTAssertEqual(error, .busy) }
        // Reads remain usable while a mutation is suspended.
        let entries = try await otherOwner.list(root)
        XCTAssertTrue(entries.contains { $0.name == "source.txt" })
        await pause.release()
        let copied = try await operation.value
        XCTAssertEqual(copied.count, 1)
        _ = try await otherOwner.newFolder(in: root, name: "after")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("after").path))
        await deletion.discard(planID: plan.id)
    }
    func testMutationGateReleasesAfterFailureAndCancellation() async throws {
        let gate = SharedOperationGate()
        do { let _: Int = try await gate.run { throw AutomationError.forbidden }; XCTFail("Expected failure") }
        catch let error as AutomationError { XCTAssertEqual(error, .forbidden) }
        do { let _: Int = try await gate.run { throw CancellationError() }; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let result = try await gate.run { 42 }
        XCTAssertEqual(result, 42)
    }
    func testS3MoveValidatesWholeSelectionBeforeConnecting() async throws {
        let id = UUID()
        func object(_ key: String) -> URL { RemoteLocation.url(connectionID: id, key: key) }
        let target = object("Sub Pasta/")
        let service = SharedFileOperations { _ in
            XCTFail("Invalid drag reached the cloud client")
            throw CloudFailure(.io)
        }
        let first = object("clip.mov")
        for (source, reason): (URL, CloudFailure.Reason) in [
            (object("another/clip.mov"), .conflict),
            (object("Sub Pasta/existing.mov"), .conflict),
            (object("folder/"), .invalidKey),
            (RemoteLocation.url(connectionID: UUID(), key: "other.mov"), .invalidConfiguration)
        ] {
            let selection = [first, source]
            XCTAssertFalse(SharedFileOperations.canMoveS3Files(selection, to: target))
            do {
                _ = try await service.moveS3Files(selection, to: target)
                XCTFail("Invalid batch succeeded")
            } catch let error as CloudFailure { XCTAssertEqual(error.reason, reason) }
        }
        XCTAssertTrue(SharedFileOperations.canMoveS3Files([object("é.mov"), object("e\u{301}.mov")], to: target))
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.SharedFiles.\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func files(_ transport: SharedListTransport = SharedListTransport()) throws -> (SharedFileOperations, UUID) {
        let connection = CloudConnection(name: "Fixture", provider: .gcs, bucket: "fixture")
        let client = try CloudStorageClient(connection: connection, credentials: .init(accessToken: "fixture"), transport: transport)
        return (SharedFileOperations(clientFactory: { _ in client }), connection.id)
    }
    func testListingNormalizesPrefixAndRejectsSiblingAndNestedResults() async throws {
        let transport = SharedListTransport(keys: ["foo/item.txt"]), (service, id) = try files(transport)
        let entries = try await service.list(RemoteLocation.url(connectionID: id, key: "foo"))
        XCTAssertEqual(entries.map(\.name), ["item.txt"])
        let prefixes = await transport.prefixes
        XCTAssertEqual(prefixes, ["foo/"])
        for key in ["foobar/secret.txt", "foo/nested/secret.txt"] {
            let (invalid, invalidID) = try files(SharedListTransport(keys: [key]))
            do { _ = try await invalid.list(RemoteLocation.url(connectionID: invalidID, key: "foo")); XCTFail("Unsafe result accepted") }
            catch let error as AutomationError { XCTAssertEqual(error, .invalidArguments) }
        }
    }
    func testEmptyPagesHaveIndependentBound() async throws {
        let transport = SharedListTransport(endless: true), (service, id) = try files(transport)
        do { _ = try await service.list(RemoteLocation.url(connectionID: id)); XCTFail("Unbounded listing accepted") }
        catch let error as AutomationError { XCTAssertEqual(error, .limitExceeded) }
        let count = await transport.prefixes.count
        XCTAssertEqual(count, 10_001)
    }
    func testLocalConflictPreservesDestinationAndReportsCompletedFiles() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("second.txt"))
        let (service, _) = try files()
        do { _ = try await service.copy([first, second], to: destination, resolveConflict: { _ in .cancel }); XCTFail("Conflict accepted") }
        catch let error as SharedFileFailure {
            XCTAssertEqual(error.reason, .conflict)
            XCTAssertEqual(error.completed.map(\.lastPathComponent), ["first.txt"])
        }
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("second.txt"), encoding: .utf8), "keep")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), ["first.txt", "second.txt"])
    }
    func testLocalRevocationPreservesPartialResultsAndCleansStaging() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        let (service, _) = try files()
        do {
            _ = try await service.copy([first, second], to: destination, resolveConflict: { _ in .cancel }, authorize: { source, _, _ in
                if source == second { throw AutomationError.forbidden }
            }); XCTFail("Revocation ignored")
        } catch let error as SharedFileFailure {
            XCTAssertEqual(error.reason, .forbidden)
            XCTAssertEqual(error.completed.map(\.lastPathComponent), ["first.txt"])
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["first.txt"])
    }
    func testNewChildAfterInventoryCannotBePublished() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("planned".utf8).write(to: source.appendingPathComponent("planned.txt"))
        let (service, _) = try files(), gate = SharedCopyGate()
        do {
            _ = try await service.copy([source], to: destination, resolveConflict: { _ in .cancel }, authorize: { url, _, _ in
                if url == source, await gate.second() { try Data("unplanned".utf8).write(to: source.appendingPathComponent("new.txt")) }
            }); XCTFail("Unplanned child published")
        } catch let error as SharedFileFailure {
            XCTAssertEqual(error.reason, .changedPlan)
            XCTAssertTrue(error.completed.isEmpty)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
private actor SharedCopyGate {
    var count = 0
    func second() -> Bool { count += 1; return count == 2 }
}
private actor SharedMutationPause {
    private var entered = false
    private var released = false
    private var started: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func pauseOnce() async {
        guard !entered else { return }
        entered = true
        for waiter in started { waiter.resume() }; started.removeAll()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { started.append($0) } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor SharedListTransport: CloudTransport {
    let keys: [String]
    let endless: Bool
    var prefixes: [String] = []
    init(keys: [String] = [], endless: Bool = false) { self.keys = keys; self.endless = endless }
    func send(_ request: URLRequest) async throws -> CloudResponse {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        prefixes.append(query.first { $0.name == "prefix" }?.value ?? "")
        var result: [String: Any] = ["kind": "storage#objects", "items": keys.map { ["name": $0, "size": "1", "generation": "1"] }]
        if endless { result["nextPageToken"] = String(prefixes.count) }
        return CloudResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: result))
    }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
}
