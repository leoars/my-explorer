// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

public enum SecureFolderDiskError: Error {
    case unsupportedLocation, unsupportedItem, sourceChanged, verificationFailed
    case diskUtilityFailed(Int32), recoveryRequired(URL)
}

/// The caller serializes operations for a vault. All temporary cleartext stays on the
/// source volume or inside the mounted encrypted image. Password material travels on stdin.
enum SecureFolderDisk {
    private static var fm: FileManager { .default }
    private static let imageName = "contents.sparsebundle"
    private static let credentialsName = "credentials.json"

    private struct Record: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let mode: mode_t
        let modificationSeconds: Int
        let modificationNanos: Int
        let changeSeconds: Int
        let changeNanos: Int
    }

    static func convert(_ source: URL, secret: Data, metadata: Data, verificationMount: URL? = nil,
                        beforePublication: () throws -> Void = {}, beforeCleanup: (URL) throws -> Void = { _ in },
                        beforeClaim: (URL) throws -> Void = { _ in }) throws -> URL {
        guard source.isFileURL, !secret.isEmpty, !metadata.isEmpty else {
            throw SecureFolderDiskError.unsupportedLocation
        }
        let folder = source.standardizedFileURL
        let parent = folder.deletingLastPathComponent()
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().pathComponents
        guard !home.starts(with: resolved.pathComponents), folder.pathExtension != "myexplorervault",
              !resolved.pathComponents.contains(where: { $0.lowercased().hasSuffix(".myexplorervault") }),
              try fileStat(folder).st_mode & S_IFMT == S_IFDIR,
              try fileStat(parent).st_dev == fileStat(folder).st_dev else {
            throw SecureFolderDiskError.unsupportedLocation
        }
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        for name in ["CloudStorage", "Mobile Documents"] {
            if resolved.pathComponents.starts(with: library.appendingPathComponent(name).resolvingSymlinksInPath().pathComponents) {
                throw SecureFolderDiskError.unsupportedLocation
            }
        }

        let vault = parent.appendingPathComponent(folder.lastPathComponent + ".myexplorervault", isDirectory: true)
        guard !fm.fileExists(atPath: vault.path) else { throw CocoaError(.fileWriteFileExists) }
        let initial = try inventory(folder)
        let stage = parent.appendingPathComponent(".myexplorer-stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Only remove the staged image once every attach has been successfully detached.
        var attached = false
        var staged = true
        defer { if staged && !attached { try? fm.removeItem(at: stage) } }
        try metadata.write(to: stage.appendingPathComponent(credentialsName), options: .withoutOverwriting)

        let totalBytes = initial.values.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let sizeMiB = max(Int64(16_384), totalBytes / (1024 * 1024) * 2 + 512)
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(sizeMiB)m", "-type", "SPARSEBUNDLE",
            "-fs", "Case-sensitive APFS", "-volname", "My Explorer", "-nospotlight", "-encryption", "AES-256",
            "-stdinpass", stage.appendingPathComponent(imageName).path], secret: secret)
        let temporaryMount = verificationMount ?? fm.temporaryDirectory.appendingPathComponent("myexplorer-" + UUID().uuidString)
        try fm.createDirectory(at: temporaryMount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { if !attached { _ = rmdir(temporaryMount.path) } }
        try mount(in: stage, secret: secret, at: temporaryMount)
        attached = true
        do {
            let contents = temporaryMount.appendingPathComponent("Files")
            try run("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", folder.path, contents.path], cancellable: true)
            try unmount(temporaryMount)
            attached = false
            // Read back from the closed and reopened image before touching the source.
            try mount(in: stage, secret: secret, at: temporaryMount)
            attached = true
            try verify(original: folder, copy: contents, initial: initial)
            try unmount(temporaryMount)
            attached = false
        } catch {
            if attached { try unmount(temporaryMount); attached = false }
            throw error
        }
        let verifiedPackage = try inventory(stage)
        try beforePublication()
        try Task.checkCancellation()
        try moveExclusively(stage, vault)
        staged = false
        // Publish the verified encrypted copy first. On interruption, either the original
        // or this explicitly named recovery folder remains alongside the complete vault.
        let backup = parent.appendingPathComponent("My Explorer Recovery " + UUID().uuidString)
        try Task.checkCancellation()
        try moveExclusively(folder, backup)
        do {
            let final = try inventory(backup)
            guard matchesAfterRename(initial, final) else {
                throw SecureFolderDiskError.sourceChanged
            }
        } catch {
            do { try moveExclusively(backup, folder) } catch { throw SecureFolderDiskError.recoveryRequired(backup) }
            throw error
        }
        do {
            try beforeCleanup(backup)
            // A second client may have replaced the published package or changed an
            // envelope or image band while we verified the plaintext recovery tree.
            guard try matchesAfterRename(verifiedPackage, inventory(vault)),
                  try Data(contentsOf: vault.appendingPathComponent(credentialsName)) == metadata else {
                throw SecureFolderDiskError.verificationFailed
            }
            try removeVerifiedEntries(in: backup, snapshot: initial, beforeClaim: beforeClaim)
        } catch { throw SecureFolderDiskError.recoveryRequired(backup) }
        return vault
    }

    private static func matchesAfterRename(_ original: [String: Record], _ current: [String: Record]) -> Bool {
        // Renaming a directory may change its own ctime. All descendant identities
        // and modification records must still match the tree we verified.
        original[""]?.inode == current[""]?.inode && original[""]?.device == current[""]?.device &&
            original.count == current.count && original.allSatisfy { $0.key.isEmpty || current[$0.key] == $0.value }
    }

    /// New entries and changed files are left in recovery. A recursive deletion here
    /// could silently discard a file added by another process after verification.
    private static func removeVerifiedEntries(in root: URL, snapshot: [String: Record],
                                              beforeClaim: (URL) throws -> Void) throws {
        let paths = snapshot.keys.filter { !$0.isEmpty }.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        for path in paths.reversed() {
            let components = path.split(separator: "/")
            let parent = components.dropLast().joined(separator: "/")
            guard let name = components.last, let expected = snapshot[path], let expectedParent = snapshot[parent] else {
                throw SecureFolderDiskError.sourceChanged
            }
            let directory = open(root.appendingPathComponent(parent).path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard directory >= 0 else { throw SecureFolderDiskError.sourceChanged }
            defer { close(directory) }
            var actualParent = stat(), actual = stat()
            guard fstat(directory, &actualParent) == 0,
                  actualParent.st_ino == expectedParent.inode, actualParent.st_dev == expectedParent.device,
                  fstatat(directory, String(name), &actual, AT_SYMLINK_NOFOLLOW) == 0,
                  actual.st_dev == expected.device, actual.st_ino == expected.inode, actual.st_mode == expected.mode
            else { throw SecureFolderDiskError.sourceChanged }
            let isDirectory = actual.st_mode & S_IFMT == S_IFDIR
            if !isDirectory {
                guard actual.st_size == expected.size, actual.st_ctimespec.tv_sec == expected.changeSeconds,
                      actual.st_ctimespec.tv_nsec == expected.changeNanos,
                      actual.st_mtimespec.tv_sec == expected.modificationSeconds,
                      actual.st_mtimespec.tv_nsec == expected.modificationNanos else {
                    throw SecureFolderDiskError.sourceChanged
                }
            }
            try beforeClaim(root.appendingPathComponent(path))
            try claimAndRemove(name: String(name), in: directory, expected: expected, isDirectory: isDirectory)
        }
        let residual = try fileStat(root)
        guard residual.st_dev == snapshot[""]?.device, residual.st_ino == snapshot[""]?.inode,
              rmdir(root.path) == 0 else { throw SecureFolderDiskError.sourceChanged }
    }

    /// An editor can atomically replace the old name after fstatat. Move whichever
    /// entry currently owns it into a fresh private directory, then check that entry
    /// before unlinking it. A failed claim stays in recovery under its original name.
    private static func claimAndRemove(name: String, in parent: Int32, expected: Record, isDirectory: Bool) throws {
        let claim = "My Explorer Recovery " + UUID().uuidString
        guard mkdirat(parent, claim, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = unlinkat(parent, claim, AT_REMOVEDIR) }
        let directory = openat(parent, claim, O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(directory) }

        guard renameat(parent, name, directory, name) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var claimed = stat()
        guard fstatat(directory, name, &claimed, AT_SYMLINK_NOFOLLOW) == 0,
              claimed.st_dev == expected.device, claimed.st_ino == expected.inode, claimed.st_mode == expected.mode,
              isDirectory || (claimed.st_size == expected.size && claimed.st_mtimespec.tv_sec == expected.modificationSeconds
                  && claimed.st_mtimespec.tv_nsec == expected.modificationNanos) else {
            throw SecureFolderDiskError.sourceChanged
        }
        guard unlinkat(directory, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    static func mount(in directory: URL, secret: Data, at mount: URL) throws {
        try fm.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-owners", "on",
            "-mountpoint", mount.path, "-stdinpass", directory.appendingPathComponent(imageName).path], secret: secret)
    }

    static func unmount(_ mount: URL) throws {
        try run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])
    }

    private static func verify(original: URL, copy: URL, initial: [String: Record]) throws {
        let copied = try inventory(copy)
        guard Set(initial.keys) == Set(copied.keys) else { throw SecureFolderDiskError.verificationFailed }
        for (path, record) in initial {
            try Task.checkCancellation()
            guard record.mode & S_IFMT == copied[path]!.mode & S_IFMT else { throw SecureFolderDiskError.verificationFailed }
            let a = original.appendingPathComponent(path), b = copy.appendingPathComponent(path)
            try verifyMetadata(a, b)
            switch record.mode & S_IFMT {
            case S_IFREG:
                guard record.size == copied[path]?.size, try digest(a) == digest(b) else {
                    throw SecureFolderDiskError.verificationFailed
                }
            case S_IFLNK:
                guard try fm.destinationOfSymbolicLink(atPath: a.path) == fm.destinationOfSymbolicLink(atPath: b.path)
                else { throw SecureFolderDiskError.verificationFailed }
            default: break
            }
        }
        guard try inventory(original) == initial else { throw SecureFolderDiskError.sourceChanged }
    }

    private static func verifyMetadata(_ source: URL, _ copy: URL) throws {
        let original = try fileStat(source)
        let target = try fileStat(copy)
        guard original.st_mode == target.st_mode, original.st_uid == target.st_uid, original.st_gid == target.st_gid,
              try accessControlList(source) == accessControlList(copy) else {
            throw SecureFolderDiskError.verificationFailed
        }
        let count = listxattr(source.path, nil, 0, XATTR_NOFOLLOW)
        if count < 0 && (errno == ENOTSUP || errno == EOPNOTSUPP) { return }
        guard count >= 0, count < 1024 * 1024 else { throw SecureFolderDiskError.verificationFailed }
        var names = [CChar](repeating: 0, count: count)
        guard count == listxattr(source.path, &names, count, XATTR_NOFOLLOW) else { throw SecureFolderDiskError.sourceChanged }
        for bytes in names.split(separator: 0) {
            guard let name = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                throw SecureFolderDiskError.verificationFailed
            }
            if name == "com.apple.ResourceFork", original.st_mode & S_IFMT == S_IFREG {
                guard try digest(source.appendingPathComponent("..namedfork/rsrc")) ==
                    digest(copy.appendingPathComponent("..namedfork/rsrc")) else {
                    throw SecureFolderDiskError.verificationFailed
                }
            } else {
                let originalValue = try attribute(name, of: source)
                let copiedValue = try attribute(name, of: copy)
                guard originalValue == copiedValue ||
                      (name == "com.apple.quarantine" && sameQuarantineEvent(originalValue, copiedValue)) else {
                    throw SecureFolderDiskError.verificationFailed
                }
            }
        }
    }

    /// Copying into another APFS volume can renew the timestamp and agent.
    /// Keep an exact match for the security flags, event ID and any later fields.
    static func sameQuarantineEvent(_ original: Data, _ copy: Data) -> Bool {
        let source = original.split(separator: 0x3b, omittingEmptySubsequences: false)
        let target = copy.split(separator: 0x3b, omittingEmptySubsequences: false)
        guard source.count >= 4, source.count == target.count,
              UInt32(String(decoding: source[0], as: UTF8.self), radix: 16) != nil,
              UUID(uuidString: String(decoding: source[3], as: UTF8.self)) != nil else { return false }
        return source[0] == target[0] && source.dropFirst(3) == target.dropFirst(3)
    }

    private static func attribute(_ name: String, of item: URL) throws -> Data {
        let count = getxattr(item.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard count >= 0, count <= 16 * 1024 * 1024 else { throw SecureFolderDiskError.verificationFailed }
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes {
            getxattr(item.path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW)
        }
        guard actual == count else { throw SecureFolderDiskError.verificationFailed }
        return data
    }

    private static func accessControlList(_ item: URL) throws -> Data? {
        errno = 0
        guard let acl = acl_get_link_np(item.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP || errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else { throw SecureFolderDiskError.verificationFailed }
        defer { acl_free(text) }
        return Data(bytes: text, count: length)
    }

    private static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize()
    }

    private static func inventory(_ root: URL) throws -> [String: Record] {
        var result: [String: Record] = [:]
        let device = try fileStat(root).st_dev
        var pending = [(root, "")]
        while let (url, path) = pending.popLast() {
            try Task.checkCancellation()
            let value = try fileStat(url)
            guard value.st_dev == device, value.st_flags & UInt32(SF_DATALESS) == 0 else {
                throw SecureFolderDiskError.unsupportedLocation
            }
            let type = value.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFLNK || (type == S_IFREG && value.st_nlink == 1) else {
                throw SecureFolderDiskError.unsupportedItem
            }
            guard type == S_IFLNK || !fm.isUbiquitousItem(at: url) else { throw SecureFolderDiskError.unsupportedLocation }
            result[path] = Record(device: device, inode: value.st_ino, size: value.st_size, mode: value.st_mode,
                modificationSeconds: value.st_mtimespec.tv_sec, modificationNanos: value.st_mtimespec.tv_nsec,
                changeSeconds: value.st_ctimespec.tv_sec, changeNanos: value.st_ctimespec.tv_nsec)
            if type == S_IFDIR {
                for name in try fm.contentsOfDirectory(atPath: url.path) {
                    pending.append((url.appendingPathComponent(name), path.isEmpty ? name : path + "/" + name))
                }
            }
        }
        return result
    }

    private static func fileStat(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return value
    }

    private static func moveExclusively(_ from: URL, _ to: URL) throws {
        if renameatx_np(AT_FDCWD, from.path, AT_FDCWD, to.path, UInt32(RENAME_EXCL)) == 0 { return }
        guard errno == ENOTSUP || errno == EOPNOTSUPP || errno == EINVAL else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // exFAT has atomic mkdir and ordinary rename, but lacks RENAME_EXCL.
        // Rename onto our exclusively reserved empty directory, never onto another user's item.
        guard mkdir(to.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let reservation = try fileStat(to)
        if rename(from.path, to.path) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            if let current = try? fileStat(to), current.st_ino == reservation.st_ino, current.st_dev == reservation.st_dev {
                _ = rmdir(to.path)
            }
            throw POSIXError(code)
        }
    }

    private static func run(_ executable: String, _ arguments: [String], secret: Data? = nil, cancellable: Bool = false) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let input = Pipe()
        task.standardInput = input
        try task.run()
        if let secret {
            // stdinpass consumes a single NUL-terminated UTF-8 password.
            try input.fileHandleForWriting.write(contentsOf: Data(secret.base64EncodedString().utf8) + Data([0]))
        }
        try input.fileHandleForWriting.close()
        if cancellable {
            while task.isRunning {
                if Task.isCancelled {
                    task.terminate()
                    task.waitUntilExit()
                    throw CancellationError()
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw SecureFolderDiskError.diskUtilityFailed(task.terminationStatus) }
    }
}
