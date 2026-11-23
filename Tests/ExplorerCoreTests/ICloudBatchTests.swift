// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ExplorerCore

final class ICloudBatchTests: XCTestCase {
    private func file(_ name: String, _ state: ICloudAvailability?, size: Int64 = 10) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/fixture/\(name)"), name: name, isDirectory: false, size: size, iCloudAvailability: state)
    }

    func testReserveIsFivePercentAndIsNeverEatenInto() {
        let volume = ICloudBatch.Volume(available: 150, total: 1_000)
        XCTAssertEqual(volume.reserve, 50)
        XCTAssertTrue(volume.fits(100))
        XCTAssertFalse(volume.fits(101))
        XCTAssertFalse(ICloudBatch.Volume(available: 40, total: 1_000).fits(0))
    }

    func testOnlyThePrefixThatLeavesTheReserveFits() {
        let items = (1...5).map { ICloudBatchItem(url: URL(fileURLWithPath: "/f/\($0)"), size: 40) }
        XCTAssertEqual(ICloudBatch.totalSize(items), 200)
        XCTAssertEqual(ICloudBatch.countThatFits(items, in: .init(available: 150, total: 1_000)), 2)
        XCTAssertEqual(ICloudBatch.countThatFits(items, in: .init(available: 250, total: 1_000)), 5)
        XCTAssertEqual(ICloudBatch.countThatFits(items, in: .init(available: 60, total: 1_000)), 0)
    }

    func testPlanKeepsTheListOrderAndOnlyWhatIsNotOnThisMac() {
        let folder = FileEntry(url: URL(fileURLWithPath: "/fixture/Sub"), name: "Sub", isDirectory: true, iCloudAvailability: .available)
        let entries = [file("b.jpg", .onlineOnly, size: 7), file("a.jpg", .available), folder,
                       file("c.jpg", .failed), file("d.jpg", .downloading), file("local.txt", nil)]
        XCTAssertTrue(ICloudBatch.isFolder(folder))
        XCTAssertFalse(ICloudBatch.isPending(folder))
        let plan = ICloudBatch.plan(entries, includingFolders: false)
        XCTAssertEqual(plan.map(\.url.lastPathComponent), ["b.jpg", "c.jpg"])
        XCTAssertEqual(plan.first?.size, 7)
    }

    func testAPackageIsADocumentToDownloadNotAFolderToAskAbout() {
        let package = FileEntry(url: URL(fileURLWithPath: "/fixture/Notes.rtfd"), name: "Notes.rtfd", isDirectory: true,
                                isPackage: true, iCloudAvailability: .onlineOnly)
        XCTAssertFalse(ICloudBatch.isFolder(package))
        XCTAssertTrue(ICloudBatch.isPackage(package))
        XCTAssertTrue(ICloudBatch.concerns(package))
        XCTAssertFalse(ICloudBatch.concerns(file("here.jpg", .available)))
    }

    func testFilesAlreadyOnThisMacUnderAFolderAreNotPending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("inner/a.txt"))
        XCTAssertTrue(ICloudBatch.pending(under: root).isEmpty)
        XCTAssertNotNil(ICloudBatch.volume(at: root))
    }
}
