// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import Darwin
@testable import ExplorerCore

final class ArchiveServiceTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.ArchiveTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func cleanup(_ root: URL) { try? FileManager.default.removeItem(at: root) }
    private func assertNoStaging(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".my-explorer-archive-") }, file: file, line: line)
    }
    private func expect(_ reason: ArchiveFailure.Reason, file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () async throws -> URL) async {
        do { _ = try await operation(); XCTFail("Expected \(reason)", file: file, line: line) }
        catch let error as ArchiveFailure { XCTAssertEqual(error.reason, reason, "\(error.detail)", file: file, line: line) }
        catch { XCTFail("Unexpected error \(error)", file: file, line: line) }
    }

    func testRoundTripPreservesUnicodeHierarchyEmptyDirectoriesAndOriginals() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("Pasta 日本語")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("vazia"), withIntermediateDirectories: true)
        let text = Data("Ação • 한국어 • café".utf8)
        try text.write(to: source.appendingPathComponent("notas é.txt"))
        XCTAssertEqual(chmod(source.appendingPathComponent("notas é.txt").path, 0o755), 0)
        try Data().write(to: source.appendingPathComponent(".hidden"))
        let zip = root.appendingPathComponent("bundle.zip")
        let destination = root.appendingPathComponent("extracted")
        let service = ArchiveService()
        _ = try await service.compress(urls: [source], to: zip)
        _ = try await service.extract(archiveURL: zip, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Pasta 日本語/notas é.txt")), text)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("notas é.txt")), text)
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("Pasta 日本語/notas é.txt").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Pasta 日本語/vazia").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Pasta 日本語/.hidden")).count, 0)
        try assertNoStaging(root)
    }

    func testNeverOverwritesDestinationsIncludingDanglingLinks() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("original.txt")
        let content = Data("unchanged".utf8)
        try content.write(to: source)
        let service = ArchiveService()
        await expect(.destinationExists) { try await service.compress(urls: [source], to: source) }
        XCTAssertEqual(try Data(contentsOf: source), content)
        let link = root.appendingPathComponent("existing.zip")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "absent")
        await expect(.destinationExists) { try await service.compress(urls: [source], to: link) }
        let zip = root.appendingPathComponent("valid.zip")
        _ = try await service.compress(urls: [source], to: zip)
        await expect(.destinationExists) { try await service.extract(archiveURL: zip, to: source) }
        XCTAssertEqual(try Data(contentsOf: source), content)
        try assertNoStaging(root)
    }

    func testCompressionRejectsLinksSpecialFilesAndSelfInclusion() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/passwd")
        let zip = root.appendingPathComponent("result.zip")
        await expect(.unsupportedEntry) { try await ArchiveService().compress(urls: [source], to: zip) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
        try FileManager.default.removeItem(at: link)
        let fifo = source.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        await expect(.unsupportedEntry) { try await ArchiveService().compress(urls: [source], to: zip) }
        await expect(.invalidDestination) { try await ArchiveService().compress(urls: [source], to: source.appendingPathComponent("self.zip")) }
        try assertNoStaging(root)
    }

    func testMaliciousPathsAndDuplicateEntriesNeverEscapeStaging() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let archive = root.appendingPathComponent("hostile.zip")
        let destination = root.appendingPathComponent("output")
        let paths = ["../escaped.txt", "/tmp/my-explorer-escape", "folder/../../escape", "folder\\escape", "C:/escape", "a//b", "./file", "nul\0tail"]
        for name in paths {
            try ZIPFixture.make([.init(name: name)]).write(to: archive)
            await expect(.unsafeEntry) { try await ArchiveService().extract(archiveURL: archive, to: destination) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            try assertNoStaging(root)
        }
        try ZIPFixture.make([.init(name: "same"), .init(name: "same")]).write(to: archive)
        await expect(.unsafeEntry) { try await ArchiveService().extract(archiveURL: archive, to: destination) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        try assertNoStaging(root)
    }

    func testEncryptedSpecialAndTruncatedArchivesAreRejectedAtomically() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let archive = root.appendingPathComponent("test.zip"), destination = root.appendingPathComponent("output")
        try ZIPFixture.make([.init(name: "secret", flags: 1)]).write(to: archive)
        await expect(.encryptedArchive) { try await ArchiveService().extract(archiveURL: archive, to: destination) }
        for type in [UInt32(S_IFLNK), UInt32(S_IFIFO)] {
            try ZIPFixture.make([.init(name: "special", data: Data("../outside".utf8), mode: type | 0o644)]).write(to: archive)
            await expect(.unsupportedEntry) { try await ArchiveService().extract(archiveURL: archive, to: destination) }
        }
        let valid = ZIPFixture.make([.init(name: "file", data: Data("payload".utf8))])
        for cut in [1, 15, 30, valid.count - 1] {
            try valid.dropLast(cut).write(to: archive)
            await expect(.corruptArchive) { try await ArchiveService().extract(archiveURL: archive, to: destination) }
        }
        var corrupt = valid
        corrupt[34] ^= 0xff // Stored payload, with untouched CRC metadata.
        try corrupt.write(to: archive)
        await expect(.corruptArchive) { try await ArchiveService().extract(archiveURL: archive, to: destination) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStaging(root)
    }

    func testLimitsApplyBeforeAndDuringOperations() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let archive = root.appendingPathComponent("large.zip"), destination = root.appendingPathComponent("output")
        let small = ArchiveService(limits: .init(entries: 2, totalBytes: 8, fileBytes: 5, depth: 2))
        try ZIPFixture.make([.init(name: "file", data: Data(repeating: 1, count: 6))]).write(to: archive)
        await expect(.limitExceeded) { try await small.extract(archiveURL: archive, to: destination) }
        try ZIPFixture.make([.init(name: "a"), .init(name: "b"), .init(name: "c")]).write(to: archive)
        await expect(.limitExceeded) { try await small.extract(archiveURL: archive, to: destination) }
        try ZIPFixture.make([.init(name: "a/b/c")]).write(to: archive)
        await expect(.limitExceeded) { try await small.extract(archiveURL: archive, to: destination) }
        let source = root.appendingPathComponent("source")
        try Data(repeating: 1, count: 6).write(to: source)
        await expect(.limitExceeded) { try await small.compress(urls: [source], to: root.appendingPathComponent("result.zip")) }
        try assertNoStaging(root)
    }

    func testCancellationDuringCompressionRemovesPartialOutput() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("large.dat"), destination = root.appendingPathComponent("cancelled.zip")
        let fd = open(source.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 512 * 1024 * 1024), 0)
        close(fd)
        let task = Task { try await ArchiveService().compress(urls: [source], to: destination) }
        var observedStaging = false
        for _ in 0..<200 {
            if try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".my-explorer-archive-") }) {
                observedStaging = true; break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        await expect(.cancelled) { try await task.value }
        XCTAssertTrue(observedStaging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value, 512 * 1024 * 1024)
        try assertNoStaging(root)
    }

    func testConcurrentCreatorsPublishExactlyOneArchive() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("file.txt"), destination = root.appendingPathComponent("shared.zip")
        try Data("source".utf8).write(to: source)
        let results = await withTaskGroup(of: ArchiveFailure.Reason?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { _ = try await ArchiveService().compress(urls: [source], to: destination); return nil }
                    catch let failure as ArchiveFailure { return failure.reason }
                    catch { return .io }
                }
            }
            var values: [ArchiveFailure.Reason?] = []
            for await result in group { values.append(result) }
            return values
        }
        XCTAssertEqual(results.filter { $0 == nil }.count, 1)
        XCTAssertEqual(results.compactMap { $0 }, [.destinationExists])
        _ = try await ArchiveService().extract(archiveURL: destination, to: root.appendingPathComponent("verified"))
        try assertNoStaging(root)
    }

    func testZIP64MetadataAndEmptyArchivesAreSupported() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let archive = root.appendingPathComponent("zip64.zip")
        let text = Data("ZIP64 Unicode 日本語".utf8)
        try ZIPFixture.make([.init(name: "日本語.txt", data: text)], zip64: true).write(to: archive)
        let destination = root.appendingPathComponent("output")
        _ = try await ArchiveService().extract(archiveURL: archive, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("日本語.txt")), text)
        try ZIPFixture.make([], zip64: true).write(to: archive)
        let empty = root.appendingPathComponent("empty")
        _ = try await ArchiveService().extract(archiveURL: archive, to: empty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
        try assertNoStaging(root)
    }

    func testCancellationDuringExtractionRemovesPartialDirectory() async throws {
        let root = try fixture(); defer { cleanup(root) }
        let source = root.appendingPathComponent("large.dat"), archive = root.appendingPathComponent("large.zip")
        let destination = root.appendingPathComponent("cancelled")
        let fd = open(source.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 128 * 1024 * 1024), 0)
        close(fd)
        _ = try await ArchiveService().compress(urls: [source], to: archive)
        let task = Task { try await ArchiveService().extract(archiveURL: archive, to: destination) }
        var observedStaging = false
        for _ in 0..<200 {
            if try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".my-explorer-archive-") }) {
                observedStaging = true; break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        await expect(.cancelled) { try await task.value }
        XCTAssertTrue(observedStaging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        try assertNoStaging(root)
    }
}

private enum ZIPFixture {
    struct Entry {
        let name: String
        var data = Data()
        var mode = UInt32(S_IFREG) | 0o644
        var flags: UInt16 = 0x800
    }
    static func make(_ entries: [Entry], zip64: Bool = false) -> Data {
        var output = Data(), directory = Data()
        func crc(_ bytes: Data) -> UInt32 {
            var result: UInt32 = 0xffff_ffff
            for byte in bytes {
                result ^= UInt32(byte)
                for _ in 0..<8 { result = result & 1 != 0 ? (result >> 1) ^ 0xedb8_8320 : result >> 1 }
            }
            return ~result
        }
        for entry in entries {
            let name = Data(entry.name.utf8), offset = output.count, checksum = crc(entry.data)
            output.le32(0x04034b50); output.le16(20); output.le16(entry.flags); output.le16(0)
            output.le16(0); output.le16(0); output.le32(checksum)
            output.le32(UInt32(entry.data.count)); output.le32(UInt32(entry.data.count))
            output.le16(UInt16(name.count)); output.le16(0); output.append(name); output.append(entry.data)
            directory.le32(0x02014b50); directory.le16(0x0314); directory.le16(20); directory.le16(entry.flags)
            directory.le16(0); directory.le16(0); directory.le16(0); directory.le32(checksum)
            directory.le32(zip64 ? .max : UInt32(entry.data.count)); directory.le32(zip64 ? .max : UInt32(entry.data.count))
            directory.le16(UInt16(name.count)); directory.le16(zip64 ? 28 : 0); directory.le16(0)
            directory.le16(0); directory.le16(0); directory.le32(entry.mode << 16); directory.le32(zip64 ? .max : UInt32(offset)); directory.append(name)
            if zip64 {
                directory.le16(1); directory.le16(24)
                directory.le64(UInt64(entry.data.count)); directory.le64(UInt64(entry.data.count)); directory.le64(UInt64(offset))
            }
        }
        let offset = output.count
        output.append(directory)
        if zip64 {
            let recordOffset = output.count
            output.le32(0x06064b50); output.le64(44); output.le16(45); output.le16(45)
            output.le32(0); output.le32(0); output.le64(UInt64(entries.count)); output.le64(UInt64(entries.count))
            output.le64(UInt64(directory.count)); output.le64(UInt64(offset))
            output.le32(0x07064b50); output.le32(0); output.le64(UInt64(recordOffset)); output.le32(1)
        }
        output.le32(0x06054b50); output.le16(0); output.le16(0)
        output.le16(zip64 ? .max : UInt16(entries.count)); output.le16(zip64 ? .max : UInt16(entries.count))
        output.le32(zip64 ? .max : UInt32(directory.count)); output.le32(zip64 ? .max : UInt32(offset)); output.le16(0)
        return output
    }
}
private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
    mutating func le64(_ value: UInt64) { le32(UInt32(truncatingIfNeeded: value)); le32(UInt32(truncatingIfNeeded: value >> 32)) }
}
