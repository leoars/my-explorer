// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import XCTest
@testable import ExplorerCore

final class LocalTransferServiceTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.LocalTransferTests.\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root.resolvingSymlinksInPath()
    }
    private func folder(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func file(_ parent: URL, _ name: String, _ text: String = "fixture") throws -> URL {
        let url = parent.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func clean(_ root: URL) { try? FileManager.default.removeItem(at: root) }
    private func expect(_ reason: LocalTransferFailure.Reason, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(reason)", file: file, line: line) }
        catch let failure as LocalTransferFailure { XCTAssertEqual(failure.reason, reason, file: file, line: line) }
        catch { XCTFail("Unexpected \(error)", file: file, line: line) }
    }
    private func copy(_ service: LocalTransferService, _ sources: [URL], _ destination: URL,
                      move: Bool = false, choice: StorageConflictChoice = .cancel) async throws -> [URL] {
        try await service.transfer(sources: sources, to: destination, move: move, resolveConflict: { _ in choice })
    }

    func testCopyHierarchyMetadataSymlinkAndUndo() async throws {
        let root = try fixture(); defer { clean(root) }
        let source = try folder(root, "Ação 日本語"), destination = try folder(root, "destination")
        _ = try folder(source, "empty")
        let original = try file(source, "notes.txt", "original")
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: original.path)
        let xattr = Data("custom metadata".utf8)
        XCTAssertEqual(xattr.withUnsafeBytes { setxattr(original.path, "com.myexplorer.test", $0.baseAddress, $0.count, 0, 0) }, 0)
        let fork = Data("resource fork".utf8)
        XCTAssertEqual(fork.withUnsafeBytes { setxattr(original.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }, 0)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: original.path)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("shortcut").path, withDestinationPath: "notes.txt")
        let service = LocalTransferService()
        let copied = try await copy(service, [source], destination)
        XCTAssertEqual(copied.map(\.path), [destination.appendingPathComponent(source.lastPathComponent).path])
        let result = copied[0].appendingPathComponent("notes.txt")
        XCTAssertEqual(try text(result), "original")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copied[0].appendingPathComponent("shortcut").path), "notes.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied[0].appendingPathComponent("empty").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(attributes[.modificationDate] as? Date, Date(timeIntervalSince1970: 1_700_000_000))
        for (key, expected) in [("com.myexplorer.test", xattr), ("com.apple.ResourceFork", fork)] {
            var bytes = [UInt8](repeating: 0, count: expected.count)
            XCTAssertEqual(getxattr(result.path, key, &bytes, bytes.count, 0, 0), expected.count)
            XCTAssertEqual(Data(bytes), expected)
        }
        let canUndo = await service.canUndo; XCTAssertTrue(canUndo)
        _ = try await service.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied[0].path))
        XCTAssertEqual(try text(original), "original")
        let after = await service.canUndo; XCTAssertFalse(after)
    }

    func testCopyDownloadedFileAndRefuseUndoAfterQuarantineChanges() async throws {
        let root = try fixture(); defer { clean(root) }
        let destination = try folder(root, "destination")
        let source = try file(root, "download.txt")
        let quarantine = "0083;665ede12;Safari;6C89D750-A56D-4B8F-A7CD-92ED627F7B3F"
        func mark(_ url: URL, _ value: String) throws {
            let bytes = Data(value.utf8)
            guard bytes.withUnsafeBytes({ setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }) == 0
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try mark(source, quarantine)
        let service = LocalTransferService()
        let copies = try await copy(service, [source], destination)
        let target = try XCTUnwrap(copies.first)
        XCTAssertEqual(try text(target), try text(source))
        XCTAssertGreaterThan(getxattr(target.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
        try mark(target, "0081;12345678;Other;6C89D750-A56D-4B8F-A7CD-92ED627F7B3F")
        await expect(.changed) { _ = try await service.undo() }
        XCTAssertEqual(try text(target), "fixture")
    }

    func testSameFolderCopyAutomaticallyKeepsBoth() async throws {
        let root = try fixture(); defer { clean(root) }
        let source = try file(root, "report.tar.gz", "original")
        _ = try file(root, "report.tar (2).gz", "existing")
        let service = LocalTransferService()
        let result = try await copy(service, [source], root)
        XCTAssertEqual(result[0].lastPathComponent, "report.tar (3).gz")
        XCTAssertEqual(try text(source), "original")
        _ = try await service.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: result[0].path))
    }

    func testReplaceAndUndoRestoresBothOriginals() async throws {
        let root = try fixture(); defer { clean(root) }
        let sourceFolder = try folder(root, "source"), destination = try folder(root, "destination")
        let source = try file(sourceFolder, "report", "new"), target = try file(destination, "report", "old")
        let service = LocalTransferService()
        var identity = stat(); XCTAssertEqual(stat(source.path, &identity), 0)
        _ = try await copy(service, [source], destination, move: true, choice: .replace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try text(target), "new")
        var moved = stat(); XCTAssertEqual(stat(target.path, &moved), 0)
        XCTAssertEqual(moved.st_ino, identity.st_ino)
        _ = try await service.undo()
        XCTAssertEqual(try text(source), "new")
        XCTAssertEqual(try text(target), "old")
        var restored = stat(); XCTAssertEqual(stat(source.path, &restored), 0)
        XCTAssertEqual(restored.st_ino, identity.st_ino)
    }

    func testMergeCopyPreservesExtrasAndUndoRestoresWholeTarget() async throws {
        let root = try fixture(); defer { clean(root) }
        let srcParent = try folder(root, "src"), destination = try folder(root, "destination")
        let source = try folder(srcParent, "folder"), target = try folder(destination, "folder")
        _ = try file(source, "same", "new"); _ = try file(source, "added", "added")
        _ = try file(target, "same", "old"); _ = try file(target, "extra", "extra")
        let service = LocalTransferService()
        _ = try await copy(service, [source], destination, choice: .replace)
        XCTAssertEqual(try text(target.appendingPathComponent("same")), "new")
        XCTAssertEqual(try text(target.appendingPathComponent("extra")), "extra")
        XCTAssertEqual(try text(target.appendingPathComponent("added")), "added")
        _ = try await service.undo()
        XCTAssertEqual(try text(target.appendingPathComponent("same")), "old")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)), ["same", "extra"])
    }

    func testMergeMoveLeavesSkippedItemsAndUndoRestoresSource() async throws {
        let root = try fixture(); defer { clean(root) }
        let srcParent = try folder(root, "src"), destination = try folder(root, "destination")
        let source = try folder(srcParent, "folder"), target = try folder(destination, "folder")
        _ = try file(source, "same", "new"); _ = try file(source, "added", "added")
        _ = try file(target, "same", "old")
        let service = LocalTransferService()
        _ = try await service.transfer(sources: [source], to: destination, move: true, resolveConflict: { conflict in
            conflict.isDirectory ? .replace : .skip
        })
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: source.path)), ["same"])
        XCTAssertEqual(try text(source.appendingPathComponent("same")), "new")
        XCTAssertEqual(try text(target.appendingPathComponent("same")), "old")
        XCTAssertEqual(try text(target.appendingPathComponent("added")), "added")
        _ = try await service.undo()
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: source.path)), ["same", "added"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)), ["same"])
    }

    func testKeepBothSkipAndCancelPreserveDestination() async throws {
        let root = try fixture(); defer { clean(root) }
        let srcParent = try folder(root, "src"), destination = try folder(root, "destination")
        let source = try file(srcParent, "same.txt", "new"), target = try file(destination, "same.txt", "old")
        let service = LocalTransferService()
        let skipped = try await copy(service, [source], destination, choice: .skip)
        XCTAssertTrue(skipped.isEmpty)
        let undo = await service.canUndo; XCTAssertFalse(undo)
        await expect(.cancelled) { _ = try await self.copy(service, [source], destination) }
        XCTAssertEqual(try text(target), "old")
        let result = try await copy(service, [source], destination, choice: .keepBoth)
        XCTAssertEqual(result[0].lastPathComponent, "same (2).txt")
        XCTAssertEqual(try text(result[0]), "new")
        await service.clearHistory()
    }

    func testUndoRejectsEditedOutputAndOccupiedSource() async throws {
        let root = try fixture(); defer { clean(root) }
        let srcParent = try folder(root, "src"), destination = try folder(root, "destination")
        let source = try file(srcParent, "file", "original")
        let service = LocalTransferService()
        let result = try await copy(service, [source], destination, move: true)
        _ = try file(srcParent, "file", "external replacement")
        await expect(.changed) { _ = try await service.undo() }
        XCTAssertEqual(try text(source), "external replacement")
        try FileManager.default.removeItem(at: source)
        try Data("edited".utf8).write(to: result[0])
        await expect(.changed) { _ = try await service.undo() }
        XCTAssertEqual(try text(result[0]), "edited")
        await service.clearHistory()
    }

    func testUndoChainAfterReplacingEarlierOutput() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), b = try folder(root, "b"), destination = try folder(root, "destination")
        let first = try file(a, "file", "first"), second = try file(b, "file", "second")
        let service = LocalTransferService()
        _ = try await copy(service, [first], destination)
        _ = try await copy(service, [second], destination, choice: .replace)
        _ = try await service.undo()
        XCTAssertEqual(try text(destination.appendingPathComponent("file")), "first")
        _ = try await service.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("file").path))
    }

    func testOneBatchWithDuplicateNamesRemainsUndoable() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), b = try folder(root, "b"), destination = try folder(root, "destination")
        let first = try file(a, "file", "first"), second = try file(b, "file", "second")
        let service = LocalTransferService()
        _ = try await copy(service, [first, second], destination, choice: .replace)
        XCTAssertEqual(try text(destination.appendingPathComponent("file")), "second")
        _ = try await service.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("file").path))
        XCTAssertEqual(try text(first), "first"); XCTAssertEqual(try text(second), "second")
    }

    func testUndoChainAfterAddingFileInsideEarlierCopiedFolder() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), destination = try folder(root, "destination")
        _ = try file(a, "original")
        let extra = try file(root, "extra")
        let service = LocalTransferService()
        let copied = try await copy(service, [a], destination)
        _ = try await copy(service, [extra], copied[0])
        _ = try await service.undo()
        _ = try await service.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied[0].path))
    }

    func testSourceChangeDuringConflictIsRejectedWithoutOverwrite() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), destination = try folder(root, "destination")
        let source = try file(a, "file", "first"), target = try file(destination, "file", "old")
        let service = LocalTransferService()
        await expect(.changed) {
            _ = try await service.transfer(sources: [source], to: destination, move: true, resolveConflict: { _ in
                try? Data("changed".utf8).write(to: source); return .replace
            })
        }
        XCTAssertEqual(try text(source), "changed")
        XCTAssertEqual(try text(target), "old")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path).contains { $0.hasPrefix(".my-explorer-") })
    }

    func testPartialCancellationKeepsCommittedItemUndoable() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), destination = try folder(root, "destination")
        let first = try file(a, "first", "first"), second = try file(a, "second", "second")
        _ = try file(destination, "second", "existing")
        let service = LocalTransferService()
        do {
            _ = try await copy(service, [first, second], destination)
            XCTFail("Expected cancellation")
        } catch let failure as LocalTransferFailure {
            XCTAssertEqual(failure.reason, .cancelled)
            XCTAssertEqual(failure.completed, [destination.appendingPathComponent("first")])
        }
        _ = try await service.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("first").path))
        XCTAssertEqual(try text(destination.appendingPathComponent("second")), "existing")
    }

    func testProgressPauseResumeAndCancelBeforePublish() async throws {
        let root = try fixture(); defer { clean(root) }
        let source = root.appendingPathComponent("large.bin"), destination = try folder(root, "destination")
        try Data(repeating: 0x52, count: 8 * 1_048_576).write(to: source)
        let service = LocalTransferService(), control = LocalTransferControl()
        let state = ProgressState()
        let task = Task {
            try await service.transfer(sources: [source], to: destination, move: false, resolveConflict: { _ in .cancel }, progress: { progress in
                state.record(progress)
                if progress.bytesCompleted > 0 && state.pauseOnce() { control.pause() }
            }, control: control)
        }
        for _ in 0..<500 { if control.isPaused { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(control.isPaused)
        let previous = state.lastBytes
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.lastBytes, previous)
        control.resume()
        let result = try await task.value
        XCTAssertEqual(result, [destination.appendingPathComponent("large.bin")])
        XCTAssertEqual(state.lastBytes, 8 * 1_048_576)
        _ = try await service.undo()
        let cancel = LocalTransferControl()
        await expect(.cancelled) {
            _ = try await service.transfer(sources: [source], to: destination, move: false, resolveConflict: { _ in .cancel }, progress: { progress in
                if progress.bytesCompleted > 0 { cancel.cancel() }
            }, control: cancel)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("large.bin").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testDestinationMutationImmediatelyBeforeRenameIsNotAccepted() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), destination = try folder(root, "destination")
        let source = try file(a, "file", "new"), target = try file(destination, "file", "old")
        let service = LocalTransferService(hooks: LocalTransferHooks(beforeRename: { from, _ in
            if from == target { try? Data("external update".utf8).write(to: from) }
        }))
        await expect(.changed) { _ = try await self.copy(service, [source], destination, choice: .replace) }
        XCTAssertEqual(try text(target), "external update")
        XCTAssertEqual(try text(source), "new")
        let undo = await service.canUndo; XCTAssertFalse(undo)
    }

    func testUndoRechecksImmediatelyBeforeQuarantiningOutput() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), destination = try folder(root, "destination")
        let source = try file(a, "file", "new")
        let service = LocalTransferService(hooks: LocalTransferHooks(beforeRename: { from, to in
            if to.lastPathComponent == "undo-output" { try? Data("external edit".utf8).write(to: from) }
        }))
        let result = try await copy(service, [source], destination)
        await expect(.changed) { _ = try await service.undo() }
        XCTAssertEqual(try text(result[0]), "external edit")
        await service.clearHistory()
    }

    func testPostRenameMutationDuringUndoRetainsRecoveryInsteadOfDeleting() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), destination = try folder(root, "destination")
        let source = try file(a, "file", "new")
        let service = LocalTransferService(hooks: LocalTransferHooks(afterRename: { _, to in
            if to.lastPathComponent == "undo-output" { try? Data("external edit after rename".utf8).write(to: to) }
        }))
        _ = try await copy(service, [source], destination)
        do { _ = try await service.undo(); XCTFail("Expected retained recovery") }
        catch let failure as LocalTransferFailure {
            XCTAssertEqual(failure.reason, .recoveryRequired)
            XCTAssertEqual(failure.recoveryLocations.count, 1)
            let recovery = try XCTUnwrap(failure.recoveryLocations.first)
            defer { clean(recovery) }
            XCTAssertTrue(LocalTransferRecovery.isProtected(recovery))
            XCTAssertEqual(try text(recovery.appendingPathComponent("undo-output")), "external edit after rename")
            await service.clearHistory()
            XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("undo-output").path))
        }
        XCTAssertEqual(try text(source), "new")
    }

    func testBoundedHistoryAndRecoveryIsNotInsideCopiedFolder() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), destination = try folder(root, "destination"), elsewhere = try folder(root, "elsewhere")
        let source = try file(a, "file", "new"), target = try file(destination, "file", "old")
        let service = LocalTransferService(historyLimit: 1)
        _ = try await copy(service, [source], destination, choice: .replace)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["file"])
        XCTAssertFalse(LocalTransferRecovery.containsRecoveryData(at: destination))
        let result = try await copy(service, [destination], elsewhere)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result[0].path), ["file"])
        _ = try await service.undo()
        XCTAssertEqual(try text(target), "new")
        let undo = await service.canUndo; XCTAssertFalse(undo)
    }

    func testFailedDirectMoveUndoRetainsUnchangedOriginalBackupAfterClearAndEviction() async throws {
        for expireHistory in [false, true] {
            let root = try fixture(); defer { clean(root) }
            let sourceFolder = try folder(root, "source"), destination = try folder(root, "destination")
            let source = try file(sourceFolder, "file", "moved bytes"), target = try file(destination, "file", "original destination")
            let service = LocalTransferService(historyLimit: 1, hooks: LocalTransferHooks(afterRename: { from, to in
                // During direct-move Undo, another process occupies the now-vacant destination.
                if from == target && to == source { try? Data("external destination".utf8).write(to: target) }
            }))
            _ = try await copy(service, [source], destination, move: true, choice: .replace)
            var recovery: URL?
            do { _ = try await service.undo(); XCTFail("Expected failed rollback with retained original") }
            catch let failure as LocalTransferFailure {
                XCTAssertEqual(failure.reason, .recoveryRequired)
                recovery = try XCTUnwrap(failure.recoveryLocations.first)
            }
            let retained = try XCTUnwrap(recovery)
            defer { clean(retained) }
            if expireHistory {
                let another = try file(sourceFolder, "another", "another")
                _ = try await copy(service, [another], destination)
            }
            await service.clearHistory()
            XCTAssertEqual(try text(retained.appendingPathComponent("original")), "original destination")
            XCTAssertEqual(try text(source), "moved bytes")
            XCTAssertEqual(try text(target), "external destination")
        }
    }

    func testExistingDestinationWithRecoveryDataCannotBeMergedOrReplaced() async throws {
        let root = try fixture(); defer { clean(root) }
        let a = try folder(root, "a"), destination = try folder(root, "destination")
        let source = try folder(a, "folder"), target = try folder(destination, "folder")
        _ = try file(source, "new")
        let recovery = try folder(target, "recovery")
        XCTAssertEqual(chmod(recovery.path, 0o700), 0)
        try LocalTransferRecovery.mark(recovery)
        _ = try file(recovery, "original", "retained original")
        let service = LocalTransferService()
        await expect(.unsupportedEntry) { _ = try await self.copy(service, [source], destination, choice: .replace) }
        XCTAssertEqual(try text(recovery.appendingPathComponent("original")), "retained original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("new").path))
    }

    func testMutationBeforeRecordingCannotBecomeUndoBaseline() async throws {
        for moving in [false, true] {
            let root = try fixture(); defer { clean(root) }
            let a = try folder(root, "a"), destination = try folder(root, "destination")
            let source = try file(a, "file", "new")
            let service = LocalTransferService(hooks: LocalTransferHooks(beforeRecord: { output in
                try? Data("external update before recording".utf8).write(to: output)
            }))
            do { _ = try await copy(service, [source], destination, move: moving); XCTFail("Expected recovery") }
            catch let failure as LocalTransferFailure {
                XCTAssertEqual(failure.reason, .recoveryRequired)
                for recovery in failure.recoveryLocations { clean(recovery) }
            }
            XCTAssertEqual(try text(destination.appendingPathComponent("file")), "external update before recording")
            let undo = await service.canUndo; XCTAssertFalse(undo)
        }
    }

    func testCrossVolumeMoveAndUndoOnDisposableVolumeWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["MYEXPLORER_TEST_VOLUME"] else { throw XCTSkip("Set MYEXPLORER_TEST_VOLUME to a disposable mounted volume") }
        let root = try fixture(); defer { clean(root) }
        let destination = URL(fileURLWithPath: path).appendingPathComponent("MyExplorer.Tests.\(UUID())")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { clean(destination) }
        var left = stat(), right = stat()
        XCTAssertEqual(stat(root.path, &left), 0); XCTAssertEqual(stat(destination.path, &right), 0)
        XCTAssertNotEqual(left.st_dev, right.st_dev)
        let source = try file(root, "cross-volume.txt", "preserve original bytes")
        let service = LocalTransferService()
        let result = try await copy(service, [source], destination, move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try text(result[0]), "preserve original bytes")
        _ = try await service.undo()
        XCTAssertEqual(try text(source), "preserve original bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result[0].path))

        let sourceTree = try folder(root, "tree"), targetTree = try folder(destination, "tree")
        _ = try file(sourceTree, "skip.txt", "source skipped")
        _ = try file(sourceTree, "replace.txt", "source replacement")
        let nested = try folder(sourceTree, "nested 日本語")
        _ = try file(nested, "added.txt", "nested payload")
        try FileManager.default.createSymbolicLink(atPath: sourceTree.appendingPathComponent("link").path, withDestinationPath: "nested 日本語/added.txt")
        _ = try file(targetTree, "skip.txt", "target skipped")
        _ = try file(targetTree, "replace.txt", "target original")
        _ = try file(targetTree, "extra.txt", "target extra")
        var originalTree = stat(); XCTAssertEqual(stat(sourceTree.path, &originalTree), 0)
        _ = try await service.transfer(sources: [sourceTree], to: destination, move: true, resolveConflict: { conflict in
            conflict.source.lastPathComponent == "skip.txt" ? .skip : .replace
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sourceTree.path), ["skip.txt"])
        XCTAssertEqual(try text(sourceTree.appendingPathComponent("skip.txt")), "source skipped")
        XCTAssertEqual(try text(targetTree.appendingPathComponent("skip.txt")), "target skipped")
        XCTAssertEqual(try text(targetTree.appendingPathComponent("replace.txt")), "source replacement")
        XCTAssertEqual(try text(targetTree.appendingPathComponent("nested 日本語/added.txt")), "nested payload")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: targetTree.appendingPathComponent("link").path), "nested 日本語/added.txt")
        _ = try await service.undo()
        XCTAssertEqual(try text(sourceTree.appendingPathComponent("replace.txt")), "source replacement")
        XCTAssertEqual(try text(sourceTree.appendingPathComponent("nested 日本語/added.txt")), "nested payload")
        XCTAssertEqual(try text(targetTree.appendingPathComponent("replace.txt")), "target original")
        XCTAssertEqual(try text(targetTree.appendingPathComponent("extra.txt")), "target extra")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetTree.appendingPathComponent("nested 日本語").path))
        var restoredTree = stat(); XCTAssertEqual(stat(sourceTree.path, &restoredTree), 0)
        XCTAssertEqual(restoredTree.st_ino, originalTree.st_ino)
    }
}

private final class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var paused = false
    var lastBytes: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
    func record(_ value: StorageTransferProgress) { lock.lock(); bytes = value.bytesCompleted; lock.unlock() }
    func pauseOnce() -> Bool { lock.lock(); defer { lock.unlock() }; if paused { return false }; paused = true; return true }
}
