// SPDX-License-Identifier: Apache-2.0
import Darwin
import CryptoKit
import Foundation

/// The actor serializes mounting, locking and password changes across the app's windows.
public actor SecureFolderService {
    public static let shared = SecureFolderService(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MyExplorer/SecureFolders", isDirectory: true))

    private struct MasterSettings: Codable {
        let credential: SecureFolderMasterCredential
        let enabled: Bool
    }

    private let directory: URL
    private let files = FileManager.default
    private struct MountedFolder {
        let url: URL
        let folderID: UUID
        let imageDevice: dev_t
        let imageInode: ino_t
        let lease: MountLease
    }

    // Keep the lock outside the mountpoint: attachment hides the underlying directory.
    // Closing this descriptor on process exit makes an orphan eligible for recovery.
    private final class MountLease {
        let file: URL
        let descriptor: Int32

        init?(mount: URL) throws {
            file = mount.appendingPathExtension("lease")
            let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let failure = errno
                close(fd)
                if failure == EWOULDBLOCK { return nil }
                throw POSIXError(.init(rawValue: failure) ?? .EIO)
            }
            descriptor = fd
        }

        deinit { close(descriptor) }
    }

    private var mounts: [URL: MountedFolder] = [:]

    package init(directory: URL) { self.directory = directory }

    private var settingsURL: URL { directory.appendingPathComponent("master.json") }
    public var hasStoredMasterPassword: Bool { files.fileExists(atPath: settingsURL.path) }
    public var hasMasterPassword: Bool { (try? settings().enabled) == true }

    public nonisolated static func isVault(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "myexplorervault"
    }

    public nonisolated static func isSessionURL(_ url: URL) -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MyExplorer/SecureFolders/Mounts", isDirectory: true)
            .standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return url.isFileURL && (path == root || path.hasPrefix(root + "/"))
    }

    private func settings() throws -> MasterSettings {
        try JSONDecoder().decode(MasterSettings.self, from: Data(contentsOf: settingsURL))
    }

    private func recoveryKey(_ password: String) throws -> SymmetricKey {
        let current = try settings()
        guard current.enabled else { throw CocoaError(.userCancelled) }
        return try current.credential.recoveryKey(password: password)
    }

    public func configureMasterPassword(current: String?, new: String?) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("master.lock").path,
                              O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let updated: MasterSettings
        if hasStoredMasterPassword {
            let previous = try settings().credential
            guard let current else { throw CocoaError(.fileReadNoPermission) }
            if let new {
                updated = MasterSettings(credential: try previous.changingPassword(from: current, to: new), enabled: true)
            } else {
                _ = try previous.recoveryKey(password: current)
                updated = MasterSettings(credential: previous, enabled: false)
            }
        } else {
            guard let new else { throw CocoaError(.fileNoSuchFile) }
            updated = MasterSettings(credential: try SecureFolderMasterCredential(password: new), enabled: true)
        }
        try JSONEncoder().encode(updated).write(to: settingsURL, options: .atomic)
    }

    public func protect(_ folder: URL, password: String, masterPassword: String) throws -> URL {
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let home = files.homeDirectoryForCurrentUser.standardizedFileURL.path
        let config = directory.standardizedFileURL.path
        guard folder.isFileURL, !Self.isVault(folder), path != "/", path != home,
              !home.hasPrefix(path + "/"), !config.hasPrefix(path + "/"), path != config,
              !path.hasPrefix(config + "/") else { throw CocoaError(.fileWriteNoPermission) }
        let key = try recoveryKey(masterPassword)
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let credentials = try SecureFolderCredentials(id: UUID(), secret: secret, password: password, recoveryKey: key)
        let (verification, lease) = try newMountDirectory()
        defer { cleanUnusedMount(verification, lease: lease) }
        return try SecureFolderDisk.convert(folder, secret: secret, metadata: JSONEncoder().encode(credentials),
                                            verificationMount: verification)
    }

    public func unlock(_ vault: URL, password: String) throws -> URL {
        let source = vault.resolvingSymlinksInPath().standardizedFileURL
        let credentials = try readCredentials(source)
        let secret: Data
        do {
            secret = try credentials.secret(password: password)
        } catch CryptoKitError.authenticationFailure {
            guard hasMasterPassword else { throw CryptoKitError.authenticationFailure }
            secret = try credentials.secret(recoveryKey: recoveryKey(password))
        }

        var image = stat()
        let imageURL = source.appendingPathComponent("contents.sparsebundle")
        guard lstat(imageURL.path, &image) == 0, image.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let existing = mounts[source] {
            if Self.isMounted(existing.url) {
                guard existing.folderID == credentials.id, existing.imageDevice == image.st_dev,
                      existing.imageInode == image.st_ino else { throw SecureFolderDiskError.sourceChanged }
                return existing.url.appendingPathComponent("Files", isDirectory: true)
            }
            cleanUnusedMount(existing.url, lease: existing.lease)
            mounts.removeValue(forKey: source)
        }
        let (mount, lease) = try newMountDirectory()
        do {
            try SecureFolderDisk.mount(in: source, secret: secret, at: mount)
        } catch {
            // rmdir can only remove an empty directory, including after a failed attach.
            cleanUnusedMount(mount, lease: lease)
            throw error
        }
        mounts[source] = MountedFolder(url: mount, folderID: credentials.id, imageDevice: image.st_dev,
                                       imageInode: image.st_ino, lease: lease)
        return mount.appendingPathComponent("Files", isDirectory: true)
    }

    private func newMountDirectory() throws -> (URL, MountLease) {
        let root = directory.appendingPathComponent("Mounts", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The mounted filesystem supplies its own root permissions. Restrict its parent too.
        let fd = open(root.path, O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let mount = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard let lease = try MountLease(mount: mount) else { throw POSIXError(.EBUSY) }
        do {
            try files.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            _ = unlink(lease.file.path)
            throw error
        }
        return (mount, lease)
    }

    private func cleanUnusedMount(_ mount: URL, lease: MountLease) {
        if rmdir(mount.path) == 0 || errno == ENOENT { _ = unlink(lease.file.path) }
    }

    public func lock(_ vault: URL) throws {
        let source = vault.resolvingSymlinksInPath().standardizedFileURL
        try lockSource(source)
    }

    private func lockSource(_ source: URL) throws {
        guard let mount = mounts[source] else { return }
        try detach(mount.url)
        _ = unlink(mount.lease.file.path)
        mounts.removeValue(forKey: source)
    }

    public func lockAll() throws {
        var failure: Error?
        // Discover mounts left by an interrupted app instance as well as the live map.
        let root = directory.appendingPathComponent("Mounts", isDirectory: true)
        for source in Array(mounts.keys) {
            do { try lockSource(source) } catch { failure = error }
        }
        if files.fileExists(atPath: root.path) {
            for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where UUID(uuidString: url.lastPathComponent) != nil {
                do {
                    guard let lease = try MountLease(mount: url) else { continue }
                    try detach(url)
                    _ = unlink(lease.file.path)
                } catch { failure = error }
            }
        }
        if let failure { throw failure }
    }

    private static func isMounted(_ mount: URL) -> Bool {
        var child = stat(), parent = stat()
        return lstat(mount.path, &child) == 0 && lstat(mount.deletingLastPathComponent().path, &parent) == 0
            && child.st_dev != parent.st_dev
    }

    private func detach(_ mount: URL) throws {
        if Self.isMounted(mount) { try SecureFolderDisk.unmount(mount) }
        if rmdir(mount.path) != 0 && errno != ENOENT { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func readCredentials(_ vault: URL) throws -> SecureFolderCredentials {
        guard Self.isVault(vault) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let url = vault.appendingPathComponent("credentials.json")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        let maximumSize = 16 * 1024
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumSize,
              let data = try handle.read(upToCount: maximumSize + 1), data.count == info.st_size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(SecureFolderCredentials.self, from: data)
    }

    public func resetPassword(_ vault: URL, masterPassword: String, newPassword: String) throws {
        let credentials = try readCredentials(vault).resettingPassword(to: newPassword, recoveryKey: recoveryKey(masterPassword))
        try JSONEncoder().encode(credentials).write(to: vault.appendingPathComponent("credentials.json"), options: .atomic)
    }
}
