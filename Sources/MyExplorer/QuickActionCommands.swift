// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import UniformTypeIdentifiers

@MainActor
enum QuickActionCommands {
    static func menu(for entries: [FileEntry], in window: NSWindow?) -> NSMenu? {
        guard let window else { return nil }
        let menu = NSMenu(title: L10n.text("quick.title"))
        for action in ImageQuickAction.allCases where action.supports(entries) {
            menu.addItem(CommandItem(title: L10n.text("quick." + action.rawValue)) { [weak window] in
                guard let window, !FileCommands.shared.isBusy else { return }
                Task { await chooseOutput(action, inputs: entries.map(\.url), in: window) }
            })
        }
        if entries.count == 1, let entry = entries.first, entry.url.isFileURL,
           !entry.isAlias, !entry.isDirectory, !entry.isSymbolicLink, !SecureFolderService.isSessionURL(entry.url),
           let type = UTType(filenameExtension: entry.url.pathExtension), type == .pdf || type.conforms(to: .image),
           let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            menu.addItem(CommandItem(title: L10n.text("quick.markup")) { [weak window] in
                NSWorkspace.shared.open([entry.url], withApplicationAt: preview, configuration: .init()) { [weak window] _, error in
                    if let error {
                        Task { @MainActor [weak window] in
                            guard let window, window.isVisible else { return }
                            NSAlert(error: error).beginSheetModal(for: window)
                        }
                    }
                }
            })
        }
        return menu.items.isEmpty ? nil : menu
    }

    #if !APP_STORE
    static func smoke(in browser: ExplorerWindowController, root: URL) throws {
        let target = FileEntry(url: root.appendingPathComponent("photo.png"), name: "photo.png", isDirectory: false)
        let fileMenu = NSMenu()
        browser.rebuildContextMenu(fileMenu, entries: [target])
        let actions = fileMenu.item(withTitle: L10n.text("quick.title"))?.submenu
        guard actions?.item(withTitle: L10n.text("quick.rotate")) != nil,
              actions?.item(withTitle: L10n.text("quick.pdf")) != nil,
              fileMenu.item(withTitle: L10n.text("icloud.remove")) == nil else {
            throw SmokeFailure.failed("Unexpected local image actions")
        }
        let online = FileEntry(url: target.url, name: target.name, isDirectory: false, iCloudAvailability: .onlineOnly)
        browser.rebuildContextMenu(fileMenu, entries: [online])
        guard fileMenu.item(withTitle: L10n.text("icloud.download")) != nil,
              fileMenu.item(withTitle: L10n.text("icloud.remove")) == nil else {
            throw SmokeFailure.failed("Unexpected online-only iCloud actions")
        }
        let table = ExplorerTableView()
        table.serviceSelection = { [target.url] }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard table.validRequestor(forSendType: .fileURL, returnType: nil) as? ExplorerTableView === table,
              table.writeSelection(to: pasteboard, types: [.fileURL]),
              (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.path == target.url.path else {
            throw SmokeFailure.failed("Services did not receive the selected file URL")
        }
        table.serviceSelection = { [] }
        guard !table.writeSelection(to: pasteboard, types: [.fileURL]) else {
            throw SmokeFailure.failed("Empty file selection advertised as a Service")
        }
    }
    #endif

    private static func chooseOutput(_ action: ImageQuickAction, inputs: [URL], in window: NSWindow) async {
        var urls = inputs
        if action == .pdf && urls.count > 1 {
            let order = PageOrderView(urls: urls)
            let alert = NSAlert()
            alert.messageText = L10n.text("quick.order")
            alert.accessoryView = order
            alert.addButton(withTitle: L10n.text("dialog.confirm"))
            alert.addButton(withTitle: L10n.text("dialog.cancel"))
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            urls = order.urls
        }
        let panel = NSSavePanel()
        panel.title = L10n.text("quick." + action.rawValue)
        panel.allowedContentTypes = [action.outputType]
        panel.directoryURL = urls[0].deletingLastPathComponent()
        let base = urls[0].deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = (action == .rotate ? base + " ↻" : base) + "." + (action.outputType.preferredFilenameExtension ?? "")
        guard await panel.beginSheetModal(for: window) == .OK, let output = panel.url else { return }
        let ordered = urls
        FileCommands.shared.run("quick." + action.rawValue) {
            try await action.export(ordered, to: output)
            return [output]
        }
    }
}

@MainActor
private final class CommandItem: NSMenuItem {
    private let performCommand: () -> Void
    init(title: String, command: @escaping () -> Void) {
        performCommand = command
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { performCommand() }
}

@MainActor
private final class PageOrderView: NSView, NSTableViewDelegate, NSTableViewDataSource {
    private(set) var urls: [URL]
    private let table = NSTableView()
    private let up = NSButton(title: L10n.text("quick.up"), target: nil, action: nil)
    private let down = NSButton(title: L10n.text("quick.down"), target: nil, action: nil)

    init(urls: [URL]) {
        self.urls = urls
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        let column = NSTableColumn(identifier: .init("page"))
        column.width = 390
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel(L10n.text("quick.order"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 420, height: 160))
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        addSubview(scroll)
        up.target = self; up.action = #selector(reorder(_:))
        down.target = self; down.action = #selector(reorder(_:))
        let buttons = NSStackView(views: [up, down])
        buttons.frame = NSRect(origin: .zero, size: buttons.fittingSize)
        addSubview(buttons)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: "\(row + 1).  " + urls[row].lastPathComponent)
        field.toolTip = urls[row].path
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        up.isEnabled = table.selectedRow > 0
        down.isEnabled = table.selectedRow >= 0 && table.selectedRow < urls.count - 1
    }
    @objc private func reorder(_ sender: NSButton) {
        let index = table.selectedRow
        let next = index + (sender === up ? -1 : 1)
        guard urls.indices.contains(index), urls.indices.contains(next) else { return }
        urls.swapAt(index, next)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }
}
