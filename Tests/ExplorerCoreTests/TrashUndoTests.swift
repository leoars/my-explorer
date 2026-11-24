// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

private struct FixtureTrash: StorageTrash {
    let folder: URL
    let refuse: String?
    /// Local items go to the Trash in parallel, and after a failure nothing new starts. The refusal
    /// waits until this item has gone, so the test does not depend on which one runs first.
    var refuseAfter: URL?
    func trash(_ source: URL) async throws { _ = try await trashReturningURL(source) }
    func trashReturningURL(_ source: URL) async throws -> URL? {
        if source.lastPathComponent == refuse {
            if let refuseAfter {
                for _ in 0..<400 where FileManager.default.fileExists(atPath: refuseAfter.path) { try await Task.sleep(for: .milliseconds(5)) }
            }
            throw CocoaError(.fileWriteNoPermission)
        }
        let result = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: source, to: result)
        return result
    }
}

struct TrashUndoTests {
    private func withFixture(_ body: (URL, URL, LocalTransferService) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root, trash, LocalTransferService())
    }

    private func remove(_ files: [URL], trash: URL, journal: LocalTransferService, refuse: String? = nil, refuseAfter: URL? = nil) async throws {
        let service = StorageDeletionService(clientFactory: { _ in throw CancellationError() },
                                             trash: FixtureTrash(folder: trash, refuse: refuse, refuseAfter: refuseAfter))
        let plan = try await service.plan(sources: files, recursive: true)
        _ = try await service.execute(planID: plan.id, undoHistory: journal) { _ in true }
    }

    @Test func cancelWholeGroupAndKeepBothWithReservedNames() async throws {
        try await withFixture { root, trash, journal in
            let first = root.appendingPathComponent("a.txt"), second = root.appendingPathComponent("a (2).txt")
            try Data([1]).write(to: first)
            try Data([2]).write(to: second)
            try await remove([first, second], trash: trash, journal: journal)
            try Data([3]).write(to: first)
            do { _ = try await journal.undo(); Issue.record("Conflict should cancel") }
            catch let failure as LocalTransferFailure { #expect(failure.reason == .cancelled) }
            #expect(!FileManager.default.fileExists(atPath: second.path))
            #expect(try Data(contentsOf: first) == Data([3]))
            _ = try await journal.undo(resolveTrashConflict: { _ in .keepBoth })
            #expect(try Data(contentsOf: second) == Data([2]))
            #expect(try Data(contentsOf: root.appendingPathComponent("a (3).txt")) == Data([1]))
            #expect(try Data(contentsOf: first) == Data([3]))
            #expect(await journal.undoKind == nil)
        }
    }

    @Test func partialDeleteRestoresBeforeEarlierCopy() async throws {
        try await withFixture { root, trash, journal in
            let source = root.appendingPathComponent("one")
            let dest = root.appendingPathComponent("output")
            let rejected = root.appendingPathComponent("two")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            try Data([4]).write(to: source)
            try Data([5]).write(to: rejected)
            let copies = try await journal.transfer(sources: [source], to: dest, move: false, resolveConflict: { _ in .cancel })
            let copy = try #require(copies.first)
            do { try await remove([copy, rejected], trash: trash, journal: journal, refuse: "two", refuseAfter: copy); Issue.record("Expected failure") }
            catch let failure as StorageDeletionFailure { #expect(failure.completed.map(\.path) == [copy.path]) }
            #expect(await journal.undoKind == .trash)
            _ = try await journal.undo()
            #expect(try Data(contentsOf: copy) == Data([4]))
            #expect(await journal.undoKind == .copy)
            _ = try await journal.undo()
            #expect(!FileManager.default.fileExists(atPath: copy.path))
            #expect(try Data(contentsOf: source) == Data([4]))
        }
    }

    @Test func restoresFolderAndKeepsTrashedItemsWhenHistoryExpires() async throws {
        try await withFixture { root, trash, _ in
            let journal = LocalTransferService(historyLimit: 1)
            let fm = FileManager.default
            let folder = root.appendingPathComponent("Project", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            let child = folder.appendingPathComponent("Notes")
            try Data([7]).write(to: child)
            try await remove([folder], trash: trash, journal: journal)
            _ = try await journal.undo()
            #expect(try Data(contentsOf: child) == Data([7]))
            try await remove([folder], trash: trash, journal: journal)
            let other = root.appendingPathComponent("Other")
            try Data([8]).write(to: other)
            try await remove([other], trash: trash, journal: journal)
            await journal.clearHistory()
            #expect(await journal.undoKind == nil)
            #expect(try fm.contentsOfDirectory(atPath: trash.path).count == 2)
        }
    }

    @Test func refusesReplacedParentAndEmptiedTrash() async throws {
        try await withFixture { root, trash, journal in
            let parent = root.appendingPathComponent("folder")
            let previous = root.appendingPathComponent("former")
            let item = parent.appendingPathComponent("item")
            let fm = FileManager.default
            try fm.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data([1]).write(to: item)
            try await remove([item], trash: trash, journal: journal)
            try fm.moveItem(at: parent, to: previous)
            try fm.createDirectory(at: parent, withIntermediateDirectories: false)
            do { _ = try await journal.undo(); Issue.record("Replaced parent") }
            catch let failure as LocalTransferFailure { #expect(failure.reason == .changed) }
            #expect(!fm.fileExists(atPath: item.path))
            for url in try fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) { try fm.removeItem(at: url) }
            do { _ = try await journal.undo(); Issue.record("Empty Trash") }
            catch let failure as LocalTransferFailure { #expect(failure.reason == .trashUnavailable) }
            #expect(await journal.undoKind == nil)
        }
    }
}
