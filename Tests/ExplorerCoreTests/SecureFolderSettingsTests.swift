// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

struct SecureFolderSettingsTests {
    @Test func disabledMasterRetainsItsIdentityAndRequiresAuthenticationToReactivate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SecureFolderService(directory: root)
        #expect(await !service.hasMasterPassword)
        try await service.configureMasterPassword(current: nil, new: "original")
        #expect(await service.hasStoredMasterPassword)
        await #expect(throws: (any Error).self) {
            try await service.configureMasterPassword(current: "incorrect", new: nil)
        }
        #expect(await service.hasMasterPassword)
        try await service.configureMasterPassword(current: "original", new: nil)
        let reopened = SecureFolderService(directory: root)
        #expect(await !reopened.hasMasterPassword)
        #expect(await reopened.hasStoredMasterPassword)
        await #expect(throws: (any Error).self) {
            try await reopened.configureMasterPassword(current: nil, new: "new password")
        }
        try await reopened.configureMasterPassword(current: "original", new: "new password")
        #expect(await service.hasMasterPassword)
    }

    @Test func vaultSessionPathsAreExcludedFromStartupAndRestorableTabs() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MyExplorer/SecureFolders/Mounts/volume/Files/private-name")
        #expect(SecureFolderService.isSessionURL(path))
        #expect(StartupPreferences.safeLocation(path) == nil)
        #expect(!SecureFolderService.isSessionURL(FileManager.default.homeDirectoryForCurrentUser))
    }
}
