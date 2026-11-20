// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

@MainActor
final class WorkspaceTests: XCTestCase {
    func testTabsKeepIndependentViewStateEvenAtTheSamePath() async {
        let workspace = ExplorerWorkspace(reader: ImmediateReader())
        let root = URL(fileURLWithPath: "/fixture")
        let first = workspace.addTab(at: root)
        await first.session.navigate(.reload).value
        first.filterQuery = "notes"
        first.sortKey = .size; first.sortAscending = false
        first.session.remember(selection: ["/fixture/notes.txt"], scrollOffset: 400)
        first.session.toggleHidden()
        await first.session.navigate(.reload).value
        let second = workspace.addTab(at: root)
        await second.session.navigate(.reload).value
        second.filterQuery = "photo"
        workspace.select(first.id)
        XCTAssertEqual(workspace.activeTab?.filterQuery, "notes")
        XCTAssertEqual(workspace.activeTab?.sortKey, .size)
        XCTAssertEqual(workspace.activeTab?.sortAscending, false)
        XCTAssertEqual(first.session.history.current.selectedPaths, ["/fixture/notes.txt"])
        XCTAssertEqual(first.session.history.current.scrollOffset, 400)
        XCTAssertTrue(first.session.showHidden)
        XCTAssertFalse(second.session.showHidden)
        XCTAssertEqual(second.filterQuery, "photo")
        XCTAssertTrue(second.session.history.current.selectedPaths.isEmpty)
    }

    func testBackgroundNavigationCannotChangeActiveSession() async {
        let reader = QueuedReader()
        let workspace = ExplorerWorkspace(reader: reader)
        let first = workspace.addTab(at: URL(fileURLWithPath: "/a"))
        await reader.waitForCount(1)
        let second = workspace.addTab(at: URL(fileURLWithPath: "/b"))
        await reader.waitForCount(2)
        await reader.complete(1)
        await waitUntilLoaded(second.session)
        let firstID = first.id
        var changed: [UUID?] = []
        workspace.onChange = { changed.append($0) }
        await reader.complete(0)
        await waitUntilLoaded(first.session)
        XCTAssertEqual(workspace.activeID, second.id)
        XCTAssertEqual(workspace.activeTab?.session.entries.first?.name, "b")
        XCTAssertEqual(changed.compactMap { $0 }, [firstID])
        workspace.select(first.id)
        XCTAssertEqual(workspace.activeTab?.session.entries.first?.name, "a")
    }

    func testClosingTabInvalidatesReadThatIgnoresCancellation() async {
        let reader = QueuedReader()
        let workspace = ExplorerWorkspace(reader: reader)
        let first = workspace.addTab(at: URL(fileURLWithPath: "/a"))
        await reader.waitForCount(1)
        await reader.complete(0)
        await waitUntilLoaded(first.session)
        let slow = first.session.navigate(.visit(URL(fileURLWithPath: "/slow")))
        await reader.waitForCount(2)
        workspace.close(first.id)
        let next = workspace.addTab(at: URL(fileURLWithPath: "/c"))
        await reader.waitForCount(3)
        await reader.complete(2)
        await waitUntilLoaded(next.session)
        var notifications = 0
        workspace.onChange = { _ in notifications += 1 }
        await reader.complete(1)
        await slow.value
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(first.session.history.current.url.path, "/a")
        XCTAssertNil(first.session.errorMessage)
        XCTAssertEqual(workspace.activeID, next.id)
        XCTAssertEqual(workspace.activeTab?.session.entries.first?.name, "c")
    }

    func testClosingAndCyclingUseStableIDsAndDeterministicNeighbours() async {
        let workspace = ExplorerWorkspace(reader: ImmediateReader())
        let a = workspace.addTab(at: URL(fileURLWithPath: "/a"))
        let b = workspace.addTab(at: URL(fileURLWithPath: "/b"))
        let c = workspace.addTab(at: URL(fileURLWithPath: "/c"))
        workspace.select(b.id)
        workspace.close(a.id)
        XCTAssertEqual(workspace.activeID, b.id)
        workspace.selectNext()
        XCTAssertEqual(workspace.activeID, c.id)
        workspace.selectNext()
        XCTAssertEqual(workspace.activeID, b.id)
        workspace.selectNext(backwards: true)
        XCTAssertEqual(workspace.activeID, c.id)
        workspace.close(c.id)
        XCTAssertEqual(workspace.activeID, b.id)
        workspace.close(b.id)
        XCTAssertNil(workspace.activeID)
        XCTAssertTrue(workspace.tabs.isEmpty)
    }

    func testTwoSimultaneousReadsAtSamePathRemainIndependent() async {
        let reader = QueuedReader()
        let workspace = ExplorerWorkspace(reader: reader)
        let url = URL(fileURLWithPath: "/shared")
        let first = workspace.addTab(at: url)
        await reader.waitForCount(1)
        let second = workspace.addTab(at: url)
        await reader.waitForCount(2)
        await reader.complete(1, name: "second")
        await waitUntilLoaded(second.session)
        await reader.complete(0, name: "first")
        await waitUntilLoaded(first.session)
        XCTAssertEqual(first.session.entries.first?.name, "first")
        XCTAssertEqual(second.session.entries.first?.name, "second")
    }

    func testRestoredTabsDoNotReadOrCreateObserversUntilSelectedIncludingAlreadyActive() async {
        let reader = QueuedReader()
        var observers: [WorkspaceObserver] = []
        let workspace = ExplorerWorkspace(reader: reader, observerFactory: {
            let observer = WorkspaceObserver(); observers.append(observer); return observer
        })
        let first = workspace.addTab(at: URL(fileURLWithPath: "/first"), startLoading: false)
        let second = workspace.addTab(at: URL(fileURLWithPath: "/second"), select: false, startLoading: false)
        XCTAssertTrue(first.pendingInitialLoad); XCTAssertTrue(second.pendingInitialLoad)
        XCTAssertEqual(workspace.activeID, first.id)
        XCTAssertTrue(observers.isEmpty)
        let before = await reader.count; XCTAssertEqual(before, 0)
        workspace.select(first.id)
        await reader.waitForCount(1)
        XCTAssertFalse(first.pendingInitialLoad); XCTAssertTrue(second.pendingInitialLoad)
        XCTAssertEqual(observers.count, 1)
        XCTAssertEqual(observers[0].watched.map(\.path), ["/first"])
        await reader.complete(0); await waitUntilLoaded(first.session)
        workspace.select(first.id)
        let unchanged = await reader.count; XCTAssertEqual(unchanged, 1)
        workspace.select(second.id)
        await reader.waitForCount(2)
        XCTAssertEqual(observers.count, 2)
        XCTAssertFalse(second.pendingInitialLoad)
        await reader.complete(1); await waitUntilLoaded(second.session)
    }

    func testClosingActiveTabStartsPendingSuccessorAndCyclingLoadsAnother() async {
        let reader = QueuedReader(), workspace = ExplorerWorkspace(reader: reader)
        let first = workspace.addTab(at: URL(fileURLWithPath: "/first"), startLoading: false)
        let second = workspace.addTab(at: URL(fileURLWithPath: "/second"), select: false, startLoading: false)
        let third = workspace.addTab(at: URL(fileURLWithPath: "/third"), select: false, startLoading: false)
        workspace.close(first.id)
        XCTAssertEqual(workspace.activeID, second.id)
        await reader.waitForCount(1)
        let firstPath = await reader.path(at: 0); XCTAssertEqual(firstPath, "/second")
        await reader.complete(0); await waitUntilLoaded(second.session)
        workspace.selectNext()
        XCTAssertEqual(workspace.activeID, third.id)
        await reader.waitForCount(2)
        await reader.complete(1); await waitUntilLoaded(third.session)
    }

    func testMissingRestoredLocalLocationFallsBackOnceWithWarningAndNoBackEntry() async {
        let reader = QueuedReader(), workspace = ExplorerWorkspace(reader: reader)
        let missing = URL(fileURLWithPath: "/missing"), fallback = URL(fileURLWithPath: "/home")
        let tab = workspace.addTab(at: missing, restorationFallback: fallback)
        await reader.waitForCount(1)
        await reader.fail(0)
        await reader.waitForCount(2)
        XCTAssertEqual(tab.restorationUnavailableURL, missing)
        XCTAssertEqual(tab.session.history.current.url, fallback)
        XCTAssertTrue(tab.session.history.back.isEmpty)
        let fallbackPath = await reader.path(at: 1); XCTAssertEqual(fallbackPath, "/home")
        await reader.complete(1); await waitUntilLoaded(tab.session)
        XCTAssertNil(tab.session.failure)
        XCTAssertTrue(tab.session.history.back.isEmpty)
        XCTAssertTrue(tab.session.history.forward.isEmpty)
        tab.prepareForUserNavigation()
        XCTAssertNil(tab.restorationUnavailableURL)
    }

    func testRestoredRemoteFailureStaysVisibleWithoutLocalFallback() async {
        let reader = QueuedReader(), workspace = ExplorerWorkspace(reader: reader)
        let remote = RemoteLocation.url(connectionID: UUID(), key: "folder/")
        let tab = workspace.addTab(at: remote, restorationFallback: URL(fileURLWithPath: "/home"))
        await reader.waitForCount(1)
        await reader.fail(0, code: .fileReadNoPermission)
        await waitUntilLoaded(tab.session)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(tab.session.history.current.url, remote)
        XCTAssertEqual(tab.session.failure?.reason, .permission)
        XCTAssertNil(tab.restorationUnavailableURL)
        let count = await reader.count; XCTAssertEqual(count, 1)
    }

    func testExplicitNavigationSupersedesPendingRestoreEvenWhenOldReadIgnoresCancellation() async {
        let reader = QueuedReader(), workspace = ExplorerWorkspace(reader: reader)
        let tab = workspace.addTab(at: URL(fileURLWithPath: "/missing"), restorationFallback: URL(fileURLWithPath: "/home"))
        await reader.waitForCount(1)
        tab.prepareForUserNavigation()
        let navigation = tab.session.navigate(.visit(URL(fileURLWithPath: "/chosen")))
        await reader.waitForCount(2)
        await reader.fail(0)
        await reader.complete(1)
        await navigation.value
        XCTAssertEqual(tab.session.history.current.url.path, "/chosen")
        XCTAssertNil(tab.restorationUnavailableURL)
        XCTAssertNil(tab.session.failure)
        let count = await reader.count; XCTAssertEqual(count, 2)
    }

    func testUserNavigationFromFailureCallbackCancelsScheduledFallbackWithoutRecursion() async {
        let reader = QueuedReader(), workspace = ExplorerWorkspace(reader: reader)
        let tab = workspace.addTab(at: URL(fileURLWithPath: "/missing"), restorationFallback: URL(fileURLWithPath: "/home"))
        await reader.waitForCount(1)
        var redirected = false
        workspace.onChange = { id in
            if id == tab.id, tab.session.failure != nil, !redirected {
                redirected = true
                tab.prepareForUserNavigation()
                tab.session.navigate(.visit(URL(fileURLWithPath: "/chosen")))
            }
        }
        await reader.fail(0)
        await reader.waitForCount(2)
        let next = await reader.path(at: 1); XCTAssertEqual(next, "/chosen")
        await reader.complete(1); await waitUntilLoaded(tab.session)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(tab.restorationUnavailableURL)
        let count = await reader.count; XCTAssertEqual(count, 2)
    }

    func testClosingBeforeRestorationFailureDoesNotReviveTabOrStartFallback() async {
        let reader = QueuedReader(), workspace = ExplorerWorkspace(reader: reader)
        let tab = workspace.addTab(at: URL(fileURLWithPath: "/missing"), restorationFallback: URL(fileURLWithPath: "/home"))
        await reader.waitForCount(1)
        workspace.close(tab.id)
        await reader.fail(0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNil(workspace.activeID)
        XCTAssertNil(tab.restorationUnavailableURL)
        let count = await reader.count; XCTAssertEqual(count, 1)
    }

    func testFallbackFailureDoesNotLoopAndSuccessfulRestorationNeverFallsBackOnLaterError() async {
        let reader = QueuedReader(), workspace = ExplorerWorkspace(reader: reader)
        let first = workspace.addTab(at: URL(fileURLWithPath: "/missing"), restorationFallback: URL(fileURLWithPath: "/home"))
        await reader.waitForCount(1); await reader.fail(0)
        await reader.waitForCount(2); await reader.fail(1)
        await waitUntilLoaded(first.session)
        XCTAssertNotNil(first.session.failure)
        XCTAssertEqual(first.restorationUnavailableURL?.path, "/missing")
        let second = workspace.addTab(at: URL(fileURLWithPath: "/exists"), restorationFallback: URL(fileURLWithPath: "/home"))
        await reader.waitForCount(3); await reader.complete(2)
        await waitUntilLoaded(second.session)
        let later = second.session.navigate(.reload)
        await reader.waitForCount(4); await reader.fail(3)
        await later.value
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(second.session.history.current.url.path, "/exists")
        XCTAssertNil(second.restorationUnavailableURL)
        let count = await reader.count; XCTAssertEqual(count, 4)
    }

    private func waitUntilLoaded(_ session: DirectorySession) async {
        for _ in 0..<10_000 {
            if !session.isLoading { return }
            await Task.yield()
        }
        XCTFail("Session did not finish loading")
    }
}

private struct ImmediateReader: DirectoryReading {
    func entries(at url: URL, showHidden: Bool) async throws -> [FileEntry] {
        [FileEntry(url: url.appendingPathComponent("notes.txt"), name: "notes.txt", isDirectory: false)]
    }
}

private actor QueuedReader: DirectoryReading {
    struct Request {
        let url: URL
        let continuation: CheckedContinuation<[FileEntry], any Error>
    }
    private var requests: [Request] = []
    var count: Int { requests.count }
    func path(at index: Int) -> String { requests[index].url.path }
    func entries(at url: URL, showHidden: Bool) async throws -> [FileEntry] {
        try await withCheckedThrowingContinuation { requests.append(Request(url: url, continuation: $0)) }
    }
    func waitForCount(_ count: Int) async {
        for _ in 0..<10_000 {
            if requests.count >= count { return }
            await Task.yield()
        }
        fatalError("Expected \(count) requests")
    }
    func complete(_ index: Int, name: String? = nil) {
        let request = requests[index]
        let name = name ?? request.url.lastPathComponent
        request.continuation.resume(returning: [FileEntry(url: request.url.appendingPathComponent(name), name: name, isDirectory: false)])
    }
    func fail(_ index: Int, code: CocoaError.Code = .fileReadNoSuchFile) {
        requests[index].continuation.resume(throwing: CocoaError(code))
    }
}

@MainActor
private final class WorkspaceObserver: DirectoryChangeObserving {
    var watched: [URL] = []
    func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) { watched.append(url) }
    func stop() {}
}
