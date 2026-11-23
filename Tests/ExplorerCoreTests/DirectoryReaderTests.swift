// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

@MainActor
final class DirectoryReaderTests: XCTestCase {
    func testEnumerationHiddenFilesNaturalOrderPackagesAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let folder = root.appendingPathComponent("Z folder")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Demo.app"), withIntermediateDirectories: true)
        for name in ["file10.txt", "file2.txt", ".secret", "Português 日本語.txt"] {
            try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
        }
        try manager.createSymbolicLink(at: root.appendingPathComponent("Folder link"), withDestinationURL: folder)
        let reader = DirectoryReader()
        let entries = try await reader.entries(at: root, showHidden: false)
        XCTAssertFalse(entries.contains { $0.name == ".secret" })
        XCTAssertTrue(entries.contains { $0.name == "Português 日本語.txt" })
        XCTAssertLessThan(try XCTUnwrap(entries.firstIndex { $0.name == "file2.txt" }),
                          try XCTUnwrap(entries.firstIndex { $0.name == "file10.txt" }))
        let package = try XCTUnwrap(entries.first { $0.name == "Demo.app" })
        XCTAssertTrue(package.isPackage)
        XCTAssertFalse(package.canNavigate)
        let link = try XCTUnwrap(entries.first { $0.name == "Folder link" })
        XCTAssertTrue(link.isSymbolicLink)
        XCTAssertTrue(link.canNavigate)
        let all = try await reader.entries(at: root, showHidden: true)
        XCTAssertTrue(all.contains { $0.name == ".secret" })
        XCTAssertEqual(entries.first { $0.name == "file2.txt" }?.size, 7)
    }

    func testDescendingSortKeepsFoldersFirst() {
        let entries = [entry("a.txt", size: 10), entry("folder", directory: true), entry("b.txt", size: 100)]
        XCTAssertEqual(EntryOrdering.sorted(entries, by: .size, ascending: false).map(\.name), ["folder", "b.txt", "a.txt"])
        XCTAssertEqual(EntryOrdering.sorted(entries, by: .name, ascending: false).map(\.name), ["folder", "b.txt", "a.txt"])
    }

    func testMissingDirectoryFailsRatherThanLookingEmpty() async {
        do {
            _ = try await DirectoryReader().entries(at: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/missing"), showHidden: false)
            XCTFail("Missing directories must report an error")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testUpRestoresSelectionThroughMacOSTmpAlias() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("my-explorer-test-\(UUID().uuidString)")
        let child = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = DirectorySession(url: child)
        await session.navigate(.reload).value
        await session.navigate(.up).value
        let entry = try XCTUnwrap(session.entries.first { $0.name == "Documents" })
        XCTAssertTrue(session.history.current.selectedPaths.contains(entry.id))
        XCTAssertEqual(entry.url.path, child.path)
    }

    func testForgetDropsRemovedItemsAndTheirSelectionAtOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
        let session = DirectorySession(url: root)
        await session.navigate(.reload).value
        let gone = try XCTUnwrap(session.entries.first { $0.name == "a.txt" })
        session.remember(selection: [gone.id], scrollOffset: 120)
        XCTAssertTrue(session.forget([gone.id]))
        XCTAssertEqual(session.entries.map(\.name), ["b.txt"])
        XCTAssertTrue(session.history.current.selectedPaths.isEmpty)
        XCTAssertEqual(session.history.current.scrollOffset, 120)
        XCTAssertFalse(session.forget([gone.id]))
    }

    @MainActor func testAReadingBegunBeforeARemovalDoesNotBringTheItemBack() async throws {
        let reader = GatedReader()
        let a = entry("a.txt"), b = entry("b.txt")
        let session = DirectorySession(url: URL(fileURLWithPath: "/fixture"), reader: reader)
        let first = session.navigate(.reload)
        await reader.release([a, b])
        await first.value
        session.refreshKeepingView()
        session.forget([a.id])
        await reader.release([a, b])
        while session.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.entries.map(\.name), ["b.txt"])
        // A reading begun after the removal is believed: the item may have been restored.
        session.refreshKeepingView()
        await reader.release([a, b])
        while session.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.entries.map(\.name), ["a.txt", "b.txt"])
    }

    @MainActor func testAReadingBegunBeforeARenameDoesNotBringTheOldNameBack() async throws {
        let reader = GatedReader()
        let a = entry("a.txt"), b = entry("b.txt")
        let session = DirectorySession(url: URL(fileURLWithPath: "/fixture"), reader: reader)
        let first = session.navigate(.reload)
        await reader.release([a, b])
        await first.value
        session.refreshKeepingView()
        let renamed = a.renamed(to: "z.txt")
        XCTAssertTrue(session.replace(a.id, with: renamed))
        await reader.release([a, b])
        while session.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(Set(session.entries.map(\.name)), ["b.txt", "z.txt"])
        // Put back, as when the rename fails: the old name is the one that stays.
        session.refreshKeepingView()
        XCTAssertTrue(session.replace(renamed.id, with: a))
        await reader.release([a, b])
        while session.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(Set(session.entries.map(\.name)), ["a.txt", "b.txt"])
    }

    func testReplaceShowsARenameAtOnceAndKeepsItSelected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
        let session = DirectorySession(url: root)
        await session.navigate(.reload).value
        let old = try XCTUnwrap(session.entries.first { $0.name == "a.txt" })
        session.remember(selection: [old.id], scrollOffset: 40)
        let renamed = old.renamed(to: "c.md")
        XCTAssertEqual(renamed.kind, "MD")
        XCTAssertEqual(renamed.url.deletingLastPathComponent().path, old.url.deletingLastPathComponent().path)
        XCTAssertTrue(session.replace(old.id, with: renamed))
        XCTAssertEqual(Set(session.entries.map(\.name)), ["b.txt", "c.md"])
        XCTAssertEqual(session.history.current.selectedPaths, [renamed.id])
        XCTAssertEqual(session.history.current.scrollOffset, 40)
        XCTAssertFalse(session.replace(old.id, with: renamed))
    }

    private func entry(_ name: String, directory: Bool = false, size: Int64 = 0) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/fixture/\(name)"), name: name, isDirectory: directory, size: size)
    }

    func testVaultPackageAndLinksRejectExplorationAndFolderDestinations() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault = root.appendingPathComponent("Documents.myexplorervault")
        let contents = vault.appendingPathComponent("contents.sparsebundle")
        let link = root.appendingPathComponent("Shortcut")
        let internalLink = root.appendingPathComponent("Inside")
        try files.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try files.createSymbolicLink(at: link, withDestinationURL: vault)
        try files.createSymbolicLink(at: internalLink, withDestinationURL: contents)
        let reader = DirectoryReader()
        let entries = try await reader.entries(at: root, showHidden: true)
        for location in [vault, link, internalLink] {
            let entry = try XCTUnwrap(entries.first { $0.name == location.lastPathComponent })
            XCTAssertEqual(entry.secureFolderURL?.resolvingSymlinksInPath().path, vault.resolvingSymlinksInPath().path)
            XCTAssertTrue(entry.isPackage)
            XCTAssertFalse(entry.canNavigate)
        }
        for location in [vault, contents, link, internalLink] {
            do {
                _ = try await reader.entries(at: location, showHidden: true)
                XCTFail("Listed a locked vault through " + location.lastPathComponent)
            } catch let error as CocoaError {
                XCTAssertEqual(error.code, .fileReadNoPermission)
            }
        }
    }

    func testDirectoryLinksEnumerateTargetsWithSelectedPathIdentity() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("Target")
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try Data("fixture".utf8).write(to: target.appendingPathComponent("Notes.txt"))
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("Relative").path, withDestinationPath: "Target")
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("Chain").path, withDestinationPath: "Relative")
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("Macintosh HD").path, withDestinationPath: "/")
        let reader = DirectoryReader()
        for name in ["Relative", "Chain", "Macintosh HD"] {
            let link = root.appendingPathComponent(name)
            let entries = try await reader.entries(at: link, showHidden: true)
            let expected = try await reader.entries(at: name == "Macintosh HD" ? URL(fileURLWithPath: "/") : target, showHidden: true)
            XCTAssertEqual(Set(entries.map(\.name)), Set(expected.map(\.name)))
            XCTAssertFalse(entries.isEmpty)
            for entry in entries { XCTAssertEqual(entry.url.deletingLastPathComponent().path, link.path) }
        }
    }

    func testDirectoryLinkNavigationPreservesHistoryAndRejectsNonDirectories() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("Target")
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try Data("fixture".utf8).write(to: target.appendingPathComponent("Notes.txt"))
        for (name, destination) in [("Link", "Target"), ("File link", "Target/Notes.txt"), ("Broken", "Missing"), ("Cycle", "Cycle")] {
            try manager.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: destination)
        }
        let session = DirectorySession(url: root)
        await session.navigate(.reload).value
        let link = try XCTUnwrap(session.entries.first { $0.name == "Link" })
        XCTAssertTrue(link.canNavigate)
        session.remember(selection: [link.id], scrollOffset: 0)
        await session.navigate(.visit(link.url)).value
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.history.current.url.path, link.url.path)
        XCTAssertEqual(session.entries.map(\.name), ["Notes.txt"])
        await session.navigate(.back).value
        XCTAssertTrue(session.history.current.selectedPaths.contains(link.id))
        await session.navigate(.forward).value
        XCTAssertNil(session.failure)
        await session.navigate(.up).value
        XCTAssertEqual(session.history.current.url.path, root.path)
        XCTAssertTrue(session.history.current.selectedPaths.contains(link.id))
        for name in ["File link", "Broken", "Cycle"] {
            let entry = try XCTUnwrap(session.entries.first { $0.name == name })
            XCTAssertFalse(entry.canNavigate)
            await session.navigate(.visit(entry.url)).value
            XCTAssertNotNil(session.failure)
            XCTAssertEqual(session.history.current.url.path, root.path)
        }
    }
}

private final class GatedReader: DirectoryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<[FileEntry], Never>] = []
    func entries(at url: URL, showHidden: Bool) async throws -> [FileEntry] {
        await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
    }
    func release(_ entries: [FileEntry]) async {
        while lock.withLock({ waiting.isEmpty }) { try? await Task.sleep(for: .milliseconds(5)) }
        lock.withLock { waiting.removeFirst() }.resume(returning: entries)
    }
}
