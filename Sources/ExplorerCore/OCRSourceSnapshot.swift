// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

internal struct OCRSource: Sendable {
    let original: URL
    let resolved: URL
    let identity: OCRFileIdentity

    static func inspect(_ url: URL, limits: OCRLimits, control: OCRCancellation) throws -> Self {
        try control.check()
        do { try DirectoryReader.validateLocalURL(url) } catch { throw OCRFailure(.invalidRequest) }
        var original = stat()
        guard lstat(url.path, &original) == 0 else { throw OCRFailure(errno == EACCES ? .permissionDenied : .unavailable) }
        // A final symlink is not a document; ancestors are separately resolved and authorized.
        try checkMetadata(original, maximumBytes: limits.maximumFileBytes)
        let resolved: URL
        switch MediaFileAccess.availability(of: url) {
        case .available(let value): resolved = value
        case .needsDownload: throw OCRFailure(.needsDownload)
        case .unavailable: throw OCRFailure(.unavailable)
        }
        try control.check()
        do { try LocalTransferRecovery.assertExportable(url); try LocalTransferRecovery.assertExportable(resolved) }
        catch { throw OCRFailure(.permissionDenied) }
        var target = stat()
        guard lstat(resolved.path, &target) == 0, OCRFileIdentity(original) == OCRFileIdentity(target) else { throw OCRFailure(.sourceChanged) }
        return Self(original: url, resolved: resolved, identity: OCRFileIdentity(target))
    }
    static func checkMetadata(_ value: stat, maximumBytes: Int64) throws {
        guard value.st_mode & S_IFMT == S_IFREG else { throw OCRFailure(.unavailable) }
        guard value.st_flags & UInt32(SF_DATALESS) == 0 else { throw OCRFailure(.needsDownload) }
        guard value.st_size >= 0, value.st_size <= maximumBytes else { throw OCRFailure(.limitExceeded) }
    }
    func validate(_ control: OCRCancellation) throws {
        try control.check()
        var first = stat(), target = stat()
        guard lstat(original.path, &first) == 0, lstat(resolved.path, &target) == 0,
              OCRFileIdentity(first) == identity, OCRFileIdentity(target) == identity else { throw OCRFailure(.sourceChanged) }
        guard first.st_flags & UInt32(SF_DATALESS) == 0, target.st_flags & UInt32(SF_DATALESS) == 0 else { throw OCRFailure(.needsDownload) }
        do { try LocalTransferRecovery.assertExportable(original); try LocalTransferRecovery.assertExportable(resolved) }
        catch { throw OCRFailure(.permissionDenied) }
        try control.check()
    }
    func snapshot(_ control: OCRCancellation) throws -> OCRSnapshot {
        try validate(control)
        let input = open(resolved.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw OCRFailure(errno == EACCES ? .permissionDenied : .unavailable) }
        defer { close(input) }
        var opened = stat()
        guard fstat(input, &opened) == 0, OCRFileIdentity(opened) == identity else { throw OCRFailure(.sourceChanged) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(".my-explorer-ocr-\(UUID())")
        guard mkdir(directory.path, 0o700) == 0 else { throw OCRFailure(.unavailable) }
        let payload = directory.appendingPathComponent("document")
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let output = open(payload.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw OCRFailure(.unavailable) }
        defer { close(output) }
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024), copied: Int64 = 0
        while true {
            try control.check()
            let count = read(input, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw OCRFailure(.unavailable) }
            if count == 0 { break }
            copied += Int64(count)
            guard copied <= identity.size else { throw OCRFailure(.sourceChanged) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < count {
                    try control.check()
                    let amount = write(output, buffer.baseAddress!.advanced(by: offset), count - offset)
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw OCRFailure(.unavailable) }
                    offset += amount
                }
            }
        }
        guard copied == identity.size, fstat(input, &opened) == 0, OCRFileIdentity(opened) == identity else { throw OCRFailure(.sourceChanged) }
        try validate(control)
        complete = true
        return OCRSnapshot(directory: directory, payload: payload)
    }
}
internal struct OCRSnapshot: Sendable {
    let directory: URL
    let payload: URL
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
internal struct OCRFileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let mode: UInt16
    let flags: UInt32
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size; mode = value.st_mode; flags = value.st_flags
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}
