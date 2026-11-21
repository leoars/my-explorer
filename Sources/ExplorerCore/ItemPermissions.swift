// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

/// The dialog edits only the nine POSIX access bits of the exact item originally inspected.
public struct ItemPermissions: Sendable {
    public let owner: String
    public let group: String
    public let mode: UInt16
    public let effectiveAccess: [Bool]
    public let acl: String?
    public let canEdit: Bool
    private let device: dev_t
    private let inode: ino_t

    private static func descriptor(_ url: URL) throws -> Int32 {
        try DirectoryReader.validateLocalURL(url)
        let resolved = url.resolvingSymlinksInPath()
        guard !LocalTransferRecovery.isProtected(url), !SecureFolderService.isSessionURL(resolved),
              DirectoryReader.enclosingVault(resolved) == nil else { throw CocoaError(.fileReadNoPermission) }
        let fd = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }

    public static func inspect(_ url: URL) throws -> Self {
        let fd = try descriptor(url)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        var rules: String?
        if let accessList = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(accessList)) }
            var entry: acl_entry_t?
            if acl_get_entry(accessList, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0, let description = acl_to_text(accessList, nil) {
                rules = String(cString: description)
                acl_free(description)
            }
        } else if errno != ENOENT && errno != ENOTSUP {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let kind = info.st_mode & S_IFMT
        return Self(owner: attributes[.ownerAccountName] as? String ?? String(info.st_uid),
                    group: attributes[.groupOwnerAccountName] as? String ?? String(info.st_gid),
                    mode: info.st_mode & 0o7777,
                    effectiveAccess: [R_OK, W_OK, X_OK].map { access(url.path, $0) == 0 },
                    acl: rules,
                    canEdit: (geteuid() == info.st_uid || geteuid() == 0) && (kind == S_IFREG || kind == S_IFDIR)
                        && info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0,
                    device: info.st_dev, inode: info.st_ino)
    }

    public func apply(accessBits: UInt16, to url: URL) throws {
        guard canEdit, accessBits <= 0o777 else { throw CocoaError(.fileWriteNoPermission) }
        let fd = try Self.descriptor(url)
        defer { close(fd) }
        var current = stat()
        guard fstat(fd, &current) == 0, current.st_dev == device, current.st_ino == inode,
              current.st_mode & 0o7777 == mode else { throw POSIXError(.ESTALE) }
        guard fchmod(fd, (mode & 0o7000) | accessBits) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
