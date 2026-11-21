// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

private struct LibraryFixtureTrash: StorageTrash {
    let folder: URL
    func trash(_ source: URL) async throws { _ = try await trashReturningURL(source) }
    func trashReturningURL(_ source: URL) async throws -> URL? {
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
}

struct TrashLibraryTests {
    private struct Fixture {
        let root: URL, trash: URL, receipts: URL, origin: URL
        var library: TrashLibrary { let trash = trash; return TrashLibrary(directory: receipts, roots: { [trash] }) }
        let fm = FileManager.default

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            trash = root.appendingPathComponent("Trash")
            receipts = root.appendingPathComponent("Index")
            origin = root.appendingPathComponent("Origin")
            for url in [trash, origin] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        }

        func trashFile(named name: String, history: LocalTransferService? = nil) async throws -> URL {
            let file = origin.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            let service = StorageDeletionService(clientFactory: { _ in throw CancellationError() },
                                                 trash: LibraryFixtureTrash(folder: trash), trashLibrary: library)
            let plan = try await service.plan(sources: [file])
            _ = try await service.execute(planID: plan.id, undoHistory: history) { _ in true }
            return file
        }
    }

    @Test func originalSurvivesRelaunchAndCollisionIsExclusive() async throws {
        let f = try Fixture(); defer { try? f.fm.removeItem(at: f.root) }
        let source = try await f.trashFile(named: "Açúcar.txt")
        let reopened = f.library
        let entry = try #require(try await reopened.inventory().entries.first)
        #expect(entry.original?.path == source.path)
        try Data([1]).write(to: source)
        do { _ = try await reopened.restore(entry, into: nil, keepBoth: false); Issue.record("Expected collision") }
        catch let error as LocalTransferFailure { #expect(error.reason == .conflict) }
        #expect(try Data(contentsOf: source) == Data([1]))
        let restored = try await reopened.restore(entry, into: nil, keepBoth: true)
        #expect(restored.lastPathComponent == "Açúcar (2).txt")
        #expect(try Data(contentsOf: restored) == Data("Açúcar.txt".utf8))
        #expect(try await reopened.inventory().entries.isEmpty)
        #expect(try f.fm.contentsOfDirectory(atPath: f.receipts.path).isEmpty)
    }

    @Test func missingOrReplacedParentRequiresChosenDestination() async throws {
        let f = try Fixture(); defer { try? f.fm.removeItem(at: f.root) }
        _ = try await f.trashFile(named: "notes")
        let library = f.library
        let entry = try #require(try await library.inventory().entries.first)
        try f.fm.moveItem(at: f.origin, to: f.root.appendingPathComponent("renamed"))
        await #expect(throws: LocalTransferFailure.self) { try await library.restore(entry, into: nil, keepBoth: false) }
        try f.fm.createDirectory(at: f.origin, withIntermediateDirectories: false)
        await #expect(throws: LocalTransferFailure.self) { try await library.restore(entry, into: nil, keepBoth: false) }
        _ = try await library.restore(entry, into: f.origin, keepBoth: false)
        #expect(f.fm.fileExists(atPath: f.origin.appendingPathComponent("notes").path))
    }

    @Test func outsideItemsCanChooseDestinationAndDeletionPreservesSymlinkTarget() async throws {
        let f = try Fixture(); defer { try? f.fm.removeItem(at: f.root) }
        let outside = f.root.appendingPathComponent("original")
        try Data([9]).write(to: outside)
        let link = f.trash.appendingPathComponent("link")
        try f.fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let foreign = f.trash.appendingPathComponent("finder-item")
        try Data([2]).write(to: foreign)
        let library = f.library
        let list = try await library.inventory()
        #expect(list.entries.allSatisfy { $0.original == nil })
        let linked = try #require(list.entries.first { $0.name == "link" })
        try await library.erase(linked)
        #expect(try Data(contentsOf: outside) == Data([9]))
        let item = try #require(list.entries.first { $0.name == "finder-item" })
        await #expect(throws: LocalTransferFailure.self) { try await library.restore(item, into: nil, keepBoth: false) }
        _ = try await library.restore(item, into: f.origin, keepBoth: false)
        #expect(try Data(contentsOf: f.origin.appendingPathComponent("finder-item")) == Data([2]))
    }

    @Test func replacementAndDisconnectedVolumeNeverModifyAnotherItem() async throws {
        let f = try Fixture(); defer { try? f.fm.removeItem(at: f.root) }
        _ = try await f.trashFile(named: "same.txt")
        let library = f.library
        let entry = try #require(try await library.inventory().entries.first)
        let offline = TrashLibrary(directory: f.receipts, roots: { [] })
        #expect(try await offline.inventory().entries.isEmpty)
        await #expect(throws: LocalTransferFailure.self) { try await offline.erase(entry) }
        #expect(try f.fm.contentsOfDirectory(atPath: f.receipts.path).count == 1)
        try f.fm.moveItem(at: entry.location, to: f.root.appendingPathComponent("held"))
        try Data([7]).write(to: entry.location)
        await #expect(throws: LocalTransferFailure.self) { try await library.erase(entry) }
        #expect(try Data(contentsOf: entry.location) == Data([7]))
        #expect(try await library.inventory().entries.first?.original == nil)
    }

    @Test func undoAndExternalRemovalReconcilePersistedReceipts() async throws {
        let f = try Fixture(); defer { try? f.fm.removeItem(at: f.root) }
        let journal = LocalTransferService()
        _ = try await f.trashFile(named: "one", history: journal)
        _ = try await journal.undo()
        #expect(try await f.library.inventory().entries.isEmpty)
        _ = try await f.trashFile(named: "two", history: journal)
        let entry = try #require(try await f.library.inventory().entries.first)
        try await f.library.erase(entry)
        await journal.forgetTrash(location: entry.location)
        #expect(await journal.undoKind == nil)
        #expect(try f.fm.contentsOfDirectory(atPath: f.receipts.path).isEmpty)
    }

    @Test func restoresAcrossVolumesWhenDisposableVolumeIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["MYEXPLORER_TEST_VOLUME"] else { return }
        let f = try Fixture(); defer { try? f.fm.removeItem(at: f.root) }
        let target = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString)
        try f.fm.createDirectory(at: target, withIntermediateDirectories: false)
        defer { try? f.fm.removeItem(at: target) }
        _ = try await f.trashFile(named: "original")
        let entry = try #require(try await f.library.inventory().entries.first)
        let destination = try await f.library.restore(entry, into: target, keepBoth: false)
        #expect(try Data(contentsOf: destination) == Data("original".utf8))
        #expect(!f.fm.fileExists(atPath: entry.location.path))
    }
}
