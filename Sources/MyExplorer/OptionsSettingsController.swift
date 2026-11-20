// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
final class OptionsSettingsController: DialogWindowController {
    private let updates = NSButton(checkboxWithTitle: L10n.text("updates.option"), target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let updater: GitHubUpdater?
    let confirmDeletion: NSButton
    let restoreFolder: NSButton
    let restoreTabs: NSButton
    var onChange: (() -> Void)?
    var onMasterPassword: (() -> Void)?
    var onShowFonts: (() -> Void)?
    private let preferences: StartupPreferences
    private let sessionPreferences: SessionPreferences

    init(preferences: StartupPreferences, sessionPreferences: SessionPreferences, updater: GitHubUpdater?) {
        self.updater = updater
        self.preferences = preferences
        self.sessionPreferences = sessionPreferences
        confirmDeletion = NSButton(checkboxWithTitle: L10n.text("options.confirm_deletion"), target: nil, action: nil)
        restoreTabs = NSButton(checkboxWithTitle: L10n.text("options.restore_tabs"), target: nil, action: nil)
        restoreFolder = NSButton(checkboxWithTitle: L10n.text("options.restore_folder"), target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("options.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        confirmDeletion.target = self
        confirmDeletion.action = #selector(deletionChanged)
        confirmDeletion.state = ExplorerStyle.browserPreferences.confirmDeletion ? .on : .off
        confirmDeletion.setAccessibilityIdentifier("options.confirmDeletion")
        restoreTabs.target = self; restoreTabs.action = #selector(tabsChanged)
        restoreTabs.state = sessionPreferences.restoreTabs ? .on : .off
        restoreTabs.setAccessibilityIdentifier("options.restoreTabs")
        restoreFolder.isEnabled = !sessionPreferences.restoreTabs
        restoreFolder.target = self; restoreFolder.action = #selector(changed)
        restoreFolder.state = preferences.restoreLastFolder ? .on : .off
        restoreFolder.setAccessibilityIdentifier("options.restoreLastFolder")
        let help = NSTextField(wrappingLabelWithString: L10n.text("options.restore_help"))
        help.textColor = .secondaryLabelColor
        let fonts = NSButton(title: L10n.text("font.title"), target: self, action: #selector(showFonts))
        fonts.bezelStyle = .rounded
        let tabsHelp = NSTextField(wrappingLabelWithString: L10n.text("options.restore_tabs_help"))
        tabsHelp.textColor = .secondaryLabelColor
        let master = NSButton(title: L10n.text("vault.master"), target: self, action: #selector(configureMaster))
        updates.target = self
        updates.action = #selector(toggleUpdates)
        updates.isEnabled = updater?.canChangePreference == true
        updates.state = updater?.enabled == true ? .on : .off
        updates.setAccessibilityIdentifier("options.automaticUpdates")
        let checkNow = NSButton(title: L10n.text("updates.check_now"), target: self, action: #selector(checkForUpdates))
        checkNow.setAccessibilityIdentifier("options.checkForUpdates")
        checkNow.isEnabled = updater?.canCheckNow == true
        let updateControls = NSStackView(views: [updates, checkNow])
        updateControls.spacing = 12
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.stringValue = L10n.text(updater?.status ?? "updates.idle")
        updater?.changed = { [weak self] in
            guard let self, let updater = self.updater else { return }
            self.updates.isEnabled = updater.canChangePreference
            checkNow.isEnabled = updater.canCheckNow
            self.updateStatus.stringValue = L10n.text(updater.status)
        }
        let stack = NSStackView(views: [restoreTabs, tabsHelp, restoreFolder, help, confirmDeletion, updateControls, updateStatus, fonts, master])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            updateStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabsHelp.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func checkForUpdates() { if let window { updater?.checkNow(from: window) } }
    @objc private func toggleUpdates(_ sender: NSButton) {
        updater?.setEnabled(sender.state == .on)
    }
    @objc private func deletionChanged(_ sender: NSButton) {
        ExplorerStyle.browserPreferences.confirmDeletion = sender.state == .on
    }
    @objc private func changed(_ sender: NSButton) { preferences.setRestoreLastFolder(sender.state == .on); onChange?() }
    @objc private func tabsChanged(_ sender: NSButton) {
        sessionPreferences.setRestoreTabs(sender.state == .on)
        restoreFolder.isEnabled = !sessionPreferences.restoreTabs
        onChange?()
    }
    @objc private func configureMaster(_ sender: Any?) { onMasterPassword?() }
    @objc private func showFonts(_ sender: Any?) { onShowFonts?() }
}
