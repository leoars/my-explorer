// SPDX-License-Identifier: Apache-2.0
import XCTest
import Darwin
@testable import ExplorerCore

final class DirectoryWatcherTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer-Watcher-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func waitFor(_ condition: () -> Bool, seconds: Double = 4) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for watcher condition")
    }

    @MainActor func testFailedStreamCreationReleasesContextExactlyOnceAndKeepsVnodeObservation() async throws {
        let directory = try fixture(), contexts = WatcherContextProbe()
        let watcher = DirectoryWatcher(forceStreamCreationFailure: true, contextLifecycle: { contexts.record($0) })
        defer { watcher.stop() }
        var notifications = 0
        watcher.watch(directory) { notifications += 1 }
        try await waitFor { notifications > 0 && contexts.created == 1 && contexts.destroyed == 1 }
        // Empty paths trigger a real FSEventStreamCreate failure after the framework has
        // retained/released its context. The independent vnode source must still function.
        let baseline = notifications
        try Data("vnode fallback".utf8).write(to: directory.appendingPathComponent("file.txt"))
        try await waitFor { notifications > baseline }
        watcher.stop()
        XCTAssertEqual(contexts.created, contexts.destroyed)
    }

    @MainActor func testManyWatchersRepeatedCreateFailureStopAndRearmBalanceAllContexts() async throws {
        let root = try fixture(), contexts = WatcherContextProbe()
        let directories = try (0..<16).map { index in
            let directory = root.appendingPathComponent("directory-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return directory
        }
        let watchers = (0..<16).map { index in
            DirectoryWatcher(forceStreamCreationFailure: index.isMultiple(of: 2), contextLifecycle: { contexts.record($0) })
        }
        defer { for watcher in watchers { watcher.stop() } }
        for round in 0..<20 {
            var installed = Set<Int>()
            for (index, watcher) in watchers.enumerated() {
                watcher.watch(directories[index]) { installed.insert(index) }
            }
            try await waitFor({ installed.count == watchers.count }, seconds: 8)
            for directory in directories { try Data("round \(round)".utf8).write(to: directory.appendingPathComponent("child.txt")) }
            if round.isMultiple(of: 4) {
                let moved = root.appendingPathComponent("moved-\(round)")
                try FileManager.default.moveItem(at: directories[1], to: moved)
                try FileManager.default.createDirectory(at: directories[1], withIntermediateDirectories: false)
                try FileManager.default.removeItem(at: moved)
                // Let native rename callbacks queue a rearm before closing all watchers.
                try await Task.sleep(for: .milliseconds(30))
            }
            for watcher in watchers { watcher.stop() }
            try await waitFor({ contexts.created == contexts.destroyed }, seconds: 8)
            XCTAssertGreaterThanOrEqual(contexts.created, 16 * (round + 1))
        }
        XCTAssertEqual(contexts.created, contexts.destroyed)
    }

    @MainActor func testNonFileAndMalformedURLsNeverPrepareFilesystemObservation() async throws {
        let probe = WatcherProbe()
        let watcher = DirectoryWatcher(beforePreparation: { _ in probe.markEntered(onMain: Thread.isMainThread) })
        defer { watcher.stop() }
        for url in [URL(string: "s3://fixture-bucket/prefix/")!, RemoteLocation.url(connectionID: UUID(), key: "prefix/"),
                    URL(string: "file://remote.example/tmp")!, URL(string: "file:///tmp/%00suffix")!] {
            watcher.watch(url) { XCTFail("Remote URL must not produce local watch events") }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(probe.entered)
    }

    @MainActor func testSlowPreparationDoesNotBlockMainActorAndStopDiscardsIt() async throws {
        let directory = try fixture(), probe = WatcherProbe()
        let release = DispatchSemaphore(value: 0)
        let watcher = DirectoryWatcher(beforePreparation: { _ in
            probe.markEntered(onMain: Thread.isMainThread)
            _ = release.wait(timeout: .now() + 5)
        })
        defer { release.signal(); watcher.stop() }
        var callbacks = 0
        let start = Date()
        watcher.watch(directory) { callbacks += 1 }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        try await waitFor { probe.entered }
        XCTAssertFalse(probe.wasMain)
        // This actor remains available while the synchronous preparation is blocked.
        watcher.stop()
        release.signal()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(callbacks, 0)
    }

    @MainActor func testCancelledPreparedDescriptorIsClosed() async throws {
        let directory = try fixture(), probe = WatcherProbe()
        let release = DispatchSemaphore(value: 0)
        let watcher = DirectoryWatcher(openedDescriptor: { descriptor in
            probe.open(descriptor)
            _ = release.wait(timeout: .now() + 5)
        })
        defer { release.signal(); watcher.stop() }
        var callbacks = 0
        watcher.watch(directory) { callbacks += 1 }
        try await waitFor { probe.descriptor >= 0 }
        watcher.stop()
        release.signal()
        try await waitFor { fcntl(probe.descriptor, F_GETFD) == -1 }
        XCTAssertEqual(callbacks, 0)
    }

    @MainActor func testLatePreparationCannotReplaceNewLocation() async throws {
        let root = try fixture(), old = root.appendingPathComponent("old"), current = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        let release = DispatchSemaphore(value: 0), probe = WatcherProbe()
        let watcher = DirectoryWatcher(beforePreparation: { url in
            if url == old { probe.markEntered(onMain: Thread.isMainThread); _ = release.wait(timeout: .now() + 5) }
        })
        defer { release.signal(); watcher.stop() }
        var oldCalls = 0, currentCalls = 0
        watcher.watch(old) { oldCalls += 1 }
        try await waitFor { probe.entered }
        watcher.watch(current) { currentCalls += 1 }
        try await waitFor { currentCalls > 0 }
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        let initial = currentCalls
        try Data("change".utf8).write(to: current.appendingPathComponent("new.txt"))
        try await waitFor { currentCalls > initial }
        XCTAssertEqual(oldCalls, 0)
    }

    @MainActor func testInstalledDescriptorClosesWhenWatcherStops() async throws {
        let directory = try fixture(), probe = WatcherProbe()
        let watcher = DirectoryWatcher(openedDescriptor: { probe.open($0) })
        defer { watcher.stop() }
        var installed = false
        watcher.watch(directory) { installed = true }
        try await waitFor { installed && probe.descriptor >= 0 }
        XCTAssertNotEqual(fcntl(probe.descriptor, F_GETFD), -1)
        watcher.stop()
        try await waitFor { fcntl(probe.descriptor, F_GETFD) == -1 }
    }

    @MainActor func testObservesMetadataAndRemovalRecreation() async throws {
        let root = try fixture(), directory = root.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("value.txt")
        try Data("before".utf8).write(to: file)
        let watcher = DirectoryWatcher()
        defer { watcher.stop() }
        var callbacks = 0
        watcher.watch(directory) { callbacks += 1 }
        try await waitFor { callbacks > 0 }
        var baseline = callbacks
        try Data("new contents".utf8).write(to: file)
        try await waitFor { callbacks > baseline }
        baseline = callbacks
        try FileManager.default.removeItem(at: directory)
        try await waitFor { callbacks > baseline }
        try await Task.sleep(for: .milliseconds(150))
        baseline = callbacks
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try await waitFor { callbacks > baseline }
        try await Task.sleep(for: .milliseconds(250))
        baseline = callbacks
        try Data("restored".utf8).write(to: file)
        try await waitFor { callbacks > baseline }
        watcher.stop()
        baseline = callbacks
        try Data("after stop".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(callbacks, baseline)
    }
}

private final class WatcherProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private var main = false
    private var fd: Int32 = -1
    var entered: Bool { lock.withLock { didEnter } }
    var wasMain: Bool { lock.withLock { main } }
    var descriptor: Int32 { lock.withLock { fd } }
    func markEntered(onMain: Bool) { lock.withLock { didEnter = true; main = onMain } }
    func open(_ descriptor: Int32) { lock.withLock { fd = descriptor } }
}

private final class WatcherContextProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var creationCount = 0
    private var destructionCount = 0
    var created: Int { lock.withLock { creationCount } }
    var destroyed: Int { lock.withLock { destructionCount } }
    func record(_ created: Bool) { lock.withLock { if created { creationCount += 1 } else { destructionCount += 1 } } }
}
