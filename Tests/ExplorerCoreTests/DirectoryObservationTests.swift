// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

@MainActor
final class DirectoryObservationTests: XCTestCase {
    func testWatchStartsBeforeFirstReadAndReconcilesEventsDuringInitialSnapshot() async throws {
        let reader = ObservationReader(), observer = RetainingObserver()
        let session = DirectorySession(url: URL(fileURLWithPath: "/initial"), reader: reader, observer: observer)
        let initial = session.navigate(.reload)
        // Registration must be synchronous, before the reader can capture its snapshot.
        XCTAssertEqual(observer.paths, ["/initial"])
        try await waitForRequests(1, reader)
        observer.callbacks[0]()
        try await Task.sleep(for: .milliseconds(350))
        let pendingCount = await reader.count
        XCTAssertEqual(pendingCount, 1)
        await reader.complete(0, names: ["old-snapshot.txt"])
        await initial.value
        try await waitForRequests(2, reader)
        await reader.complete(1, names: ["latest.txt"])
        try await waitUntilLoaded(session)
        XCTAssertEqual(session.entries.map(\.name), ["latest.txt"])
        XCTAssertEqual(observer.paths, ["/initial"])
        session.cancelLoading()
    }

    func testFailedNavigationRestoresPriorWatchAndRejectsFailedDestinationEvents() async throws {
        let reader = ObservationReader(), observer = RetainingObserver()
        let session = DirectorySession(url: URL(fileURLWithPath: "/working"), reader: reader, observer: observer)
        let initial = session.navigate(.reload)
        try await waitForRequests(1, reader)
        await reader.complete(0, names: ["original.txt"])
        await initial.value
        let failed = session.navigate(.visit(URL(fileURLWithPath: "/denied")))
        XCTAssertEqual(observer.paths, ["/working", "/denied"])
        try await waitForRequests(2, reader)
        let obsolete = observer.callbacks[1]
        obsolete()
        await reader.fail(1)
        await failed.value
        XCTAssertEqual(observer.paths, ["/working", "/denied", "/working"])
        XCTAssertEqual(session.history.current.url.path, "/working")
        XCTAssertEqual(session.entries.map(\.name), ["original.txt"])
        XCTAssertEqual(session.failure?.path, "/denied")
        obsolete()
        try await Task.sleep(for: .milliseconds(350))
        let countAfterFailure = await reader.count
        XCTAssertEqual(countAfterFailure, 2)
        observer.callbacks[2]()
        try await waitForRequests(3, reader)
        await reader.complete(2, names: ["restored-watch.txt"])
        try await waitUntilLoaded(session)
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.entries.map(\.name), ["restored-watch.txt"])
        session.cancelLoading()
    }

    func testBurstProducesOneRefreshAndSnapshotsViewBeforeReading() async throws {
        let reader = ObservationReader(), observer = RetainingObserver()
        let session = DirectorySession(url: URL(fileURLWithPath: "/fixture"), reader: reader, observer: observer)
        let initial = session.navigate(.reload)
        try await waitForRequests(1, reader)
        await reader.complete(0, names: ["keep.txt", "removed.txt"])
        await initial.value
        var snapshots = 0
        session.onWillAutoRefresh = {
            snapshots += 1
            session.remember(selection: ["/fixture/keep.txt", "/fixture/removed.txt"], scrollOffset: 640)
        }
        for _ in 0..<30 { observer.callbacks[0]() }
        try await waitForRequests(2, reader)
        XCTAssertEqual(snapshots, 1)
        await reader.complete(1, names: ["keep.txt", "new.txt"])
        try await waitUntilLoaded(session)
        try await Task.sleep(for: .milliseconds(350))
        let count = await reader.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(session.history.current.selectedPaths, ["/fixture/keep.txt"])
        XCTAssertEqual(session.history.current.scrollOffset, 640)
        XCTAssertTrue(session.history.back.isEmpty)
        XCTAssertTrue(session.history.forward.isEmpty)
        session.onWillAutoRefresh = nil
        session.cancelLoading()
    }

    func testNavigatingCancelsQueuedRefreshAndRejectsOldWatchCallback() async throws {
        let reader = ObservationReader(), observer = RetainingObserver()
        let session = DirectorySession(url: URL(fileURLWithPath: "/old"), reader: reader, observer: observer)
        let initial = session.navigate(.reload)
        try await waitForRequests(1, reader)
        await reader.complete(0)
        await initial.value
        let obsolete = observer.callbacks[0]
        obsolete() // Already queued before navigation invalidates the old watcher.
        let navigation = session.navigate(.visit(URL(fileURLWithPath: "/new")))
        try await waitForRequests(2, reader)
        obsolete() // Also simulate an event already delivered by the old OS stream.
        await reader.complete(1)
        await navigation.value
        obsolete()
        try await Task.sleep(for: .milliseconds(350))
        let count = await reader.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(observer.paths, ["/old", "/new"])
        XCTAssertGreaterThanOrEqual(observer.stops, 1)
        XCTAssertEqual(session.history.current.url.path, "/new")
        session.cancelLoading()
    }

    func testClosedTabRejectsQueuedAndRetainedCallbacksWithoutTouchingNeighbour() async throws {
        let reader = ObservationReader()
        var observers: [RetainingObserver] = []
        let workspace = ExplorerWorkspace(reader: reader, observerFactory: {
            let observer = RetainingObserver()
            observers.append(observer)
            return observer
        })
        let first = workspace.addTab(at: URL(fileURLWithPath: "/first"))
        try await waitForRequests(1, reader)
        await reader.complete(0)
        try await waitUntilLoaded(first.session)
        let neighbour = workspace.addTab(at: URL(fileURLWithPath: "/neighbour"))
        try await waitForRequests(2, reader)
        await reader.complete(1)
        try await waitUntilLoaded(neighbour.session)
        let obsolete = observers[0].callbacks[0]
        obsolete()
        workspace.close(first.id)
        var notifications = 0, refreshes = 0
        workspace.onChange = { _ in notifications += 1 }
        workspace.onWillAutoRefresh = { _ in refreshes += 1 }
        obsolete()
        try await Task.sleep(for: .milliseconds(350))
        let count = await reader.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(refreshes, 0)
        XCTAssertGreaterThanOrEqual(observers[0].stops, 1)
        XCTAssertEqual(workspace.activeID, neighbour.id)
        XCTAssertEqual(neighbour.session.entries.first?.name, "entry.txt")
        workspace.close(neighbour.id)
    }

    func testEventDuringReadSchedulesExactlyOneFollowupAfterCompletion() async throws {
        let reader = ObservationReader(), observer = RetainingObserver()
        let session = DirectorySession(url: URL(fileURLWithPath: "/fixture"), reader: reader, observer: observer)
        let initial = session.navigate(.reload)
        try await waitForRequests(1, reader)
        await reader.complete(0)
        await initial.value
        let manual = session.navigate(.reload)
        try await waitForRequests(2, reader)
        for _ in 0..<20 { observer.callbacks[0]() }
        // Let the debounce expire while the controlled reader is still suspended.
        try await Task.sleep(for: .milliseconds(350))
        let pendingCount = await reader.count
        XCTAssertEqual(pendingCount, 2)
        XCTAssertTrue(session.isLoading)
        await reader.complete(1, names: ["intermediate.txt"])
        await manual.value
        try await waitForRequests(3, reader)
        await reader.complete(2, names: ["latest.txt"])
        try await waitUntilLoaded(session)
        try await Task.sleep(for: .milliseconds(350))
        let finalCount = await reader.count
        XCTAssertEqual(finalCount, 3)
        XCTAssertEqual(session.entries.map(\.name), ["latest.txt"])
        XCTAssertEqual(observer.paths, ["/fixture"])
        session.cancelLoading()
    }

    func testBackgroundWatchRefreshesOnlyItsOwnTab() async throws {
        let reader = ObservationReader()
        var observers: [RetainingObserver] = []
        let workspace = ExplorerWorkspace(reader: reader, observerFactory: {
            let observer = RetainingObserver()
            observers.append(observer)
            return observer
        })
        let background = workspace.addTab(at: URL(fileURLWithPath: "/shared"))
        try await waitForRequests(1, reader)
        await reader.complete(0, names: ["background.txt"])
        try await waitUntilLoaded(background.session)
        let active = workspace.addTab(at: URL(fileURLWithPath: "/shared"))
        try await waitForRequests(2, reader)
        await reader.complete(1, names: ["active.txt"])
        try await waitUntilLoaded(active.session)
        var refreshed: [UUID] = []
        workspace.onWillAutoRefresh = { refreshed.append($0) }
        observers[0].callbacks[0]()
        try await waitForRequests(3, reader)
        await reader.complete(2, names: ["updated.txt"])
        try await waitUntilLoaded(background.session)
        XCTAssertEqual(refreshed, [background.id, background.id])
        XCTAssertEqual(workspace.activeID, active.id)
        XCTAssertEqual(active.session.entries.map(\.name), ["active.txt"])
        XCTAssertEqual(background.session.entries.map(\.name), ["updated.txt"])
        workspace.close(background.id)
        workspace.close(active.id)
    }

    func testFailedAutomaticReadCapturesInteractionMadeWhileReading() async throws {
        let reader = ObservationReader(), observer = RetainingObserver()
        let session = DirectorySession(url: URL(fileURLWithPath: "/fixture"), reader: reader, observer: observer)
        let initial = session.navigate(.reload)
        try await waitForRequests(1, reader)
        await reader.complete(0, names: ["first.txt", "second.txt"])
        await initial.value
        session.onWillAutoRefresh = {
            session.remember(selection: ["/fixture/first.txt"], scrollOffset: 100)
        }
        var applyCalls = 0
        var interaction: Set<String> = ["/fixture/first.txt"]
        var scroll = 100.0
        session.onWillApplyAutoRefresh = {
            applyCalls += 1
            session.remember(selection: interaction, scrollOffset: scroll)
        }
        observer.callbacks[0]()
        try await waitForRequests(2, reader)
        XCTAssertTrue(session.isAutoRefreshing)
        XCTAssertFalse(session.blocksInteraction)
        // The UI remains interactive while the background reader is suspended.
        interaction = ["/fixture/second.txt"]
        scroll = 750
        await reader.fail(1)
        try await waitUntilLoaded(session)
        XCTAssertEqual(applyCalls, 1)
        XCTAssertEqual(session.history.current.selectedPaths, ["/fixture/second.txt"])
        XCTAssertEqual(session.history.current.scrollOffset, 750)
        XCTAssertEqual(session.entries.map(\.name), ["first.txt", "second.txt"])
        XCTAssertNotNil(session.failure)
        XCTAssertFalse(session.isAutoRefreshing)
        XCTAssertFalse(session.blocksInteraction)
        session.onWillAutoRefresh = nil
        session.onWillApplyAutoRefresh = nil
        session.cancelLoading()
    }

    private func waitForRequests(_ count: Int, _ reader: ObservationReader) async throws {
        for _ in 0..<200 {
            if await reader.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(count) directory reads")
        throw ObservationTimeout.expired
    }

    private func waitUntilLoaded(_ session: DirectorySession) async throws {
        for _ in 0..<200 {
            if !session.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Directory session did not finish loading")
        throw ObservationTimeout.expired
    }
}

private enum ObservationTimeout: Error { case expired }

@MainActor
private final class RetainingObserver: DirectoryChangeObserving {
    var paths: [String] = []
    var callbacks: [@MainActor () -> Void] = []
    var stops = 0
    func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        paths.append(url.path)
        callbacks.append(onChange)
    }
    // Intentionally retain obsolete callbacks to exercise cancellation races.
    func stop() { stops += 1 }
}

private actor ObservationReader: DirectoryReading {
    struct Request {
        let url: URL
        var continuation: CheckedContinuation<[FileEntry], any Error>?
    }
    private var requests: [Request] = []
    var count: Int { requests.count }
    func entries(at url: URL, showHidden: Bool) async throws -> [FileEntry] {
        try await withCheckedThrowingContinuation {
            requests.append(Request(url: url, continuation: $0))
        }
    }
    func complete(_ index: Int, names: [String] = ["entry.txt"]) {
        let request = requests[index]
        requests[index].continuation = nil
        request.continuation?.resume(returning: names.map {
            FileEntry(url: request.url.appendingPathComponent($0), name: $0, isDirectory: false)
        })
    }
    func fail(_ index: Int) {
        let continuation = requests[index].continuation
        requests[index].continuation = nil
        continuation?.resume(throwing: CocoaError(.fileReadNoPermission))
    }
}
