// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

struct TrashIdentity: Hashable, Codable, Sendable {
    let device: dev_t
    let inode: ino_t
    let type: mode_t
    let birthSeconds: Int
    let birthNanos: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        type = info.st_mode & S_IFMT
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanos = info.st_birthtimespec.tv_nsec
    }
}

struct TrashRestoreOrigin: Codable, Sendable {
    let url: URL
    let parent: TrashIdentity
    let item: TrashIdentity
    var isDirectory: Bool { item.type == S_IFDIR }

    init(_ url: URL) throws {
        var parent = stat(), item = stat()
        guard stat(url.deletingLastPathComponent().path, &parent) == 0,
              lstat(url.path, &item) == 0 else { throw StorageDeletionFailure(.changed) }
        self.url = url
        self.parent = TrashIdentity(parent)
        self.item = TrashIdentity(item)
    }
}

struct TrashedItem: Codable, Sendable {
    let origin: TrashRestoreOrigin
    let location: URL

    private func checkItem() throws {
        var info = stat()
        guard lstat(location.path, &info) == 0 else {
            throw LocalTransferFailure(errno == ENOENT ? .trashUnavailable : .io)
        }
        guard TrashIdentity(info) == origin.item else { throw LocalTransferFailure(.trashUnavailable) }
    }

    func validate() throws {
        try withOriginalParent { _ in }
    }

    private func withOriginalParent(_ body: (Int32) throws -> Void) throws {
        // macOS can grant access to the exact Trash item while denying enumeration of its parent.
        try checkItem()
        let parent = open(origin.url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw LocalTransferFailure(.invalidDestination) }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, TrashIdentity(info) == origin.parent else { throw LocalTransferFailure(.changed) }
        try body(parent)
    }

    func restore(to destination: URL) throws {
        try withOriginalParent { parent in
            guard renameatx_np(AT_FDCWD, location.path, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                throw LocalTransferFailure(errno == EEXIST || errno == ENOTEMPTY ? .conflict : .io)
            }
        }
    }
}
