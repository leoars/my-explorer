// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class SecureFolderDiskTests: XCTestCase {
    private let fm = FileManager.default

    private func fixture() throws -> (URL, URL) {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("Pasta")
        try fm.createDirectory(at: source.appendingPathComponent("Vazia"), withIntermediateDirectories: true)
        try Data("conteúdo privado".utf8).write(to: source.appendingPathComponent("arquivo privado"))
        return (root, source)
    }

    func testConversionMountAndRoundTrip() throws {
        let (root, source) = try fixture()
        defer { try? fm.removeItem(at: root) }
        let file = source.appendingPathComponent("arquivo privado")
        let quarantine = Array("0083;665ede12;Safari;6C89D750-A56D-4B8F-A7CD-92ED627F7B3F".utf8)
        XCTAssertEqual(setxattr(file.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0), 0)
        let attribute = "org.myexplorer.fixture"
        let tag = Array("tag-fixture".utf8)
        XCTAssertEqual(setxattr(file.path, attribute, tag, tag.count, 0, 0), 0)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("atalho").path,
                                  withDestinationPath: "arquivo privado")
        try Data([10, 20, 30]).write(to: file.appendingPathComponent("..namedfork/rsrc"))
        let secret = Data(UUID().uuidString.utf8)
        let vault = try SecureFolderDisk.convert(source, secret: secret, metadata: Data("metadata".utf8))
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try Set(fm.contentsOfDirectory(atPath: vault.path)), ["contents.sparsebundle", "credentials.json"])
        let mount = root.appendingPathComponent("Mounted")
        XCTAssertThrowsError(try SecureFolderDisk.mount(in: vault, secret: Data("wrong".utf8), at: mount))
        try SecureFolderDisk.mount(in: vault, secret: secret, at: mount)
        let files = mount.appendingPathComponent("Files")
        defer { if fm.fileExists(atPath: files.path) { try? SecureFolderDisk.unmount(mount) } }
        XCTAssertEqual(try String(contentsOf: files.appendingPathComponent("arquivo privado"), encoding: .utf8), "conteúdo privado")
        let mountedFile = files.appendingPathComponent("arquivo privado")
        var returnedTag = [UInt8](repeating: 0, count: tag.count)
        XCTAssertEqual(getxattr(mountedFile.path, attribute, &returnedTag, tag.count, 0, 0), tag.count)
        XCTAssertEqual(returnedTag, tag)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: files.appendingPathComponent("atalho").path), "arquivo privado")
        XCTAssertEqual(try Data(contentsOf: mountedFile.appendingPathComponent("..namedfork/rsrc")), Data([10, 20, 30]))
        XCTAssertTrue(fm.fileExists(atPath: files.appendingPathComponent("Vazia").path))
        try Data([42]).write(to: files.appendingPathComponent("alterado"))
        try SecureFolderDisk.unmount(mount)
        XCTAssertFalse(fm.fileExists(atPath: files.path))
        try SecureFolderDisk.mount(in: vault, secret: secret, at: mount)
        XCTAssertEqual(try Data(contentsOf: files.appendingPathComponent("alterado")), Data([42]))
        try SecureFolderDisk.unmount(mount)
    }

    func testQuarantineComparisonRequiresOriginalFlagsAndEvent() {
        let event = "6C89D750-A56D-4B8F-A7CD-92ED627F7B3F"
        let original = Data("0083;665ede12;Safari;\(event)".utf8)
        XCTAssertTrue(SecureFolderDisk.sameQuarantineEvent(original, Data("0083;6afe005e;;\(event)".utf8)))
        XCTAssertFalse(SecureFolderDisk.sameQuarantineEvent(original, Data("0000;6afe005e;;\(event)".utf8)))
        XCTAssertFalse(SecureFolderDisk.sameQuarantineEvent(original, Data("0083;6afe005e;;\(UUID().uuidString)".utf8)))
        XCTAssertFalse(SecureFolderDisk.sameQuarantineEvent(original, Data()))
    }

    func testInterruptedPublicationPreservesCompleteOriginal() throws {
        let (root, source) = try fixture()
        defer { try? fm.removeItem(at: root) }
        XCTAssertThrowsError(try SecureFolderDisk.convert(source, secret: Data([1]), metadata: Data([2]),
            beforePublication: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["Pasta"])
        XCTAssertEqual(try Set(fm.contentsOfDirectory(atPath: source.path)), ["arquivo privado", "Vazia"])
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("arquivo privado"), encoding: .utf8), "conteúdo privado")
    }

    func testFileAddedDuringCleanupRemainsInRecovery() throws {
        let (root, source) = try fixture()
        defer { try? fm.removeItem(at: root) }
        let addition = Data("late edit".utf8)
        do {
            _ = try SecureFolderDisk.convert(source, secret: Data([1]), metadata: Data([2]), beforeCleanup: { backup in
                try addition.write(to: backup.appendingPathComponent("new"))
            })
            XCTFail("The conversion should report the remaining recovery directory")
        } catch SecureFolderDiskError.recoveryRequired(let backup) {
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("new")), addition)
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Pasta.myexplorervault").path))
        }
    }

    func testChangedPublishedPackagePreservesCompleteRecoveryTree() throws {
        for replacePackage in [false, true] {
            let (root, source) = try fixture()
            defer { try? fm.removeItem(at: root) }
            let vault = root.appendingPathComponent("Pasta.myexplorervault")
            do {
                _ = try SecureFolderDisk.convert(source, secret: Data([1]), metadata: Data([2]), beforeCleanup: { _ in
                    if replacePackage {
                        try self.fm.moveItem(at: vault, to: root.appendingPathComponent("moved"))
                        try self.fm.createDirectory(at: vault, withIntermediateDirectories: false)
                    } else {
                        try Data([3]).write(to: vault.appendingPathComponent("credentials.json"), options: .atomic)
                    }
                })
                XCTFail("A replaced package or envelope must retain the plaintext recovery tree")
            } catch SecureFolderDiskError.recoveryRequired(let backup) {
                XCTAssertEqual(try Set(fm.contentsOfDirectory(atPath: backup.path)), ["arquivo privado", "Vazia"])
                XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("arquivo privado")), Data("conteúdo privado".utf8))
            }
        }
    }

    func testAtomicReplacementAfterIdentityCheckSurvivesCleanup() throws {
        let (root, source) = try fixture()
        defer { try? fm.removeItem(at: root) }
        let edited = Data("substituição concorrente".utf8)
        do {
            _ = try SecureFolderDisk.convert(source, secret: Data([1]), metadata: Data([2]), beforeClaim: { entry in
                if entry.lastPathComponent == "arquivo privado" {
                    try edited.write(to: entry, options: .atomic)
                }
            })
            XCTFail("An entry replaced during cleanup must remain recoverable")
        } catch SecureFolderDiskError.recoveryRequired(let backup) {
            let entries = try fm.subpathsOfDirectory(atPath: backup.path)
            let name = try XCTUnwrap(entries.first { $0.hasSuffix("/arquivo privado") })
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(name)), edited)
        }
    }

    func testConflictingDestinationAndHardLinksPreserveOriginal() throws {
        let (root, source) = try fixture()
        defer { try? fm.removeItem(at: root) }
        let conflict = root.appendingPathComponent("Pasta.myexplorervault")
        try Data([9]).write(to: conflict)
        let convert = { try SecureFolderDisk.convert(source, secret: Data([1]), metadata: Data([2])) }
        XCTAssertThrowsError(try convert())
        XCTAssertEqual(try Data(contentsOf: conflict), Data([9]))
        try fm.removeItem(at: conflict)
        try fm.linkItem(at: source.appendingPathComponent("arquivo privado"), to: root.appendingPathComponent("link"))
        XCTAssertThrowsError(try convert())
        XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("arquivo privado").path))
        XCTAssertFalse(fm.fileExists(atPath: conflict.path))
    }
}
