// SPDX-License-Identifier: Apache-2.0
// Folder access in the App Sandbox (docs/APP-STORE.md, stage 2). Only the App Store build has a
// sandbox; the direct build compiles none of this and reads every folder as before.
#if APP_STORE
import AppKit
import ExplorerCore

/// The folders the person granted, kept as app-scoped security-scoped bookmarks. At launch every
/// bookmark is resolved and its access started for the life of the process; a stale bookmark is
/// made again. Grants come from an open panel the person answers; revoking stops the access.
@MainActor
final class SandboxAccess {
    static let shared = SandboxAccess()

    enum Request { case disk, folders, folder(URL) }

    let store: FolderGrantStore
    /// Called after a grant or a revocation, to read again the folders that had no access.
    var onChange: (() -> Void)?
    /// Grants whose bookmark resolved, by their path, with the URL whose access was started.
    private var active: [String: URL] = [:]
    private(set) var unavailable: Set<String> = []

    init(store: FolderGrantStore = FolderGrantStore()) {
        self.store = store
    }

    /// Resolves the stored bookmarks and starts their access. Called once, before the first
    /// listing, so the restored tabs, the startup folder and the tree can read them.
    func activate() {
        stopAll()
        var started: [String: URL] = [:]
        let results = store.resolveAll { url in
            let ok = url.startAccessingSecurityScopedResource()
            if ok { started[FolderGrantStore.normalized(url.path)] = url }
            return ok
        }
        unavailable = []
        for result in results {
            if let url = result.url, let start = started[FolderGrantStore.normalized(url.path)] {
                active[result.grant.path] = start
            } else {
                unavailable.insert(result.grant.path)
            }
        }
    }

    var grants: [FolderGrant] { store.grants }
    var grantsWholeDisk: Bool { store.grants.contains { $0.path == "/" } }

    /// Whether the folder is inside a granted folder. When it is and the listing still fails, the
    /// system refused it for another reason (privacy controls in System Settings).
    func covers(_ url: URL) -> Bool { url.isFileURL && store.covers(url) }

    /// Shows the open panel and keeps what the person chose. Returns the granted folders (none
    /// when the panel is cancelled).
    @discardableResult
    func request(_ request: Request, in window: NSWindow?) async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        panel.prompt = L10n.text("access.panel.prompt")
        switch request {
        case .disk:
            panel.directoryURL = URL(fileURLWithPath: "/", isDirectory: true)
            panel.message = L10n.text("access.panel.disk")
        case .folders:
            panel.allowsMultipleSelection = true
            panel.directoryURL = RealHome.url
            panel.message = L10n.text("access.panel.folders")
        case .folder(let url):
            panel.directoryURL = url
            panel.message = L10n.text("access.panel.folder")
        }
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        guard response == .OK else { return [] }
        var granted: [URL] = []
        for url in panel.urls {
            do {
                try store.add(url)
                granted.append(url)
            } catch {
                NSLog("My Explorer could not keep access to %@: %@", url.path, error.localizedDescription)
            }
        }
        guard !granted.isEmpty else { return [] }
        store.answeredFirstLaunch = true
        // The panel's own access lasts until the app quits; the bookmark's is what the next launch
        // has. Start it now, so revoking later stops the same access.
        activate()
        onChange?()
        return granted
    }

    func revoke(path: String) {
        let path = FolderGrantStore.normalized(path)
        if let url = active.removeValue(forKey: path) { url.stopAccessingSecurityScopedResource() }
        store.remove(path: path)
        unavailable.remove(path)
        onChange?()
    }

    /// `--reset-folder-access`: forget every grant and the first-launch answer (store build tests).
    func reset() {
        stopAll()
        store.removeAll()
        store.answeredFirstLaunch = false
        unavailable = []
    }

    private func stopAll() {
        for url in active.values { url.stopAccessingSecurityScopedResource() }
        active = [:]
    }

    // MARK: First launch

    /// The first-launch question: the whole disk, some folders, or nothing for now. It comes back
    /// until answered; afterwards Options › Folder access… does the same.
    func askOnFirstLaunch(in window: NSWindow) {
        guard !store.answeredFirstLaunch, store.grants.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("access.first.title")
        alert.informativeText = L10n.text("access.first.message")
        alert.addButton(withTitle: L10n.text("access.allow_disk"))
        alert.addButton(withTitle: L10n.text("access.choose_folders"))
        alert.addButton(withTitle: L10n.text("access.not_now"))
        alert.buttons[0].setAccessibilityIdentifier("access.first.disk")
        alert.buttons[1].setAccessibilityIdentifier("access.first.folders")
        alert.buttons[2].setAccessibilityIdentifier("access.first.later")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn, .alertSecondButtonReturn:
                let request: Request = response == .alertFirstButtonReturn ? .disk : .folders
                Task { @MainActor in
                    // Give the alert's sheet time to leave before the panel takes its place.
                    try? await Task.sleep(for: .milliseconds(250))
                    let granted = await self.request(request, in: window)
                    // A cancelled panel asks again: the person has not answered yet.
                    if granted.isEmpty { self.askOnFirstLaunch(in: window) }
                }
            default:
                self.store.answeredFirstLaunch = true
            }
        }
    }
}

/// Options › Folder access…: the granted folders, to add and remove.
@MainActor
final class FolderAccessWindowController: DialogWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let remove = NSButton()
    private let empty = NSTextField(labelWithString: L10n.text("access.window.empty"))
    private var rows: [FolderGrant] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("access.window.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 340)
        super.init(window: window)
        let help = NSTextField(wrappingLabelWithString: L10n.text("access.window.help"))
        help.textColor = .secondaryLabelColor
        let folder = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        folder.title = L10n.text("access.column.folder")
        folder.width = 420
        let state = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        state.title = L10n.text("access.column.status")
        state.width = 130
        table.addTableColumn(folder)
        table.addTableColumn(state)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.setAccessibilityIdentifier("access.grants")
        table.setAccessibilityLabel(L10n.text("access.window.title"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        let disk = NSButton(title: L10n.text("access.allow_disk"), target: self, action: #selector(allowDisk))
        disk.setAccessibilityIdentifier("access.disk")
        let add = NSButton(title: L10n.text("access.add"), target: self, action: #selector(addFolders))
        add.setAccessibilityIdentifier("access.add")
        remove.title = L10n.text("access.remove")
        remove.bezelStyle = .rounded
        remove.target = self
        remove.action = #selector(removeSelected)
        remove.setAccessibilityIdentifier("access.remove")
        let close = NSButton(title: L10n.text("access.done"), target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [disk, add, remove, spacer, close])
        buttons.spacing = 8
        for view in [help, scroll, empty, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(view)
        }
        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([
            help.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            help.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            buttons.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        rows = SandboxAccess.shared.grants
        table.reloadData()
        empty.isHidden = !rows.isEmpty
        remove.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let grant = rows[row]
        let text: String
        if tableColumn?.identifier.rawValue == "state" {
            text = L10n.text(SandboxAccess.shared.unavailable.contains(grant.path) ? "access.status.missing" : "access.status.ok")
        } else {
            text = grant.path == "/" ? L10n.text("access.whole_disk") : grant.path
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = grant.path
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        remove.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    @objc private func allowDisk() { Task { await SandboxAccess.shared.request(.disk, in: window); reload() } }
    @objc private func addFolders() { Task { await SandboxAccess.shared.request(.folders, in: window); reload() } }
    @objc private func removeSelected() {
        let paths = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].path : nil }
        for path in paths { SandboxAccess.shared.revoke(path: path) }
        reload()
    }
    @objc private func closeWindow() { close() }
}

/// What the list shows in place of the files when the sandbox refuses a folder.
@MainActor
final class NoAccessView: NSView {
    private let title = NSTextField(labelWithString: L10n.text("access.denied.title"))
    private let path = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let grant = NSButton(title: L10n.text("access.grant_folder"), target: nil, action: nil)
    private let settings = NSButton(title: L10n.text("access.open_settings"), target: nil, action: nil)
    private(set) var folder: URL?
    var onGrant: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 36, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        path.alignment = .center
        path.lineBreakMode = .byTruncatingMiddle
        path.textColor = .secondaryLabelColor
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.alignment = .center
        detail.textColor = .secondaryLabelColor
        grant.bezelStyle = .rounded
        grant.keyEquivalent = ""
        grant.target = self
        grant.action = #selector(grantFolder)
        grant.setAccessibilityIdentifier("access.grantFolder")
        settings.bezelStyle = .rounded
        settings.target = self
        settings.action = #selector(openSettings)
        settings.setAccessibilityIdentifier("access.openSettings")
        let buttons = NSStackView(views: [grant, settings])
        buttons.spacing = 10
        buttons.setHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, title, path, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            path.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        ])
        // A group VoiceOver enters: the title, the explanation and the buttons stay reachable.
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("access.noAccess")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() { layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }

    func show(_ folder: URL) {
        self.folder = folder
        path.stringValue = folder.path
        let covered = SandboxAccess.shared.covers(folder)
        detail.stringValue = L10n.text(covered ? "access.denied.covered" : "access.denied.detail")
        settings.isHidden = !covered
        setAccessibilityLabel(L10n.text("access.denied.title") + ". " + detail.stringValue)
        isHidden = false
    }

    @objc private func grantFolder() { if let folder { onGrant?(folder) } }
    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
