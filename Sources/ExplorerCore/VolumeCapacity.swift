// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// The filesystem ID keeps a menu opened before ejection bound to its original mount.
public struct VolumeMount: Equatable, Sendable {
    public enum Removal: Sendable { case eject, disconnect }
    public let removal: Removal?
    public let url: URL
    private let id0: Int32
    private let id1: Int32

    public static func identify(at url: URL) throws -> Self {
        let stats = try mountStats(at: url)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var removal: Removal?
        if resolved.path == url.standardizedFileURL.path, resolved.deletingLastPathComponent().path == "/Volumes" {
            let info = try? resolved.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey])
            if info?.volumeIsLocal == false { removal = .disconnect }
            else if info?.volumeIsEjectable == true || info?.volumeIsRemovable == true { removal = .eject }
        }
        return Self(removal: removal, url: url, id0: stats.f_fsid.val.0, id1: stats.f_fsid.val.1)
    }

    public func capacity() throws -> VolumeCapacity {
        let stats = try Self.mountStats(at: url)
        guard stats.f_fsid.val == (id0, id1) else { throw CocoaError(.fileReadUnknown) }
        return try VolumeCapacity(blocks: stats.f_blocks, available: stats.f_bavail, blockSize: stats.f_bsize)
    }

    private static func mountStats(at url: URL) throws -> statfs {
        try DirectoryReader.validateLocalURL(url)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = open(resolved.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var stats = statfs()
        guard fstatfs(descriptor, &stats) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let mountPath = withUnsafeBytes(of: stats.f_mntonname) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard mountPath == resolved.path else { throw CocoaError(.fileReadUnknown) }
        return stats
    }
}

public struct VolumeCapacity: Sendable {
    public let total: Int64
    public let free: Int64
    public var used: Int64 { total - free }

    init(blocks: UInt64, available: UInt64, blockSize: UInt32) throws {
        let (size, overflow) = blocks.multipliedReportingOverflow(by: UInt64(blockSize))
        guard blocks > 0, blockSize > 0, available <= blocks, !overflow,
              let total = Int64(exactly: size) else { throw CocoaError(.fileReadUnknown) }
        self.total = total
        free = Int64(available * UInt64(blockSize))
    }
}
