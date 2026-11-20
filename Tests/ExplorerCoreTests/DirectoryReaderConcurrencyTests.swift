// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

@MainActor
final class DirectoryReaderConcurrencyTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.ReadPool.\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("file.txt"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    func testBlockedFilesystemWorkersDoNotUseSwiftExecutorAndCancellationReturnsImmediately() async throws {
        let root = try fixture(), probe = ReadWorkerProbe(), release = DispatchSemaphore(value: 0)
        let executor = DirectoryReadExecutor(concurrency: 2, maximumPending: 2)
        let reader = DirectoryReader(executor: executor, beforeEnumeration: { _ in
            probe.enter()
            _ = release.wait(timeout: .now() + 5)
            probe.exit()
        })
        defer { release.signal(); release.signal() }
        var cancelled = 0
        let jobs = (0..<2).map { _ in Task {
            do { _ = try await reader.entries(at: root, showHidden: false); XCTFail("Expected cancellation") }
            catch is CancellationError { cancelled += 1 }
            catch { XCTFail("Unexpected \(error)") }
        } }
        try await wait { probe.entered == 2 }
        XCTAssertFalse(probe.usedMainThread)
        XCTAssertFalse(probe.usedSwiftTask, "Blocking work must not run in a Task.detached/cooperative worker")
        let heartbeat = await Task.detached { 42 }.value
        XCTAssertEqual(heartbeat, 42)
        let start = Date()
        jobs.forEach { $0.cancel() }
        try await wait { cancelled == 2 }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(probe.exited, 0, "Awaiters must return before the uninterruptible operation finishes")
        do { _ = try await reader.entries(at: root, showHidden: false); XCTFail("Blocked slots cannot be reused") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EBUSY) }
        release.signal(); release.signal()
        try await wait { probe.exited == 2 }
        for job in jobs { await job.value }
    }

    func testDeadlineReturnsWithoutFreeingBlockedWorkerOrGrowingQueue() async throws {
        let root = try fixture(), probe = ReadWorkerProbe(), release = DispatchSemaphore(value: 0)
        let reader = DirectoryReader(executor: DirectoryReadExecutor(concurrency: 1, maximumPending: 1, timeout: 0.05),
                                     beforeEnumeration: { _ in
            probe.enter(); _ = release.wait(timeout: .now() + 5); probe.exit()
        })
        defer { release.signal() }
        let start = Date()
        do { _ = try await reader.entries(at: root, showHidden: false); XCTFail("Expected deadline") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .ETIMEDOUT) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(probe.exited, 0)
        for _ in 0..<20 {
            do { _ = try await reader.entries(at: root, showHidden: false); XCTFail("Expected bounded admission") }
            catch let error as POSIXError { XCTAssertEqual(error.code, .EBUSY) }
        }
        XCTAssertEqual(probe.entered, 1)
        release.signal()
        try await wait { probe.exited == 1 }
    }

    func testCancelledQueuedReadNeverStartsFilesystemWork() async throws {
        let root = try fixture(), probe = ReadWorkerProbe(), release = DispatchSemaphore(value: 0)
        let reader = DirectoryReader(executor: DirectoryReadExecutor(concurrency: 1, maximumPending: 2), beforeEnumeration: { _ in
            probe.enter(); _ = release.wait(timeout: .now() + 5); probe.exit()
        })
        defer { release.signal(); release.signal() }
        let first = Task { try await reader.entries(at: root, showHidden: false) }
        try await wait { probe.entered == 1 }
        var finished = false
        let queued = Task {
            do { _ = try await reader.entries(at: root, showHidden: false); XCTFail("Expected cancellation") }
            catch is CancellationError { finished = true }
            catch { XCTFail("Unexpected \(error)") }
        }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        try await wait { finished }
        release.signal()
        let entries = try await first.value
        XCTAssertEqual(entries.map(\.name), ["file.txt"])
        await queued.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(probe.entered, 1)
    }

    func testSaturatedSidebarPoolCannotDelayForegroundNavigation() async throws {
        let root = try fixture(), probe = ReadWorkerProbe(), release = DispatchSemaphore(value: 0)
        let sidebar = DirectoryReader(purpose: .background, beforeEnumeration: { _ in
            probe.enter(); _ = release.wait(timeout: .now() + 5); probe.exit()
        })
        defer { release.signal(); release.signal() }
        let jobs = (0..<16).map { _ in Task { try await sidebar.entries(at: root, showHidden: false) } }
        try await wait { probe.entered == 2 }
        // Two running sidebar reads plus their queued requests cannot use foreground capacity.
        let start = Date()
        let entries = try await DirectoryReader().entries(at: root, showHidden: false)
        XCTAssertEqual(entries.map(\.name), ["file.txt"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(probe.exited, 0)
        jobs.forEach { $0.cancel() }
        for job in jobs {
            do { _ = try await job.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
        }
        let afterCancellation = try await DirectoryReader(purpose: .foreground).entries(at: root, showHidden: false)
        XCTAssertEqual(afterCancellation.map(\.name), ["file.txt"])
        XCTAssertEqual(probe.exited, 0)
        release.signal(); release.signal()
        try await wait { probe.exited == 2 }
    }

    func testNonFileAndMalformedURLsNeverEnterReadPool() async throws {
        let probe = ReadWorkerProbe()
        let reader = DirectoryReader(executor: DirectoryReadExecutor(), beforeEnumeration: { _ in probe.enter() })
        for url in [URL(string: "s3://fixture-bucket/prefix/")!, RemoteLocation.url(connectionID: UUID(), key: "prefix/"),
                    URL(string: "file://remote.example/tmp")!, URL(string: "file:///tmp/%00suffix")!] {
            do { _ = try await reader.entries(at: url, showHidden: false); XCTFail("Expected local URL rejection") }
            catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadUnsupportedScheme) }
        }
        XCTAssertEqual(probe.entered, 0)
    }
}

private final class ReadWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, ends = 0
    private var main = false, swiftTask = false
    var entered: Int { lock.withLock { starts } }
    var exited: Int { lock.withLock { ends } }
    var usedMainThread: Bool { lock.withLock { main } }
    var usedSwiftTask: Bool { lock.withLock { swiftTask } }
    func enter() {
        let task = withUnsafeCurrentTask { $0 != nil }
        lock.withLock { starts += 1; main = main || Thread.isMainThread; swiftTask = swiftTask || task }
    }
    func exit() { lock.withLock { ends += 1 } }
}
