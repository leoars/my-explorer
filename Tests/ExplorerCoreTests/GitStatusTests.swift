// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class GitStatusTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/fixture/repository")
    private let fixtureHash = String(repeating: "a", count: 40)
    private func data(_ records: [String]) -> Data { Data((records.joined(separator: "\0") + (records.isEmpty ? "" : "\0")).utf8) }
    private func ordinary(_ xy: String, _ path: String, submodule: String = "N...") -> String {
        "1 \(xy) \(submodule) 100644 100644 100644 \(fixtureHash) \(fixtureHash) \(path)"
    }
    private func status(_ snapshot: GitStatusSnapshot, _ path: String, directory: Bool = false) -> GitFileStatus? {
        snapshot.status(for: root.appendingPathComponent(path), isDirectory: directory)
    }

    func testParsesBranchAndEveryOrdinaryStatusWithoutLosingUnusualNames() throws {
        let snapshot = try GitStatusParser.parse(data(["# branch.oid \(fixtureHash)", "# branch.head feature/ação",
            "# future.header ignored value", ordinary(".M", "folder/日本語 with spaces\nline.txt"),
            ordinary("A.", "added.txt"), ordinary(".D", "deleted.txt"), ordinary("MM", "both.txt"),
            "? new.txt", "! ignored.txt"]), rootURL: root)
        XCTAssertEqual(snapshot.branch, "feature/ação")
        XCTAssertEqual(snapshot.headOID, fixtureHash)
        XCTAssertFalse(snapshot.isDetached); XCTAssertFalse(snapshot.isUnborn)
        XCTAssertEqual(status(snapshot, "folder/日本語 with spaces\nline.txt")?.kind, .modified)
        XCTAssertEqual(status(snapshot, "added.txt"), GitFileStatus(kind: .added, staged: true))
        XCTAssertEqual(status(snapshot, "deleted.txt"), GitFileStatus(kind: .deleted, unstaged: true))
        XCTAssertEqual(status(snapshot, "both.txt"), GitFileStatus(kind: .modified, staged: true, unstaged: true))
        XCTAssertEqual(status(snapshot, "new.txt")?.kind, .untracked)
        XCTAssertEqual(status(snapshot, "ignored.txt")?.kind, .ignored)
    }

    func testDetachedAndUnbornBranchHeaders() throws {
        let detached = try GitStatusParser.parse(data(["# branch.oid \(fixtureHash)", "# branch.head (detached)"]), rootURL: root)
        XCTAssertTrue(detached.isDetached); XCTAssertNil(detached.branch); XCTAssertFalse(detached.isUnborn)
        let unborn = try GitStatusParser.parse(data(["# branch.oid (initial)", "# branch.head main"]), rootURL: root)
        XCTAssertTrue(unborn.isUnborn); XCTAssertNil(unborn.headOID); XCTAssertEqual(unborn.branch, "main")
    }

    func testRenameConsumesSecondNULRecordAndAggregatesBothParents() throws {
        let destination = "new folder/new\nname.txt", source = "old folder/old\tname.txt"
        let snapshot = try GitStatusParser.parse(data([
            "2 R. N... 100644 100644 100644 \(fixtureHash) \(fixtureHash) R100 \(destination)", source,
            "? unrelated.txt"]), rootURL: root)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(status(snapshot, destination), GitFileStatus(kind: .renamed, staged: true, originalPath: source))
        XCTAssertEqual(status(snapshot, "new folder", directory: true)?.kind, .renamed)
        XCTAssertEqual(status(snapshot, "old folder", directory: true)?.kind, .renamed)
        XCTAssertEqual(status(snapshot, "unrelated.txt")?.kind, .untracked)
    }

    func testCopyDoesNotMarkOriginalParentChanged() throws {
        let snapshot = try GitStatusParser.parse(data([
            "2 C. N... 100644 100644 100644 \(fixtureHash) \(fixtureHash) C75 new/file.txt", "original/file.txt"]),
            rootURL: root, trackedPaths: ["original/file.txt"])
        XCTAssertEqual(status(snapshot, "new/file.txt")?.kind, .added)
        XCTAssertEqual(status(snapshot, "original", directory: true)?.kind, .clean)
    }

    func testConflictHasHighestDirectoryPriorityAndSubmoduleChangesAreModified() throws {
        let snapshot = try GitStatusParser.parse(data([
            "u UU N... 100644 100644 100644 100644 \(fixtureHash) \(fixtureHash) \(fixtureHash) folder/conflict.txt",
            ordinary("M.", "folder/modified.txt"), "? folder/new.txt", "! folder/ignored.txt",
            ordinary("..", "submodule", submodule: "S.MU")]), rootURL: root)
        XCTAssertEqual(status(snapshot, "folder", directory: true)?.kind, .conflicted)
        XCTAssertEqual(snapshot.status(for: root, isDirectory: true)?.kind, .conflicted)
        XCTAssertEqual(status(snapshot, "submodule")?.kind, .modified)
        XCTAssertTrue(status(snapshot, "submodule")?.unstaged == true)
    }

    func testDirectoryInheritanceUsesComponentsAndIgnoredChildrenDoNotIgnoreTheirParent() throws {
        let snapshot = try GitStatusParser.parse(data(["! ignored/", "? new/", "! ordinary/cache.bin",
            "? foo/child.txt", ordinary(".M", "foobar/file.txt")]), rootURL: root)
        XCTAssertEqual(status(snapshot, "ignored", directory: true)?.kind, .ignored)
        XCTAssertEqual(status(snapshot, "ignored/deep/file.txt")?.kind, .ignored)
        XCTAssertEqual(status(snapshot, "new/deep/file.txt")?.kind, .untracked)
        XCTAssertNil(status(snapshot, "ordinary", directory: true))
        XCTAssertEqual(status(snapshot, "foo", directory: true)?.kind, .untracked)
        XCTAssertEqual(status(snapshot, "foobar", directory: true)?.kind, .modified)
        XCTAssertNil(status(snapshot, "ignored-extra", directory: true))
    }

    func testCleanRequiresTrackedInventoryAndGitMetadataNeverGetsStatus() throws {
        let paths = try GitStatusParser.trackedPaths(from: data(["source/clean.txt", "source/clean.txt", " leading\nfile.txt"]))
        let snapshot = try GitStatusParser.parse(Data(), rootURL: root, trackedPaths: paths)
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(status(snapshot, "source/clean.txt")?.kind, .clean)
        XCTAssertEqual(status(snapshot, "source", directory: true)?.kind, .clean)
        XCTAssertNil(status(snapshot, "unknown.txt"))
        XCTAssertNil(status(snapshot, ".git", directory: true))
        XCTAssertNil(status(snapshot, ".git/index"))
        XCTAssertNil(snapshot.status(for: URL(fileURLWithPath: "/fixture/repository-extra/source/clean.txt"), isDirectory: false))
    }

    func testTruncationMalformedRecordsAndUnsafePathsFailInsteadOfLookingClean() throws {
        for value in [Data("? missing terminator".utf8), data(["2 R. N... 100644 100644 100644 \(fixtureHash) \(fixtureHash) R100 new.txt"]),
                      data(["1 invalid"]), data(["? ../escape.txt"]), data(["! /absolute/"]), data(["? empty//part"]),
                      data(["? .git/index"]), data(["? duplicate", "? duplicate"]), Data([63, 32, 255, 0])] {
            XCTAssertThrowsError(try GitStatusParser.parse(value, rootURL: root))
        }
        XCTAssertThrowsError(try GitStatusParser.trackedPaths(from: Data("truncated".utf8)))
        XCTAssertThrowsError(try GitStatusParser.trackedPaths(from: data(["../escape"])))
        XCTAssertThrowsError(try GitStatusParser.parse(Data(repeating: 0, count: 16 * 1024 * 1024 + 1), rootURL: root))
    }
}
