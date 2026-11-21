// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import ExplorerAutomation
import ExplorerClipboard
import UniformTypeIdentifiers

@MainActor
final class FileCommands: NSObject, NSWindowDelegate {
    static let shared = FileCommands()
    weak var owner: ExplorerWindowController?
    private(set) var task: Task<Void, Never>?
    var isBusy: Bool { task != nil }
    private(set) var shuttingDown = false
    var interruptionStore = OperationInterruptionStore()
    private var cancelDecision: (@MainActor () -> Void)?
    var hasPendingDecision: Bool { cancelDecision != nil }
    private var activeOperationID: UUID?
    var onIdle: (() -> Void)?
    private var cutPaths = Set<String>()
    private var cutChangeCount: Int?
    var pasteboard: NSPasteboard = .general
    private let clipboard = FileClipboard()
    private(set) var clipboardTask: Task<Void, Never>?
    private var pendingPaste: Task<Void, Never>?
    private var copyGeneration = 0
    private(set) var undoKind: LocalTransferKind?
    private var localControl: LocalTransferControl?
    private var pauseButton: NSButton?
    private var panel: NSPanel?
    private var operationKey = "operation.busy"
    private var label: NSTextField?
    private var cancelButton: NSButton?
    private var progressLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var conflictAlert: NSAlert?
    private var lastProgressUpdate = Date.distantPast
    var pasteURLs: [URL] {
        FileClipboard.readURLs(from: pasteboard)
    }
    func canCut(_ entries: [FileEntry]) -> Bool {
        guard !isBusy, !shuttingDown, let first = entries.first else { return false }
        if first.url.isFileURL { return entries.allSatisfy { $0.url.isFileURL } }
        guard let location = RemoteLocation.parse(first.url),
              CloudAccounts.shared.connections.contains(where: { $0.id == location.connectionID && $0.provider == .s3 }) else { return false }
        return entries.allSatisfy { entry in
            guard !entry.isDirectory, let source = RemoteLocation.parse(entry.url) else { return false }
            return source.connectionID == location.connectionID && !source.key.isEmpty && !source.key.hasSuffix("/")
        }
    }
    private func isCut(_ urls: [URL]) -> Bool {
        cutChangeCount == pasteboard.changeCount && Set(urls.map(\.explorerIdentity)) == cutPaths
    }
    func canPaste(into directory: URL) -> Bool {
        guard !shuttingDown, clipboardTask == nil else { return false }
        let urls = pasteURLs
        guard !urls.isEmpty else { return false }
        return canTransfer(urls, to: directory, move: isCut(urls))
    }
    func canTransfer(_ urls: [URL], to directory: URL, move: Bool) -> Bool {
        guard !shuttingDown, !isBusy, !urls.isEmpty else { return false }
        if move {
            if directory.isFileURL { return urls.allSatisfy(\.isFileURL) }
            guard let target = RemoteLocation.parse(directory),
                  CloudAccounts.shared.connections.contains(where: { $0.id == target.connectionID && $0.provider == .s3 }) else { return false }
            return SharedFileOperations.canMoveS3Files(urls, to: directory)
        }
        return directory.isFileURL ? (urls.allSatisfy(\.isFileURL) || urls.allSatisfy { RemoteLocation.parse($0) != nil }) :
            RemoteLocation.parse(directory) != nil && urls.allSatisfy(\.isFileURL)
    }
    @discardableResult
    func copy(_ entries: [FileEntry], cut: Bool) -> Task<Void, Never>? {
        guard !shuttingDown, !entries.isEmpty, !cut || canCut(entries) else { return nil }
        clipboardTask?.cancel()
        pendingPaste?.cancel(); pendingPaste = nil
        copyGeneration += 1
        let generation = copyGeneration
        let pending = Task {
            let written = await clipboard.write(urls: entries.map(\.url), to: pasteboard)
            guard !shuttingDown, generation == copyGeneration else { return }
            if written, pasteboard.changeCount == clipboard.lastWriteChangeCount,
               FileClipboard.readURLs(from: pasteboard) == entries.map(\.url) {
                cutPaths = cut ? Set(entries.map(\.id)) : []
                cutChangeCount = cut ? pasteboard.changeCount : nil
            }
            clipboardTask = nil
            if !written, clipboard.lastFailure == .rejectedFiles { presentError(key: "clipboard.rejected") }
        }
        clipboardTask = pending
        return pending
    }
    func paste(into directory: URL, move: Bool = false) {
        guard !shuttingDown else { return }
        if let preparing = clipboardTask {
            let generation = copyGeneration
            pendingPaste?.cancel()
            pendingPaste = Task {
                await preparing.value
                guard !shuttingDown, !Task.isCancelled, generation == copyGeneration,
                      pasteboard.changeCount == clipboard.lastWriteChangeCount else { return }
                pendingPaste = nil
                paste(into: directory, move: move)
            }
            return
        }
        guard !isBusy, canPaste(into: directory) else { return }
        let urls = pasteURLs
        guard !urls.isEmpty else { return }
        let moving = move || isCut(urls)
        transfer(urls, to: directory, move: moving, consumesClipboard: true)
    }
    func transfer(_ urls: [URL], to directory: URL, move: Bool, consumesClipboard: Bool = false) {
        guard canTransfer(urls, to: directory, move: move) else { return }
        let clipboardCount = pasteboard.changeCount
        if directory.isFileURL && urls.allSatisfy(\.isFileURL) {
            let control = LocalTransferControl()
            localControl = control
            run(move ? "operation.move" : "command.paste_files") {
                do {
                    let result = try await AppAutomation.files.transferLocal(urls, to: directory, move: move,
                        resolveConflict: { conflict in await self.resolveConflict(conflict) },
                        progress: { progress in Task { @MainActor in self.updateProgress(progress) } }, control: control)
                    if consumesClipboard { await self.finishMovedClipboard(urls, move: move, changeCount: clipboardCount) }
                    return result
                } catch {
                    if consumesClipboard { await self.finishMovedClipboard(urls, move: move, changeCount: clipboardCount) }
                    throw error
                }
            }
        } else if move {
            let affectedDirectories = Set((urls.map(\.explorerParent) + [directory]).map(\.explorerIdentity))
            run("operation.move", refreshing: affectedDirectories) {
                do {
                    let moved = try await AppAutomation.files.moveS3Files(urls, to: directory)
                    if consumesClipboard { await self.finishMovedClipboard(urls, move: true, changeCount: clipboardCount, remaining: []) }
                    return moved
                } catch let partial as S3MoveBatchFailure {
                    if consumesClipboard {
                        let remaining = Array(urls.dropFirst(partial.completed.count))
                        await self.finishMovedClipboard(urls, move: true, changeCount: clipboardCount, remaining: remaining)
                    }
                    throw partial
                }
            }
        } else {
            run("cloud.transfer.title") {
                return try await AppAutomation.files.copy(urls, to: directory, resolveConflict: { conflict in
                    await self.resolveConflict(conflict)
                }, progress: { progress in
                    Task { @MainActor in self.updateProgress(progress) }
                })
            }
        }
    }
    private func finishMovedClipboard(_ sources: [URL], move: Bool, changeCount: Int, remaining unconfirmedSources: [URL]? = nil) async {
        guard !shuttingDown, move, clipboardTask == nil, pasteboard.changeCount == changeCount,
              Set(pasteURLs.map(\.explorerIdentity)) == Set(sources.map(\.explorerIdentity)) else { return }
        let wasCut = cutChangeCount == changeCount
        let remaining = unconfirmedSources ?? sources.filter { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil }
        if remaining.isEmpty {
            cutPaths = []; cutChangeCount = nil
            pasteboard.clearContents()
        }
        else if remaining.count != sources.count {
            let generation = copyGeneration
            if await clipboard.write(urls: remaining, to: pasteboard), !shuttingDown, generation == copyGeneration, clipboardTask == nil,
               pasteboard.changeCount == clipboard.lastWriteChangeCount,
               FileClipboard.readURLs(from: pasteboard) == remaining {
                cutPaths = wasCut ? Set(remaining.map(\.explorerIdentity)) : []
                cutChangeCount = wasCut ? pasteboard.changeCount : nil
            }
        }
    }
    var undoTitle: String {
        switch undoKind {
        case .copy: L10n.text("command.undo_copy")
        case .move: L10n.text("command.undo_move")
        case .trash: L10n.text("command.undo_trash")
        case nil: L10n.text("command.undo_files")
        }
    }
    func undo() {
        guard !shuttingDown, !isBusy, undoKind != nil else { return }
        let control = LocalTransferControl(); localControl = control
        run("command.undo_files", refreshingResultParents: true) {
            try await AppAutomation.files.undoLocal(resolveTrashConflict: { await self.resolveConflict($0, restoring: true) }, progress: { progress in
                Task { @MainActor in self.updateProgress(progress) }
            }, control: control)
        }
    }
    func resumeAfterCancelledQuit() { shuttingDown = false }

    func prepareToQuit() {
        guard !shuttingDown else { return }
        shuttingDown = true
        copyGeneration += 1
        pendingPaste?.cancel(); pendingPaste = nil
        clipboardTask?.cancel(); clipboardTask = nil; clipboard.cancelPendingWrite()
        localControl?.cancel(); task?.cancel()
        dismissDecision()
        if let window = owner?.window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        panel?.close(); panel = nil
    }
    func openRemote(_ entry: FileEntry) {
        guard !shuttingDown, let location = RemoteLocation.parse(entry.url), !entry.isDirectory,
              !entry.name.isEmpty, entry.name != ".", entry.name != "..", !entry.name.contains("/"), !entry.name.utf8.contains(0) else { return }
        run("cloud.open_copy") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer-Open-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let destination = directory.appendingPathComponent(entry.name)
            do {
                let client = try await CloudAccounts.shared.client(id: location.connectionID)
                _ = try await client.download(key: location.key, to: destination, progress: { progress in
                    Task { @MainActor in self.updateBytes(progress, name: entry.name) }
                })
                try Task.checkCancellation()
                await MainActor.run { if !self.shuttingDown { _ = NSWorkspace.shared.open(destination) } }
                return []
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }
    func rename(_ entry: FileEntry) {
        guard !shuttingDown, entry.url.isFileURL, !isBusy else { return }
        askName(title: "command.rename", initial: entry.name) { name in
            self.rename(entry, to: name)
        }
    }
    func rename(_ entry: FileEntry, to name: String) {
        run("command.rename") { [try await AppAutomation.files.rename(entry.url, to: name)] }
    }
    func canCreateFolder(in directory: URL) -> Bool {
        guard !shuttingDown, !isBusy else { return false }
        if directory.isFileURL { return true }
        guard let location = RemoteLocation.parse(directory) else { return false }
        return CloudAccounts.shared.connections.contains { $0.id == location.connectionID && $0.provider == .s3 }
    }

    func newFolder(in directory: URL) {
        guard canCreateFolder(in: directory) else { return }
        askName(title: "command.new_folder", initial: L10n.text("folder.default")) { name in
            self.run("command.new_folder") { [try await AppAutomation.files.newFolder(in: directory, name: name)] }
        }
    }
    func trash(_ entries: [FileEntry]) {
        guard !shuttingDown, !entries.isEmpty else { return }
        run("command.delete") {
            let plan = try await AppAutomation.deletion.plan(sources: entries.map(\.url), recursive: true)
            guard await self.confirmDeletion(count: plan.itemCount) else { await AppAutomation.deletion.discard(planID: plan.id); throw CancellationError() }
            _ = try await AppAutomation.files.executeDeletion(planID: plan.id, using: AppAutomation.deletion, recordUndo: true, authorizationCheck: { _ in !Task.isCancelled })
            return []
        }
    }
    func compress(_ entries: [FileEntry], in directory: URL) {
        guard !shuttingDown, !entries.isEmpty, directory.isFileURL, entries.allSatisfy({ $0.url.isFileURL }) else { return }
        let base = entries.count == 1 ? entries[0].name : L10n.text("archive.default")
        let destination = availableURL(name: base, ext: "zip", in: directory)
        run("command.compress") { [try await AppAutomation.files.compress(entries.map(\.url), to: destination)] }
    }
    func extract(_ entry: FileEntry, in directory: URL) {
        guard !shuttingDown, entry.url.isFileURL, directory.isFileURL else { return }
        let destination = availableURL(name: entry.url.deletingPathExtension().lastPathComponent, ext: nil, in: directory)
        run("command.extract") { [try await AppAutomation.files.extract(entry.url, to: destination)] }
    }
    private func availableURL(name: String, ext: String?, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name + (ext.map { ".\($0)" } ?? ""))
        var suffix = 2
        while (try? FileManager.default.attributesOfItem(atPath: candidate.path)) != nil {
            candidate = directory.appendingPathComponent("\(name) (\(suffix))" + (ext.map { ".\($0)" } ?? ""))
            suffix += 1
        }
        return candidate
    }
    private func askName(title: String, initial: String, accepted: @escaping @MainActor (String) -> Void) {
        guard !shuttingDown, let window = owner?.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text(title)
        alert.addButton(withTitle: L10n.text("dialog.confirm"))
        alert.addButton(withTitle: L10n.text("dialog.cancel"))
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        field.setAccessibilityLabel(L10n.text("dialog.name"))
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in
            if !self.shuttingDown, response == .alertFirstButtonReturn { accepted(field.stringValue) }
        }
        alert.window.makeFirstResponder(field)
        field.selectText(nil)
    }
    func properties(_ entry: FileEntry) {
        guard !shuttingDown, let window = owner?.window else { return }
        let alert = NSAlert()
        alert.window.representedURL = entry.url
        alert.messageText = entry.name
        alert.icon = entry.url.isFileURL ? NSWorkspace.shared.icon(forFile: entry.url.path) : NSWorkspace.shared.icon(for: UTType(filenameExtension: entry.url.pathExtension) ?? .data)
        let size = entry.isDirectory ? "—" : entry.size.map { L10n.current.bytes($0) } ?? "—"
        let details = [
            (L10n.text("column.kind"), L10n.current.fileKind(entry)),
            (L10n.text("column.size"), size),
            (L10n.text("column.modified"), entry.modified.map(L10n.current.date) ?? "—"),
            (L10n.text("properties.path"), CloudAccounts.shared.address(for: entry.url))
        ]
        let text = NSTextView()
        text.isEditable = false
        text.drawsBackground = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.string = details.map { $0.0 + "\n" + $0.1 }.joined(separator: "\n\n")
        text.setAccessibilityLabel(L10n.text("command.properties"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 210))
        scroll.hasVerticalScroller = true
        text.frame.size.width = scroll.contentSize.width
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.text("dialog.confirm"))
        let editableItem = entry.url.isFileURL && entry.secureFolderURL == nil && !entry.isSymbolicLink && !SecureFolderService.isSessionURL(entry.url)
        if editableItem {
            alert.addButton(withTitle: L10n.text("permissions.title"))
            alert.addButton(withTitle: L10n.text("search.tags_edit"))
            Task { [weak text] in
                let tags = try? await Task.detached(priority: .utility) { try FinderTags.read(entry.url) }.value
                guard let tags, !tags.isEmpty, let text else { return }
                text.string += "\n\n" + L10n.text("search.tags") + "\n" + tags.joined(separator: ", ")
            }
        }
        alert.beginSheetModal(for: window) { response in
            guard editableItem else { return }
            if response == .alertSecondButtonReturn { PermissionsDialog.present(for: entry, in: window) }
            if response == .alertThirdButtonReturn { SearchTagEditor.present(urls: [entry.url], owner: window) }
        }
    }
    func openWith(_ entries: [FileEntry]) {
        guard !shuttingDown, let window = owner?.window, !entries.isEmpty, entries.allSatisfy({ $0.url.isFileURL }) else { return }
        let picker = NSOpenPanel()
        picker.title = L10n.text("command.open_with")
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.canChooseDirectories = false
        picker.beginSheetModal(for: window) { response in
            guard !self.shuttingDown, response == .OK, let application = picker.url else { return }
            NSWorkspace.shared.open(entries.map(\.url), withApplicationAt: application,
                configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if error != nil { Task { @MainActor in self.presentError(key: "error.operation") } }
                }
        }
    }
    func run(_ title: String, refreshing directories: Set<String> = [], refreshingResultParents: Bool = false,
             operation: @escaping @Sendable () async throws -> [URL]) {
        guard !shuttingDown, !isBusy else { return }
        let tabID = owner?.workspace.activeID
        activeOperationID = UUID()
        showProgress(title)
        func refresh(_ urls: [URL]) {
            guard !shuttingDown else { return }
            let hasRemoteResults = refreshingResultParents && urls.contains { !$0.isFileURL }
            let resultParents = hasRemoteResults ? urls.map { $0.explorerParent.explorerIdentity } : []
            owner?.operationFinished(urls: urls, tabID: tabID, refreshing: directories.union(resultParents))
        }
        task = Task {
            do {
                refresh(try await operation())
            } catch {
                let restored = refreshingResultParents ? (error as? LocalTransferFailure)?.completed : nil
                refresh(restored ?? (error as? S3MoveBatchFailure)?.completed ?? [])
                self.panel?.close()
                if self.shuttingDown { self.recordInterruption(error, operation: title) }
                else if let failure = error as? LocalTransferFailure {
                    if !failure.recoveryLocations.isEmpty {
                        self.presentError(key: "operation.recovery", details: failure.recoveryLocations.map(\.path).joined(separator: "\n"))
                    } else if !failure.completed.isEmpty { self.presentError(key: "operation.partial") }
                    else {
                        switch failure.reason {
                        case .changed: self.presentError(key: "undo.changed")
                        case .trashUnavailable: self.presentError(key: "undo.trash_unavailable")
                        case .copyVerificationFailed: self.presentError(key: "operation.copy_verification_failed")
                        case .conflict: self.presentError(key: "error.conflict")
                        case .recursive: self.presentError(key: "error.recursive")
                        case .cancelled: break
                        default: self.presentError(key: "error.operation")
                        }
                    }
                } else if let failure = error as? ArchiveFailure {
                    if failure.reason != .cancelled { self.presentError(key: "archive.error.\(failure.reason.rawValue)") }
                } else if let failure = error as? FileMutationFailure {
                    if failure.completed > 0 { self.presentError(key: "operation.partial") }
                    else {
                        switch failure.reason {
                        case .conflict: self.presentError(key: "error.conflict")
                        case .invalidName: self.presentError(key: "error.invalid_name")
                        case .recursive: self.presentError(key: "error.recursive")
                        case .io: self.presentError(key: "error.operation")
                        case .cancelled: break
                        }
                    }
                } else if let failure = error as? StorageDeletionFailure {
                    if !failure.completed.isEmpty || !failure.indeterminate.isEmpty { self.presentError(key: "deletion.partial") }
                    else if failure.reason == .changed { self.presentError(key: "deletion.changed") }
                    else if failure.reason == .limitExceeded { self.presentError(key: "storage.error.limitExceeded") }
                    else if failure.reason != .cancelled, let reason = failure.cloudReason { self.presentError(key: "cloud.error.\(reason.rawValue)") }
                    else if failure.reason != .cancelled { self.presentError(key: "error.operation") }
                } else if let failure = error as? SharedFileFailure {
                    if !failure.completed.isEmpty { self.presentError(key: "operation.partial") }
                    else if failure.reason != .cancelled { self.presentError(key: failure.reason == .conflict ? "error.conflict" : "error.operation") }
                } else if let batch = error as? S3MoveBatchFailure {
                    self.presentError(key: "operation.partial", details: self.s3MoveDetails(for: batch.cause))
                } else if let failure = error as? S3MoveFailure {
                    self.presentError(key: self.s3MoveMessage(failure), details: failure.sourceKey + " → " + failure.destinationKey)
                } else if let failure = error as? StorageTransferFailure {
                    if failure.reason == .cancelled { self.presentError(key: "cloud.cancel_notice") }
                    else if failure.completedCount > 0 { self.presentError(key: "operation.partial") }
                    else if let reason = failure.cloudReason { self.presentError(key: "cloud.error.\(reason.rawValue)") }
                    else { self.presentError(key: failure.reason == .limitExceeded ? "storage.error.limitExceeded" : failure.reason == .conflictChanged ? "error.conflict" : "error.operation") }
                } else if let failure = error as? CloudFailure {
                    if failure.reason != .cancelled { self.presentError(key: "cloud.error.\(failure.reason.rawValue)") }
                } else if !(error is CancellationError) { self.presentError(key: "error.operation") }
            }
            self.panel?.close(); self.panel = nil
            if self.shuttingDown { self.undoKind = nil }
            else { self.undoKind = await AppAutomation.files.localUndoKind() }
            self.localControl = nil; self.pauseButton = nil
            self.task = nil; self.activeOperationID = nil
            let idle = self.onIdle; self.onIdle = nil; idle?()
        }
    }
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        DialogPlacement.sheetAnchor(sheet, in: window)
    }

    private func showProgress(_ title: String) {
        operationKey = title
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: L10n.text(title))
        label.font = ExplorerStyle.font(.menus)
        label.frame = NSRect(x: 24, y: 150, width: 490, height: 30)
        let detail = NSTextField(labelWithString: "")
        detail.frame = NSRect(x: 24, y: 115, width: 490, height: 28)
        detail.lineBreakMode = .byTruncatingMiddle
        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 88, width: 490, height: 16))
        spinner.style = .bar; spinner.isIndeterminate = true; spinner.startAnimation(nil)
        let cancel = NSButton(title: L10n.text("dialog.cancel"), target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 390, y: 30, width: 126, height: 34); cancel.bezelStyle = .rounded
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(detail); panel.contentView?.addSubview(spinner); panel.contentView?.addSubview(cancel)
        if localControl != nil {
            let pause = NSButton(title: L10n.text("operation.pause"), target: self, action: #selector(togglePause))
            pause.frame = NSRect(x: 250, y: 30, width: 126, height: 34); pause.bezelStyle = .rounded
            panel.contentView?.addSubview(pause); pauseButton = pause
        }
        panel.title = L10n.text("operation.title")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        DialogPlacement.center(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel; self.label = label; self.cancelButton = cancel
        self.progressLabel = detail; self.progressBar = spinner; lastProgressUpdate = .distantPast
    }
    private func updateBytes(_ progress: CloudTransferProgress, name: String) {
        guard !shuttingDown, isBusy, operationKey != "operation.cancelling", Date().timeIntervalSince(lastProgressUpdate) >= 0.05 || progress.completedBytes == progress.totalBytes else { return }
        lastProgressUpdate = Date()
        progressLabel?.stringValue = L10n.format("cloud.transfer.item", name, L10n.current.bytes(progress.completedBytes))
        if let total = progress.totalBytes, total > 0 {
            progressBar?.stopAnimation(nil); progressBar?.isIndeterminate = false
            progressBar?.minValue = 0; progressBar?.maxValue = Double(total); progressBar?.doubleValue = Double(progress.completedBytes)
        }
    }
    private func updateProgress(_ progress: StorageTransferProgress) {
        updateBytes(CloudTransferProgress(completedBytes: progress.bytesCompleted, totalBytes: progress.totalBytes), name: progress.currentSource?.lastPathComponent ?? "")
        guard !shuttingDown, operationKey != "operation.cancelling" else { return }
        label?.stringValue = L10n.text(operationKey) + " · " + L10n.format("cloud.transfer.items", String(progress.completedItems), String(progress.totalItems))
    }
    private func confirmDeletion(count: Int) async -> Bool {
        guard !shuttingDown, !Task.isCancelled, let panel else { return false }
        guard ExplorerStyle.browserPreferences.confirmDeletion else { return true }
        let operationID = activeOperationID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !shuttingDown, !Task.isCancelled else { continuation.resume(returning: false); return }
                let decision = FileCommandDecision(continuation)
                let alert = NSAlert(); alert.alertStyle = .warning
                alert.messageText = L10n.text("deletion.confirm")
                alert.informativeText = L10n.text("deletion.warning") + "\n" + L10n.format("deletion.count", String(count))
                alert.addButton(withTitle: L10n.text("dialog.cancel"))
                alert.addButton(withTitle: L10n.text("command.delete"))
                conflictAlert = alert
                cancelDecision = { decision.resolve(false) }
                alert.beginSheetModal(for: panel) { response in
                    if self.conflictAlert === alert { self.conflictAlert = nil; self.cancelDecision = nil }
                    decision.resolve(!self.shuttingDown && response == .alertSecondButtonReturn)
                }
            }
        } onCancel: { Task { @MainActor in
            if let operationID, self.activeOperationID == operationID { self.dismissDecision() }
        } }
    }
    func resolveConflict(_ conflict: StorageConflict, restoring: Bool = false) async -> StorageConflictChoice {
        guard !shuttingDown, !Task.isCancelled, let panel else { return .cancel }
        let operationID = activeOperationID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !shuttingDown, !Task.isCancelled else { continuation.resume(returning: .cancel); return }
                let decision = FileCommandDecision(continuation)
                let alert = NSAlert()
                alert.messageText = L10n.text("cloud.conflict.title")
                alert.informativeText = L10n.format("cloud.conflict.message", CloudAccounts.shared.address(for: conflict.destination))
                let keys = restoring ? ["cancel", "keep_both"] : [conflict.isDirectory ? "merge" : "replace", "keep_both", "skip", "cancel"]
                for key in keys { alert.addButton(withTitle: L10n.text("cloud.conflict.\(key)")) }
                conflictAlert = alert
                cancelDecision = { decision.resolve(.cancel) }
                alert.beginSheetModal(for: panel) { response in
                    if self.conflictAlert === alert { self.conflictAlert = nil; self.cancelDecision = nil }
                    let choices: [StorageConflictChoice] = restoring ? [.cancel, .keepBoth] : [.replace, .keepBoth, .skip, .cancel]
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    decision.resolve(!self.shuttingDown && choices.indices.contains(index) ? choices[index] : .cancel)
                }
            }
        } onCancel: { Task { @MainActor in
            if let operationID, self.activeOperationID == operationID { self.dismissDecision() }
        } }
    }
    private func dismissDecision() {
        let cancel = cancelDecision; cancelDecision = nil
        let alert = conflictAlert; conflictAlert = nil
        // Resume independently of AppKit's delayed sheet completion, and only once.
        cancel?()
        if let alert {
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
            alert.window.orderOut(nil)
        }
    }
    private func s3MoveMessage(_ failure: S3MoveFailure) -> String {
        switch failure.reason {
        case .copyUnconfirmed: "s3.move.copy_unconfirmed"
        case .sourceRetained: "s3.move.source_retained"
        case .deleteUnconfirmed: "s3.move.delete_unconfirmed"
        }
    }
    private func s3MoveDetails(for error: any Error) -> String? {
        if let failure = error as? S3MoveFailure {
            return L10n.text(s3MoveMessage(failure)) + "\n" + failure.sourceKey + " → " + failure.destinationKey
        }
        if let failure = error as? CloudFailure { return L10n.text("cloud.error.\(failure.reason.rawValue)") }
        return nil
    }

    private func recordInterruption(_ error: any Error, operation: String) {
        if let failure = error as? LocalTransferFailure {
            if failure.reason == .recoveryRequired || !failure.recoveryLocations.isEmpty {
                interruptionStore.append(code: .recoveryRequired, recoveryLocations: failure.recoveryLocations)
            } else if !failure.completed.isEmpty { interruptionStore.append(code: .partialOperation) }
        } else if let failure = error as? FileMutationFailure, failure.completed > 0 {
            interruptionStore.append(code: .partialOperation)
        } else if let failure = error as? StorageDeletionFailure,
                  !failure.completed.isEmpty || !failure.indeterminate.isEmpty {
            interruptionStore.append(code: .deletionPartial)
        } else if let failure = error as? SharedFileFailure, !failure.completed.isEmpty {
            interruptionStore.append(code: .partialOperation)
        } else if error is S3MoveFailure || error is S3MoveBatchFailure {
            interruptionStore.append(code: .partialOperation)
        } else if let failure = error as? StorageTransferFailure {
            if failure.completedCount > 0 { interruptionStore.append(code: .partialOperation) }
            if failure.reason == .cancelled { interruptionStore.append(code: .cloudCancellationUncertain) }
        } else if let failure = error as? CloudFailure, failure.reason == .cancelled, operation != "cloud.open_copy" {
            interruptionStore.append(code: .cloudCancellationUncertain)
        } else if error is CancellationError, operation == "cloud.transfer.title" {
            interruptionStore.append(code: .cloudCancellationUncertain)
        }
    }
    func relocalize() {
        panel?.title = L10n.text("operation.title")
        label?.stringValue = L10n.text(operationKey)
        label?.font = ExplorerStyle.font(.menus)
        cancelButton?.title = L10n.text("dialog.cancel")
        pauseButton?.title = L10n.text(localControl?.isPaused == true ? "operation.resume" : "operation.pause")
    }
    @objc func togglePause(_ sender: Any?) {
        guard !shuttingDown, let control = localControl, isBusy else { return }
        if control.isPaused { control.resume() } else { control.pause() }
        pauseButton?.title = L10n.text(control.isPaused ? "operation.resume" : "operation.pause")
    }
    @objc func cancel(_ sender: Any?) {
        localControl?.cancel()
        task?.cancel()
        dismissDecision()
        operationKey = "operation.cancelling"
        label?.stringValue = L10n.text(operationKey)
        cancelButton?.isEnabled = false
        pauseButton?.isEnabled = false
    }
    private func presentError(key: String, details: String? = nil) {
        guard !shuttingDown, onIdle == nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("operation.title")
        alert.informativeText = L10n.text(key) + (details.map { "\n\n" + $0 } ?? "")
        if let window = owner?.window, window.isVisible { alert.beginSheetModal(for: window) }
        else if onIdle == nil { _ = DialogPlacement.runModal(alert.window) { alert.runModal() } }
    }
}

/// AppKit may deliver a completion after quit already cancelled the same sheet.
@MainActor
private final class FileCommandDecision<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func resolve(_ value: Value) {
        let pending = continuation; continuation = nil
        pending?.resume(returning: value)
    }
}
