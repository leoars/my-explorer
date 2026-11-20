// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore
import ExplorerAutomation

final class RecoveryFacadeTests: XCTestCase, @unchecked Sendable {
    func testStrictCopyCannotExportRecoveryEvenWithBroadAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-facade-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        let recovery = source.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try LocalTransferRecovery.mark(recovery)
        try Data("private".utf8).write(to: recovery.appendingPathComponent("original"))
        let files = SharedFileOperations(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) })
        do {
            _ = try await files.copy([source], to: destination, resolveConflict: { _ in .cancel }, authorize: { _, _, _ in })
            XCTFail("Exported recovery through automation")
        } catch let error as SharedFileFailure { XCTAssertEqual(error.reason, .forbidden) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
