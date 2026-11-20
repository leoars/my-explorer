// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

@MainActor
final class FileAliasMetadataTests: XCTestCase {
    func testReaderDistinguishesFinderAliasesSymbolicLinksAndRegularFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.IconAliases.\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Original.pdf")
        try Data("fixture".utf8).write(to: original)
        let alias = folder.appendingPathComponent("Alias.pdf")
        let bookmark = try original.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let aliasBytes = try Data(contentsOf: alias)
        let symbolic = folder.appendingPathComponent("Link.pdf")
        try FileManager.default.createSymbolicLink(atPath: symbolic.path, withDestinationPath: original.path)
        let entries = try await DirectoryReader().entries(at: folder, showHidden: true)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.name == "Alias.pdf" }).isAlias)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.name == "Link.pdf" }).isSymbolicLink)
        let normal = try XCTUnwrap(entries.first { $0.name == "Original.pdf" })
        XCTAssertFalse(normal.isAlias)
        XCTAssertFalse(normal.isSymbolicLink)
        // Reading metadata must neither replace the alias nor change its target contents.
        XCTAssertEqual(try Data(contentsOf: original), Data("fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: alias), aliasBytes)
    }
}
