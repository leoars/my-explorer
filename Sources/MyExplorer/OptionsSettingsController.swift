// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import ExplorerLocalization

@MainActor
final class OptionsSettingsController: DialogWindowController {
    private let updates = NSButton(checkboxWithTitle: L10n.text("updates.option"), target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let updater: GitHubUpdater?
    let confirmDeletion: NSButton
    let restoreFolder: NSButton
    let restoreTabs: NSButton
    let expandTree: NSButton
    let autoplayMedia: NSButton
    var onExpandTreeChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onMasterPassword: (() -> Void)?
    var onConnectAssistant: (() -> Void)?
    var onShowFonts: (() -> Void)?
    /// The language of the interface is chosen here; the window is no place for a control that
    /// is used once.
    var onLanguageChange: ((AppLanguage) -> Void)?
    private let language = NSPopUpButton()
    let showFavorites = NSButton(checkboxWithTitle: L10n.text("options.show_favorites"), target: nil, action: nil)
    let showRecents = NSButton(checkboxWithTitle: L10n.text("options.show_recents"), target: nil, action: nil)
    let recentLimit = NSPopUpButton()
    private let preferences: StartupPreferences
    private let sessionPreferences: SessionPreferences

    init(preferences: StartupPreferences, sessionPreferences: SessionPreferences, updater: GitHubUpdater?) {
        self.updater = updater
        self.preferences = preferences
        self.sessionPreferences = sessionPreferences
        confirmDeletion = NSButton(checkboxWithTitle: L10n.text("options.confirm_deletion"), target: nil, action: nil)
        restoreTabs = NSButton(checkboxWithTitle: L10n.text("options.restore_tabs"), target: nil, action: nil)
        restoreFolder = NSButton(checkboxWithTitle: L10n.text("options.restore_folder"), target: nil, action: nil)
        expandTree = NSButton(checkboxWithTitle: L10n.text("options.expand_tree"), target: nil, action: nil)
        autoplayMedia = NSButton(checkboxWithTitle: L10n.text("options.autoplay_media"), target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 684),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("options.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        confirmDeletion.target = self
        confirmDeletion.action = #selector(deletionChanged)
        confirmDeletion.state = ExplorerStyle.browserPreferences.confirmDeletion ? .on : .off
        confirmDeletion.setAccessibilityIdentifier("options.confirmDeletion")
        expandTree.target = self
        expandTree.action = #selector(expandTreeChanged)
        expandTree.state = ExplorerStyle.browserPreferences.expandTreeToOpenFolder ? .on : .off
        expandTree.setAccessibilityIdentifier("options.expandTree")
        let expandTreeHelp = NSTextField(wrappingLabelWithString: L10n.text("options.expand_tree_help"))
        expandTreeHelp.textColor = .secondaryLabelColor
        autoplayMedia.target = self
        autoplayMedia.action = #selector(autoplayMediaChanged)
        autoplayMedia.state = ExplorerStyle.browserPreferences.autoplayMedia ? .on : .off
        autoplayMedia.setAccessibilityIdentifier("options.autoplayMedia")
        let autoplayHelp = NSTextField(wrappingLabelWithString: L10n.text("options.autoplay_media_help"))
        autoplayHelp.textColor = .secondaryLabelColor
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
        language.addItems(withTitles: AppLanguage.allCases.map { $0 == .system ? L10n.text("language.system") : $0.nativeName })
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: L10n.preferences.selection) ?? 0)
        language.target = self; language.action = #selector(languageChanged)
        language.setAccessibilityLabel(L10n.text("language.accessibility"))
        language.setAccessibilityIdentifier("options.language")
        let languageRow = NSStackView(views: [NSTextField(labelWithString: L10n.text("language.label")), language])
        languageRow.spacing = 10
        // Favorite and recent folders: what the tree shows and how many recent folders it keeps.
        let shortcuts = ExplorerStyle.folderShortcuts
        let shortcutsTitle = NSTextField(labelWithString: L10n.text("options.shortcuts"))
        shortcutsTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        showFavorites.target = self; showFavorites.action = #selector(shortcutsChanged)
        showFavorites.state = shortcuts.showFavorites ? .on : .off
        showFavorites.setAccessibilityIdentifier("options.showFavorites")
        showRecents.target = self; showRecents.action = #selector(shortcutsChanged)
        showRecents.state = shortcuts.showRecents ? .on : .off
        showRecents.setAccessibilityIdentifier("options.showRecents")
        recentLimit.addItems(withTitles: FolderShortcuts.recentLimits.map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .none) })
        recentLimit.selectItem(at: FolderShortcuts.recentLimits.firstIndex(of: shortcuts.recentLimit) ?? 0)
        recentLimit.target = self; recentLimit.action = #selector(recentLimitChanged)
        recentLimit.isEnabled = shortcuts.showRecents
        recentLimit.setAccessibilityLabel(L10n.text("options.recent_limit"))
        recentLimit.setAccessibilityIdentifier("options.recentLimit")
        let clearRecents = NSButton(title: L10n.text("recents.clear"), target: self, action: #selector(clearRecentFolders))
        clearRecents.setAccessibilityIdentifier("options.clearRecents")
        let limitRow = NSStackView(views: [NSTextField(labelWithString: L10n.text("options.recent_limit")), recentLimit, clearRecents])
        limitRow.spacing = 10
        let recentsHelp = NSTextField(wrappingLabelWithString: L10n.text("options.recents_help"))
        recentsHelp.textColor = .secondaryLabelColor
        let shortcutsSection = NSStackView(views: [shortcutsTitle, showFavorites, showRecents, limitRow, recentsHelp])
        shortcutsSection.orientation = .vertical; shortcutsSection.alignment = .leading; shortcutsSection.spacing = 8
        let stack = NSStackView(views: [languageRow, restoreTabs, tabsHelp, restoreFolder, help, expandTree, expandTreeHelp, shortcutsSection, autoplayMedia, autoplayHelp, confirmDeletion, updateControls, updateStatus, fonts, master])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let general = NSTabViewItem(identifier: "general")
        general.label = L10n.text("options.general")
        let generalView = NSView()
        general.view = generalView
        generalView.addSubview(stack)

        let integrations = NSTabViewItem(identifier: "integrations")
        integrations.label = L10n.text("options.integrations")
        let integrationsView = NSView()
        integrations.view = integrationsView
        let connect = NSButton(title: L10n.text("automation.title"), target: self, action: #selector(connectAssistant))
        connect.setAccessibilityIdentifier("options.connectAssistant")
        connect.translatesAutoresizingMaskIntoConstraints = false
        integrationsView.addSubview(connect)

        let tabs = NSTabView()
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(integrations)
        tabs.selectTabViewItem(general)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            connect.leadingAnchor.constraint(equalTo: integrationsView.leadingAnchor, constant: 16),
            connect.topAnchor.constraint(equalTo: integrationsView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: generalView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: generalView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: generalView.topAnchor, constant: 16),
            updateStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabsHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            expandTreeHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            autoplayHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recentsHelp.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        // Tall enough for everything the General tab holds, in any language and font size.
        generalView.layoutSubtreeIfNeeded()
        let needed = stack.fittingSize.height + 16 + 16 + 12 + 12 + 40
        if needed > window.frame.height { window.setContentSize(NSSize(width: window.frame.width, height: needed)) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func checkForUpdates() { if let window { updater?.checkNow(from: window) } }
    @objc private func toggleUpdates(_ sender: NSButton) {
        updater?.setEnabled(sender.state == .on)
    }
    @objc private func expandTreeChanged(_ sender: NSButton) {
        ExplorerStyle.browserPreferences.expandTreeToOpenFolder = sender.state == .on
        onExpandTreeChange?()
    }
    @objc private func autoplayMediaChanged(_ sender: NSButton) {
        ExplorerStyle.browserPreferences.autoplayMedia = sender.state == .on
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
    @objc private func shortcutsChanged(_ sender: NSButton) {
        let shortcuts = ExplorerStyle.folderShortcuts
        if sender === showFavorites { shortcuts.showFavorites = sender.state == .on }
        if sender === showRecents { shortcuts.showRecents = sender.state == .on }
        recentLimit.isEnabled = shortcuts.showRecents
    }
    @objc private func recentLimitChanged(_ sender: NSPopUpButton) {
        guard FolderShortcuts.recentLimits.indices.contains(sender.indexOfSelectedItem) else { return }
        ExplorerStyle.folderShortcuts.recentLimit = FolderShortcuts.recentLimits[sender.indexOfSelectedItem]
    }
    @objc private func clearRecentFolders(_ sender: Any?) { ExplorerStyle.folderShortcuts.clearRecents() }
    @objc private func configureMaster(_ sender: Any?) { onMasterPassword?() }
    @objc private func connectAssistant() { onConnectAssistant?() }
    @objc private func showFonts(_ sender: Any?) { onShowFonts?() }
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard AppLanguage.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        onLanguageChange?(AppLanguage.allCases[sender.indexOfSelectedItem])
    }
}
