// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerCore

/// Whether the favorite and recent folders still exist, found out away from the main thread: a
/// folder on a network volume that stopped answering must never hold the window back. Until a
/// folder has been checked it counts as present; every question schedules a new check, and a
/// change of answer is announced so the tree and the menus can follow.
@MainActor
final class FolderPresence {
    static let shared = FolderPresence()
    static let didChange = Notification.Name("MyExplorer.FolderPresence.didChange")

    private var known: [String: Bool] = [:]
    private var pending = Set<String>()
    #if APP_STORE
    /// Folders that exist but the sandbox does not let the app read (App Store build).
    private var refused = Set<String>()
    #endif

    func exists(_ url: URL) -> Bool {
        let path = url.path
        check(path)
        return known[path] ?? true
    }

    /// Whether the folder is there but cannot be read for lack of access (App Store build); found
    /// out by the same check as `exists`, so it never touches the disk on the main thread.
    func isRefused(_ url: URL) -> Bool {
        #if APP_STORE
        let path = url.path
        check(path)
        return refused.contains(path)
        #else
        return false
        #endif
    }

    /// After folder access changed: the tree and the menus ask again, and every question checks anew.
    func recheck() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    private func check(_ path: String) {
        guard pending.insert(path).inserted else { return }
        Task.detached(priority: .utility) {
            let present = FolderShortcuts.folderExists(URL(fileURLWithPath: path, isDirectory: true))
            #if APP_STORE
            var denied = false
            if present {
                if let directory = opendir(path) { closedir(directory) } else { denied = errno == EPERM || errno == EACCES }
            }
            #endif
            await MainActor.run {
                let shared = FolderPresence.shared
                shared.pending.remove(path)
                let previous = shared.known[path] ?? true
                shared.known[path] = present
                var changed = previous != present
                #if APP_STORE
                if denied != shared.refused.contains(path) {
                    if denied { shared.refused.insert(path) } else { shared.refused.remove(path) }
                    changed = true
                }
                #endif
                if changed { NotificationCenter.default.post(name: Self.didChange, object: shared) }
            }
        }
    }
}
