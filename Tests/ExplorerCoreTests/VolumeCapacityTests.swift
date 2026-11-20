// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class VolumeCapacityTests: XCTestCase {
    func testByteAccountingAndInvalidCounters() throws {
        let sizes = try VolumeCapacity(blocks: 100, available: 40, blockSize: 4096)
        XCTAssertEqual(sizes.total, 409600)
        XCTAssertEqual(sizes.used, 245760)
        XCTAssertEqual(sizes.free, 163840)
        XCTAssertThrowsError(try VolumeCapacity(blocks: .max, available: 0, blockSize: 4096))
        XCTAssertThrowsError(try VolumeCapacity(blocks: 1, available: 2, blockSize: 512))
    }

    func testMissingAndReplacedMountCannotReportParentDisk() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let link = fixture.appendingPathComponent("Startup")
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "/")
        let mount = try VolumeMount.identify(at: link)
        let sizes = try mount.capacity()
        XCTAssertGreaterThan(sizes.total, 0)
        XCTAssertEqual(sizes.used + sizes.free, sizes.total)
        try manager.removeItem(at: link)
        XCTAssertThrowsError(try mount.capacity())
        try manager.createDirectory(at: link, withIntermediateDirectories: false)
        XCTAssertThrowsError(try mount.capacity())
        XCTAssertThrowsError(try VolumeMount.identify(at: fixture))
    }
}
