// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

struct DirectorySizeTests {
    @Test func countsEveryFileAtAnyDepthWithoutFollowingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectorySize-\(UUID())")
        let inner = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 1000).write(to: root.appendingPathComponent("one.bin"))
        try Data(count: 234).write(to: inner.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: inner.appendingPathComponent("loop"), withDestinationURL: root)
        let total = try #require(DirectorySize.total(of: root))
        #expect(total == DirectorySize.Total(bytes: 1234, files: 3, folders: 2))
        let package = root.appendingPathComponent("Tool.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(count: 66).write(to: package.appendingPathComponent("Tool"))
        // The package is one file, its bytes all counted.
        #expect(DirectorySize.total(of: root) == DirectorySize.Total(bytes: 1300, files: 4, folders: 2))
    }

    @Test func anEmptyOrMissingFolderIsZeroAndCancellingGivesNoAnswer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectorySize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(DirectorySize.total(of: root) == DirectorySize.Total(bytes: 0, files: 0, folders: 0))
        #expect(DirectorySize.total(of: root.appendingPathComponent("gone"))?.bytes == 0)
        #expect(DirectorySize.total(of: root, isCancelled: { true }) == nil)
    }
}
