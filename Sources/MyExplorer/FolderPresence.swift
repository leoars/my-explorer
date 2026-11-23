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

    func exists(_ url: URL) -> Bool {
        let path = url.path
        check(path)
        return known[path] ?? true
    }

    private func check(_ path: String) {
        guard pending.insert(path).inserted else { return }
        Task.detached(priority: .utility) {
            let present = FolderShortcuts.folderExists(URL(fileURLWithPath: path, isDirectory: true))
            await MainActor.run {
                let shared = FolderPresence.shared
                shared.pending.remove(path)
                let previous = shared.known[path] ?? true
                shared.known[path] = present
                if previous != present { NotificationCenter.default.post(name: Self.didChange, object: shared) }
            }
        }
    }
}
