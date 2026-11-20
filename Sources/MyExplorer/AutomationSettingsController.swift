// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerAutomation
import ExplorerCore

private final class AutomationDocument: NSView { override var isFlipped: Bool { true } }

@MainActor
final class AutomationSettingsController: DialogWindowController {
    private let enabled = NSButton(checkboxWithTitle: L10n.text("automation.enabled"), target: nil, action: nil)
    private let clients = NSPopUpButton()
    private let name = NSTextField(string: "")
    private let rootLabel = NSTextField(labelWithString: "—")
    private let connection = NSPopUpButton()
    private let prefix = NSTextField(string: "")
    private let recursive = NSButton(checkboxWithTitle: L10n.text("automation.recursive"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var permissions: [String: NSButton] = [:]
    private var root: URL?
    private var grants: [AutomationGrant] = []
    private var connections: [CloudConnection] = []
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 690), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("automation.title"); window.isReleasedWhenClosed = false
        super.init(window: window)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        window.contentView?.addSubview(scroll)
        let document = AutomationDocument(frame: NSRect(x: 0, y: 0, width: 650, height: 690))
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        enabled.target = self; enabled.action = #selector(toggleEnabled); enabled.setAccessibilityIdentifier("automation.enabled")
        stack.addArrangedSubview(enabled)
        clients.widthAnchor.constraint(equalToConstant: 430).isActive = true
        clients.setAccessibilityIdentifier("automation.clients")
        let revoke = NSButton(title: L10n.text("automation.revoke"), target: self, action: #selector(revokeAccess)); revoke.bezelStyle = .rounded
        stack.addArrangedSubview(ExplorerStyle.stack([clients, revoke]))
        func row(_ key: String, _ control: NSView) {
            let label = NSTextField(labelWithString: L10n.text(key)); label.widthAnchor.constraint(equalToConstant: 195).isActive = true
            control.widthAnchor.constraint(equalToConstant: 380).isActive = true; control.setAccessibilityIdentifier(key)
            control.setAccessibilityLabel(label.stringValue)
            stack.addArrangedSubview(ExplorerStyle.stack([label, control]))
        }
        row("automation.client", name)
        let choose = NSButton(title: L10n.text("automation.choose"), target: self, action: #selector(chooseRoot)); choose.bezelStyle = .rounded
        stack.addArrangedSubview(choose)
        rootLabel.lineBreakMode = .byTruncatingMiddle; rootLabel.widthAnchor.constraint(equalToConstant: 590).isActive = true
        rootLabel.setAccessibilityLabel(L10n.text("automation.local_root")); stack.addArrangedSubview(rootLabel)
        connections = CloudAccounts.shared.connections
        connection.addItems(withTitles: [L10n.text("automation.none")] + connections.map(\.name))
        row("automation.connection", connection); row("automation.prefix", prefix)
        let permissionKeys = [("read", "read"), ("files.ocr", "ocr"), ("files.ocr.pdf", "ocr_pdf"), ("copy", "copy"), ("replace", "replace"), ("trash", "trash"), ("deleteRemote", "delete_remote"), ("configure", "configure"), ("preferences", "preferences")]
        for (operation, key) in permissionKeys {
            let button = NSButton(checkboxWithTitle: L10n.text("automation.\(key)"), target: nil, action: nil)
            button.state = operation == "read" ? .on : .off
            button.setAccessibilityIdentifier("automation.permission.\(operation)")
            permissions[operation] = button; stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(recursive)
        let note = NSTextField(wrappingLabelWithString: L10n.text("automation.note")); note.widthAnchor.constraint(equalToConstant: 590).isActive = true
        note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        let create = NSButton(title: L10n.text("automation.create"), target: self, action: #selector(createAccess)); create.bezelStyle = .rounded
        create.setAccessibilityIdentifier("automation.create"); stack.addArrangedSubview(create)
        status.widthAnchor.constraint(equalToConstant: 590).isActive = true; stack.addArrangedSubview(status)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24)])
        window.delegate = self; Task { await refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refresh() async {
        guard let service = AppAutomation.shared.service else { status.stringValue = L10n.text("automation.error"); return }
        enabled.state = await service.isEnabled() ? .on : .off
        grants = await service.grants()
        clients.removeAllItems(); clients.addItems(withTitles: grants.map(\.name))
    }
    @objc private func toggleEnabled(_ sender: NSButton) {
        let value = sender.state == .on
        Task { do { try await AppAutomation.shared.service?.setEnabled(value) } catch { status.stringValue = L10n.text("automation.error") }; await refresh() }
    }
    @objc private func chooseRoot(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.beginSheetModal(for: window) { result in if result == .OK { self.root = panel.url; self.rootLabel.stringValue = panel.url?.path ?? "—" } }
    }
    @objc private func revokeAccess(_ sender: Any?) {
        let index = clients.indexOfSelectedItem
        guard grants.indices.contains(index) else { return }
        let id = grants[index].id
        Task { do { try await AppAutomation.shared.service?.revoke(id); await refresh() } catch { status.stringValue = L10n.text("automation.error") } }
    }
    @objc private func createAccess(_ sender: NSButton) {
        let operations = Set(permissions.filter { $0.value.state == .on }.keys)
        let selected = connection.indexOfSelectedItem - 1
        let cloud = connections.indices.contains(selected) ? connections[selected] : nil
        sender.isEnabled = false
        Task {
            defer { sender.isEnabled = true }
            do {
                let url = try await AppAutomation.shared.createAccess(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), root: root, connection: cloud, prefix: prefix.stringValue, operations: operations, recursive: recursive.state == .on)
                status.stringValue = L10n.format("automation.created", url.path); await refresh()
            } catch { status.stringValue = L10n.text("automation.error") }
        }
    }
}
