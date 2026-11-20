// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import XCTest
@testable import ExplorerCore

/// Exercises the public service on a disposable, separately mounted exFAT filesystem.
/// All mountpoints, source data, credentials and disk images belong to this fixture.
final class SecureFolderVolumeTests: XCTestCase {
    @MainActor
    func testProtectionAndMasterRecoveryAcrossExternalVolumeReconnect() async throws {
        let files = FileManager.default
        let fixture = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("secure-folder-volume-" + UUID().uuidString)
        try files.createDirectory(at: fixture, withIntermediateDirectories: false)
        let volume = fixture.appendingPathComponent("volume")
        let image = fixture.appendingPathComponent("external.sparseimage")
        let config = fixture.appendingPathComponent("settings")
        try files.createDirectory(at: volume, withIntermediateDirectories: false)
        try files.createDirectory(at: config, withIntermediateDirectories: false)
        var service = SecureFolderService(directory: config)
        var attached = false

        do {
            try diskImage(["create", "-size", "512m", "-fs", "ExFAT", "-type", "SPARSE",
                           "-volname", "VaultTest", image.path])
            let attach = ["attach", "-nobrowse", "-noautoopen", "-mountpoint", volume.path, image.path]
            try diskImage(attach)
            attached = true

            let source = volume.appendingPathComponent("Research")
            try files.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
            let filename = "confidential-" + UUID().uuidString + ".txt"
            let content = Data(UUID().uuidString.utf8)
            try content.write(to: source.appendingPathComponent(filename))

            try await service.configureMasterPassword(current: nil, new: "master-one")
            let vault = try await service.protect(source, password: "folder-one", masterPassword: "master-one")
            XCTAssertTrue(SecureFolderService.isVault(vault))
            XCTAssertFalse(files.fileExists(atPath: source.path))
            XCTAssertFalse(try files.subpathsOfDirectory(atPath: vault.path).contains { $0.contains(filename) })
            let firstMount = try await service.unlock(vault, password: "folder-one")
            XCTAssertEqual(try Data(contentsOf: firstMount.appendingPathComponent(filename)), content)
            XCTAssertTrue(files.fileExists(atPath: firstMount.appendingPathComponent("empty").path))
            // Replacing credentials in a restored package must never reuse a mount from a different vault.
            let slot = vault.appendingPathComponent("credentials.json")
            let originalCredentials = try Data(contentsOf: slot)
            let other = try SecureFolderCredentials(id: UUID(), secret: Data([5]), password: "other-folder",
                                                    recoveryKey: SymmetricKey(size: .bits256))
            try JSONEncoder().encode(other).write(to: slot, options: .atomic)
            do {
                _ = try await service.unlock(vault, password: "other-folder")
                XCTFail("Reused a mount belonging to a different vault")
            } catch SecureFolderDiskError.sourceChanged {}
            try originalCredentials.write(to: slot, options: .atomic)
            // A second instance must leave live mounts alone, then recover them after their owner exits.
            let restarted = SecureFolderService(directory: config)
            try await restarted.lockAll()
            XCTAssertEqual(try Data(contentsOf: firstMount.appendingPathComponent(filename)), content)
            service = restarted
            try await restarted.lockAll()
            XCTAssertFalse(files.fileExists(atPath: firstMount.appendingPathComponent(filename).path))
            let mountRoot = config.appendingPathComponent("Mounts")
            XCTAssertTrue(try files.contentsOfDirectory(atPath: mountRoot.path).isEmpty)

            try diskImage(["detach", volume.path])
            attached = false
            // No vault metadata is reachable while the master password rotates.
            try await restarted.configureMasterPassword(current: "master-one", new: "master-two")
            try diskImage(attach)
            attached = true

            let recovered = try await restarted.unlock(vault, password: "master-two")
            XCTAssertEqual(try Data(contentsOf: recovered.appendingPathComponent(filename)), content)
            try await restarted.lock(vault)
            try await restarted.resetPassword(vault, masterPassword: "master-two", newPassword: "folder-two")
            try await restarted.configureMasterPassword(current: "master-two", new: nil)
            do {
                _ = try await restarted.unlock(vault, password: "incorrect")
                XCTFail("Accepted an incorrect folder password")
            } catch CryptoKitError.authenticationFailure {}
            let finalMount = try await restarted.unlock(vault, password: "folder-two")
            XCTAssertEqual(try Data(contentsOf: finalMount.appendingPathComponent(filename)), content)
            try await restarted.lockAll()
            try diskImage(["detach", volume.path])
            attached = false
            try files.removeItem(at: fixture)
        } catch {
            // Keep the fixture when an unmount fails, rather than recursively deleting a live volume.
            try? await service.lockAll()
            if attached { try diskImage(["detach", volume.path]) }
            try files.removeItem(at: fixture)
            throw error
        }
    }

    private func diskImage(_ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        task.standardError = errors
        try task.run()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw NSError(domain: "SecureFolderVolumeFixture", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: diagnostics, as: UTF8.self)])
        }
    }
}
