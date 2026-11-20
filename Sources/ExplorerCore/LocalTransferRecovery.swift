// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

/// Identifies only private recovery directories bearing a marker bound to their filesystem identity.
/// This is accidental-export prevention, not isolation from an unrestricted process of the same user.
public enum LocalTransferRecovery {
    private static let marker = ".my-explorer-local-journal-v1"
    static func mark(_ root: URL) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw LocalTransferFailure(.io) }
        let location = root.appendingPathComponent(marker)
        let fd = open(location.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalTransferFailure(.io) }
        defer { close(fd) }
        let bytes = Array(payload(info).utf8)
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count, fsync(fd) == 0 else {
            throw LocalTransferFailure(.io)
        }
    }
    private static func payload(_ info: stat) -> String {
        "io.github.leoars.myexplorer.local-journal:1:\(info.st_uid):\(info.st_dev):\(info.st_ino)\n"
    }
    private static func marked(_ root: URL) -> Bool {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { return false }
        let fd = open(root.appendingPathComponent(marker).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_nlink == 1,
              file.st_uid == getuid(), file.st_size > 0, file.st_size <= 512 else { return false }
        var data = [UInt8](repeating: 0, count: Int(file.st_size))
        guard read(fd, &data, data.count) == data.count else { return false }
        return String(decoding: data, as: UTF8.self) == payload(info)
    }
    public static func isProtected(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var input = url.standardizedFileURL
        // Destination paths may not exist yet; check the nearest existing ancestor as well.
        while true {
            if let path = realpath(input.path, nil) {
                var current = URL(fileURLWithPath: String(cString: path)); free(path)
                while true {
                    if marked(current) { return true }
                    if current.path == "/" { break }
                    current.deleteLastPathComponent()
                }
                return false
            }
            if input.path == "/" { return false }
            input.deleteLastPathComponent()
        }
    }
    public static func containsRecoveryData(at url: URL) -> Bool {
        do { try assertExportable(url); return false } catch { return true }
    }
    public static func assertExportable(_ url: URL) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { return }
        if isProtected(url) { throw LocalTransferFailure(.unsupportedEntry) }
        var root = stat()
        guard lstat(url.path, &root) == 0 else { throw LocalTransferFailure(.io) }
        guard root.st_mode & S_IFMT == S_IFDIR else { return }
        var count = 0
        func walk(_ directory: URL, _ depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 128 else { throw LocalTransferFailure(.limitExceeded) }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                try Task.checkCancellation()
                count += 1
                guard count <= 100_000 else { throw LocalTransferFailure(.limitExceeded) }
                let child = directory.appendingPathComponent(name)
                if isProtected(child) { throw LocalTransferFailure(.unsupportedEntry) }
                var info = stat()
                guard lstat(child.path, &info) == 0 else { throw LocalTransferFailure(.changed) }
                if info.st_mode & S_IFMT == S_IFDIR { try walk(child, depth + 1) }
            }
        }
        try walk(url, 0)
    }
    static var markerName: String { marker }
}
