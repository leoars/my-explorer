// SPDX-License-Identifier: Apache-2.0
import AppKit
import XCTest
@testable import ExplorerCore

final class CustomBundleIconTests: XCTestCase {
    func testRemoveClearsTheIconFileAndFinderInformation() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("CustomIcon-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        XCTAssertTrue(NSWorkspace.shared.setIcon(image, forFile: bundle.path))
        XCTAssertTrue(CustomBundleIcon.isPresent(at: bundle))
        XCTAssertGreaterThan(getxattr(bundle.path, "com.apple.FinderInfo", nil, 0, 0, XATTR_NOFOLLOW), 0)

        try CustomBundleIcon.remove(at: bundle)

        XCTAssertFalse(CustomBundleIcon.isPresent(at: bundle))
        XCTAssertEqual(getxattr(bundle.path, "com.apple.FinderInfo", nil, 0, 0, XATTR_NOFOLLOW), -1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bundle.path), ["Contents"])
    }

    func testRemoveIsHarmlessWithoutACustomIcon() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("PlainIcon-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        XCTAssertFalse(CustomBundleIcon.isPresent(at: bundle))
        XCTAssertNoThrow(try CustomBundleIcon.remove(at: bundle))
    }
}
