// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class NavigationTests: XCTestCase {
    let root = URL(fileURLWithPath: "/fixtures")

    func testBackRestoresSelectionAndScrollAndForwardRestoresDestination() {
        var history = NavigationHistory(url: root)
        history.remember(selection: ["/fixtures/notes.txt"], scrollOffset: 240)
        history.visit(root.appendingPathComponent("Documents"))
        history.remember(selection: ["/fixtures/Documents/Project"], scrollOffset: 80)
        history.goBack()
        XCTAssertEqual(history.current.selectedPaths, ["/fixtures/notes.txt"])
        XCTAssertEqual(history.current.scrollOffset, 240)
        history.goForward()
        XCTAssertEqual(history.current.url.lastPathComponent, "Documents")
        XCTAssertEqual(history.current.selectedPaths, ["/fixtures/Documents/Project"])
        XCTAssertEqual(history.current.scrollOffset, 80)
    }

    func testNewVisitClearsForwardButSameLocationDoesNotCreateHistory() {
        var history = NavigationHistory(url: root)
        history.visit(root.appendingPathComponent("A"))
        history.goBack()
        history.visit(root.appendingPathComponent("."))
        XCTAssertEqual(history.forward.count, 1)
        XCTAssertTrue(history.back.isEmpty)
        history.visit(root.appendingPathComponent("B"))
        XCTAssertTrue(history.forward.isEmpty)
        XCTAssertEqual(history.back.count, 1)
    }

    func testUpSelectsChildAndRootDoesNotLoop() {
        var history = NavigationHistory(url: root.appendingPathComponent("Documents"))
        history.goUp()
        XCTAssertEqual(history.current.url.path, root.path)
        XCTAssertEqual(history.current.selectedPaths, ["/fixtures/Documents"])
        var filesystemRoot = NavigationHistory(url: URL(fileURLWithPath: "/"))
        filesystemRoot.goUp()
        XCTAssertTrue(filesystemRoot.back.isEmpty)
    }

    func testSessionsHaveIndependentHistories() {
        var first = NavigationHistory(url: root)
        let second = first
        first.visit(root.appendingPathComponent("A"))
        XCTAssertEqual(second.current.url, root)
        XCTAssertTrue(second.back.isEmpty)
    }

    func testAddressResolutionPreservesSpacesAndRejectsRemoteSchemes() {
        XCTAssertEqual(AddressParser.resolve("../Other folder", relativeTo: root)?.path, "/Other folder")
        XCTAssertEqual(AddressParser.resolve("file:///tmp/A%20B", relativeTo: root)?.path, "/tmp/A B")
        XCTAssertEqual(AddressParser.resolve("folder ", relativeTo: root)?.lastPathComponent, "folder ")
        XCTAssertEqual(AddressParser.resolve("~", relativeTo: root)?.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNil(AddressParser.resolve("https://example.com", relativeTo: root))
        XCTAssertNil(AddressParser.resolve("file://remote/share", relativeTo: root))
        XCTAssertNil(AddressParser.resolve("", relativeTo: root))
    }
}

@MainActor
final class SessionTests: XCTestCase {
    func testFailedNavigationKeepsOriginalHistoryAndListing() async {
        let root = URL(fileURLWithPath: "/root")
        let reader = ControlledReader()
        let session = DirectorySession(url: root, reader: reader)
        let initial = session.navigate(.reload)
        await reader.waitForRequest("/root")
        await reader.finish("/root", entries: [FileEntry(url: root.appendingPathComponent("one"), name: "one", isDirectory: false)])
        await initial.value
        let failed = session.navigate(.visit(URL(fileURLWithPath: "/missing")))
        await reader.waitForRequest("/missing")
        await reader.fail("/missing")
        await failed.value
        XCTAssertEqual(session.history.current.url.path, "/root")
        XCTAssertTrue(session.history.back.isEmpty)
        XCTAssertEqual(session.entries.map(\.name), ["one"])
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(session.isLoading)
    }

    func testStaleResponseCannotReplaceNewerDirectoryEvenIfReaderIgnoresCancellation() async {
        let reader = ControlledReader()
        let session = DirectorySession(url: URL(fileURLWithPath: "/root"), reader: reader)
        let slow = session.navigate(.visit(URL(fileURLWithPath: "/slow")))
        await reader.waitForRequest("/slow")
        let fast = session.navigate(.visit(URL(fileURLWithPath: "/fast")))
        await reader.waitForRequest("/fast")
        await reader.finish("/fast", entries: [])
        await fast.value
        await reader.finish("/slow", entries: [FileEntry(url: URL(fileURLWithPath: "/slow/old"), name: "old", isDirectory: false)])
        await slow.value
        XCTAssertEqual(session.history.current.url.path, "/fast")
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertEqual(session.history.back.map(\.url.path), ["/root"])
    }
}

private actor ControlledReader: DirectoryReading {
    private var requests: [String: CheckedContinuation<[FileEntry], any Error>] = [:]
    func entries(at url: URL, showHidden: Bool) async throws -> [FileEntry] {
        try await withCheckedThrowingContinuation { requests[url.path] = $0 }
    }
    func waitForRequest(_ path: String) async {
        for _ in 0..<10_000 {
            if requests[path] != nil { return }
            await Task.yield()
        }
        fatalError("Timed out waiting for controlled request: \(path)")
    }
    func finish(_ path: String, entries: [FileEntry]) { requests.removeValue(forKey: path)?.resume(returning: entries) }
    func fail(_ path: String) { requests.removeValue(forKey: path)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
}
