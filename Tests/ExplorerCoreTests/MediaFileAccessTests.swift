// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import XCTest
@testable import ExplorerCore

final class MediaFileAccessTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.MediaAvailability.\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func testDatalessFlagsOnOriginalOrResolvedTargetRequireDownload() {
        let url = URL(fileURLWithPath: "/fixture/movie.mp4")
        for (original, target): (UInt32, UInt32) in [(UInt32(SF_DATALESS), 0), (0, UInt32(SF_DATALESS)),
                                                   (UInt32(SF_DATALESS), UInt32(SF_DATALESS) | UInt32(UF_COMPRESSED))] {
            XCTAssertEqual(MediaFileAccess.classify(mode: S_IFREG | 0o644, originalFlags: original,
                                                    resolvedFlags: target, resolvedURL: url), .needsDownload)
        }
        XCTAssertEqual(MediaFileAccess.classify(mode: S_IFREG | 0o644, originalFlags: 0,
                                                resolvedFlags: UInt32(UF_COMPRESSED), resolvedURL: url), .available(url))
        XCTAssertEqual(MediaFileAccess.classify(mode: S_IFDIR | 0o755, originalFlags: 0,
                                                resolvedFlags: UInt32(SF_DATALESS), resolvedURL: url), .unavailable)
    }

    func testRegularFileAndSymbolicLinkResolveWithoutChangingContents() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vídeo 日本語.mp4"), link = root.appendingPathComponent("link.mp4")
        let bytes = Data("disposable fixture".utf8)
        try bytes.write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        guard case .available(let originalResolved) = MediaFileAccess.availability(of: file),
              case .available(let linkResolved) = MediaFileAccess.availability(of: link) else {
            return XCTFail("Regular files and symlinks to them must be available")
        }
        XCTAssertEqual(originalResolved, linkResolved)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), file.path)
    }

    func testMissingDirectoryRemoteAndSpecialFileAreUnavailable() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(MediaFileAccess.availability(of: root), .unavailable)
        XCTAssertEqual(MediaFileAccess.availability(of: root.appendingPathComponent("missing.mp4")), .unavailable)
        let broken = root.appendingPathComponent("broken.mp4")
        try FileManager.default.createSymbolicLink(atPath: broken.path, withDestinationPath: "missing.mp4")
        XCTAssertEqual(MediaFileAccess.availability(of: broken), .unavailable)
        let fifo = root.appendingPathComponent("pipe.mp4")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(MediaFileAccess.availability(of: fifo), .unavailable)
        for value in ["s3://bucket/movie.mp4", "https://example.com/movie.mp4", "file://remote/movie.mp4"] {
            XCTAssertEqual(MediaFileAccess.availability(of: try XCTUnwrap(URL(string: value))), .unavailable)
        }
    }

    func testExplicitAndFinderMetadataAliasesAreUnavailable() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias.jpg")
        try Data("not actual media".utf8).write(to: alias)
        XCTAssertEqual(MediaFileAccess.availability(of: alias, isAlias: true), .unavailable)
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x80
        XCTAssertEqual(setxattr(alias.path, "com.apple.FinderInfo", &finderInfo, finderInfo.count, 0, 0), 0)
        XCTAssertEqual(MediaFileAccess.availability(of: alias), .unavailable)
    }

    func testRecoveryFilesAndLinksToThemAreUnavailable() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(journal.path, 0o700), 0)
        try LocalTransferRecovery.mark(journal)
        let file = journal.appendingPathComponent("original.jpg")
        try Data("recovery content".utf8).write(to: file)
        let link = root.appendingPathComponent("outside.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(MediaFileAccess.availability(of: file), .unavailable)
        XCTAssertEqual(MediaFileAccess.availability(of: link), .unavailable)
    }
}
