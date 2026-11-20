// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class RecoveryIsolationTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-isolation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func folder(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func recovery(_ parent: URL) throws -> URL {
        let root = try folder(parent, "private-recovery")
        try LocalTransferRecovery.mark(root)
        try Data("old private bytes".utf8).write(to: root.appendingPathComponent("original.txt"))
        return root
    }
    func testReaderHidesMarkedRootsAndDeniesDirectOrAliasedAccess() async throws {
        let root = try fixture(), secret = try recovery(root), ordinary = try folder(root, ".my-explorer-undo-user")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secret)
        let entries = try await DirectoryReader().entries(at: root, showHidden: true)
        XCTAssertEqual(entries.map(\.name), [ordinary.lastPathComponent])
        for url in [secret, alias] {
            do { _ = try await DirectoryReader().entries(at: url, showHidden: true); XCTFail("Read recovery") }
            catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadNoPermission) }
        }
        XCTAssertTrue(LocalTransferRecovery.isProtected(secret.appendingPathComponent("new/not-created")))
    }
    func testCopiedMarkerOrMatchingNameDoesNotHideUserFiles() async throws {
        let root = try fixture(), secret = try recovery(root), ordinary = try folder(root, "ordinary")
        try FileManager.default.copyItem(at: secret.appendingPathComponent(LocalTransferRecovery.markerName),
                                         to: ordinary.appendingPathComponent(LocalTransferRecovery.markerName))
        XCTAssertFalse(LocalTransferRecovery.isProtected(ordinary))
        XCTAssertNoThrow(try LocalTransferRecovery.assertExportable(ordinary))
        let destination = try folder(root, "destination")
        let copied = try await FileMutationService().transfer([ordinary], to: destination, move: false)
        XCTAssertEqual(copied.count, 1)
    }
    func testNativeCopyMoveRenameAndMutationRejectRecoveryOrItsAncestor() async throws {
        let root = try fixture(), source = try folder(root, "source"), secret = try recovery(source)
        let destination = try folder(root, "destination"), service = FileMutationService()
        for selected in [source, secret, secret.appendingPathComponent("original.txt")] {
            for moving in [false, true] {
                do { _ = try await service.transfer([selected], to: destination, move: moving); XCTFail("Exported recovery") }
                catch is FileMutationFailure {}
            }
        }
        do { _ = try await service.rename(source, to: "renamed"); XCTFail("Renamed recovery ancestor") }
        catch is FileMutationFailure {}
        do { _ = try await service.newFolder(in: secret, name: "new"); XCTFail("Mutated recovery") }
        catch is FileMutationFailure {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.appendingPathComponent("original.txt").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
    func testArchiveRejectsAncestorBeforeCreatingOutput() async throws {
        let root = try fixture(), source = try folder(root, "source")
        _ = try recovery(source)
        let output = root.appendingPathComponent("export.zip")
        do { _ = try await ArchiveService().compress(urls: [source], to: output); XCTFail("Archived recovery") }
        catch let error as ArchiveFailure { XCTAssertEqual(error.reason, .unsupportedEntry) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testCloudPlanRejectsRecoveryBeforeCreatingClientOrUploading() async throws {
        let root = try fixture(), source = try folder(root, "source")
        _ = try recovery(source)
        let service = StorageTransferService(clientFactory: { _ in
            XCTFail("Reached cloud transport for a protected selection")
            throw CloudFailure(.invalidConfiguration)
        })
        do {
            _ = try await service.copy(sources: [source], to: RemoteLocation.url(connectionID: UUID(), key: ""),
                                       resolveConflict: { _ in .cancel })
            XCTFail("Uploaded recovery")
        } catch let error as StorageTransferFailure { XCTAssertEqual(error.reason, .unsupportedEntry) }
    }
    func testDeletionRejectsRecoveryAtPlanAndAfterFinalAuthorization() async throws {
        let root = try fixture(), source = try folder(root, "source")
        try Data("keep".utf8).write(to: source.appendingPathComponent("file"))
        let trash = IsolationTrash(), counter = IsolationCounter()
        let service = StorageDeletionService(clientFactory: { _ in throw CloudFailure(.invalidConfiguration) }, trash: trash)
        let plan = try await service.plan(sources: [source], recursive: true)
        do {
            _ = try await service.execute(planID: plan.id) { _ in
                if await counter.next() == 5 { try? LocalTransferRecovery.mark(source) }
                return true
            }
            XCTFail("Trashed newly marked recovery")
        } catch let error as StorageDeletionFailure { XCTAssertEqual(error.reason, .unsupportedEntry) }
        do { _ = try await service.plan(sources: [source], recursive: true); XCTFail("Planned recovery deletion") }
        catch let error as StorageDeletionFailure { XCTAssertEqual(error.reason, .unsupportedEntry) }
        let count = await trash.count
        XCTAssertEqual(count, 0)
    }
}
private actor IsolationTrash: StorageTrash {
    var count = 0
    func trash(_ url: URL) async throws { count += 1 }
}
private actor IsolationCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}
