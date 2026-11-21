// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

/// A separate browser keeps normal file gestures (Open, paste, drag and Delete) away from trashed items.
@MainActor
final class TrashBrowserController: DialogWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let restore = NSButton(), choose = NSButton(), erase = NSButton(), empty = NSButton()
    private var entries: [TrashEntry] = []
    private var unreadable: [URL] = []
    private var load: Task<Void, Never>?
    private var working = false
    private var failures: [String] = []
    private var watchers: [URL: DirectoryWatcher] = [:]

    init() {
        let panel = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: 430),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L10n.text("trash.title")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 660, height: 340)
        super.init(window: panel)
        panel.delegate = self
        for (key, width) in [("column.name", 250.0), ("trash.origin", 420.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            col.title = L10n.text(key); col.width = width
            table.addTableColumn(col)
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel(L10n.text("trash.title"))
        table.setAccessibilityIdentifier("explorer.trash.items")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        let refresh = NSButton(title: L10n.text("command.refresh"), target: self, action: #selector(reload))
        for (button, key, action) in [(restore, "trash.restore", #selector(putBack)), (choose, "trash.restore_to", #selector(restoreTo)),
                                      (erase, "trash.erase", #selector(deleteSelected)), (empty, "trash.empty", #selector(emptyTrash))] {
            button.title = L10n.text(key); button.target = self; button.action = action; button.bezelStyle = .rounded
            button.setAccessibilityIdentifier(key)
        }
        let commands = NSStackView(views: [restore, choose, erase])
        let footer = NSStackView(views: [refresh, NSView(), empty])
        let stack = NSStackView(views: [commands, scroll, status, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        status.maximumNumberOfLines = 3; status.setContentCompressionResistancePriority(.required, for: .vertical)
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) {
        load?.cancel()
        load = nil
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    private func watch(_ roots: [URL]) {
        let desired = Set(roots)
        for root in Set(watchers.keys).subtracting(desired) { watchers.removeValue(forKey: root)?.stop() }
        for root in desired.subtracting(watchers.keys) {
            let watcher = DirectoryWatcher()
            watchers[root] = watcher
            watcher.watch(root) { [weak self] in self?.refresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.removeObserver(self, name: name, object: nil)
            center.addObserver(self, selector: #selector(volumesChanged(_:)), name: name, object: nil)
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    @objc private func volumesChanged(_ notification: Notification) { refresh() }
    @objc private func reload() { refresh() }

    func refresh() {
        guard !working else { return }
        load?.cancel()
        status.stringValue = L10n.text("trash.loading")
        load = Task { [weak self] in
            do {
                let list = try await TrashLibrary.shared.inventory()
                guard !Task.isCancelled, let self else { return }
                let selected = Set(self.selection.map { $0.location.path })
                self.watch(list.readableRoots)
                self.entries = list.entries; self.unreadable = list.unreadable; self.table.reloadData()
                self.table.selectRowIndexes(IndexSet(self.entries.indices.filter { selected.contains(self.entries[$0].location.path) }),
                                            byExtendingSelection: false)
                let count = L10n.format("trash.count", String(list.entries.count))
                self.status.stringValue = list.unreadable.isEmpty ? count : count + " · " + L10n.text("trash.restricted")
                self.status.toolTip = list.unreadable.map(\.path).joined(separator: "\n")
                self.load = nil; self.updateButtons()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.entries = []; self.table.reloadData()
                self.status.stringValue = L10n.text("error.generic"); self.load = nil; self.updateButtons()
            }
        }
        updateButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let entry = entries[row]
        let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        field.identifier = id
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = id.rawValue == "column.name" ? entry.name :
            entry.original?.deletingLastPathComponent().path ?? L10n.text("trash.unknown")
        field.toolTip = field.stringValue
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private var selection: [TrashEntry] { table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil } }

    private func updateButtons() {
        let selected = selection
        let ready = load == nil && !working
        restore.isEnabled = ready && !selected.isEmpty && selected.allSatisfy { $0.original != nil }
        choose.isEnabled = ready && !selected.isEmpty
        erase.isEnabled = ready && !selected.isEmpty
        empty.isEnabled = ready && !entries.isEmpty && unreadable.isEmpty
    }

    @objc private func putBack() { perform(selection, restoring: true, folder: nil) }
    @objc private func restoreTo() {
        guard let window, !working else { return }
        let items = selection
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.canCreateDirectories = true; picker.allowsMultipleSelection = false
        picker.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let folder = picker.url { self?.perform(items, restoring: true, folder: folder) }
        }
    }
    @objc private func emptyTrash() { if unreadable.isEmpty { confirmErase(entries, all: true) } }
    @objc private func deleteSelected() { confirmErase(selection, all: false) }

    private func confirmErase(_ items: [TrashEntry], all: Bool) {
        guard let window, !items.isEmpty, !working else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(all ? "trash.empty" : "trash.erase")
        alert.informativeText = L10n.format("trash.permanent", String(items.count))
        alert.addButton(withTitle: L10n.text("dialog.cancel"))
        alert.addButton(withTitle: L10n.text("trash.erase"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.perform(items, restoring: false, folder: nil) }
        }
    }

    private func perform(_ items: [TrashEntry], restoring: Bool, folder: URL?) {
        guard !items.isEmpty, !working else { return }
        let commands = FileCommands.shared
        guard !commands.isBusy else { status.stringValue = L10n.text("trash.busy"); return }
        let title = restoring ? "trash.restore" : "trash.erase"
        failures.removeAll()
        commands.run(title) { @MainActor in
            var restored: [URL] = []
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }
                self.status.stringValue = L10n.format("cloud.transfer.items", String(index + 1), String(items.count)) + " · " + item.name
                do {
                    if restoring {
                        do { restored.append(try await AppAutomation.files.restoreTrashItem(item, into: folder)) }
                        catch let failure as LocalTransferFailure where failure.reason == .conflict {
                            guard let target = folder?.appendingPathComponent(item.name) ?? item.original else { throw failure }
                            let conflict = StorageConflict(source: item.location, destination: target, isDirectory: false)
                            guard await commands.resolveConflict(conflict, restoring: true) == .keepBoth else { break }
                            restored.append(try await AppAutomation.files.restoreTrashItem(item, into: folder, keepBoth: true))
                        }
                    } else { try await AppAutomation.files.eraseTrashItem(item) }
                } catch {
                    let reason: String
                    if let failure = error as? LocalTransferFailure {
                        switch failure.reason {
                        case .invalidDestination, .changed: reason = L10n.text("trash.choose_destination")
                        case .trashUnavailable: reason = L10n.text("undo.trash_unavailable")
                        case .conflict: reason = L10n.text("error.conflict")
                        case .recoveryRequired: reason = L10n.text("operation.recovery") + " " + failure.recoveryLocations.map(\.path).joined(separator: ", ")
                        default: reason = error.localizedDescription
                        }
                    } else { reason = error.localizedDescription }
                    self.failures.append(item.name + " — " + reason)
                }
            }
            return restored
        }
        guard let operation = commands.task else { return }
        working = true; updateButtons()
        Task {
            await operation.value
            self.working = false
            if self.window?.isVisible == true { self.refresh() }
            if !failures.isEmpty, let window = self.window, window.isVisible {
                let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = L10n.text("operation.partial")
                let list = NSTextView()
                list.string = failures.joined(separator: "\n")
                list.isEditable = false; list.font = .systemFont(ofSize: NSFont.systemFontSize)
                let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 460, height: 150))
                list.frame.size.width = scroll.bounds.width; list.autoresizingMask = .width
                scroll.hasVerticalScroller = true; scroll.documentView = list; alert.accessoryView = scroll
                await alert.beginSheetModal(for: window)
            }
        }
    }
}
