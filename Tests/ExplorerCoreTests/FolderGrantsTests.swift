// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

/// The grant store of the App Store build, with plain bookmarks on disposable folders. The
/// security-scoped side (sandbox, open panel) is checked by running the store build
/// (docs/APP-STORE.md, stage 2).
@MainActor
struct FolderGrantsTests {
    private func fixture() throws -> (root: URL, defaults: UserDefaults, name: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderGrants-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "MyExplorer.FolderGrantsTests.\(UUID().uuidString)"
        return (root, UserDefaults(suiteName: name)!, name)
    }

    private func cleanUp(_ root: URL, _ name: String) {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    @Test func coverageFollowsWholePathComponents() {
        #expect(FolderGrantStore.covers("/Users/ana/Documents/a.txt", roots: ["/Users/ana"]))
        #expect(FolderGrantStore.covers("/Users/ana", roots: ["/Users/ana/"]))
        #expect(!FolderGrantStore.covers("/Users/anabela", roots: ["/Users/ana"]))
        #expect(!FolderGrantStore.covers("/Users", roots: ["/Users/ana"]))
        #expect(FolderGrantStore.covers("/Volumes/Disk/x", roots: ["/"]))
        #expect(FolderGrantStore.covers("/", roots: ["/"]))
        #expect(!FolderGrantStore.covers("/Users/ana", roots: []))
        #expect(FolderGrantStore.covers("/Users/ana/x/../y", roots: ["/Users/ana/y"]))
        #expect(FolderGrantStore.normalized("/private/tmp") == FolderGrantStore.normalized("/tmp"))
    }

    @Test func grantsPersistAndAreRemoved() throws {
        let (root, defaults, name) = try fixture()
        defer { cleanUp(root, name) }
        let first = root.appendingPathComponent("B", isDirectory: true)
        let second = root.appendingPathComponent("A", isDirectory: true)
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let store = FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks())
        #expect(store.grants.isEmpty)
        #expect(!store.answeredFirstLaunch)
        try store.add(first)
        try store.add(second)
        try store.add(first) // the same folder again replaces its grant
        store.answeredFirstLaunch = true
        let reopened = FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks())
        #expect(reopened.grants.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["A", "B"])
        #expect(reopened.answeredFirstLaunch)
        #expect(reopened.covers(first.appendingPathComponent("inner/file.txt")))
        #expect(!reopened.covers(root))
        #expect(reopened.grant(covering: second.appendingPathComponent("x"))?.path == FolderGrantStore.normalized(second.path))
        reopened.remove(path: first.path)
        #expect(FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks()).grants.count == 1)
        reopened.removeAll()
        #expect(FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks()).grants.isEmpty)
    }

    @Test func closestGrantWins() throws {
        let (root, defaults, name) = try fixture()
        defer { cleanUp(root, name) }
        let inner = root.appendingPathComponent("outer/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let store = FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks())
        try store.add(root)
        try store.add(inner)
        #expect(store.grant(covering: inner.appendingPathComponent("f"))?.path == FolderGrantStore.normalized(inner.path))
        #expect(store.grant(covering: root.appendingPathComponent("outer"))?.path == FolderGrantStore.normalized(root.path))
    }

    @Test func aMovedFolderIsFollowedAndTheBookmarkRefreshed() throws {
        let (root, defaults, name) = try fixture()
        defer { cleanUp(root, name) }
        let original = root.appendingPathComponent("Before", isDirectory: true)
        let moved = root.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let store = FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks())
        try store.add(original)
        try FileManager.default.moveItem(at: original, to: moved)
        var accessed: [String] = []
        let results = store.resolveAll { accessed.append(FolderGrantStore.normalized($0.path)); return true }
        #expect(results.count == 1)
        #expect(results.first?.url.map { FolderGrantStore.normalized($0.path) } == FolderGrantStore.normalized(moved.path))
        #expect(accessed == [FolderGrantStore.normalized(moved.path)])
        #expect(store.grants.map(\.path) == [FolderGrantStore.normalized(moved.path)])
        // The new path is what the next launch reads.
        #expect(FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks()).grants.map(\.path) == [FolderGrantStore.normalized(moved.path)])
    }

    @Test func aMissingFolderKeepsItsGrant() throws {
        let (root, defaults, name) = try fixture()
        defer { cleanUp(root, name) }
        let folder = root.appendingPathComponent("Gone", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks())
        try store.add(folder)
        try FileManager.default.removeItem(at: folder)
        let results = store.resolveAll { _ in true }
        #expect(results.count == 1)
        #expect(results.first?.url == nil)
        #expect(results.first?.error != nil)
        #expect(store.grants.count == 1)
    }

    @Test func refusedAccessDoesNotRewriteTheBookmark() throws {
        let (root, defaults, name) = try fixture()
        defer { cleanUp(root, name) }
        let original = root.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let store = FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks())
        let saved = try store.add(original)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("New", isDirectory: true))
        _ = store.resolveAll { _ in false }
        #expect(store.grants == [saved])
    }

    @Test func malformedStoredEntriesAreIgnored() throws {
        let (root, defaults, name) = try fixture()
        defer { cleanUp(root, name) }
        defaults.set([["path": "relative", "bookmark": Data()], ["path": "/x"], ["bookmark": Data([1])],
                      ["path": "/ok", "bookmark": Data([1, 2])]], forKey: FolderGrantStore.grantsKey)
        let store = FolderGrantStore(defaults: defaults, bookmarks: PlainBookmarks())
        #expect(store.grants == [FolderGrant(path: "/ok", bookmark: Data([1, 2]))])
        // A bookmark that does not resolve is reported, not thrown.
        let results = store.resolveAll { _ in true }
        #expect(results.first?.url == nil)
    }
}
