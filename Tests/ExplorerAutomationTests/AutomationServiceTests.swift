// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerAutomation
import ExplorerCore

final class AutomationServiceTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL
        let allowed: URL
        let destination: URL
        let stateURL: URL
        let source: URL
        let service: AutomationService
        let environment: ServiceTestEnvironment
        let transport: ServiceTestCloudTransport
        let connection: CloudConnection
        let files: SharedFileOperations
        let trash: ServiceTestTrash
        let grant: AutomationGrant
        let token = "AUTOMATION-TEST-TOKEN-NOT-FOR-OUTPUT"
        func call(_ method: String, _ args: [String: JSONValue] = [:]) async -> AutomationResponse {
            await service.handle(.init(method: method, arguments: .object(args), clientID: grant.id.uuidString, token: token))
        }
        func plan(_ source: URL? = nil) async -> AutomationResponse {
            await call("transfers.plan", ["sources": .array([.string((source ?? self.source).absoluteString)]), "destination": .string(destination.absoluteString)])
        }
        func start(_ plan: String, key: String = "first") async -> AutomationResponse {
            await call("transfers.start", ["planID": .string(plan), "idempotencyKey": .string(key)])
        }
    }
    private func fixture(operations: Set<String> = ["read", "copy", "trash", "configure", "preferences"], expires: Date = Date().addingTimeInterval(60)) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("automation-tests-\(UUID())").resolvingSymlinksInPath()
        let allowed = root.appendingPathComponent("allowed"), destination = allowed.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = allowed.appendingPathComponent("source 日本.txt")
        try Data("original fixture".utf8).write(to: source)
        let connection = CloudConnection(name: "fixture", provider: .s3, bucket: "fixture-bucket", region: "us-east-1")
        let transport = ServiceTestCloudTransport()
        let client = try CloudStorageClient(connection: connection, credentials: .init(accessKeyID: "FAKEACCESS", secretAccessKey: "CLOUD-SECRET-NOT-FOR-OUTPUT"), transport: transport)
        let files = SharedFileOperations(clientFactory: { id in
            guard id == connection.id else { throw CloudFailure(.invalidConfiguration) }; return client
        })
        let environment = ServiceTestEnvironment(connection: connection)
        let trash = ServiceTestTrash()
        let deletion = StorageDeletionService(clientFactory: files.clientFactory, trash: trash)
        let stateURL = root.appendingPathComponent("state/state.json")
        let service = try AutomationService(files: files, deletion: deletion, environment: environment.adapter, stateURL: stateURL)
        let grant = AutomationGrant(name: "test", token: "AUTOMATION-TEST-TOKEN-NOT-FOR-OUTPUT", expires: expires, operations: operations, localRoots: [allowed.path], cloudScopes: [.init(connectionID: connection.id, prefix: "allowed")], recursive: true)
        try await service.setEnabled(true); try await service.grant(grant)
        addTeardownBlock {
            await environment.resumeRevision()
            await service.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, allowed: allowed, destination: destination, stateURL: stateURL, source: source, service: service, environment: environment, transport: transport, connection: connection, files: files, trash: trash, grant: grant)
    }
    private func value(_ response: AutomationResponse, _ field: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        XCTAssertTrue(response.ok, response.error ?? "failure", file: file, line: line)
        return try XCTUnwrap(response.result?[field]?.stringValue, file: file, line: line)
    }
    private func terminal(_ fixture: Fixture, jobID: String, method: String = "transfers.status") async throws -> JSONValue {
        for _ in 0..<500 {
            let response = await fixture.call(method, ["jobID": .string(jobID)])
            let state = try value(response, "state")
            if !["queued", "running"].contains(state) { return try XCTUnwrap(response.result) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Job did not complete"); throw AutomationError.busy
    }
    func testMissingWrongRevokedAndDisabledGrantsDenyRequests() async throws {
        let f = try await fixture()
        let missing = await f.service.handle(.init(method: "connections.list"))
        XCTAssertEqual(missing.error, "unauthenticated")
        let wrong = await f.service.handle(.init(method: "connections.list", clientID: f.grant.id.uuidString, token: "wrong"))
        XCTAssertEqual(wrong.error, "unauthenticated")
        try await f.service.revoke(f.grant.id)
        let revoked = await f.call("connections.list"); XCTAssertEqual(revoked.error, "unauthenticated")
        try await f.service.setEnabled(false)
        let disabled = await f.call("connections.list"); XCTAssertEqual(disabled.error, "disabled")
        let capabilities = await f.service.handle(.init(method: "capabilities.get"))
        XCTAssertTrue(capabilities.ok); XCTAssertEqual(capabilities.result?["enabled"], .bool(false))
    }
    func testMissingOperationPermissionAndRevokedPlanCannotMutate() async throws {
        let readOnly = try await fixture(operations: ["read"])
        let copyDenied = await readOnly.plan(); XCTAssertEqual(copyDenied.error, "forbidden")
        let deletionDenied = await readOnly.call("deletions.plan", ["sources": .array([.string(readOnly.source.absoluteString)])])
        XCTAssertEqual(deletionDenied.error, "forbidden")
        let writable = try await fixture()
        let plan = try value(await writable.plan(), "planID")
        try await writable.service.revoke(writable.grant.id)
        let startDenied = await writable.start(plan); XCTAssertEqual(startDenied.error, "unauthenticated")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: writable.destination.path).isEmpty)
    }
    func testPersistenceFailureDoesNotDispatchOrConsumeTransferPlan() async throws {
        let f = try await fixture()
        let plan = try value(await f.plan(), "planID")
        let directory = f.stateURL.deletingLastPathComponent(), backup = f.root.appendingPathComponent("state-backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("not a directory".utf8).write(to: directory)
        let failed = await f.start(plan, key: "durable-start")
        XCTAssertFalse(failed.ok)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        let retried = try value(await f.start(plan, key: "durable-start"), "id")
        let result = try await terminal(f, jobID: retried)
        XCTAssertEqual(result["state"], .string("succeeded"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).count, 1)
    }
    func testPersistenceFailureCannotExpandGrantOrEnableAutomation() async throws {
        let f = try await fixture(operations: ["read"])
        try await f.service.setEnabled(false)
        let directory = f.stateURL.deletingLastPathComponent(), backup = f.root.appendingPathComponent("state-backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("not a directory".utf8).write(to: directory)
        var expanded = f.grant; expanded.operations.insert("copy")
        do { try await f.service.grant(expanded); XCTFail("Persistence failure must reject grant update") } catch {}
        let grants = await f.service.grants()
        XCTAssertEqual(grants.first?.operations, ["read"])
        do { try await f.service.setEnabled(true); XCTFail("Persistence failure must reject enabling") } catch {}
        let enabled = await f.service.isEnabled(); XCTAssertFalse(enabled)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
    }
    func testExpiredGrantCannotAuthenticate() async throws {
        let f = try await fixture(expires: Date().addingTimeInterval(0.25))
        try await Task.sleep(for: .milliseconds(300))
        let response = await f.call("connections.list")
        XCTAssertEqual(response.error, "unauthenticated")
    }
    func testLocalRootBoundaryAndSymlinkEscapeAreDenied() async throws {
        let f = try await fixture()
        let outside = f.root.appendingPathComponent("allowed-outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        let link = f.allowed.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for url in [outside, link, link.appendingPathComponent("secret.txt")] {
            let denied = await f.call("locations.list", ["url": .string(url.absoluteString)])
            XCTAssertEqual(denied.error, "forbidden")
        }
        let listing = await f.call("locations.list", ["url": .string(f.allowed.absoluteString)])
        XCTAssertTrue(listing.ok)
        XCTAssertFalse(listing.result?["entries"]?.arrayValue?.contains(where: { $0["name"] == .string("escape") }) ?? true)
        let copy = await f.plan(link.appendingPathComponent("secret.txt")); XCTAssertEqual(copy.error, "forbidden")
    }
    func testCloudScopeUsesConnectionAndPrefixBoundaries() async throws {
        let f = try await fixture()
        for key in ["", "outside/", "allowed-evil/"] {
            let url = RemoteLocation.url(connectionID: f.connection.id, key: key)
            let result = await f.call("locations.list", ["url": .string(url.absoluteString)])
            XCTAssertEqual(result.error, "forbidden")
        }
        let wrong = RemoteLocation.url(connectionID: UUID(), key: "allowed/")
        let denied = await f.call("locations.list", ["url": .string(wrong.absoluteString)]); XCTAssertEqual(denied.error, "forbidden")
        let permitted = RemoteLocation.url(connectionID: f.connection.id, key: "allowed/")
        let allowed = await f.call("locations.list", ["url": .string(permitted.absoluteString)])
        XCTAssertTrue(allowed.ok)
        let requests = await f.transport.requests
        XCTAssertEqual(requests.count, 1, "Denied paths must never reach the provider")
    }
    func testLocalCopyJobIsIdempotentAndPlanIsSingleUse() async throws {
        let f = try await fixture()
        let plan = try value(await f.plan(), "planID")
        let job = try value(await f.start(plan), "id")
        let result = try await terminal(f, jobID: job)
        XCTAssertEqual(result["state"], .string("succeeded"))
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent(f.source.lastPathComponent)), Data("original fixture".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        let replay = try value(await f.start(plan), "id"); XCTAssertEqual(replay, job)
        let different = await f.start(plan, key: "different"); XCTAssertEqual(different.error, "notFound")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.destination.path), [f.source.lastPathComponent])
        let nextPlan = try value(await f.plan(), "planID")
        let reuseKey = await f.start(nextPlan); XCTAssertEqual(reuseKey.error, "conflict")
    }
    func testRecursiveLocalFolderCopyPreservesUnicodeNestedAndEmptyFolders() async throws {
        let f = try await fixture()
        let source = f.allowed.appendingPathComponent("Pasta 日本 ç", isDirectory: true)
        let nested = source.appendingPathComponent("nível 한글", isDirectory: true)
        let empty = nested.appendingPathComponent("vazia 空", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let filename = "conteúdo 😀.txt"
        let bytes = Data("nested Unicode fixture 日本語".utf8)
        try bytes.write(to: nested.appendingPathComponent(filename))
        let prepared = await f.call("transfers.plan", ["sources": .array([.string(source.absoluteString)]), "destination": .string(f.destination.absoluteString), "recursive": .bool(true)])
        let plan = try value(prepared, "planID")
        let job = try value(await f.start(plan, key: "recursive-folder"), "id")
        let result = try await terminal(f, jobID: job)
        XCTAssertEqual(result["state"], .string("succeeded"), "Failure detail: \(result)")
        guard result["state"] == .string("succeeded") else { return }
        let copied = f.destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        let copiedNested = copied.appendingPathComponent(nested.lastPathComponent, isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: copiedNested.appendingPathComponent(filename)), bytes)
        let copiedEmpty = copiedNested.appendingPathComponent(empty.lastPathComponent, isDirectory: true)
        XCTAssertTrue(try copiedEmpty.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: copiedEmpty.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent(filename)), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.destination.path), [source.lastPathComponent])
    }
    func testTransferPlanRejectsDuplicateAndOverlappingSources() async throws {
        let f = try await fixture()
        let directory = f.allowed.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let child = directory.appendingPathComponent("child.txt")
        try Data("child".utf8).write(to: child)
        for sources in [[f.source, f.source], [directory, child], [child, directory]] {
            let response = await f.call("transfers.plan", ["sources": .array(sources.map { .string($0.absoluteString) }), "destination": .string(f.destination.absoluteString), "recursive": .bool(true)])
            XCTAssertFalse(response.ok, "Duplicate or overlapping sources must be rejected before execution")
            XCTAssertNil(response.result)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
    }
    func testConcurrentStartsWithSameKeyReturnOneJob() async throws {
        let f = try await fixture()
        let plan = try value(await f.plan(), "planID")
        await f.environment.pauseRevision()
        let first = Task { await f.start(plan, key: "simultaneous") }
        let second = Task { await f.start(plan, key: "simultaneous") }
        for _ in 0..<200 {
            if await f.environment.revisionWaiterCount == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await f.environment.revisionWaiterCount; XCTAssertEqual(waiting, 2)
        await f.environment.resumeRevision()
        let firstID = try value(await first.value, "id"), secondID = try value(await second.value, "id")
        XCTAssertEqual(firstID, secondID)
        let result = try await terminal(f, jobID: firstID); XCTAssertEqual(result["state"], .string("succeeded"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).count, 1)
    }
    func testShutdownWhileStartAwaitsRevisionCannotCreateJobOrCopy() async throws {
        let f = try await fixture()
        let plan = try value(await f.plan(), "planID")
        await f.environment.pauseRevision()
        let pending = Task { await f.start(plan, key: "shutdown-race") }
        for _ in 0..<200 {
            if await f.environment.revisionWaiterCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await f.environment.revisionWaiterCount
        XCTAssertEqual(waiting, 1, "The start request must suspend before shutdown")
        await f.service.shutdown()
        await f.environment.resumeRevision()
        let response = await pending.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "disabled")
        XCTAssertNil(response.result)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.source), Data("original fixture".utf8))
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as? [String: Any])
        let jobs = try XCTUnwrap(state["jobs"] as? [[String: Any]])
        XCTAssertTrue(jobs.isEmpty, "No queued or running job may be persisted after shutdown")
    }
    func testChangedSourceAndRevisionCannotExecuteOldPlan() async throws {
        let f = try await fixture()
        let plan = try value(await f.plan(), "planID")
        try Data("changed and longer fixture".utf8).write(to: f.source)
        let job = try value(await f.start(plan), "id")
        let result = try await terminal(f, jobID: job)
        XCTAssertEqual(result["state"], .string("failed")); XCTAssertEqual(result["error"], .string("changedPlan"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
        let nextPlan = try value(await f.plan(), "planID")
        await f.environment.changeRevision()
        let changed = await f.start(nextPlan, key: "revision-change"); XCTAssertEqual(changed.error, "changedPlan")
    }
    func testRestartMarksRunningJobNeedsInputWithoutReplaying() async throws {
        let f = try await fixture()
        let plan = try value(await f.plan(), "planID"), job = try value(await f.start(plan), "id")
        _ = try await terminal(f, jobID: job)
        await f.service.shutdown()
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.stateURL)) as? [String: Any])
        var jobs = try XCTUnwrap(state["jobs"] as? [[String: Any]])
        jobs[0]["state"] = "running"; state["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: state).write(to: f.stateURL)
        let resumed = try AutomationService(files: f.files, environment: f.environment.adapter, stateURL: f.stateURL)
        let status = await resumed.handle(.init(method: "transfers.status", arguments: .object(["jobID": .string(job)]), clientID: f.grant.id.uuidString, token: f.token))
        XCTAssertEqual(status.result?["state"], .string("needs_input")); XCTAssertEqual(status.result?["error"], .string("interrupted"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).count, 1)
        await resumed.shutdown()
    }
    func testSecretsNeverAppearInResponsesAuditOrPersistedState() async throws {
        let f = try await fixture()
        let secret = "SECRET-SUBMITTED-IN-INVALID-ARGUMENT"
        let invalid = await f.call("connections.prepare", ["name": .string("test"), "provider": .string("s3"), "bucket": .string("fixture-bucket"), "secretAccessKey": .string(secret)])
        XCTAssertEqual(invalid.error, "invalidArguments")
        let connections = await f.call("connections.list")
        let audit = await f.call("audit.list")
        let encoded = try AutomationWire.encode(JSONValue.array([try AutomationWire.decode(JSONValue.self, from: AutomationWire.encode(invalid)), try AutomationWire.decode(JSONValue.self, from: AutomationWire.encode(connections)), try AutomationWire.decode(JSONValue.self, from: AutomationWire.encode(audit))]))
        let combined = String(decoding: encoded, as: UTF8.self) + String(decoding: try Data(contentsOf: f.stateURL), as: UTF8.self)
        for secret in [secret, f.token, "CLOUD-SECRET-NOT-FOR-OUTPUT"] { XCTAssertFalse(combined.contains(secret)) }
        let events = try XCTUnwrap(audit.result?["events"]?.arrayValue)
        XCTAssertTrue(events.allSatisfy { Set($0.objectValue?.keys.map { $0 } ?? []).isSubset(of: ["date", "clientID", "method", "result"]) })
    }
    func testConnectionAuthenticationRequiresAppInputAndDoesNotGrantCloudScope() async throws {
        let f = try await fixture()
        let prepared = await f.call("connections.prepare", ["name": .string("new"), "provider": .string("s3"), "bucket": .string("new-fixture-bucket"), "region": .string("us-east-1")])
        let plan = try value(prepared, "planID")
        let pending = await f.call("connections.authenticate", ["planID": .string(plan)])
        XCTAssertEqual(pending.result?["state"], .string("needs_input"))
        let denied = await f.call("connections.apply", ["planID": .string(plan)]); XCTAssertEqual(denied.error, "needsInput")
        await f.environment.completeAuthentication()
        let applied = await f.call("connections.apply", ["planID": .string(plan)])
        XCTAssertEqual(applied.result?["accessGrantRequired"], .bool(true))
        let id = try value(applied, "connectionID")
        let listings = await f.call("connections.list")
        XCTAssertFalse(listings.result?["connections"]?.arrayValue?.contains(where: { $0["id"]?.stringValue == id }) ?? true)
    }
    func testDeletionUsesInjectedTrashAndSingleUsePlan() async throws {
        let f = try await fixture()
        let prepared = await f.call("deletions.plan", ["sources": .array([.string(f.source.absoluteString)])])
        let plan = try value(prepared, "planID")
        let started = await f.call("deletions.start", ["planID": .string(plan), "idempotencyKey": .string("trash-test")])
        let job = try value(started, "id")
        let result = try await terminal(f, jobID: job, method: "deletions.status")
        XCTAssertEqual(result["state"], .string("succeeded"))
        let repeatStart = await f.call("deletions.start", ["planID": .string(plan), "idempotencyKey": .string("trash-test")])
        XCTAssertEqual(try value(repeatStart, "id"), job)
        let consumed = await f.call("deletions.start", ["planID": .string(plan), "idempotencyKey": .string("new-trash-key")])
        XCTAssertEqual(consumed.error, "notFound")
        let trashed = await f.trash.urls; XCTAssertEqual(trashed, [f.source])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path), "The injected Trash never touches the user's Trash")
    }
}

private actor ServiceTestEnvironment {
    var values: [CloudConnection]
    var revisionValue = "initial"
    var paused = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var awaitingAuthentication: UUID?
    var authenticatedIDs = Set<UUID>()
    init(connection: CloudConnection) { values = [connection] }
    nonisolated var adapter: AutomationEnvironment {
        AutomationEnvironment(connections: { await self.connections() }, revision: { await self.revision() }, authenticate: { await self.authenticate($0) }, authenticated: { await self.isAuthenticated($0) }, apply: { await self.apply($0) }, preferences: { .object(["language": .string("en")]) }, updatePreferences: { $0 })
    }
    func connections() -> [CloudConnection] { values }
    func revision() async -> String {
        if paused { await withCheckedContinuation { waiters.append($0) } }
        return revisionValue
    }
    func pauseRevision() { paused = true }
    var revisionWaiterCount: Int { waiters.count }
    func resumeRevision() { paused = false; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
    func changeRevision() { revisionValue = UUID().uuidString }
    func authenticate(_ connection: CloudConnection) { awaitingAuthentication = connection.id }
    func completeAuthentication() { if let id = awaitingAuthentication { authenticatedIDs.insert(id) } }
    func isAuthenticated(_ id: UUID) -> Bool { authenticatedIDs.contains(id) }
    func apply(_ connection: CloudConnection) { values.append(connection) }
}
private actor ServiceTestTrash: StorageTrash {
    var urls: [URL] = []
    func trash(_ url: URL) async throws { urls.append(url) }
}
private actor ServiceTestCloudTransport: CloudTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> CloudResponse {
        requests.append(request)
        return .init(statusCode: 200, body: Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
    }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse { throw CloudFailure(.io) }
}
