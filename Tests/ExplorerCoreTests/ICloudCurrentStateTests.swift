// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ExplorerCore

final class ICloudCurrentStateTests: XCTestCase {
    func testItemsOutsideICloudHaveNoState() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString).txt")
        try Data("local".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(ICloudAvailability.current(at: file))
        XCTAssertNil(ICloudAvailability.isDownloaded(at: file))
        XCTAssertNil(ICloudAvailability.current(at: file.appendingPathExtension("missing")))
    }

    func testCoarseStateComesFromTheFileSystemAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coarse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("local.txt")
        try Data("local".utf8).write(to: file)
        XCTAssertEqual(ICloudAvailability.coarse(at: file), .available)
        XCTAssertEqual(ICloudAvailability.coarse(at: folder), .available)
        XCTAssertEqual(ICloudAvailability.coarse(at: folder.appendingPathComponent("missing")), .unknown)
        XCTAssertGreaterThan(ICloudAvailability.detailedListingLimit, 0)
    }

    func testAPlainFolderIsNotARecoveryLocation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(LocalTransferRecovery.isMarkedDirectory(folder))
        XCTAssertFalse(LocalTransferRecovery.isProtected(folder))
        let listed = try DirectoryReaderProbe.names(in: folder.deletingLastPathComponent(), containing: folder.lastPathComponent)
        XCTAssertEqual(listed, [folder.lastPathComponent])
    }
}

private enum DirectoryReaderProbe {
    static func names(in parent: URL, containing name: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0 == name }
    }
}
