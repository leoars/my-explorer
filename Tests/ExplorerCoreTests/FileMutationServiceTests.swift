// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class FileMutationServiceTests: XCTestCase, @unchecked Sendable {
    private let service = FileMutationService()
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.MutationTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func folder(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    private func file(_ url: URL, _ contents: String) throws { try Data(contents.utf8).write(to: url) }
    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func expect<T: Sendable>(_ reason: FileMutationFailure.Reason, completed: Int = 0,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ operation: @Sendable () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected operation failure", file: file, line: line) }
        catch let error as FileMutationFailure {
            XCTAssertTrue(error.reason == reason, "Unexpected reason: \(error.reason)", file: file, line: line)
            XCTAssertEqual(error.completed, completed, file: file, line: line)
        }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
    private func assertNoStaging(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: url.path).contains { $0.hasPrefix(".my-explorer-copy-") }, file: file, line: line)
    }

    func testCreateRenameUnicodeAndRejectInvalidNames() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let created = try await service.newFolder(in: root, name: "Ação 日本語")
        let renamed = try await service.rename(created, to: "한국어 é")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
        for invalid in ["", ".", "..", "a/b", "a:b", "nul\0tail"] {
            await expect(.invalidName) { try await service.newFolder(in: root, name: invalid) }
            await expect(.invalidName) { try await service.rename(renamed, to: invalid) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["한국어 é"])
    }

    func testCaseOnlyRenameChangesDirectoryEntryWithoutReplacingOtherFile() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("report.txt")
        try file(source, "original")
        let target = try await service.rename(source, to: "Report.txt")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Report.txt"])
        XCTAssertEqual(try text(target), "original")
        let other = root.appendingPathComponent("other.txt")
        try file(other, "untouched")
        await expect(.conflict) { try await service.rename(target, to: "other.txt") }
        XCTAssertEqual(try text(target), "original")
        XCTAssertEqual(try text(other), "untouched")
    }

    func testExistingDestinationsAndDanglingLinksRemainUntouched() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let sourceFolder = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try folder(sourceFolder); try folder(destination)
        let source = sourceFolder.appendingPathComponent("item.txt")
        try file(source, "source")
        let target = destination.appendingPathComponent("item.txt")
        try file(target, "existing")
        for move in [false, true] {
            await expect(.conflict) { try await service.transfer([source], to: destination, move: move) }
            XCTAssertEqual(try text(source), "source")
            XCTAssertEqual(try text(target), "existing")
        }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "absent-target")
        await expect(.conflict) { try await service.transfer([source], to: destination, move: false) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), "absent-target")
        await expect(.conflict) { try await service.newFolder(in: root, name: "destination") }
        await expect(.conflict) { try await service.newFolder(in: destination, name: "item.txt") }
        try assertNoStaging(destination)
    }

    func testCopyPreservesHierarchyLinksAndSourceThenMoveWithinVolume() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try folder(source.appendingPathComponent("empty")); try folder(destination)
        try file(source.appendingPathComponent("notes.txt"), "original")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("shortcut").path, withDestinationPath: "notes.txt")
        let copied = try await service.transfer([source], to: destination, move: false)
        XCTAssertEqual(copied.map(\.path), [destination.appendingPathComponent("source").path])
        XCTAssertEqual(try text(source.appendingPathComponent("notes.txt")), "original")
        XCTAssertEqual(try text(copied[0].appendingPathComponent("notes.txt")), "original")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copied[0].appendingPathComponent("shortcut").path), "notes.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied[0].appendingPathComponent("empty").path))
        let moveDestination = root.appendingPathComponent("moved")
        try folder(moveDestination)
        let moved = try await service.transfer([copied[0]], to: moveDestination, move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied[0].path))
        XCTAssertEqual(try text(moved[0].appendingPathComponent("notes.txt")), "original")
        XCTAssertEqual(try text(source.appendingPathComponent("notes.txt")), "original")
        try assertNoStaging(destination)
    }

    func testRecursiveCopiesAreRejectedIncludingSymlinkDestination() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("source"), inside = source.appendingPathComponent("child")
        try folder(inside)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: inside.path)
        for destination in [source, inside, link] {
            await expect(.recursive) { try await service.transfer([source], to: destination, move: false) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), ["child"])
        try assertNoStaging(inside)
    }

    func testBatchConflictAndMissingSourceAreDetectedBeforeAnyCopy() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try folder(source); try folder(destination)
        let first = source.appendingPathComponent("first.txt"), second = source.appendingPathComponent("second.txt")
        try file(first, "first"); try file(second, "second")
        let conflict = destination.appendingPathComponent("second.txt")
        try file(conflict, "existing")
        await expect(.conflict) { try await service.transfer([first, second], to: destination, move: false) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("first.txt").path))
        XCTAssertEqual(try text(conflict), "existing")
        try FileManager.default.removeItem(at: conflict)
        try FileManager.default.removeItem(at: second)
        await expect(.io, completed: 0) { try await service.transfer([first, second], to: destination, move: false) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("first.txt").path))
        XCTAssertEqual(try text(first), "first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("second.txt").path))
        try assertNoStaging(destination)
    }

    @MainActor
    func testAlreadyCancelledOperationHasStructuredErrorAndNoWrites() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let task = Task { @MainActor in try await FileMutationService().newFolder(in: root, name: "cancelled") }
        task.cancel()
        await expect(.cancelled) { try await task.value }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testConcurrentCopiesPublishOneWinnerWithoutOverwritingEitherSource() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), destination = root.appendingPathComponent("destination")
        try folder(a); try folder(b); try folder(destination)
        let first = a.appendingPathComponent("same.txt"), second = b.appendingPathComponent("same.txt")
        try file(first, "A"); try file(second, "B")
        let results = await withTaskGroup(of: (String, Bool).self) { group in
            for (source, marker) in [(first, "A"), (second, "B")] {
                group.addTask {
                    do { _ = try await FileMutationService().transfer([source], to: destination, move: false); return (marker, true) }
                    catch let failure as FileMutationFailure {
                        XCTAssertTrue(failure.reason == .conflict)
                        XCTAssertEqual(failure.completed, 0)
                        return (marker, false)
                    } catch { XCTFail("Unexpected error: \(error)"); return (marker, false) }
                }
            }
            var collected: [(String, Bool)] = []
            for await value in group { collected.append(value) }
            return collected
        }
        let successes = results.filter(\.1)
        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(try text(destination.appendingPathComponent("same.txt")), successes.first?.0)
        XCTAssertEqual(try text(first), "A"); XCTAssertEqual(try text(second), "B")
        try assertNoStaging(destination)
    }

    func testConcurrentNewFoldersHaveOneSuccessAndOneConflict() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { _ = try await FileMutationService().newFolder(in: root, name: "same"); return true }
                    catch let failure as FileMutationFailure {
                        XCTAssertTrue(failure.reason == .conflict)
                        return false
                    } catch { XCTFail("Unexpected error: \(error)"); return false }
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["same"])
    }

    func testCancellationBeforeCopyPublicationCleansStagingAndKeepsSource() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try folder(source); try folder(destination)
        for index in 0..<1024 { try file(source.appendingPathComponent("item-\(index).txt"), "fixture") }
        let task = Task { try await FileMutationService().transfer([source], to: destination, move: false) }
        var observedStaging = false
        for _ in 0..<500 {
            if try FileManager.default.contentsOfDirectory(atPath: destination.path).contains(where: { $0.hasPrefix(".my-explorer-copy-") }) {
                observedStaging = true; break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        await expect(.cancelled) { try await task.value }
        XCTAssertTrue(observedStaging)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).count, 1024)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        try assertNoStaging(destination)
    }
}
