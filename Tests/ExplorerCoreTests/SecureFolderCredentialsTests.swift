// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class SecureFolderCredentialsTests: XCTestCase {
    func testFolderAndMasterPasswordsUnlockPersistedFoldersAfterMasterRotation() throws {
        let master = try SecureFolderMasterCredential(password: "senha mestra")
        let recoveryKey = try master.recoveryKey(password: "senha mestra")
        let first = try SecureFolderCredentials(
            id: UUID(), secret: Data([1, 2]), password: "pasta A", recoveryKey: recoveryKey
        )
        let second = try SecureFolderCredentials(
            id: UUID(), secret: Data([3, 4]), password: "pasta B", recoveryKey: recoveryKey
        )
        let persisted = try JSONDecoder().decode(
            [SecureFolderCredentials].self, from: JSONEncoder().encode([first, second])
        )
        XCTAssertThrowsError(try persisted[0].secret(password: "pasta B"))
        XCTAssertEqual(try persisted[0].secret(password: "pasta A"), Data([1, 2]))

        let rotated = try master.changingPassword(from: "senha mestra", to: "nova senha mestra")
        XCTAssertThrowsError(try rotated.recoveryKey(password: "senha mestra"))
        let newKey = try rotated.recoveryKey(password: "nova senha mestra")
        XCTAssertEqual(try persisted[0].secret(recoveryKey: newKey), Data([1, 2]))
        XCTAssertEqual(try persisted[1].secret(recoveryKey: newKey), Data([3, 4]))
        XCTAssertEqual(try persisted[1].secret(password: "pasta B"), Data([3, 4]))

        let reset = try persisted[0].resettingPassword(to: "nova senha A", recoveryKey: newKey)
        XCTAssertEqual(reset.id, persisted[0].id)
        XCTAssertThrowsError(try reset.secret(password: "pasta A"))
        XCTAssertEqual(try reset.secret(password: "nova senha A"), Data([1, 2]))
        XCTAssertEqual(try reset.secret(recoveryKey: newKey), Data([1, 2]))
    }

    func testEmptyPasswordAndUnrelatedMasterAreRejected() throws {
        XCTAssertThrowsError(try SecureFolderMasterCredential(password: ""))
        let first = try SecureFolderMasterCredential(password: "primeira")
        let second = try SecureFolderMasterCredential(password: "segunda")
        let folder = try SecureFolderCredentials(
            id: UUID(), secret: Data([1, 2]), password: "pasta",
            recoveryKey: first.recoveryKey(password: "primeira")
        )
        XCTAssertThrowsError(try folder.secret(recoveryKey: second.recoveryKey(password: "segunda")))
    }
}
