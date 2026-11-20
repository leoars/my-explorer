// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import CArchive

public struct ArchiveFailure: Error, Sendable {
    public enum Reason: String, Sendable {
        case invalidSelection, destinationExists, invalidDestination, unsafeEntry, unsupportedEntry
        case unsupportedArchive, encryptedArchive, corruptArchive, limitExceeded, cancelled, io
    }
    public let reason: Reason
    public let detail: String
    public init(_ reason: Reason, detail: String = "") { self.reason = reason; self.detail = detail }
}

/// ZIP/ZIP64. Never replaces an existing destination, follows archive links, or writes outside staging.
public struct ArchiveService: Sendable {
    public struct Limits: Sendable {
        public let entries: Int
        public let totalBytes: Int64
        public let fileBytes: Int64
        public let depth: Int
        public init(entries: Int = 10_000, totalBytes: Int64 = 2_147_483_648,
                    fileBytes: Int64 = 1_073_741_824, depth: Int = 64) {
            self.entries = max(0, entries); self.totalBytes = max(0, totalBytes)
            self.fileBytes = max(0, fileBytes); self.depth = max(0, depth)
        }
    }
    public let limits: Limits
    public init(limits: Limits = Limits()) { self.limits = limits }

    public func compress(urls: [URL], to destination: URL) async throws -> URL {
        try cancelled()
        let worker = Task.detached(priority: .userInitiated) { try compressSynchronously(urls, to: destination) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    public func extract(archiveURL: URL, to destination: URL) async throws -> URL {
        try cancelled()
        let worker = Task.detached(priority: .userInitiated) { try extractSynchronously(archiveURL, to: destination) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func cancelled() throws {
        if Task.isCancelled { throw ArchiveFailure(.cancelled) }
    }

    private func stage(for destination: URL) throws -> URL {
        try cancelled()
        guard !LocalTransferRecovery.isProtected(destination) else { throw ArchiveFailure(.invalidDestination) }
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
              destination.path != "/" else { throw ArchiveFailure(.invalidDestination) }
        var info = stat()
        if lstat(destination.path, &info) == 0 { throw ArchiveFailure(.destinationExists) }
        guard errno == ENOENT else { throw io("destination") }
        let parent = destination.deletingLastPathComponent()
        guard stat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ArchiveFailure(.invalidDestination)
        }
        let staging = parent.appendingPathComponent(".my-explorer-archive-\(UUID().uuidString)")
        guard mkdir(staging.path, 0o700) == 0 else { throw io("staging") }
        return staging
    }

    private func publish(_ staged: URL, to destination: URL) throws -> URL {
        try cancelled()
        guard !LocalTransferRecovery.isProtected(destination) else { throw ArchiveFailure(.invalidDestination) }
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST || errno == ENOTEMPTY { throw ArchiveFailure(.destinationExists) }
            throw io("publish")
        }
        return destination
    }

    private func io(_ operation: String) -> ArchiveFailure {
        ArchiveFailure(.io, detail: "\(operation): \(String(cString: strerror(errno)))")
    }

    private func libraryFailure(_ handle: OpaquePointer, reason: ArchiveFailure.Reason) -> ArchiveFailure {
        ArchiveFailure(reason, detail: archive_error_string(handle).map { String(cString: $0) } ?? "libarchive")
    }

    private func checkedPath(_ name: String) throws -> [String] {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.utf8.contains(0) else { throw ArchiveFailure(.unsafeEntry) }
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let parts = components.last == "" ? Array(components.dropLast()) : components
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ArchiveFailure(.unsafeEntry)
        }
        guard parts.count <= limits.depth else { throw ArchiveFailure(.limitExceeded) }
        return parts
    }

    private func compressSynchronously(_ urls: [URL], to destination: URL) throws -> URL {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw ArchiveFailure(.invalidSelection) }
        for url in urls {
            do { try LocalTransferRecovery.assertExportable(url) }
            catch { throw ArchiveFailure(Task.isCancelled ? .cancelled : .unsupportedEntry) }
        }
        // Staging inside a selected directory would cause the ZIP to recursively include itself.
        let outputPath = destination.deletingLastPathComponent().resolvingSymlinksInPath().path
        for url in urls {
            let source = url.resolvingSymlinksInPath().path
            if outputPath == source || outputPath.hasPrefix(source + "/") {
                throw ArchiveFailure(.invalidDestination)
            }
        }
        let staging = try stage(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload.zip")
        let output = open(payload.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw io("create ZIP") }
        defer { close(output) }
        guard let writer = archive_write_new() else { throw ArchiveFailure(.io) }
        defer { archive_write_free(writer) }
        guard archive_write_set_format_zip(writer) == ARCHIVE_OK,
              archive_write_open_fd(writer, output) == ARCHIVE_OK else { throw libraryFailure(writer, reason: .io) }
        var count = 0, bytes: Int64 = 0
        var names = Set<String>()
        func append(_ descriptor: Int32, name: String, sourceURL: URL) throws {
            try cancelled()
            guard !LocalTransferRecovery.isProtected(sourceURL) else { throw ArchiveFailure(.unsupportedEntry) }
            _ = try checkedPath(name)
            count += 1
            guard count <= limits.entries else { throw ArchiveFailure(.limitExceeded) }
            guard names.insert(name).inserted else { throw ArchiveFailure(.invalidSelection) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw io("source metadata") }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { throw ArchiveFailure(.unsupportedEntry) }
            guard info.st_size >= 0, type == S_IFDIR || info.st_size <= limits.fileBytes else {
                throw ArchiveFailure(.limitExceeded)
            }
            guard let entry = archive_entry_new() else { throw ArchiveFailure(.io) }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, name)
            archive_entry_set_filetype(entry, UInt32(type))
            // Preserve ordinary permission bits (including executable scripts), never set-ID bits.
            archive_entry_set_perm(entry, info.st_mode & 0o777)
            archive_entry_set_size(entry, type == S_IFDIR ? 0 : info.st_size)
            archive_entry_set_mtime(entry, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec)
            guard archive_write_header(writer, entry) == ARCHIVE_OK else { throw libraryFailure(writer, reason: .io) }
            if type == S_IFREG {
                var remaining = info.st_size
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while remaining > 0 {
                    try cancelled()
                    let n = read(descriptor, &buffer, min(buffer.count, Int(remaining)))
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw io("source changed or unreadable") }
                    bytes += Int64(n)
                    guard bytes <= limits.totalBytes else { throw ArchiveFailure(.limitExceeded) }
                    guard archive_write_data(writer, buffer, n) == n else { throw libraryFailure(writer, reason: .io) }
                    remaining -= Int64(n)
                }
            } else {
                let directoryDescriptor = dup(descriptor)
                guard directoryDescriptor >= 0 else { throw io("source directory") }
                guard let directory = fdopendir(directoryDescriptor) else {
                    close(directoryDescriptor)
                    throw io("source directory")
                }
                defer { closedir(directory) }
                var children: [String] = []
                errno = 0
                while let record = readdir(directory) {
                    try cancelled()
                    let child = withUnsafePointer(to: &record.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    if child != "." && child != ".." { children.append(child) }
                    guard children.count <= limits.entries else { throw ArchiveFailure(.limitExceeded) }
                    errno = 0
                }
                guard errno == 0 else { throw io("enumerate source") }
                for child in children.sorted() {
                    let fd = openat(descriptor, child, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard fd >= 0 else {
                        if errno == ELOOP { throw ArchiveFailure(.unsupportedEntry) }
                        throw io("open source")
                    }
                    defer { close(fd) }
                    try append(fd, name: name + "/" + child, sourceURL: sourceURL.appendingPathComponent(child))
                }
            }
            guard archive_write_finish_entry(writer) == ARCHIVE_OK else { throw libraryFailure(writer, reason: .io) }
        }
        for url in urls {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else {
                if errno == ELOOP { throw ArchiveFailure(.unsupportedEntry) }
                throw io("open source")
            }
            defer { close(fd) }
            try append(fd, name: url.lastPathComponent, sourceURL: url)
        }
        guard archive_write_close(writer) == ARCHIVE_OK else { throw libraryFailure(writer, reason: .io) }
        guard fsync(output) == 0 else { throw io("flush ZIP") }
        return try publish(payload, to: destination)
    }

    private func extractSynchronously(_ archiveURL: URL, to destination: URL) throws -> URL {
        try cancelled()
        guard !LocalTransferRecovery.isProtected(archiveURL) else { throw ArchiveFailure(.unsupportedEntry) }
        guard archiveURL.isFileURL else { throw ArchiveFailure(.invalidSelection) }
        let input = open(archiveURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw io("open ZIP") }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ArchiveFailure(.unsupportedEntry)
        }
        let expected = try validateEnvelope(input, length: info.st_size)
        let staging = try stage(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("contents")
        guard mkdir(contents.path, 0o700) == 0 else { throw io("create extraction directory") }
        guard let reader = archive_read_new() else { throw ArchiveFailure(.io) }
        defer { archive_read_free(reader) }
        guard archive_read_support_format_zip_seekable(reader) == ARCHIVE_OK,
              archive_read_open_fd(reader, input, 65_536) == ARCHIVE_OK else {
            throw libraryFailure(reader, reason: .corruptArchive)
        }
        var count = 0, bytes: Int64 = 0
        var seen = Set<String>()
        while true {
            try cancelled()
            var entry: OpaquePointer?
            let result = archive_read_next_header(reader, &entry)
            if result == ARCHIVE_EOF { break }
            guard result == ARCHIVE_OK, let entry else { throw libraryFailure(reader, reason: .corruptArchive) }
            count += 1
            guard count <= limits.entries else { throw ArchiveFailure(.limitExceeded) }
            guard archive_entry_is_encrypted(entry) == 0 else { throw ArchiveFailure(.encryptedArchive) }
            guard archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil else {
                throw ArchiveFailure(.unsupportedEntry)
            }
            guard let rawName = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
                  let name = String(validatingCString: rawName) else { throw ArchiveFailure(.unsafeEntry) }
            let parts = try checkedPath(name)
            let identity = parts.joined(separator: "/")
            guard seen.insert(identity).inserted else { throw ArchiveFailure(.unsafeEntry) }
            let type = archive_entry_filetype(entry)
            guard type == UInt32(S_IFREG) || type == UInt32(S_IFDIR) else { throw ArchiveFailure(.unsupportedEntry) }
            let size = archive_entry_size(entry)
            guard size >= 0, size <= limits.fileBytes, bytes <= limits.totalBytes - size else {
                throw ArchiveFailure(.limitExceeded)
            }
            let target = parts.reduce(contents) { $0.appendingPathComponent($1) }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                if type == UInt32(S_IFDIR) {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                }
            } catch { throw ArchiveFailure(.unsafeEntry, detail: "Conflicting entry paths") }
            if type == UInt32(S_IFREG) {
                let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard output >= 0 else { throw ArchiveFailure(.unsafeEntry, detail: "Duplicate or conflicting entry") }
                defer { close(output) }
                var fileBytes: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    try cancelled()
                    let n = archive_read_data(reader, &buffer, buffer.count)
                    guard n >= 0 else { throw libraryFailure(reader, reason: .corruptArchive) }
                    if n == 0 { break }
                    fileBytes += Int64(n); bytes += Int64(n)
                    guard fileBytes <= size, fileBytes <= limits.fileBytes, bytes <= limits.totalBytes else {
                        throw ArchiveFailure(.limitExceeded)
                    }
                    try buffer.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < n {
                            let written = write(output, raw.baseAddress!.advanced(by: offset), n - offset)
                            if written < 0 && errno == EINTR { continue }
                            guard written > 0 else { throw io("write extracted file") }
                            offset += written
                        }
                    }
                }
                guard fileBytes == size else { throw ArchiveFailure(.corruptArchive) }
                let permissions = archive_entry_perm(entry) & 0o777
                guard fchmod(output, permissions == 0 ? 0o600 : permissions) == 0 else { throw io("file permissions") }
            } else {
                guard size == 0, archive_read_data_skip(reader) == ARCHIVE_OK else { throw ArchiveFailure(.corruptArchive) }
            }
        }
        guard count == expected, archive_read_has_encrypted_entries(reader) <= 0,
              archive_read_close(reader) == ARCHIVE_OK else { throw ArchiveFailure(.corruptArchive) }
        return try publish(contents, to: destination)
    }

    /// Verify a complete, single-volume ZIP/ZIP64 central directory before any extraction.
    /// Inspect raw names here because ZIP readers may normalize backslashes or embedded NULs.
    private func validateEnvelope(_ fd: Int32, length: Int64) throws -> Int {
        guard length >= 22 else { throw ArchiveFailure(.corruptArchive) }
        func readAt(_ offset: Int64, _ count: Int) throws -> [UInt8] {
            guard offset >= 0, offset <= length, count >= 0, Int64(count) <= length - offset else {
                throw ArchiveFailure(.corruptArchive)
            }
            var data = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                try cancelled()
                let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: done), count - done, offset + Int64(done)) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ArchiveFailure(.corruptArchive) }
                done += n
            }
            return data
        }
        func u16(_ b: [UInt8], _ n: Int) -> Int { Int(b[n]) | Int(b[n + 1]) << 8 }
        func u32(_ b: [UInt8], _ n: Int) -> Int64 { Int64(u16(b,n)) | Int64(u16(b,n + 2)) << 16 }
        func u64(_ b: [UInt8], _ n: Int) throws -> Int64 {
            guard n >= 0, n <= b.count - 8 else { throw ArchiveFailure(.corruptArchive) }
            let value = UInt64(u32(b, n)) | UInt64(u32(b, n + 4)) << 32
            guard value <= Int64.max else { throw ArchiveFailure(.limitExceeded) }
            return Int64(value)
        }
        let tailSize = Int(min(length, 65_557))
        let tail = try readAt(length - Int64(tailSize), tailSize)
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            u32(tail, $0) == 0x06054b50 && $0 + 22 + u16(tail, $0 + 20) == tail.count
        }) else { throw ArchiveFailure(.corruptArchive) }
        guard u16(tail, end + 4) == 0, u16(tail, end + 6) == 0,
              u16(tail, end + 8) == u16(tail, end + 10) else { throw ArchiveFailure(.unsupportedArchive) }
        var count = Int64(u16(tail, end + 10))
        var directorySize = u32(tail, end + 12), directoryOffset = u32(tail, end + 16)
        let endOffset = length - Int64(tailSize) + Int64(end)
        var directoryEnd = endOffset
        let locator = endOffset >= 20 ? try readAt(endOffset - 20, 20) : []
        if locator.count == 20 && u32(locator, 0) == 0x07064b50 {
            guard u32(locator, 4) == 0, u32(locator, 16) == 1 else { throw ArchiveFailure(.unsupportedArchive) }
            let recordOffset = try u64(locator, 8)
            let record = try readAt(recordOffset, 56)
            let recordSize = try u64(record, 4)
            guard u32(record, 0) == 0x06064b50, recordSize >= 44,
                  recordOffset <= endOffset - 32, recordSize == endOffset - 32 - recordOffset else {
                throw ArchiveFailure(.corruptArchive)
            }
            guard u32(record, 16) == 0, u32(record, 20) == 0,
                  try u64(record, 24) == u64(record, 32) else { throw ArchiveFailure(.unsupportedArchive) }
            count = try u64(record, 32)
            directorySize = try u64(record, 40)
            directoryOffset = try u64(record, 48)
            directoryEnd = recordOffset
        } else if count == 65_535 || directorySize == 0xffff_ffff || directoryOffset == 0xffff_ffff {
            throw ArchiveFailure(.corruptArchive)
        }
        guard count <= limits.entries else { throw ArchiveFailure(.limitExceeded) }
        guard directoryOffset <= directoryEnd, directorySize == directoryEnd - directoryOffset else {
            throw ArchiveFailure(.corruptArchive)
        }
        var offset = directoryOffset, total: Int64 = 0
        for _ in 0..<Int(count) {
            try cancelled()
            let header = try readAt(offset, 46)
            guard u32(header, 0) == 0x02014b50 else { throw ArchiveFailure(.corruptArchive) }
            guard u16(header, 8) & 0x41 == 0 else { throw ArchiveFailure(.encryptedArchive) }
            let declaredType = UInt32(u32(header, 38) >> 16) & UInt32(S_IFMT)
            guard declaredType == 0 || declaredType == UInt32(S_IFREG) || declaredType == UInt32(S_IFDIR) else {
                throw ArchiveFailure(.unsupportedEntry)
            }
            var size = u32(header, 24), compressed = u32(header, 20), localOffset = u32(header, 42)
            var disk = Int64(u16(header, 34))
            let nameLength = u16(header, 28), extraLength = u16(header, 30)
            let rawName = try readAt(offset + 46, nameLength)
            let extra = try readAt(offset + 46 + Int64(nameLength), extraLength)
            var extraPosition = 0, zip64: [UInt8]?
            while extraPosition < extra.count {
                guard extraPosition <= extra.count - 4 else { throw ArchiveFailure(.corruptArchive) }
                let identifier = u16(extra, extraPosition), size = u16(extra, extraPosition + 2)
                extraPosition += 4
                guard size <= extra.count - extraPosition else { throw ArchiveFailure(.corruptArchive) }
                if identifier == 1 {
                    guard zip64 == nil else { throw ArchiveFailure(.corruptArchive) }
                    zip64 = Array(extra[extraPosition..<(extraPosition + size)])
                }
                extraPosition += size
            }
            if size == 0xffff_ffff || compressed == 0xffff_ffff || localOffset == 0xffff_ffff || disk == 65_535 {
                guard let zip64 else { throw ArchiveFailure(.corruptArchive) }
                var cursor = 0
                if size == 0xffff_ffff { size = try u64(zip64, cursor); cursor += 8 }
                if compressed == 0xffff_ffff { compressed = try u64(zip64, cursor); cursor += 8 }
                if localOffset == 0xffff_ffff { localOffset = try u64(zip64, cursor); cursor += 8 }
                if disk == 65_535 {
                    guard cursor <= zip64.count - 4 else { throw ArchiveFailure(.corruptArchive) }
                    disk = u32(zip64, cursor)
                }
            }
            guard disk == 0 else { throw ArchiveFailure(.unsupportedArchive) }
            guard size <= limits.fileBytes, size <= limits.totalBytes - total else { throw ArchiveFailure(.limitExceeded) }
            total += size
            guard !rawName.contains(0), !rawName.contains(92), !rawName.contains(58), rawName.first != 47 else {
                throw ArchiveFailure(.unsafeEntry)
            }
            // Non-UTF8 legacy ZIP names are decoded by libarchive; ASCII separators are validated here.
            _ = try checkedPath(String(decoding: rawName, as: UTF8.self))
            let local = try readAt(localOffset, 30)
            let localHeaderSize = Int64(30 + nameLength + u16(local, 28))
            guard u32(local, 0) == 0x04034b50, u16(local, 6) == u16(header, 8),
                  u16(local, 8) == u16(header, 10), u16(local, 26) == nameLength,
                  try readAt(localOffset + 30, nameLength) == rawName,
                  localOffset <= directoryOffset, localHeaderSize <= directoryOffset - localOffset,
                  compressed <= directoryOffset - localOffset - localHeaderSize else { throw ArchiveFailure(.corruptArchive) }
            offset += Int64(46 + nameLength + extraLength + u16(header, 32))
            guard offset <= directoryEnd else { throw ArchiveFailure(.corruptArchive) }
        }
        guard offset == directoryEnd else { throw ArchiveFailure(.corruptArchive) }
        return Int(count)
    }
}
