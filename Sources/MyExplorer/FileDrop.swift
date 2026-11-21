// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import ExplorerClipboard

@MainActor
enum FileDrop {
    static func isInternal(_ info: any NSDraggingInfo) -> Bool {
        let source = info.draggingSource as? NSView
        guard let owner = FileCommands.shared.owner else { return false }
        return source === owner.table || source === owner.tree.outline
    }
    static func readURLs(from info: any NSDraggingInfo) -> [URL] {
        FileClipboard.readURLs(from: info.draggingPasteboard, allowPrivateLocalReferences: isInternal(info))
    }
    static func allowedOperations(for info: any NSDraggingInfo) -> NSDragOperation {
        // External sources may delete originals immediately after a .move drop returns.
        if isInternal(info) { return info.draggingSourceOperationMask }
        return info.draggingSourceOperationMask.intersection(.copy)
    }
    static func operation(for urls: [URL], to destination: URL, allowed: NSDragOperation,
                          modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> NSDragOperation {
        guard !urls.isEmpty, !FileCommands.shared.isBusy else { return [] }
        let local = destination.isFileURL && urls.allSatisfy(\.isFileURL)
        if local {
            let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
            for source in urls {
                let path = source.resolvingSymlinksInPath().standardizedFileURL.path
                if target == path || target.hasPrefix(path + "/") { return [] }
            }
        }
        let wantsCopy = modifiers.contains(.option) || modifiers.contains(.control)
        let destinationVolume = local ? volume(of: destination) : nil
        let sameVolume = local && destinationVolume != nil && Set(urls.map { $0.deletingLastPathComponent() }).allSatisfy {
            volume(of: $0) == destinationVolume
        }
        let prefersMove = local ? modifiers.contains(.command) || sameVolume : !destination.isFileURL
        let move = prefersMove && !wantsCopy && allowed.contains(.move)
        if move && FileCommands.shared.canTransfer(urls, to: destination, move: true) { return .move }
        if allowed.contains(.copy) && FileCommands.shared.canTransfer(urls, to: destination, move: false) { return .copy }
        return []
    }

    private static func volume(of url: URL) -> NSNumber? {
        (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemNumber]) as? NSNumber
    }
}
