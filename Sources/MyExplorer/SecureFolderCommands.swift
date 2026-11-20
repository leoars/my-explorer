// SPDX-License-Identifier: Apache-2.0
import AppKit
import CryptoKit
import ExplorerCore

@MainActor
private final class PasswordConfirmation: NSObject {
    let password: NSSecureTextField
    let confirmation: NSSecureTextField
    let hint = NSTextField(wrappingLabelWithString: L10n.text("vault.mismatch"))

    init(password: NSSecureTextField, confirmation: NSSecureTextField) {
        self.password = password
        self.confirmation = confirmation
        super.init()
        hint.isHidden = true
        hint.textColor = .systemRed
    }

    @objc func submit(_ sender: NSButton) {
        guard !password.stringValue.isEmpty, password.stringValue == confirmation.stringValue else {
            hint.isHidden = false
            let field = password.stringValue.isEmpty ? password : confirmation
            field.selectText(nil)
            NSAccessibility.post(element: hint, notification: .announcementRequested,
                                 userInfo: [.announcement: hint.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            return
        }
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
    }
}

@MainActor
final class SecureFolderCommands: NSObject, NSMenuItemValidation {
    var onUnlock: ((URL) -> Void)?
    var onConceal: (([URL]) -> Void)?
    var onChange: (() -> Void)?
    private let service: SecureFolderService
    private var mounts: [URL: URL] = [:]
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var locking = 0
    private weak var promptWindow: NSWindow?

    init(service: SecureFolderService = .shared) {
        self.service = service
        super.init()
    }

    func observeSession() {
        lockAll() // Recover mounts left behind by a previous process.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sessionLocked),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            center.addObserver(self, selector: #selector(sessionLocked), name: name, object: nil)
        }
    }

    func addCommands(to menu: NSMenu) {
        menu.addItem(.separator())
        for (key, action) in [("vault.protect", #selector(chooseFolder)),
                              ("vault.unlock", #selector(chooseVault)),
                              ("vault.lock", #selector(lockOpened))] {
            menu.addItem(withTitle: L10n.text(key), action: action, keyEquivalent: "").target = self
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(lockOpened) { return !mounts.isEmpty && locking == 0 }
        return operation == nil && locking == 0
    }

    private func selectFolder(vault: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text(vault ? "vault.unlock" : "vault.protect")
        panel.canChooseFiles = vault
        panel.canChooseDirectories = true
        panel.canCreateDirectories = !vault
        panel.allowsMultipleSelection = false
        return DialogPlacement.runModal(panel, present: { panel.runModal() }) == .OK ? panel.url : nil
    }

    @objc private func chooseFolder(_ sender: Any?) {
        if let url = selectFolder(vault: false) { protect(url) }
    }

    @objc private func chooseVault(_ sender: Any?) {
        if let url = selectFolder(vault: true) { unlock(url) }
    }

    private func run(_ work: @escaping @MainActor (Int) async throws -> Void) {
        guard operation == nil, locking == 0 else { NSSound.beep(); return }
        let expected = generation
        operation = Task {
            defer { operation = nil }
            do { try await work(expected) }
            catch { if expected == generation { report(error) } }
        }
    }

    func protect(_ url: URL) {
        run { [self] expected in
            var newMaster: String?
            if !(await service.hasMasterPassword) {
                guard let password = try await setMasterPassword(expected: expected, detail: url.path) else { return }
                newMaster = password
            }
            let keys = newMaster == nil ? ["vault.master", "vault.new", "vault.confirm"] : ["vault.new", "vault.confirm"]
            guard generation == expected,
                  let values = prompt("vault.protect", keys, detail: url.path + "\n\n" + L10n.text("vault.close_files")) else { return }
            let folderPassword = values[values.count - 2]
            guard generation == expected else { return }
            _ = try await service.protect(url, password: folderPassword, masterPassword: newMaster ?? values[0])
            onConceal?([url])
            onChange?()
        }
    }

    func unlock(_ vault: URL) {
        run { [self] expected in
            guard SecureFolderService.isVault(vault) else { message("vault.select"); return }
            guard let passwords = prompt("vault.unlock", ["vault.either"], detail: vault.lastPathComponent) else { return }
            let mount = try await service.unlock(vault, password: passwords[0])
            mounts[vault.standardizedFileURL] = mount
            if expected == generation { onUnlock?(mount) }
        }
    }

    func isUnlocked(_ vault: URL) -> Bool {
        mounts[vault.standardizedFileURL] != nil
    }

    func lock(_ vault: URL) {
        run { [self] _ in
            let key = vault.standardizedFileURL
            guard let mount = mounts[key] else { return }
            onConceal?([mount])
            try await service.lock(vault)
            mounts.removeValue(forKey: key)
            onChange?()
        }
    }

    func reset(_ vault: URL) {
        run { [self] _ in
            guard let passwords = prompt("vault.reset", ["vault.master", "vault.new", "vault.confirm"], detail: vault.lastPathComponent) else { return }
            try await service.resetPassword(vault, masterPassword: passwords[0], newPassword: passwords[1])
        }
    }

    @objc func configureMaster(_ sender: Any?) {
        run { [self] expected in
            let active = await service.hasMasterPassword
            guard expected == generation else { return }
            if active {
                let choice = NSAlert()
                choice.messageText = L10n.text("vault.master")
                for key in ["vault.change", "vault.disable", "dialog.cancel"] {
                    choice.addButton(withTitle: L10n.text(key))
                }
                let response = runModal(choice)
                if response == .alertSecondButtonReturn {
                    guard let password = prompt("vault.disable", ["vault.current"])?.first else { return }
                    try await service.configureMasterPassword(current: password, new: nil)
                    return
                }
                guard response == .alertFirstButtonReturn else { return }
            }
            _ = try await setMasterPassword(expected: expected)
        }
    }

    private func setMasterPassword(expected: Int, detail: String = "") async throws -> String? {
        let stored = await service.hasStoredMasterPassword
        let keys = stored ? ["vault.current", "vault.new", "vault.confirm"] : ["vault.new", "vault.confirm"]
        guard generation == expected, let values = prompt("vault.master", keys, detail: detail) else { return nil }
        let password = values[values.count - 2]
        guard generation == expected else { return nil }
        try await service.configureMasterPassword(current: stored ? values[0] : nil, new: password)
        return password
    }

    private func prompt(_ title: String, _ keys: [String], detail: String = "") -> [String]? {
        let alert = NSAlert()
        alert.messageText = L10n.text(title)
        alert.informativeText = detail
        // NSAlert uses the accessory's frame when sizing the modal. Give it the
        // full measured form, including space around the native focus ring.
        let labels = keys.map { NSTextField(labelWithString: L10n.text($0)) }
        let fields = labels.map { label in
            let field = NSSecureTextField()
            field.setAccessibilityLabel(label.stringValue)
            return field
        }
        let padding: CGFloat = 8
        let width = max(320, labels.map { ceil($0.intrinsicContentSize.width) }.max() ?? 0)
        let form = NSView()
        var y = padding
        let validation = keys.last == "vault.confirm"
            ? PasswordConfirmation(password: fields[fields.count - 2], confirmation: fields[fields.count - 1]) : nil
        if let hint = validation?.hint {
            hint.preferredMaxLayoutWidth = width
            hint.frame = NSRect(x: padding, y: y, width: width, height: ceil(hint.intrinsicContentSize.height))
            form.addSubview(hint)
            y = hint.frame.maxY + 8
        }
        for index in labels.indices.reversed() {
            let field = fields[index]
            let label = labels[index]
            field.frame = NSRect(x: padding, y: y, width: width, height: ceil(field.intrinsicContentSize.height))
            y = field.frame.maxY + 10
            label.frame = NSRect(x: padding, y: y, width: width, height: ceil(label.intrinsicContentSize.height))
            y = label.frame.maxY + (index == 0 ? padding : 14)
        }
        form.setFrameSize(NSSize(width: width + 2 * padding, height: y))
        for (label, field) in zip(labels, fields) {
            form.addSubview(label)
            form.addSubview(field)
        }
        alert.accessoryView = form
        let submit = alert.addButton(withTitle: L10n.text("dialog.confirm"))
        if let validation {
            submit.target = validation
            submit.action = #selector(PasswordConfirmation.submit(_:))
        }
        alert.addButton(withTitle: L10n.text("dialog.cancel"))
        alert.window.initialFirstResponder = fields.first
        guard withExtendedLifetime(validation, { runModal(alert) }) == .alertFirstButtonReturn else { return nil }
        return fields.map(\.stringValue)
    }

    private func message(_ key: String, detail: String = "") {
        let alert = NSAlert()
        alert.messageText = L10n.text(key)
        alert.informativeText = detail
        _ = runModal(alert)
    }

    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        promptWindow = alert.window
        defer { promptWindow = nil }
        return DialogPlacement.runModal(alert.window) { alert.runModal() }
    }

    private func report(_ error: Error) {
        let detail: String
        switch error {
        case CryptoKitError.authenticationFailure:
            detail = L10n.text("vault.bad_password")
        case let error as SecureFolderDiskError:
            switch error {
            case .unsupportedLocation: detail = L10n.text("vault.location")
            case .unsupportedItem: detail = L10n.text("vault.item")
            case .sourceChanged: detail = L10n.text("vault.changed")
            case .verificationFailed: detail = L10n.text("vault.verification")
            case .diskUtilityFailed(let code): detail = L10n.format("vault.utility", String(code))
            case .recoveryRequired(let url): detail = L10n.format("vault.recovery", url.path)
            }
        default:
            detail = error.localizedDescription
        }
        message("vault.error", detail: detail)
    }

    nonisolated static func contains(_ url: URL, in root: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path
        if path == prefix || path.hasPrefix(prefix + "/") { return true }
        // Sessions retain the path entered by the user, including symbolic links.
        // Compare filesystem identities while the volume is still mounted.
        var relation: FileManager.URLRelationship = .other
        let target = url.resolvingSymlinksInPath()
        do {
            try FileManager.default.getRelationship(&relation, ofDirectoryAt: root.resolvingSymlinksInPath(), toItemAt: target)
            return relation == .contains || relation == .same
        } catch {
            return false
        }
    }

    func sessionURL(_ url: URL) -> URL {
        mounts.first(where: { Self.contains(url, in: $0.value) })?.key.deletingLastPathComponent() ?? url
    }

    @objc private func sessionLocked(_ sender: Notification) { lockAll() }
    @objc private func lockOpened(_ sender: Any?) { lockAll() }

    func lockAll() {
        invalidate()
        Task { _ = await finishLock() }
    }

    func lockForExit() async -> Bool {
        invalidate()
        return await finishLock()
    }

    private func invalidate() {
        generation += 1
        operation?.cancel()
        locking += 1
        if let window = promptWindow, NSApp.modalWindow === window { NSApp.abortModal() }
        if !mounts.isEmpty { onConceal?(Array(mounts.values)) }
    }

    private func finishLock() async -> Bool {
        defer { locking -= 1 }
        await operation?.value
        do {
            try await service.lockAll()
            mounts.removeAll()
            onChange?()
            return true
        } catch {
            report(error)
            return false
        }
    }
}
