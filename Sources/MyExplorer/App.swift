// SPDX-License-Identifier: Apache-2.0
import AppKit
import AVFoundation
import PDFKit
import ExplorerCore
import ExplorerLocalization
import ExplorerAutomation
import ExplorerClipboard

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var controller: ExplorerWindowController?
    private let secureFolders = SecureFolderCommands()
    private var mediaViewer: MediaViewerWindowController?
    private var ocrViewer: OCRWindowController?
    private var ocrBatchViewer: OCRBatchWindowController?
    private var fontSettings: FontSettingsController?
    private var restartingForUpdate = false
    private var updater: GitHubUpdater?
    private var optionsSettings: OptionsSettingsController?
    private var startupPreferences = StartupPreferences()
    private var sessionPreferences = SessionPreferences()
    private var sessionSaveTask: Task<Void, Never>?
    private var lastSessionState: (tabs: [SessionTabState], activeIndex: Int)?
    private var cloudSettings: CloudSettingsController?
    private var automationSettings: AutomationSettingsController?
    private var smokeDefaultsName: String?
    private var terminationRequested = false
    private var terminationReady = false
    private var automationHost = false
    private var interruptionAlert: NSAlert?
    private var quitSmokeExpectation: (code: OperationInterruptionCode?, destination: URL, files: [String: Data])?

    /// Gives an installed copy the custom Finder icon that escapes the grey plate. Only copies in
    /// an Applications folder qualify, so build output and test bundles keep a clean signature.
    private static func applyFinderIcon(_ icon: NSImage) {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let arguments = ProcessInfo.processInfo.arguments
        let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
        guard bundle.pathExtension == "app", folders.contains(bundle.deletingLastPathComponent().path),
              !arguments.contains("--smoke-test"), !arguments.contains("--automation-host"),
              !CustomBundleIcon.isPresent(at: bundle), FileManager.default.isWritableFile(atPath: bundle.path) else { return }
        _ = NSWorkspace.shared.setIcon(icon, forFile: bundle.path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        // macOS frames free-form icons in a grey plate; drawing the Dock tile ourselves keeps the
        // artwork edge to edge with a transparent background.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            let tile = NSImageView(image: icon)
            tile.imageScaling = .scaleProportionallyUpOrDown
            NSApp.dockTile.contentView = tile
            NSApp.dockTile.display()
            Self.applyFinderIcon(icon)
        }
        let smoke = arguments.contains("--smoke-test")
        automationHost = arguments.contains("--automation-host") && !smoke
        if smoke {
            let suiteIndex = arguments.firstIndex(of: "--smoke-suite")
            let requestedSuite = suiteIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            let name = requestedSuite.flatMap { $0.hasPrefix("MyExplorer.Smoke.") ? $0 : nil } ?? "MyExplorer.Smoke.\(UUID().uuidString)"
            smokeDefaultsName = name
            L10n.preferences = LanguagePreferences(defaults: UserDefaults(suiteName: name)!)
            ExplorerStyle.preferences = DisplayPreferences(defaults: UserDefaults(suiteName: name)!)
            startupPreferences = StartupPreferences(defaults: UserDefaults(suiteName: name)!)
            sessionPreferences = SessionPreferences(defaults: UserDefaults(suiteName: name)!)
            FileCommands.shared.interruptionStore = OperationInterruptionStore(defaults: UserDefaults(suiteName: name)!)
            ExplorerStyle.browserPreferences = BrowserViewPreferences(defaults: UserDefaults(suiteName: name)!)
            // A smoke run must never read or modify real connections or Keychain credentials.
            CloudAccounts.shared = CloudAccounts(defaults: UserDefaults(suiteName: name)!, useKeychain: false)
            L10n.preferences.select(.portuguese)
        }
        ExplorerStyle.preferences.onChange = { [weak self] change in
            switch change {
            case .fileNames: self?.controller?.refreshFileNames()
            case .fonts:
                self?.fontSettings?.refreshValues()
                self?.rebuildInterface()
            case .preview: self?.controller?.updatePreviewVisibility()
            }
        }
        secureFolders.onUnlock = { [weak self] url in self?.controller?.addTab(at: url) }
        secureFolders.onChange = { [weak self] in self?.controller?.refresh(nil) }
        secureFolders.onConceal = { [weak self] roots in
            guard let self else { return }
            self.controller?.concealSecureFolders(roots)
            func affected(_ url: URL) -> Bool { roots.contains { SecureFolderCommands.contains(url, in: $0) } }
            if self.mediaViewer?.usesFiles(where: affected) == true { self.mediaViewer?.close() }
            if self.ocrViewer?.usesFiles(where: affected) == true { self.ocrViewer?.close() }
            if self.ocrBatchViewer?.usesFiles(where: affected) == true { self.ocrBatchViewer?.close() }
        }
        if !automationHost && !smoke { secureFolders.observeSession() }
        installMenu()
        let pathIndex = arguments.firstIndex(of: "--directory")
        let path = pathIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let fixtureIndex = arguments.firstIndex(of: "--session-fixture-root")
        let fixtureRoot = smoke ? fixtureIndex.flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true) : nil } : nil
        let fallback = fixtureRoot ?? FileManager.default.homeDirectoryForCurrentUser
        if !automationHost && !smoke { _ = CloudAccounts.shared.consolidateDuplicateS3Connections() }
        let aliases = CloudAccounts.shared.connectionAliases
        let connectionIDs = Set(CloudAccounts.shared.connections.map(\.id)).union(aliases.keys)
        let plan = path == nil ? sessionPreferences.restorationPlan(fallback: fallback, availableConnectionIDs: connectionIDs)?.resolvingCloudAliases(aliases) : nil
        let initial = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? plan.map { $0.tabs[$0.activeIndex].url }
            ?? RemoteLocation.resolvingAliases(in: startupPreferences.initialURL(fallback: fallback, availableConnectionIDs: connectionIDs), aliases: aliases)
        if !automationHost {
            let workspace = ExplorerWorkspace(reader: ApplicationDirectoryReader(), observerFactory: { DirectoryWatcher() })
            var fallbackTabs: Set<UUID> = []
            if let plan {
                for (index, state) in plan.tabs.enumerated() {
                    let tab = workspace.addTab(at: state.url, select: false, sortKey: state.sortKey, sortAscending: state.sortAscending,
                        showHidden: state.showHidden, startLoading: false, restorationFallback: fallback)
                    if plan.fallbackReasons[index] != nil { fallbackTabs.insert(tab.id) }
                }
                workspace.select(workspace.tabs[plan.activeIndex].id)
            } else {
                let view = ExplorerStyle.browserPreferences
                workspace.addTab(at: initial, sortKey: view.sortKey, sortAscending: view.sortAscending, showHidden: view.showHidden,
                    restorationFallback: path == nil && startupPreferences.restoreLastFolder ? fallback : nil)
            }
            controller = ExplorerWindowController(initialURL: initial, sidebarHome: smoke ? (fixtureRoot ?? initial) : nil, existingWorkspace: workspace)
            controller?.restorationFallbackTabs = fallbackTabs
        }
        if let controller { configureCallbacks(controller); scheduleSessionSave() }
        if arguments.contains("--dark") { controller?.window?.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--light") { controller?.window?.appearance = NSAppearance(named: .aqua) }
        controller?.showWindow(nil)
        if !automationHost { NSApp.activate(ignoringOtherApps: true) }
        if smoke { runSmokeTest(root: initial, arguments: arguments) }
        else {
            AppAutomation.shared.onLanguage = { [weak self] language in self?.changeLanguage(language) }
            Task { try? await AppAutomation.shared.start() }
            if !automationHost {
                updater = GitHubUpdater()
                updater?.requestRestart = { [weak self] in
                    guard let self, !self.terminationRequested else { return }
                    self.restartingForUpdate = true
                    NSApp.terminate(nil)
                }
                updater?.start()
                showInterruptionNotices()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !automationHost }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        guard !terminationRequested else { return .terminateCancel }
        terminationRequested = true
        if !restartingForUpdate { updater?.cancel() }
        controller?.savePresentation()
        sessionSaveTask?.cancel(); sessionSaveTask = nil
        saveSession()
        mediaViewer?.close()
        ocrViewer?.close(); ocrBatchViewer?.close()
        FileCommands.shared.prepareToQuit()
        if let controller {
            startupPreferences.remember(url: secureFolders.sessionURL(controller.workspace.activeTab?.session.history.current.url ?? controller.lastLocation))
        }
        if FileCommands.shared.isBusy { FileCommands.shared.cancel(nil) }
        // Return to the normal run loop before awaiting actor jobs. terminateLater can
        // enter an AppKit modal loop while the caller still occupies the main actor.
        Task {
            if let task = FileCommands.shared.task { await task.value }
            if !automationHost, smokeDefaultsName == nil, await !secureFolders.lockForExit() {
                if restartingForUpdate { restartingForUpdate = false; updater?.cancel() }
                FileCommands.shared.resumeAfterCancelledQuit()
                terminationRequested = false
                return
            }
            if restartingForUpdate, let updater {
                do { try await updater.installForRestart() }
                catch {
                    restartingForUpdate = false
                    terminationRequested = false
                    FileCommands.shared.resumeAfterCancelledQuit()
                    updater.cancel()
                    updater.reportFailure()
                    return
                }
            }
            await AppAutomation.shared.shutdown()
            await AppAutomation.files.clearLocalTransferHistory()
            terminationReady = true
            DispatchQueue.main.async { sender.terminate(nil) }
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if restartingForUpdate {
            do { try UpdateInstaller.reopenAfterExit(Bundle.main.bundleURL) }
            catch { NSLog("Unable to reopen updated My Explorer: %@", error.localizedDescription) }
        }
        verifyQuitOperationSmoke()
        if let smokeDefaultsName, !ProcessInfo.processInfo.arguments.contains("--close-main-window-smoke"), !ProcessInfo.processInfo.arguments.contains("--save-layout-smoke"), !ProcessInfo.processInfo.arguments.contains("--save-tabs-smoke"), !ProcessInfo.processInfo.arguments.contains("--restore-tabs-smoke") {
            UserDefaults.standard.removePersistentDomain(forName: smokeDefaultsName)
        }
    }

    private func changeLanguage(_ language: AppLanguage) {
        guard language != L10n.preferences.selection else { return }
        let previousCloudText = Dictionary(uniqueKeysWithValues: Self.cloudSettingsKeys.map { ($0, L10n.text($0)) })
        automationSettings?.close(); automationSettings = nil
        L10n.preferences.select(language)
        relocalizeCloudSettings(previousText: previousCloudText)
        let settingsVisible = fontSettings?.window?.isVisible == true
        let optionsVisible = optionsSettings?.window?.isVisible == true
        optionsSettings?.close(); optionsSettings = nil
        fontSettings?.close(); fontSettings = nil
        rebuildInterface()
        if settingsVisible { showFontSettings(nil) }
        if optionsVisible { showOptions(nil) }
    }

    private func rebuildInterface() {
        guard let previous = controller, let active = previous.workspace.activeTab else { return }
        let mediaFocused = NSApp.keyWindow === mediaViewer?.window
        let ocrFocused = NSApp.keyWindow === ocrViewer?.window
        let batchFocused = NSApp.keyWindow === ocrBatchViewer?.window
        let treeFocused = previous.window?.firstResponder === previous.tree.outline
        previous.prepareForLanguageChange()
        installMenu()
        let next = ExplorerWindowController(initialURL: active.session.history.current.url,
                                            sidebarHome: previous.sidebarHome, existingWorkspace: previous.workspace,
                                            existingTree: previous.tree)
        next.restorationFallbackTabs = previous.restorationFallbackTabs
        configureCallbacks(next)
        next.window?.appearance = previous.window?.appearance
        if let frame = previous.window?.frame { next.window?.setFrame(frame, display: false) }
        controller = next
        next.showWindow(nil)
        next.restorePresentation(from: previous)
        if treeFocused { next.window?.makeFirstResponder(next.tree.outline) }
        FileCommands.shared.relocalize()
        mediaViewer?.reloadAppearance()
        ocrViewer?.reloadAppearance(); ocrBatchViewer?.reloadAppearance()
        previous.close()
        if mediaFocused { mediaViewer?.window?.makeKeyAndOrderFront(nil) }
        if ocrFocused { ocrViewer?.window?.makeKeyAndOrderFront(nil) }
        if batchFocused { ocrBatchViewer?.window?.makeKeyAndOrderFront(nil) }
        if fontSettings?.window?.isVisible == true { fontSettings?.window?.makeKeyAndOrderFront(nil) }
        if cloudSettings?.window?.isVisible == true { cloudSettings?.window?.makeKeyAndOrderFront(nil) }
        if optionsSettings?.window?.isVisible == true { optionsSettings?.window?.makeKeyAndOrderFront(nil) }
    }

    private func configureCallbacks(_ controller: ExplorerWindowController) {
        controller.secureFolders = secureFolders
        controller.onOpenMedia = { [weak self, weak controller] entries, url in
            guard let self else { return }
            if self.mediaViewer == nil { self.mediaViewer = MediaViewerWindowController() }
            self.mediaViewer?.onExtractText = { [weak self] url in self?.showOCR(url) }
            self.mediaViewer?.window?.appearance = controller?.window?.appearance
            self.mediaViewer?.open(entries: entries, selectedURL: url)
        }
        controller.onLanguageChange = { [weak self] in self?.changeLanguage($0) }
        controller.onExtractText = { [weak self] url in self?.showOCR(url) }
        controller.onBatchOCR = { [weak self] urls in self?.showBatchOCR(urls) }
        controller.onShowFontSettings = { [weak self] in self?.showFontSettings(nil) }
        controller.onManageCloud = { [weak self] in self?.showCloudSettings(nil) }
        controller.onShowOptions = { [weak self] in self?.showOptions(nil) }
        controller.onSessionChange = { [weak self] in self?.scheduleSessionSave() }
        controller.onClose = { [weak self] url in
            self?.saveSession()
            if let self { self.startupPreferences.remember(url: self.secureFolders.sessionURL(url)) }
            self?.requestQuit(nil)
        }
    }

    @objc private func requestQuit(_ sender: Any?) {
        ocrViewer?.close(); ocrBatchViewer?.close()
        // AppKit can defer terminate while a progress sheet is open. Resolve decisions
        // before requesting termination, rather than waiting for the termination delegate.
        FileCommands.shared.prepareToQuit()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func captureSession() {
        guard let workspace = controller?.workspace, !workspace.tabs.isEmpty else { return }
        let tabs = workspace.tabs.map { tab in
            SessionTabState(url: secureFolders.sessionURL(tab.session.history.current.url), sortKey: tab.sortKey,
                sortAscending: tab.sortAscending, showHidden: tab.session.showHidden)
        }
        lastSessionState = (tabs, workspace.tabs.firstIndex { $0.id == workspace.activeID } ?? 0)
    }

    private func scheduleSessionSave() {
        captureSession()
        sessionSaveTask?.cancel()
        guard sessionPreferences.restoreTabs else { sessionSaveTask = nil; return }
        sessionSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.saveSession()
        }
    }

    private func saveSession() {
        captureSession()
        guard let state = lastSessionState else { return }
        sessionPreferences.remember(tabs: state.tabs, activeIndex: state.activeIndex)
    }

    private func installMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); main.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: L10n.text("app.about"), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L10n.text("options.title"), action: #selector(showOptions), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        let services = NSMenu(title: L10n.text("quick.services"))
        appMenu.addItem(withTitle: services.title, action: nil, keyEquivalent: "").submenu = services
        NSApp.registerServicesMenuSendTypes(ExplorerTableView.serviceTypes, returnTypes: [])
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("app.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L10n.text("app.quit"), action: #selector(requestQuit), keyEquivalent: "q").target = self
        let file = NSMenuItem(title: L10n.text("menu.file"), action: nil, keyEquivalent: ""); main.addItem(file)
        let fileMenu = NSMenu(title: L10n.text("menu.file")); file.submenu = fileMenu
        fileMenu.addItem(withTitle: L10n.text("command.new_tab"), action: #selector(newTab), keyEquivalent: "t").target = self
        fileMenu.addItem(withTitle: L10n.text("command.close_tab"), action: #selector(closeTab), keyEquivalent: "w").target = self
        fileMenu.addItem(withTitle: L10n.text("ocr.title"), action: #selector(extractText), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: L10n.text("ocr.batch.title"), action: #selector(batchOCR), keyEquivalent: "").target = self
        secureFolders.addCommands(to: fileMenu)
        let edit = NSMenuItem(title: L10n.text("menu.edit"), action: nil, keyEquivalent: ""); main.addItem(edit)
        let editMenu = NSMenu(title: L10n.text("menu.edit")); edit.submenu = editMenu
        editMenu.addItem(withTitle: L10n.text("command.undo_files"), action: #selector(undoFiles), keyEquivalent: "z").target = self
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("command.cut_files"), action: #selector(cut), keyEquivalent: "x").target = self
        editMenu.addItem(withTitle: L10n.text("command.copy_files"), action: #selector(copy(_:)), keyEquivalent: "c").target = self
        editMenu.addItem(withTitle: L10n.text("command.paste_files"), action: #selector(paste), keyEquivalent: "v").target = self
        let moveHere = editMenu.addItem(withTitle: L10n.text("command.move_here"), action: #selector(moveFilesHere), keyEquivalent: "v")
        moveHere.target = self; moveHere.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(withTitle: L10n.text("command.select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let view = NSMenuItem(title: L10n.text("menu.view"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: view.title)
        viewMenu.addItem(withTitle: L10n.text("view.extensions"), action: #selector(toggleFileExtensions), keyEquivalent: "").target = self
        viewMenu.addItem(withTitle: L10n.text("preview.title"), action: #selector(togglePreview), keyEquivalent: "").target = self
        viewMenu.addItem(withTitle: L10n.text("font.title"), action: #selector(showFontSettings), keyEquivalent: "").target = self
        viewMenu.addItem(withTitle: L10n.text("options.title"), action: #selector(showOptions), keyEquivalent: "").target = self
        let increase = viewMenu.addItem(withTitle: L10n.text("font.increase"), action: #selector(increaseFonts), keyEquivalent: "+")
        increase.target = self; increase.keyEquivalentModifierMask = .control
        let decrease = viewMenu.addItem(withTitle: L10n.text("font.decrease"), action: #selector(decreaseFonts), keyEquivalent: "-")
        decrease.target = self; decrease.keyEquivalentModifierMask = .control
        viewMenu.addItem(withTitle: L10n.text("cloud.manage"), action: #selector(showCloudSettings), keyEquivalent: "").target = self
        view.submenu = viewMenu; main.addItem(view)
        let navigation = NSMenuItem(title: L10n.text("menu.navigate"), action: nil, keyEquivalent: ""); main.addItem(navigation)
        let navMenu = NSMenu(title: L10n.text("menu.navigate")); navigation.submenu = navMenu
        let address = navMenu.addItem(withTitle: L10n.text("command.edit_address"), action: #selector(focusAddress), keyEquivalent: "l")
        address.target = self
        let search = navMenu.addItem(withTitle: L10n.text("search.title"), action: #selector(showFileSearch), keyEquivalent: "f")
        search.keyEquivalentModifierMask = [.command, .shift]
        search.target = self
        navMenu.addItem(withTitle: L10n.text("server.connect"), action: #selector(connectToServer), keyEquivalent: "k").target = self
        let reload = navMenu.addItem(withTitle: L10n.text("command.refresh"), action: #selector(refresh), keyEquivalent: "r")
        reload.target = self
        let languageItem = NSMenuItem(title: L10n.text("menu.language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: L10n.text("menu.language"))
        for language in AppLanguage.allCases {
            let item = languageMenu.addItem(withTitle: language == .system ? L10n.text("language.system") : language.nativeName,
                                           action: #selector(selectLanguage), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == L10n.preferences.selection ? .on : .off
        }
        languageItem.submenu = languageMenu
        main.addItem(languageItem)
        NSApp.mainMenu = main
        ExplorerStyle.configureMenu(main)
    }

    @objc private func toggleFileExtensions(_ sender: Any?) { controller?.toggleFileExtensions(sender) }
    @objc private func increaseFonts(_ sender: Any?) { ExplorerStyle.preferences.adjustAllFontSizes(by: 1) }
    @objc private func decreaseFonts(_ sender: Any?) { ExplorerStyle.preferences.adjustAllFontSizes(by: -1) }
    @objc private func cut(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.cut(sender) }
        else if NSApp.keyWindow === controller?.window, controller?.acceptsFileListCommands == true { controller?.cutFiles(sender) }
    }
    @objc private func copy(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            if let controller, editor === controller.address.currentEditor(), !editor.hasMarkedText() {
                controller.copyAddressText(editor)
            } else {
                editor.copy(sender)
            }
        }
        else if NSApp.keyWindow === controller?.window, controller?.acceptsFileListCommands == true { controller?.copyFiles(sender) }
    }
    @objc private func paste(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.paste(sender) }
        else if NSApp.keyWindow === controller?.window, controller?.acceptsFileListCommands == true { controller?.pasteFiles(sender) }
    }
    @objc private func moveFilesHere(_ sender: Any?) {
        guard !(NSApp.keyWindow?.firstResponder is NSTextView), NSApp.keyWindow === controller?.window, controller?.acceptsFileListCommands == true else { return }
        controller?.moveFilesHere(sender)
    }
    @objc private func undoFiles(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.undo() }
        else if NSApp.keyWindow === controller?.window { FileCommands.shared.undo() }
    }
    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(sender)
        if let panel = NSApp.keyWindow, panel !== controller?.window { DialogPlacement.center(panel) }
    }

    @objc private func showFontSettings(_ sender: Any?) {
        if fontSettings == nil { fontSettings = FontSettingsController() }
        fontSettings?.showWindow(nil)
        fontSettings?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showOptions(_ sender: Any?) {
        if optionsSettings == nil {
            let settings = OptionsSettingsController(preferences: startupPreferences, sessionPreferences: sessionPreferences, updater: updater)
            settings.onChange = { [weak self] in self?.saveSession() }
            settings.onMasterPassword = { [weak self] in self?.secureFolders.configureMaster(nil) }
            settings.onConnectAssistant = { [weak self] in self?.showAutomationSettings(nil) }
            settings.onShowFonts = { [weak self] in self?.showFontSettings(nil) }
            optionsSettings = settings
        }
        optionsSettings?.showWindow(nil)
        optionsSettings?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showCloudSettings(_ sender: Any?) {
        if cloudSettings?.window?.isVisible != true {
            let settings = CloudSettingsController()
            settings.onConnected = { [weak self] url in
                guard let self else { return }
                if let controller = self.controller, controller.workspace.activeTab != nil {
                    controller.openConnectedBucket(url)
                } else {
                    let controller = ExplorerWindowController(initialURL: url)
                    self.configureCallbacks(controller)
                    self.controller = controller
                    controller.showWindow(nil)
                    controller.window?.makeKeyAndOrderFront(nil)
                }
            }
            cloudSettings = settings
        }
        cloudSettings?.showWindow(nil)
        cloudSettings?.window?.makeKeyAndOrderFront(nil)
    }

    private func testS3CredentialImport(_ settings: CloudSettingsController) async throws {
        guard let window = settings.window, let content = window.contentView else { throw SmokeFailure.failed("Missing settings window") }
        let views = descendants(of: content)
        func view<T: NSView>(_ key: String, as type: T.Type) throws -> T {
            guard let value = views.first(where: { $0.accessibilityIdentifier() == key }) as? T else {
                throw SmokeFailure.failed("Missing settings control " + key)
            }
            return value
        }
        let button = try view("cloud.import_csv", as: NSButton.self)
        let provider = try view("cloud.provider", as: NSPopUpButton.self)
        let id = try view("cloud.access_key", as: NSTextField.self)
        let secret = try view("cloud.secret", as: NSSecureTextField.self)
        let token = try view("cloud.session_token", as: NSSecureTextField.self)
        let bucket = try view("cloud.bucket", as: NSTextField.self)
        bucket.stringValue = "smoke-test-bucket"
        token.stringValue = "obsolete"
        button.performClick(nil)
        try await waitForCondition("CSV picker") { window.attachedSheet is NSOpenPanel }
        (window.attachedSheet as? NSOpenPanel)?.cancel(nil)
        try await waitForCondition("CSV picker closed") { window.attachedSheet == nil }
        guard token.stringValue == "obsolete" else { throw SmokeFailure.failed("Cancel changed the draft") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Access key ID,Secret access key\nid-test,secret-test".utf8).write(to: file)
        settings.fillS3Credentials(from: file)
        try await waitForCondition("CSV imported") { button.isEnabled }
        guard id.stringValue == "id-test", secret.stringValue == "secret-test", token.stringValue.isEmpty,
              bucket.stringValue == "smoke-test-bucket" else { throw SmokeFailure.failed("Incorrect CSV draft") }
        bucket.stringValue = "  "
        let connect = try view("cloud.connect", as: NSButton.self)
        connect.performClick(nil)
        guard views.contains(where: { ($0 as? NSTextField)?.stringValue == L10n.text("cloud.bucket_needed") }),
              bucket.currentEditor() != nil, button.isEnabled, secret.stringValue == "secret-test" else {
            throw SmokeFailure.failed("Missing S3 bucket did not focus the field and preserve the draft")
        }
        try Data("invalid".utf8).write(to: file)
        settings.fillS3Credentials(from: file)
        try await waitForCondition("CSV rejected") { button.isEnabled }
        guard id.stringValue == "id-test", secret.stringValue == "secret-test" else { throw SmokeFailure.failed("Invalid import changed the draft") }
        provider.selectItem(at: 1)
        if let action = provider.action { NSApp.sendAction(action, to: provider.target, from: provider) }
        guard button.isHidden, secret.stringValue.isEmpty else { throw SmokeFailure.failed("Credentials survived provider change") }
        provider.selectItem(at: 0)
        if let action = provider.action { NSApp.sendAction(action, to: provider.target, from: provider) }
        bucket.stringValue = ""
    }

    private func testS3BucketSelection() async throws {
        let settings = CloudSettingsController { credentials, _ in
            guard credentials.secretAccessKey == "smoke" else { throw CloudFailure(.permissionDenied) }
            return .init(buckets: [.init(name: "test-one", region: "us-east-1"),
                                   .init(name: "test-two", region: "sa-east-1")], isPartial: false)
        }
        settings.showWindow(nil)
        defer { settings.close() }
        guard let window = settings.window, let content = window.contentView else { throw SmokeFailure.failed("Missing form") }
        let controls = descendants(of: content)
        func field(_ name: String) -> NSTextField? {
            controls.first { $0.accessibilityIdentifier() == "cloud." + name } as? NSTextField
        }
        guard let button = controls.first(where: { $0.accessibilityIdentifier() == "cloud.bucket_lookup" }) as? NSButton,
              let id = field("access_key"), let key = field("secret"), let bucket = field("bucket"),
              let region = field("region") else { throw SmokeFailure.failed("Missing bucket discovery controls") }
        id.stringValue = "example"
        key.stringValue = "smoke"
        bucket.stringValue = "manual-example"
        for response in [NSApplication.ModalResponse.alertSecondButtonReturn, .alertFirstButtonReturn] {
            button.performClick(nil)
            try await waitForCondition("bucket picker") { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet, let container = sheet.contentView,
                  let picker = descendants(of: container).compactMap({ $0 as? NSPopUpButton }).first,
                  picker.numberOfItems == 2 else { throw SmokeFailure.failed("Missing accessible buckets") }
            picker.selectItem(at: 1)
            window.endSheet(sheet, returnCode: response)
            try await waitForCondition("bucket picker finished") { bucket.isEnabled }
            if response == .alertSecondButtonReturn && bucket.stringValue != "manual-example" {
                throw SmokeFailure.failed("Cancelling changed the manual bucket")
            }
        }
        guard bucket.stringValue == "test-two", region.stringValue == "sa-east-1" else {
            throw SmokeFailure.failed("Wrong selected bucket or region")
        }
        key.stringValue = "denied"
        button.performClick(nil)
        try await waitForCondition("manual bucket fallback") {
            bucket.isEnabled && controls.contains { ($0 as? NSTextField)?.stringValue == L10n.text("cloud.bucket_denied") }
        }
        guard bucket.stringValue == "test-two", region.stringValue == "sa-east-1" else {
            throw SmokeFailure.failed("Denied discovery changed the draft")
        }
    }

    private static let cloudSettingsKeys = ["cloud.manage", "cloud.new", "cloud.remove", "cloud.provider", "cloud.name",
        "cloud.bucket", "cloud.region", "cloud.account", "cloud.access_key", "cloud.secret", "cloud.session_token",
        "cloud.sas", "cloud.access_token", "cloud.credentials_note", "cloud.connect", "cloud.testing",
        "cloud.import_csv", "cloud.import_csv_ok", "cloud.import_csv_error", "cloud.bucket_needed", "cloud.import_bucket_needed",
        "cloud.bucket_lookup", "cloud.bucket_keys_needed", "cloud.bucket_searching", "cloud.bucket_partial",
        "cloud.bucket_none", "cloud.bucket_choose", "cloud.bucket_denied"] +
        ["invalidConfiguration", "invalidKey", "authenticationRequired", "permissionDenied", "notFound", "conflict",
         "preconditionFailed", "rateLimited", "serviceUnavailable", "malformedResponse", "insecureTransport", "cancelled",
         "localConflict", "limitExceeded", "io"].map { "cloud.error." + $0 }

    /// Update labels in place so a language switch never copies, discards, or persists draft secrets.
    private func relocalizeCloudSettings(previousText: [String: String]) {
        guard let window = cloudSettings?.window, let content = window.contentView else { return }
        window.title = L10n.text("cloud.manage")
        let translated = Dictionary(previousText.map { ($0.value, L10n.text($0.key)) }, uniquingKeysWith: { first, _ in first })
        for view in descendants(of: content) {
            let identifier = view.accessibilityIdentifier()
            if Self.cloudSettingsKeys.contains(identifier) {
                view.setAccessibilityLabel(L10n.text(identifier))
            }
            if let popup = view as? NSPopUpButton {
                if popup.accessibilityIdentifier() == "cloud.connections" { popup.item(at: 0)?.title = L10n.text("cloud.new") }
            } else if let button = view as? NSButton, let title = translated[button.title] {
                button.title = title
            } else if let label = view as? NSTextField, !label.isEditable, let text = translated[label.stringValue] {
                label.stringValue = text
            }
        }
        content.layoutSubtreeIfNeeded()
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(batchOCR) {
            guard NSApp.keyWindow === controller?.window, let controller else { return false }
            return controller.validateMenuItem(NSMenuItem(title: "", action: #selector(ExplorerWindowController.batchOCR), keyEquivalent: ""))
        }
        if menuItem.action == #selector(extractText) {
            guard NSApp.keyWindow === controller?.window, let controller else { return false }
            return controller.validateMenuItem(NSMenuItem(title: "", action: #selector(ExplorerWindowController.extractText), keyEquivalent: ""))
        }
        if menuItem.action == #selector(closeTab) {
            menuItem.title = L10n.text(NSApp.keyWindow === mediaViewer?.window || NSApp.keyWindow === ocrViewer?.window || NSApp.keyWindow === ocrBatchViewer?.window ? "media.close" : "command.close_tab")
            return controller != nil || mediaViewer?.window?.isVisible == true
        }
        if menuItem.action == #selector(undoFiles) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                menuItem.title = L10n.text("command.undo_files")
                return editor.undoManager?.canUndo == true
            }
            menuItem.title = FileCommands.shared.undoTitle
            return NSApp.keyWindow === controller?.window && !FileCommands.shared.isBusy && FileCommands.shared.undoKind != nil
        }
        let fileActions: [Selector: Selector] = [#selector(copy(_:)): #selector(ExplorerWindowController.copyFiles(_:)),
            #selector(cut(_:)): #selector(ExplorerWindowController.cutFiles(_:)), #selector(paste(_:)): #selector(ExplorerWindowController.pasteFiles(_:))]
        if let action = menuItem.action, let forwarded = fileActions[action] {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                if action == #selector(copy(_:)), editor === controller?.address.currentEditor(), !editor.hasMarkedText() {
                    return !editor.string.isEmpty
                }
                return action == #selector(copy(_:)) ? editor.selectedRange().length > 0 : editor.isEditable
            }
            guard let controller, NSApp.keyWindow === controller.window, controller.acceptsFileListCommands else { return false }
            return controller.validateMenuItem(NSMenuItem(title: menuItem.title, action: forwarded, keyEquivalent: ""))
        }
        if menuItem.action == #selector(moveFilesHere) {
            guard NSApp.keyWindow === controller?.window, controller?.acceptsFileListCommands == true, !(NSApp.keyWindow?.firstResponder is NSTextView),
                  let destination = controller?.workspace.activeTab?.session.history.current.url else { return false }
            return FileCommands.shared.canPaste(into: destination) && FileCommands.shared.canTransfer(FileCommands.shared.pasteURLs, to: destination, move: true)
        }
        if menuItem.action == #selector(increaseFonts) || menuItem.action == #selector(decreaseFonts) {
            return controller != nil && NSApp.modalWindow == nil && NSApp.keyWindow?.attachedSheet == nil
                && NSApp.keyWindow?.sheetParent == nil
                && (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true
        }
        if menuItem.action == #selector(togglePreview) { menuItem.state = ExplorerStyle.preferences.showPreviewPane ? .on : .off }
        if menuItem.action == #selector(toggleFileExtensions) {
            menuItem.state = ExplorerStyle.preferences.showFileExtensions ? .on : .off
        }
        return true
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) { changeLanguage(language) }
    }
    @objc private func showAutomationSettings(_ sender: Any?) {
        if automationSettings?.window?.isVisible != true { automationSettings = AutomationSettingsController() }
        automationSettings?.showWindow(nil)
    }
    @objc private func togglePreview(_ sender: Any?) { controller?.togglePreviewPane(sender) }

    @objc private func connectToServer(_ sender: Any?) { controller?.systemVolumes.promptForServer() }
    @objc private func showFileSearch(_ sender: Any?) { controller?.showFileSearch(sender) }
    @objc private func focusAddress(_ sender: Any?) { controller?.focusAddress(sender) }
    @objc private func refresh(_ sender: Any?) { controller?.refresh(sender) }
    @objc private func newTab(_ sender: Any?) { controller?.newTab(sender) }
    @objc private func closeTab(_ sender: Any?) {
        if NSApp.keyWindow === mediaViewer?.window { mediaViewer?.close() }
        else if NSApp.keyWindow === ocrViewer?.window { ocrViewer?.close() }
        else if NSApp.keyWindow === ocrBatchViewer?.window { ocrBatchViewer?.close() }
        else { controller?.closeCurrentTab(sender) }
    }

    @objc private func batchOCR(_ sender: Any?) { controller?.batchOCR(sender) }
    private func showBatchOCR(_ urls: [URL]) {
        guard !terminationRequested else { return }
        if ocrBatchViewer == nil { ocrBatchViewer = OCRBatchWindowController() }
        ocrBatchViewer?.window?.appearance = controller?.window?.appearance
        ocrBatchViewer?.open(urls)
    }
    @objc private func extractText(_ sender: Any?) { controller?.extractText(sender) }
    private func showOCR(_ url: URL) {
        guard !terminationRequested else { return }
        if ocrViewer == nil { ocrViewer = OCRWindowController() }
        ocrViewer?.window?.appearance = controller?.window?.appearance
        ocrViewer?.open(url)
    }

    private func runSmokeTest(root: URL, arguments: [String]) {
        Task {
            do {
                guard let controller else { throw SmokeFailure.failed("No window") }
                try await waitForListing(controller)
                if let index = arguments.firstIndex(of: "--quit-operation-smoke"), arguments.indices.contains(index + 1) {
                    try await quitOperationSmoke(root: root, kind: arguments[index + 1])
                    return
                }
                if arguments.contains("--save-tabs-smoke") {
                    try await saveTabsSmoke(root: root)
                    return
                }
                if arguments.contains("--restore-tabs-smoke") {
                    guard let index = arguments.firstIndex(of: "--session-fixture-root"), arguments.indices.contains(index + 1) else { throw SmokeFailure.failed("Missing session fixture root") }
                    try await restoreTabsSmoke(root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--override-tabs-smoke") {
                    guard sessionPreferences.restoreTabs, controller.workspace.tabs.count == 1,
                          controller.session.history.current.url.path == root.path else { throw SmokeFailure.failed("Explicit directory did not override saved tabs") }
                    print("SMOKE PASS: explicit startup directory overrides saved tabs")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--dialogs-smoke") {
                    try await testDialogPlacement(browser: controller)
                    print("SMOKE PASS: dialogs centered on the Explorer window")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--vault-smoke") {
                    let directory = root.appendingPathComponent("Documents")
                    let tab = controller.addTab(at: directory)
                    try await waitForListing(controller)
                    let menu = NSMenu()
                    controller.rebuildContextMenu(menu, entries: [FileEntry(url: directory, name: "Documents", isDirectory: true)])
                    guard menu.item(withTitle: L10n.text("vault.protect")) != nil else {
                        throw SmokeFailure.failed("Missing folder protection command")
                    }
                    let vault = root.appendingPathComponent("Example.myexplorervault")
                    controller.rebuildContextMenu(menu, entries: [FileEntry(url: vault, name: vault.lastPathComponent, isDirectory: true)])
                    guard menu.item(withTitle: L10n.text("vault.unlock")) != nil,
                          menu.item(withTitle: L10n.text("vault.reset")) != nil else {
                        throw SmokeFailure.failed("Missing secure folder commands")
                    }
                    tab.filterQuery = "Notes"
                    controller.concealSecureFolders([directory])
                    guard !controller.workspace.tabs.contains(where: { $0.id == tab.id }), controller.previewedURL == nil else {
                        throw SmokeFailure.failed("Lock retained a secure listing or preview")
                    }
                    try await testProtectFolderSetup(root: root, browser: controller)
                    print("SMOKE PASS: master setup from Protect Folder, cancellation, conversion and secure tab concealment")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--trash-undo-smoke") {
                    try await testTrashUndo(root: root, browser: controller)
                    print("SMOKE PASS: sidebar Trash, permanent-delete cancellation, Put Back, Ctrl+Z, Command+Z and name conflicts")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--file-search-smoke") {
                    try await FileSearchController.smoke(root: root)
                    try QuickActionCommands.smoke(in: controller, root: root)
                    print("SMOKE PASS: nested file search, Finder tags, live saved results, quick actions, iCloud menus and Services")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--s3-drag-smoke") {
                    try await testS3Drag(controller)
                    print("SMOKE PASS: S3 drag, Delete and undo, context-menu cut and paste, Ctrl+X and Command+V")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--s3-folder-smoke") {
                    try await testS3FolderMenu(controller)
                    print("SMOKE PASS: New Folder in S3 root and subfolder, local and cloud overview")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--cloud-reconnect-smoke") {
                    try await CloudConnectionIdentitySmoke.run()
                    try await testCloudReconnect(controller)
                    print("SMOKE PASS: cloud identity, migration, reconnect, focus and disconnect")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--s3-csv-smoke") {
                    showCloudSettings(nil)
                    guard let settings = cloudSettings else { throw SmokeFailure.failed("Missing connection editor") }
                    try await testS3CredentialImport(settings)
                    settings.close()
                    try await testS3BucketSelection()
                    print("SMOKE PASS: S3 CSV import, bucket validation, selection, region and manual fallback")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--address-completion-smoke") {
                    try await testAddressCompletion(root: root, browser: controller)
                    print("SMOKE PASS: address text select all/copy/cut/paste with Control and Command, completion, keyboard navigation, cancellation and focus")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--inline-rename-smoke") {
                    try await testInlineRename(root: root, browser: controller)
                    print("SMOKE PASS: inline rename clicks, Enter, Escape, double-click, F2 and context menu")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--deletion-smoke") {
                    try await testDeletionPreference(root: root, browser: controller)
                    print("SMOKE PASS: Delete confirmation, cancellation and immediate trash of the selected file")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--clipboard-smoke") {
                    try await testLocalClipboard(root: root)
                    print("SMOKE PASS: local clipboard copy, quarantine, conflicts and Undo")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--eject-smoke") {
                    try await testMobileDevicePanel(browser: controller)
                    try await testDisposableEjection(root: root, browser: controller)
                    print("SMOKE PASS: device panel, native ejection, affected and unaffected tabs")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--volumes-smoke") {
                    try await testVolumeNavigation(root: root)
                    print("SMOKE PASS: volume navigation and clicked-volume capacity, used and free space in tree properties")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--buttons-smoke") {
                    try await testOutlinedButtons(root: root, arguments: arguments)
                    print("SMOKE PASS: outlined buttons, enabled/disabled actions, hover, focus, preview toggle, fonts and localization")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--git-smoke") {
                    try await testGitIntegration(root: root, arguments: arguments)
                    print("SMOKE PASS: Git roots, tree/list statuses, branch/worktree, refresh and stale/cancelled requests")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--stability-smoke") {
                    try await BetaStabilitySmoke.run(root: root, browser: controller)
                    print("SMOKE PASS: beta stability batch50, repeat/cancel/close/reopen, integrity, search, navigation and responsiveness")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--ocr-smoke") {
                    try await testOCR(root: root, arguments: arguments)
                    try await testOCRBatch(root: root, arguments: arguments)
                    try await testAutomation(root: root)
                    print("SMOKE PASS: OCR images/PDF, context/preview, eight languages, copy/export/cancel/close and signed CLI/MCP grants")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--save-layout-smoke") {
                    try await saveLayoutSmoke()
                    return
                }
                if arguments.contains("--restore-layout-smoke") {
                    try await restoreLayoutSmoke()
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--restore-startup-smoke") {
                    guard let index = arguments.firstIndex(of: "--expected-directory"), arguments.indices.contains(index + 1),
                          root.path == arguments[index + 1], startupPreferences.restoreLastFolder else {
                        throw SmokeFailure.failed("App did not reopen in the persisted folder")
                    }
                    print("SMOKE PASS: new app process restored the last folder")
                    NSApp.terminate(nil)
                    return
                }
                if arguments.contains("--close-main-window-smoke") {
                    let audio = root.appendingPathComponent("Media/02-Áudio.wav")
                    controller.onOpenMedia?([FileEntry(url: audio, name: audio.lastPathComponent, isDirectory: false)], audio)
                    try await waitForCondition("media ready before app quit") { self.mediaViewer?.playbackReady == true }
                    mediaViewer?.player?.play()
                    controller.navigate(.visit(root.appendingPathComponent("Documents")))
                    try await waitForListing(controller)
                    showOptions(nil)
                    guard let settings = optionsSettings, !startupPreferences.restoreLastFolder else {
                        throw SmokeFailure.failed("Restore-folder option must start disabled")
                    }
                    settings.restoreFolder.performClick(nil)
                    guard startupPreferences.restoreLastFolder, settings.window?.isVisible == true else {
                        throw SmokeFailure.failed("Options checkbox did not persist")
                    }
                    controller.window?.standardWindowButton(.closeButton)?.performClick(nil)
                    guard controller.window?.isVisible == false, settings.window?.isVisible == true,
                          startupPreferences.initialURL(fallback: root, availableConnectionIDs: []).path == root.appendingPathComponent("Documents").path else {
                        throw SmokeFailure.failed("Red close button did not save the active folder")
                    }
                    print("SMOKE PASS: red close button saved folder with Options and media player open")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        fputs("SMOKE FAIL: app stayed alive after red close button\n", stderr)
                        exit(1)
                    }
                    return
                }
                if arguments.contains("--close-last-tab-smoke") {
                    try sendKey("w", code: 13, flags: .command, to: controller)
                    guard controller.workspace.activeTab == nil, controller.window?.isVisible == false else {
                        throw SmokeFailure.failed("Closing last tab did not close the window")
                    }
                    print("SMOKE PASS: closing the last tab closes the window and terminates normally")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        fputs("SMOKE FAIL: process did not exit after closing the last tab\n", stderr)
                        exit(1)
                    }
                    return
                }
                try await testVolumeNavigation(root: root)
                guard controller.table.numberOfRows > 0 else { throw SmokeFailure.failed("Empty fixture") }
                let row = controller.session.entries.firstIndex { $0.name == "Documents" }
                guard let row else { throw SmokeFailure.failed("Missing Documents fixture") }
                controller.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                controller.navigate(.visit(root.appendingPathComponent("Documents")))
                try await waitForListing(controller)
                guard controller.session.history.current.url.lastPathComponent == "Documents" else {
                    throw SmokeFailure.failed("Navigation failed")
                }
                controller.goBack(nil)
                try await waitForListing(controller)
                guard controller.table.selectedRow == row else { throw SmokeFailure.failed("Selection was not restored") }
                controller.goForward(nil)
                try await waitForListing(controller)
                controller.goUp(nil)
                try await waitForListing(controller)
                guard controller.table.selectedRow == row else {
                    throw SmokeFailure.failed("Up did not select child: row=\(controller.table.selectedRow), expected=\(row), selection=\(controller.session.history.current.selectedPaths), entries=\(controller.session.entries.map(\.id))")
                }
                controller.filter.stringValue = "Roadmap"
                controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.filter))
                guard controller.table.numberOfRows == 1 else { throw SmokeFailure.failed("Filter did not narrow the listing") }
                controller.filter.stringValue = ""
                controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.filter))
                let outline = controller.tree.outline
                guard let homeNode = outline.item(atRow: 0) as? FolderNode else { throw SmokeFailure.failed("Missing tree root") }
                outline.expandItem(homeNode)
                for _ in 0..<1000 {
                    if outline.isItemExpanded(homeNode) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard outline.isItemExpanded(homeNode), controller.session.history.current.url.path == root.path else {
                    throw SmokeFailure.failed("Expanding tree must load children without navigating")
                }
                guard let documentRow = (0..<outline.numberOfRows).first(where: {
                    (outline.item(atRow: $0) as? FolderNode)?.url.path == root.appendingPathComponent("Documents").path
                }) else { throw SmokeFailure.failed("Missing child in tree") }
                outline.selectRowIndexes(IndexSet(integer: documentRow), byExtendingSelection: false)
                try await waitForListing(controller)
                guard controller.session.history.current.url.lastPathComponent == "Documents" else {
                    throw SmokeFailure.failed("Tree selection did not navigate")
                }
                controller.goUp(nil)
                try await waitForListing(controller)
                try await testTabs(controller, root: root)
                try await testLanguages(root: root, arguments: arguments)
                try await testOutlinedButtons(root: root, arguments: arguments)
                try await testFileUpdates(root: root)
                try await testDisplaySettings(root: root, arguments: arguments)
                try testFontShortcuts()
                try await testFileCommandFocus()
                try await testFileTypeIcons(root: root, arguments: arguments)
                try await testGitIntegration(root: root, arguments: arguments)
                try await testLargeDirectory(root: root)
                try await testFileSharing(root: root)
                try await testInterruptionNotice(root: root)
                try await testMediaViewer(root: root, arguments: arguments)
                try await testMediaLoadingLifecycle(root: root)
                try await testOCR(root: root, arguments: arguments)
                    try await testOCRBatch(root: root, arguments: arguments)
                try await testLocalClipboard(root: root)
                try await testArchiveCommands(root: root)
                try await testCloudConnections(root: root)
                try await testAutomation(root: root)
                try await testPreviewPane(root: root, arguments: arguments)
                try await testPreviewLoading(root: root)
                guard let controller = self.controller else { throw SmokeFailure.failed("Missing localized window") }
                if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1) {
                    try await Task.sleep(for: .milliseconds(600))
                    try await waitForListing(controller)
                    controller.window?.makeKeyAndOrderFront(nil)
                    controller.window?.makeFirstResponder(controller.table)
                    try await Task.sleep(for: .milliseconds(80))
                    guard controller.fileScroll.contentView.bounds.minY == -controller.fileScroll.contentView.contentInsets.top else {
                        throw SmokeFailure.failed("Top row overlaps the table header")
                    }
                    try controller.savePreview(to: URL(fileURLWithPath: arguments[index + 1]))
                }
                print("SMOKE PASS: navigation, eight languages, fonts, Git status/worktrees, image/audio/video viewer, OCR, clipboard/Undo, ZIP, cloud, signed CLI/broker, MCP and grants")
                NSApp.terminate(nil)
            } catch {
                fputs("SMOKE FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func showInterruptionNotices() {
        let store = FileCommands.shared.interruptionStore
        let notices = store.pendingNotices
        guard !notices.isEmpty, let window = controller?.window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("startup.interruption_title")
        let messages = notices.map { notice -> String in
            switch notice.code {
            case .partialOperation: return L10n.text("operation.partial")
            case .recoveryRequired: return L10n.text("operation.recovery")
            case .cloudCancellationUncertain: return L10n.text("cloud.cancel_notice")
            case .deletionPartial: return L10n.text("deletion.partial")
            }
        }
        var details = messages.joined(separator: "\n\n")
        let paths = notices.flatMap(\.recoveryPaths)
        if !paths.isEmpty { details += "\n\n" + paths.joined(separator: "\n") }
        if notices.contains(where: \.additionalRecoveryLocations) { details += "\n\n" + L10n.text("startup.recovery_overflow") }
        alert.informativeText = L10n.text("startup.interruption_help")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: CGFloat(min(300, max(120, notices.count * 55 + paths.count * 18)))))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = ExplorerStyle.font(.files); text.string = details
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        text.setAccessibilityIdentifier("startup.interruption.details")
        scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.text("startup.interruption_ack"))
        alert.addButton(withTitle: L10n.text("dialog.cancel"))
        interruptionAlert = alert
        let ids = Set(notices.map(\.id))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { store.acknowledge(ids: ids) }
            self?.interruptionAlert = nil
        }
    }

    private func testInterruptionNotice(root: URL) async throws {
        guard let browser = controller, let window = browser.window else { throw SmokeFailure.failed("Missing notice browser") }
        let store = FileCommands.shared.interruptionStore
        let recovery = root.appendingPathComponent("Recovery fixture")
        store.append(code: .recoveryRequired, recoveryLocations: [recovery])
        showInterruptionNotices()
        guard let notice = interruptionAlert,
              let scroll = notice.accessoryView as? NSScrollView,
              let text = scroll.documentView as? NSTextView, text.string.contains(recovery.path),
              !store.pendingNotices.isEmpty else { throw SmokeFailure.failed("Recovery notice was not visible/selectable or was consumed on startup") }
        window.endSheet(notice.window, returnCode: .alertSecondButtonReturn)
        try await waitForCondition("notice dismissal") { self.interruptionAlert == nil }
        guard !store.pendingNotices.isEmpty else { throw SmokeFailure.failed("Dismissal lost recovery notice") }
        showInterruptionNotices()
        guard let shown = interruptionAlert else { throw SmokeFailure.failed("Recovery notice did not reopen") }
        window.endSheet(shown.window, returnCode: .alertFirstButtonReturn)
        try await waitForCondition("notice acknowledgement") { self.interruptionAlert == nil && store.pendingNotices.isEmpty }
    }

    private func quitOperationSmoke(root: URL, kind: String) async throws {
        guard let browser = controller else { throw SmokeFailure.failed("Missing shutdown browser") }
        let base = root.appendingPathComponent("Shutdown-" + kind)
        let source = base.appendingPathComponent("source"), destination = base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = Data("existing destination\n".utf8), first = Data("completed first item\n".utf8)
        try original.write(to: destination.appendingPathComponent("Second.txt"))
        try Data("new source\n".utf8).write(to: source.appendingPathComponent("Second.txt"))
        var expected = ["Second.txt": original]
        let commands = FileCommands.shared
        if kind == "cloud" {
            commands.run("cloud.transfer.title") {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { throw StorageTransferFailure(.cancelled, completedCount: 1) }
                return []
            }
            quitSmokeExpectation = (.cloudCancellationUncertain, destination, expected)
        } else {
            var urls = [source.appendingPathComponent("Second.txt")]
            if kind == "paused" {
                try first.write(to: source.appendingPathComponent("First.txt"))
                urls.insert(source.appendingPathComponent("First.txt"), at: 0)
                expected["First.txt"] = first
            }
            commands.transfer(urls, to: destination, move: false)
            try await waitForCondition("shutdown conflict ready") { commands.hasPendingDecision }
            if kind == "paused" {
                guard try Data(contentsOf: destination.appendingPathComponent("First.txt")) == first else { throw SmokeFailure.failed("First transfer item not completed before quit") }
                commands.togglePause(nil)
                guard NSApp.windows.contains(where: { window in
                    window.contentView.map { descendants(of: $0).contains { ($0 as? NSButton)?.title == L10n.text("operation.resume") } } == true
                }) else { throw SmokeFailure.failed("Transfer did not pause before quit") }
            }
            quitSmokeExpectation = (kind == "paused" ? .partialOperation : nil, destination, expected)
        }
        guard commands.isBusy, commands.onIdle == nil else { throw SmokeFailure.failed("Shutdown must exercise a real busy command without alert suppression") }
        if kind == "conflict" {
            guard let quit = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "q" }),
                  let action = quit.action, NSApp.sendAction(action, to: quit.target, from: quit) else { throw SmokeFailure.failed("Quit menu action missing") }
        } else { browser.window?.standardWindowButton(.closeButton)?.performClick(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak browser] in
            let state = "requested=\(self?.terminationRequested ?? false), ready=\(self?.terminationReady ?? false), visible=\(browser?.window?.isVisible ?? false), shuttingDown=\(FileCommands.shared.shuttingDown), busy=\(FileCommands.shared.isBusy), decision=\(FileCommands.shared.hasPendingDecision)"
            fputs("SMOKE FAIL: operation or modal prevented app shutdown: \(state)\n", stderr); exit(1)
        }
    }

    private func verifyQuitOperationSmoke() {
        guard let expected = quitSmokeExpectation else { return }
        let commands = FileCommands.shared
        guard commands.shuttingDown, !commands.isBusy, !commands.hasPendingDecision,
              expected.code.map({ code in commands.interruptionStore.pendingNotices.contains { $0.code == code } }) ?? commands.interruptionStore.pendingNotices.isEmpty else {
            fputs("SMOKE FAIL: shutdown state or durable interruption notice missing\n", stderr); exit(1)
        }
        for (name, bytes) in expected.files {
            guard (try? Data(contentsOf: expected.destination.appendingPathComponent(name))) == bytes else {
                fputs("SMOKE FAIL: shutdown damaged completed/existing fixture data\n", stderr); exit(1)
            }
        }
        print("SMOKE PASS: shutdown cancelled operation, closed decisions, preserved fixture data and recorded required notices")
    }

    private func saveTabsSmoke(root: URL) async throws {
        guard let browser = controller else { throw SmokeFailure.failed("Missing session browser") }
        let missing = root.appendingPathComponent("RestoreGone")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        browser.navigate(.visit(root.appendingPathComponent("Documents")))
        try await waitForListing(browser)
        let documents = browser.workspace.activeTab!
        documents.sortKey = .modified; documents.sortAscending = false
        documents.session.toggleHidden(); try await waitForListing(browser)
        let downloads = browser.addTab(at: root.appendingPathComponent("Downloads"))
        try await waitForListing(browser)
        downloads.sortKey = .size; downloads.sortAscending = true
        let pictures = browser.addTab(at: root.appendingPathComponent("Pictures"))
        try await waitForListing(browser)
        pictures.sortKey = .kind; pictures.sortAscending = false
        _ = browser.addTab(at: missing); try await waitForListing(browser)
        browser.selectTab(id: downloads.id); try await waitForListing(browser)
        showOptions(nil)
        guard let options = optionsSettings, !sessionPreferences.restoreTabs else { throw SmokeFailure.failed("Session restoration must start disabled") }
        options.restoreTabs.performClick(nil)
        guard sessionPreferences.restoreTabs, !options.restoreFolder.isEnabled else { throw SmokeFailure.failed("Session checkbox precedence missing") }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1),
           let content = options.window?.contentView?.superview {
            try await Task.sleep(for: .milliseconds(150))
            content.layoutSubtreeIfNeeded()
            options.window?.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw SmokeFailure.failed("Missing Options preview bitmap") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SmokeFailure.failed("Missing Options PNG") }
            try png.write(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        options.close()
        let before = sessionPreferences.restorationPlan(fallback: root, availableConnectionIDs: [])
        guard before?.tabs.count == 4, before?.activeIndex == 1 else { throw SmokeFailure.failed("Session snapshot not saved") }
        changeLanguage(.english)
        changeLanguage(.portuguese)
        rebuildInterface()
        try await Task.sleep(for: .milliseconds(350))
        guard let current = controller,
              sessionPreferences.restorationPlan(fallback: root, availableConnectionIDs: []) == before,
              current.workspace.activeID == downloads.id else { throw SmokeFailure.failed("Rebuild altered tab snapshot or active identity") }
        // The next process must handle a tab whose folder disappeared after it was saved.
        try FileManager.default.removeItem(at: missing)
        current.window?.standardWindowButton(.closeButton)?.performClick(nil)
        print("SMOKE PASS: four tabs/order/active/sort/hidden saved across language and window rebuild")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { fputs("SMOKE FAIL: session-save process did not quit\n", stderr); exit(1) }
    }

    private func restoreTabsSmoke(root: URL) async throws {
        guard let browser = controller else { throw SmokeFailure.failed("Missing restored browser") }
        let tabs = browser.workspace.tabs
        guard tabs.count == 4, tabs.map({ $0.session.history.current.url.lastPathComponent }) == ["Documents", "Downloads", "Pictures", "RestoreGone"],
              browser.workspace.activeID == tabs[1].id,
              tabs[0].pendingInitialLoad, !tabs[1].pendingInitialLoad, tabs[2].pendingInitialLoad, tabs[3].pendingInitialLoad,
              tabs[0].sortKey == .modified, !tabs[0].sortAscending, tabs[0].session.showHidden,
              tabs[1].sortKey == .size, tabs[1].sortAscending,
              tabs[2].sortKey == .kind, !tabs[2].sortAscending else {
            throw SmokeFailure.failed("Session order/active/lazy state or per-tab settings not restored")
        }
        browser.selectTab(id: tabs[0].id); try await waitForListing(browser)
        guard !tabs[0].pendingInitialLoad, browser.table.sortDescriptors.first?.key == "modified",
              browser.table.sortDescriptors.first?.ascending == false, browser.session.showHidden else { throw SmokeFailure.failed("Restored tab view did not apply") }
        browser.selectTab(id: tabs[3].id)
        try await waitForCondition("restored missing folder fallback") {
            !tabs[3].session.isLoading && tabs[3].session.history.current.url.path == root.path && tabs[3].restorationUnavailableURL != nil
        }
        guard browser.errorLabel.stringValue == L10n.text("options.restore_unavailable"), !browser.errorLabel.isHidden,
              tabs[3].session.history.back.isEmpty else { throw SmokeFailure.failed("Restoration fallback lacks warning or kept invalid Back history") }
        browser.navigate(.visit(root.appendingPathComponent("Pictures"))); try await waitForListing(browser)
        guard tabs[3].restorationUnavailableURL == nil, browser.errorLabel.isHidden else { throw SmokeFailure.failed("Fallback warning survived user navigation") }
        showOptions(nil)
        optionsSettings?.restoreTabs.performClick(nil)
        guard !sessionPreferences.restoreTabs,
              sessionPreferences.restorationPlan(fallback: root, availableConnectionIDs: []) == nil else { throw SmokeFailure.failed("Disabling session restore did not clear snapshot") }
        optionsSettings?.restoreTabs.performClick(nil)
        browser.selectTab(id: tabs[1].id)
        print("SMOKE PASS: new process restored tabs/active/lazy settings; missing folder fallback and disabling verified")
    }

    private static let smokeColumnOrder = ["size", "name", "kind", "modified"]
    private static let smokeColumnWidths: [String: CGFloat] = ["name": 415, "modified": 188, "kind": 142, "size": 118]

    private func assertSmokeColumns(_ browser: ExplorerWindowController) throws {
        guard browser.table.tableColumns.map({ $0.identifier.rawValue }) == Self.smokeColumnOrder,
              browser.table.tableColumns.allSatisfy({ abs($0.width - Self.smokeColumnWidths[$0.identifier.rawValue]!) < 1 }) else {
            throw SmokeFailure.failed("Column order or widths were not restored by stable IDs")
        }
    }

    private func saveLayoutSmoke() async throws {
        guard let browser = controller, let window = browser.window, let suite = smokeDefaultsName else { throw SmokeFailure.failed("Missing layout fixture") }
        window.setContentSize(NSSize(width: 1100, height: 680))
        if let screen = window.screen { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 30)) }
        ExplorerStyle.preferences.setShowPreviewPane(true)
        browser.sidebarWidth = 245
        browser.previewPaneWidth = 265
        for (index, id) in Self.smokeColumnOrder.enumerated() {
            browser.table.moveColumn(browser.table.column(withIdentifier: NSUserInterfaceItemIdentifier(id)), toColumn: index)
        }
        for column in browser.table.tableColumns { column.width = Self.smokeColumnWidths[column.identifier.rawValue]! }
        browser.table.sortDescriptors = [NSSortDescriptor(key: "modified", ascending: false)]
        guard let hidden = window.contentView.flatMap({ descendants(of: $0).first { ($0 as? NSButton)?.title == L10n.text("view.hidden") } }) as? NSButton else {
            throw SmokeFailure.failed("Missing hidden-files checkbox")
        }
        hidden.performClick(nil)
        try await waitForListing(browser)
        try await Task.sleep(for: .milliseconds(300))
        guard ExplorerStyle.browserPreferences.columnOrder == Self.smokeColumnOrder else { throw SmokeFailure.failed("Column notifications did not save layout") }
        browser.togglePreviewPane(nil)
        browser.savePresentation()
        guard abs(ExplorerStyle.browserPreferences.previewWidth - 265) < 2 else { throw SmokeFailure.failed("Hiding preview lost its width") }
        browser.togglePreviewPane(nil)
        changeLanguage(.german)
        ExplorerStyle.preferences.setFontSize(15, for: .files)
        guard let current = controller else { throw SmokeFailure.failed("Missing rebuilt layout") }
        try await waitForListing(current)
        try assertSmokeColumns(current)
        current.savePresentation()
        guard abs(current.sidebarWidth - 245) < 2, abs(current.previewPaneWidth - 265) < 2 else {
            throw SmokeFailure.failed("Rebuild lost panel widths")
        }
        UserDefaults(suiteName: suite)?.set(NSStringFromRect(current.window!.frame), forKey: "layoutSmoke.expectedFrame")
        print("SMOKE PASS: custom columns, panels, window, sort and hidden files saved through rebuild and close")
        current.window?.performClose(nil)
    }

    private func restoreLayoutSmoke() async throws {
        guard let browser = controller, let suite = smokeDefaultsName,
              let expected = UserDefaults(suiteName: suite)?.string(forKey: "layoutSmoke.expectedFrame"), let window = browser.window else {
            throw SmokeFailure.failed("Missing restarted layout")
        }
        try assertSmokeColumns(browser)
        let frame = NSRectFromString(expected)
        guard browser.previewPaneVisible, abs(browser.previewPaneWidth - 265) < 2, abs(browser.sidebarWidth - 245) < 2,
              browser.workspace.activeTab?.sortKey == .modified, browser.workspace.activeTab?.sortAscending == false,
              browser.session.showHidden, browser.session.entries.contains(where: { $0.name == ".hidden" }),
              abs(window.frame.minX - frame.minX) < 2, abs(window.frame.minY - frame.minY) < 2,
              abs(window.frame.width - frame.width) < 2, abs(window.frame.height - frame.height) < 2 else {
            throw SmokeFailure.failed("New app process lost panels, window, ordering or hidden-files preference")
        }
        print("SMOKE PASS: new app process restored column order/widths, window, panels, sort and hidden files")
    }

    private func testPreviewPane(root: URL, arguments: [String]) async throws {
        guard let original = controller, !original.previewPaneVisible else { throw SmokeFailure.failed("Preview must start hidden") }
        func select(_ name: String, in window: ExplorerWindowController) throws {
            guard let index = (0..<window.table.numberOfRows).first(where: { window.tableView(window.table, typeSelectStringFor: nil, row: $0) == name }) else { throw SmokeFailure.failed("Missing preview fixture") }
            window.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        try select("Preview.png", in: original)
        let sidebar = original.sidebarWidth
        original.previewButton.performClick(nil)
        guard original.previewPaneVisible, original.previewedURL?.lastPathComponent == "Preview.png", original.previewButton.state == .on else { throw SmokeFailure.failed("Preview toggle did not show selected image") }
        original.previewPaneWidth = 280
        for _ in 0..<200 {
            if original.previewImageLoaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard original.previewImageLoaded else { throw SmokeFailure.failed("Selected PNG did not render") }
        try select("Example.pdf", in: original)
        guard original.previewedURL?.lastPathComponent == "Example.pdf" else { throw SmokeFailure.failed("PDF preview did not update") }
        try select("Notes.txt", in: original)
        guard original.previewedURL?.lastPathComponent == "Notes.txt" else { throw SmokeFailure.failed("Text preview did not update") }
        try select("Documents", in: original)
        guard original.previewedURL == nil, original.previewMessage == L10n.text("preview.folder") else { throw SmokeFailure.failed("Folder retained stale file preview") }
        original.table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        guard original.previewedURL == nil, original.previewMessage == L10n.text("preview.multiple") else { throw SmokeFailure.failed("Multiple selection retained preview") }
        try select("Preview.png", in: original)
        changeLanguage(.german)
        guard let translated = controller, translated.previewPaneVisible, translated.previewedURL?.lastPathComponent == "Preview.png",
              abs(translated.previewPaneWidth - 280) < 2 else { throw SmokeFailure.failed("Language change lost preview") }
        ExplorerStyle.preferences.setFontSize(15, for: .files)
        guard let enlarged = controller, enlarged.previewPaneVisible, enlarged.previewedURL?.lastPathComponent == "Preview.png" else { throw SmokeFailure.failed("Font change lost preview") }
        ExplorerStyle.preferences.resetFonts(); changeLanguage(.portuguese)
        guard let current = controller else { throw SmokeFailure.failed("Lost preview window") }
        for _ in 0..<200 {
            if current.previewImageLoaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard current.previewImageLoaded else { throw SmokeFailure.failed("Rebuilt preview image did not render") }
        if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1) {
            try await Task.sleep(for: .milliseconds(600))
            let path = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path + "-preview.png"
            try current.savePreview(to: URL(fileURLWithPath: path))
        }
        let selection = current.table.selectedRowIndexes
        current.togglePreviewPane(nil)
        guard !current.previewPaneVisible, current.previewedURL == nil, current.table.selectedRowIndexes == selection,
              abs(current.sidebarWidth - sidebar) < 2 else { throw SmokeFailure.failed("Hiding preview lost selection or sidebar") }
        current.togglePreviewPane(nil)
        guard abs(current.previewPaneWidth - 280) < 2 else { throw SmokeFailure.failed("Preview width was not retained") }
        current.togglePreviewPane(nil)
        // Unit-level view test for a remote item: it must never construct a Quick Look preview.
        let preview = PreviewPaneController()
        preview.update(entries: [FileEntry(url: RemoteLocation.url(connectionID: UUID(), key: "photo.png"), name: "photo.png", isDirectory: false)])
        guard preview.previewedURL == nil, preview.message == L10n.text("preview.remote") else { throw SmokeFailure.failed("Remote selection triggered preview") }
        preview.update(entries: [FileEntry(url: root.appendingPathComponent("Preview.png"), name: "Preview.png", isDirectory: false)])
        preview.update(entries: [FileEntry(url: root, name: "Folder", isDirectory: true)])
        try await Task.sleep(for: .milliseconds(100))
        guard !preview.previewImageLoaded, preview.previewedURL == nil else { throw SmokeFailure.failed("Stale image replaced folder placeholder") }
        let invalid = root.appendingPathComponent("Invalid-preview.png")
        try Data("not an image".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        preview.update(entries: [FileEntry(url: invalid, name: invalid.lastPathComponent, isDirectory: false)])
        for _ in 0..<200 {
            if preview.message == L10n.text("preview.unavailable") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !preview.previewImageLoaded, preview.message == L10n.text("preview.unavailable") else { throw SmokeFailure.failed("Invalid image did not report preview failure") }
    }

    private func testPreviewLoading(root: URL) async throws {
        let folder = root.appendingPathComponent("PreviewCacheFixtures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = root.appendingPathComponent("Preview.png")
        let imageURL = folder.appendingPathComponent("cached.png")
        try FileManager.default.copyItem(at: source, to: imageURL)
        let entry = FileEntry(url: imageURL, name: "cached.png", isDirectory: false)
        let loader = PreviewImageLoader()
        guard case .image = await loader.prepare(entry, image: true, maximumEdge: 640),
              case .image = await loader.prepare(entry, image: true, maximumEdge: 640),
              await loader.decodeCount == 1 else { throw SmokeFailure.failed("Repeated preview did not use image cache") }
        try Data(contentsOf: root.appendingPathComponent("Media/01-Imagem 日本語.png")).write(to: imageURL)
        guard case .image = await loader.prepare(entry, image: true, maximumEdge: 640),
              await loader.decodeCount == 2 else { throw SmokeFailure.failed("Modified image reused stale cached pixels") }
        for index in 0..<35 {
            let url = folder.appendingPathComponent("image-\(index).png")
            try FileManager.default.copyItem(at: source, to: url)
            _ = await loader.prepare(FileEntry(url: url, name: url.lastPathComponent, isDirectory: false), image: true, maximumEdge: 1600)
        }
        guard await loader.cachedByteCount <= 32 * 1024 * 1024, await loader.cachedItemCount <= 32 else {
            throw SmokeFailure.failed("Preview cache exceeded its memory/count budget")
        }
        let deferredLoader = PreviewImageLoader()
        let deferred = PreviewPaneController(imageLoader: deferredLoader)
        deferred.update(entries: [entry]); deferred.closePreview()
        try await Task.sleep(for: .milliseconds(200))
        guard await deferredLoader.decodeCount == 0, !deferred.previewImageLoaded, deferred.previewedURL == nil else {
            throw SmokeFailure.failed("Closing during preview debounce still decoded or displayed an image")
        }
        let offlineLoader = PreviewImageLoader(fileAccess: { _, _ in .needsDownload })
        let offline = PreviewPaneController(imageLoader: offlineLoader)
        for name in ["offline.png", "offline.mp4"] {
            offline.update(entries: [FileEntry(url: folder.appendingPathComponent(name), name: name, isDirectory: false)])
            try await waitForCondition("offline preview message") { offline.message == L10n.text("preview.needs_download") }
            guard await offlineLoader.decodeCount == 0, !offline.previewImageLoaded,
                  !descendants(of: offline.view).contains(where: { $0.accessibilityIdentifier() == "explorer.preview.content" }) else {
                throw SmokeFailure.failed("Offline file opened a decoder or Quick Look")
            }
        }
        offline.closePreview()
        let slowLoader = PreviewImageLoader(fileAccess: { _, _ in
            Thread.sleep(forTimeInterval: 0.4)
            return .unavailable
        })
        let slow = PreviewPaneController(imageLoader: slowLoader)
        slow.update(entries: [entry])
        try await Task.sleep(for: .milliseconds(180))
        let started = ContinuousClock.now
        slow.closePreview()
        try await Task.sleep(for: .milliseconds(20))
        guard started.duration(to: .now) < .milliseconds(250) else { throw SmokeFailure.failed("Slow metadata blocked preview close/UI heartbeat") }
        try await Task.sleep(for: .milliseconds(450))
        guard slow.previewedURL == nil, !slow.previewImageLoaded else { throw SmokeFailure.failed("Late preview result survived close") }
    }

    private func makeOCRFixture(_ url: URL, text: String, pdf: Bool) throws {
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 240)
        if pdf {
            var mediaBox = bounds
            guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw SmokeFailure.failed("OCR PDF fixture") }
            context.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor.white.setFill(); bounds.fill()
            (text as NSString).draw(at: NSPoint(x: 30, y: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
            context.endPDFPage(); context.closePDF()
        } else {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 240, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw SmokeFailure.failed("OCR image fixture") }
            NSGraphicsContext.current = context
            NSColor.white.setFill(); bounds.fill()
            (text as NSString).draw(at: NSPoint(x: 30, y: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SmokeFailure.failed("OCR PNG fixture") }
            try data.write(to: url)
        }
    }

    // The first accurate multilingual request may compile Vision models on this Mac.
    // Allow language discovery (15 seconds), recognition, and delivery to the UI.
    private var ocrSmokeTimeout: Duration { .seconds(OCRLimits().timeoutSeconds + 20) }

    private func testOCRToolbar(_ browser: ExplorerWindowController, image: URL, pdf: URL) async throws {
        let originalDirectory = browser.session.history.current.url
        browser.navigate(.visit(image.deletingLastPathComponent()))
        try await waitForListing(browser)
        guard let content = browser.window?.contentView else { throw SmokeFailure.failed("Missing Explorer window") }
        func visibleButton(_ id: String) -> NSButton? {
            descendants(of: content).compactMap { $0 as? NSButton }.first {
                $0.accessibilityIdentifier() == id && !$0.isHiddenOrHasHiddenAncestor
            }
        }
        let extractID = "explorer.toolbar.extractText", pdfID = "explorer.toolbar.searchablePDF"
        browser.table.deselectAll(nil)
        guard visibleButton(extractID) == nil, visibleButton(pdfID) == nil else {
            throw SmokeFailure.failed("Document actions visible without a selection")
        }
        func row(for source: URL) throws -> Int {
            let stem = source.deletingPathExtension().lastPathComponent
            guard let row = (0..<browser.table.numberOfRows).first(where: {
                let title = browser.tableView(browser.table, typeSelectStringFor: nil, row: $0)
                return title == source.lastPathComponent || title == stem
            }) else { throw SmokeFailure.failed("Missing toolbar fixture: \(source.lastPathComponent)") }
            return row
        }
        let imageRow = try row(for: image), pdfRow = try row(for: pdf)
        let originalExtract = browser.onExtractText, originalBatch = browser.onBatchOCR
        defer { browser.onExtractText = originalExtract; browser.onBatchOCR = originalBatch }
        var extracted: URL?, pdfSources: [URL] = []
        browser.onExtractText = { extracted = $0 }
        browser.onBatchOCR = { pdfSources = $0 }
        browser.table.selectRowIndexes(IndexSet(integer: imageRow), byExtendingSelection: false)
        guard let extract = visibleButton(extractID), extract.isEnabled,
              let singlePDF = visibleButton(pdfID), singlePDF.isEnabled else {
            throw SmokeFailure.failed("Missing OCR toolbar actions for an image")
        }
        extract.performClick(nil)
        singlePDF.performClick(nil)
        guard extracted?.standardizedFileURL == image.standardizedFileURL,
              pdfSources.map(\.standardizedFileURL) == [image.standardizedFileURL] else {
            throw SmokeFailure.failed("Single-file OCR toolbar action used the wrong selection")
        }
        browser.table.selectRowIndexes(IndexSet([imageRow, pdfRow]), byExtendingSelection: false)
        guard visibleButton(extractID) == nil, let multiplePDF = visibleButton(pdfID), multiplePDF.isEnabled else {
            throw SmokeFailure.failed("Incorrect OCR toolbar for a multiple selection")
        }
        multiplePDF.performClick(nil)
        guard Set(pdfSources.map(\.standardizedFileURL)) == Set([image.standardizedFileURL, pdf.standardizedFileURL]) else {
            throw SmokeFailure.failed("PDF toolbar action did not receive both selected documents")
        }
        browser.navigate(.visit(originalDirectory))
        try await waitForListing(browser)
    }

    private func testOCR(root: URL, arguments: [String]) async throws {
        let folder = root.appendingPathComponent("OCRSmoke", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { ocrViewer?.close(); try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("Texto 日本語.png"), pdf = folder.appendingPathComponent("Document.pdf")
        try makeOCRFixture(image, text: "MY EXPLORER OCR 2026", pdf: false)
        try makeOCRFixture(pdf, text: "PDF ORIGINAL TEXT 2026", pdf: true)
        let imageBefore = try Data(contentsOf: image), pdfBefore = try Data(contentsOf: pdf)
        let unavailableLanguages = OCRWindowController(discoverLanguages: { [] })
        unavailableLanguages.open(image)
        try await waitForCondition("OCR has no supported languages") { !unavailableLanguages.isRunning }
        guard unavailableLanguages.statusText == L10n.text("ocr.error.options") else { throw SmokeFailure.failed("Empty OCR language list was not handled") }
        unavailableLanguages.startRecognition(nil)
        try await waitForCondition("OCR language retry remains explicit") { !unavailableLanguages.isRunning }
        unavailableLanguages.close()
        guard let browser = controller else { throw SmokeFailure.failed("Missing OCR browser") }
        try await testOCRToolbar(browser, image: image, pdf: pdf)
        let entry = FileEntry(url: image, name: image.lastPathComponent, isDirectory: false)
        let menu = browser.table.menu!
        browser.rebuildContextMenu(menu, entries: [entry])
        guard let action = menu.items.first(where: { $0.action == #selector(ExplorerWindowController.extractText) }),
              browser.validateMenuItem(action) else { throw SmokeFailure.failed("Missing OCR context action") }
        browser.extractText(action)
        guard let viewer = ocrViewer else { throw SmokeFailure.failed("OCR context did not open viewer") }
        try await waitForCondition("OCR PNG result", timeout: ocrSmokeTimeout) { !viewer.isRunning }
        guard viewer.resultText.contains("EXPLORER"), viewer.resultText.contains("2026") else {
            throw SmokeFailure.failed("Image OCR did not find fixture anchors: \(viewer.statusText)")
        }
        viewer.copyText(nil)
        guard NSPasteboard.general.string(forType: .string) == viewer.resultText else { throw SmokeFailure.failed("OCR copy changed text") }
        let output = folder.appendingPathComponent("result.txt")
        try await OCRWindowController.exportText(viewer.resultText, to: output)
        guard try String(contentsOf: output, encoding: .utf8) == viewer.resultText else { throw SmokeFailure.failed("OCR TXT export mismatch") }
        do { try await OCRWindowController.exportText("overwrite", to: output); throw SmokeFailure.failed("OCR overwrote existing TXT") }
        catch is CocoaError { }
        viewer.window?.makeFirstResponder(viewer.textView)
        viewer.textView.insertText("Reviewed: ", replacementRange: NSRange(location: 0, length: 0))
        let text = viewer.resultText
        let searchable = folder.appendingPathComponent("image-searchable.pdf")
        viewer.startPDFExport(to: searchable)
        try await waitForCondition("GUI searchable image PDF", timeout: ocrSmokeTimeout) { !viewer.isRunning }
        guard viewer.exportedPDFURL == searchable, viewer.statusText == L10n.text("ocr.pdf_saved"),
              viewer.resultText == text, let searchableDocument = PDFDocument(url: searchable),
              searchableDocument.pageCount == 1, !searchableDocument.findString("EXPLORER", withOptions: []).isEmpty,
              searchableDocument.string?.contains("Reviewed:") == false else {
            throw SmokeFailure.failed("Searchable PDF did not use original image geometry/text: \(viewer.statusText)")
        }
        let searchableBefore = try Data(contentsOf: searchable)
        viewer.startPDFExport(to: searchable)
        try await waitForCondition("GUI searchable PDF refuses overwrite") { !viewer.isRunning }
        guard viewer.statusText == L10n.text("ocr.pdf_exists"), viewer.exportedPDFURL == nil,
              try Data(contentsOf: searchable) == searchableBefore else { throw SmokeFailure.failed("Searchable PDF overwrote destination") }
        let cancelledPDF = folder.appendingPathComponent("cancelled.pdf")
        viewer.startPDFExport(to: cancelledPDF); viewer.cancelRecognition(nil)
        try await waitForCondition("GUI searchable PDF cancellation") { !viewer.isRunning }
        guard !FileManager.default.fileExists(atPath: cancelledPDF.path), viewer.resultText == text,
              viewer.statusText == L10n.text("cloud.error.cancelled") else { throw SmokeFailure.failed("Cancelled PDF published output or lost edited text") }
        for language in AppLanguage.allCases where language != .system {
            changeLanguage(language)
            guard viewer.resultText == text, viewer.window?.title.contains(L10n.text("ocr.title")) == true,
                  !viewer.languagePicker.itemTitles.contains("ocr.automatic") else { throw SmokeFailure.failed("OCR localization lost result") }
        }
        changeLanguage(.portuguese)
        viewer.open(image); viewer.cancelRecognition(nil)
        try await Task.sleep(for: .milliseconds(150))
        guard !viewer.isRunning, viewer.resultText.isEmpty, viewer.textView.undoManager?.canUndo != true else { throw SmokeFailure.failed("Cancelled OCR published a result or retained prior Undo") }
        viewer.open(image); viewer.open(pdf)
        try await waitForCondition("OCR PDF supersedes image") { !viewer.isRunning }
        guard viewer.resultText.contains("PDF ORIGINAL TEXT"), !viewer.resultText.contains("EXPLORER") else { throw SmokeFailure.failed("OCR stale image replaced PDF") }
        let textPDF = folder.appendingPathComponent("text-searchable.pdf")
        viewer.startPDFExport(to: textPDF)
        try await waitForCondition("GUI PDF with existing text") { !viewer.isRunning }
        guard viewer.exportedPDFURL == textPDF, let textDocument = PDFDocument(url: textPDF),
              textDocument.findString("PDF ORIGINAL TEXT", withOptions: []).count == 1 else { throw SmokeFailure.failed("PDF text was lost or duplicated") }
        if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1), let content = viewer.window?.contentView {
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let path = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path + "-ocr.png"
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        let preview = PreviewPaneController(); var previewRequested = false
        preview.onExtractText = { previewRequested = $0 == pdf }
        preview.update(entries: [FileEntry(url: pdf, name: pdf.lastPathComponent, isDirectory: false)])
        guard let button = descendants(of: preview.view).first(where: { $0.accessibilityIdentifier() == "explorer.preview.ocr" }) as? NSButton,
              button.isEnabled else { throw SmokeFailure.failed("Missing OCR preview action") }
        button.performClick(nil); preview.closePreview()
        guard previewRequested else { throw SmokeFailure.failed("Preview OCR did not use selected PDF") }
        let media = MediaViewerWindowController(); var mediaRequested = false
        media.onExtractText = { mediaRequested = $0 == image }
        media.open(entries: [entry], selectedURL: image)
        try await waitForCondition("OCR image viewer action") { media.imageLoaded }
        guard let mediaContent = media.window?.contentView,
              let mediaOCR = descendants(of: mediaContent).first(where: { $0.accessibilityIdentifier() == "explorer.media.ocr" }) as? NSButton,
              mediaOCR.isEnabled else { throw SmokeFailure.failed("Missing OCR image viewer action") }
        mediaOCR.performClick(nil); media.close()
        guard mediaRequested else { throw SmokeFailure.failed("Image viewer OCR used wrong file") }
        viewer.window?.makeKeyAndOrderFront(nil)
        guard let content = viewer.window?.contentView,
              let save = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "explorer.ocr.save" }) as? NSButton else { throw SmokeFailure.failed("Missing OCR save button") }
        save.performClick(nil)
        try await waitForCondition("OCR save panel") { viewer.window?.attachedSheet != nil }
        viewer.open(image)
        try await waitForCondition("OCR save panel cancelled by new document") { viewer.window?.attachedSheet == nil }
        try await waitForCondition("OCR ready for searchable PDF save panel", timeout: ocrSmokeTimeout) { !viewer.isRunning }
        guard let pdfSave = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "explorer.ocr.pdf" }) as? NSButton,
              pdfSave.isEnabled, pdfSave.title == L10n.text("ocr.pdf_save") else { throw SmokeFailure.failed("Missing searchable PDF button") }
        pdfSave.performClick(nil)
        try await waitForCondition("Searchable PDF save panel") { viewer.window?.attachedSheet != nil }
        viewer.open(pdf)
        try await waitForCondition("Searchable PDF panel invalidated by new source") { viewer.window?.attachedSheet == nil }
        try await waitForCondition("OCR ready for close during PDF export", timeout: ocrSmokeTimeout) { !viewer.isRunning }
        let closedPDF = folder.appendingPathComponent("closed.pdf")
        viewer.startPDFExport(to: closedPDF)
        let started = ContinuousClock.now
        viewer.close()
        guard started.duration(to: .now) < .milliseconds(250) else { throw SmokeFailure.failed("Closing OCR blocked interface") }
        try await Task.sleep(for: .milliseconds(150))
        guard viewer.window?.isVisible == false, !viewer.isRunning, controller?.window?.isVisible == true,
              !FileManager.default.fileExists(atPath: closedPDF.path),
              try Data(contentsOf: image) == imageBefore, try Data(contentsOf: pdf) == pdfBefore else {
            throw SmokeFailure.failed("OCR close/original preservation failed")
        }
        for denied in [FileEntry(url: root, name: "folder", isDirectory: true),
                       FileEntry(url: RemoteLocation.url(connectionID: UUID(), key: "image.png"), name: "remote.png", isDirectory: false),
                       FileEntry(url: image, name: "alias.png", isDirectory: false, isAlias: true)] {
            guard !ExplorerWindowController.canExtractText([denied]) else { throw SmokeFailure.failed("OCR allowed unsupported entry") }
        }
    }

    private func testOCRBatch(root: URL, arguments: [String]) async throws {
        let folder = root.appendingPathComponent("BatchOCRSmoke", isDirectory: true)
        let destination = folder.appendingPathComponent("Results", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { ocrBatchViewer?.close(); try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("Photo.png"), pdf = folder.appendingPathComponent("Photo.pdf"), broken = folder.appendingPathComponent("Broken.pdf")
        try makeOCRFixture(image, text: "BATCH IMAGE 2048", pdf: false)
        try makeOCRFixture(pdf, text: "BATCH PDF 2048", pdf: true)
        try Data("invalid PDF fixture".utf8).write(to: broken)
        let urls = [image, pdf, broken], before = try [image, pdf, broken].map { try Data(contentsOf: $0) }
        let existing = destination.appendingPathComponent("Photo-OCR.pdf")
        try Data("existing output must survive".utf8).write(to: existing)
        guard let browser = controller else { throw SmokeFailure.failed("Missing batch browser") }
        let entries = urls.map { FileEntry(url: $0, name: $0.lastPathComponent, isDirectory: false) }
        let menu = browser.table.menu!
        browser.rebuildContextMenu(menu, entries: entries)
        guard let action = menu.items.first(where: { $0.action == #selector(ExplorerWindowController.batchOCR) }), browser.validateMenuItem(action),
              !ExplorerWindowController.canExtractText(entries), !ExplorerWindowController.canBatchOCR(Array(repeating: entries[0], count: 51)) else {
            throw SmokeFailure.failed("Batch selection eligibility/menu incorrect")
        }
        browser.batchOCR(action)
        guard let batch = ocrBatchViewer else { throw SmokeFailure.failed("Batch context action did not open window") }
        try await waitForCondition("Batch language discovery") { batch.languagePicker.numberOfItems > 1 }
        batch.setDestination(destination); batch.startBatch(nil)
        try await waitForCondition("Batch mixed results") { !batch.isRunning }
        guard let report = batch.report, report.items.count == 3,
              report.items.map(\.state) == [.succeeded, .succeeded, .failed],
              report.items[0].destinationURL?.lastPathComponent == "Photo-OCR (2).pdf",
              report.items[1].destinationURL?.lastPathComponent == "Photo-OCR (3).pdf" else {
            throw SmokeFailure.failed("Batch did not retain partial results or unique names: \(batch.statusText)")
        }
        for (index, text) in [(0, "BATCH IMAGE"), (1, "BATCH PDF")] {
            guard let url = report.items[index].destinationURL, let document = PDFDocument(url: url),
                  !document.findString(text, withOptions: []).isEmpty else { throw SmokeFailure.failed("Batch output is not searchable") }
        }
        guard try Data(contentsOf: existing) == Data("existing output must survive".utf8), try urls.map({ try Data(contentsOf: $0) }) == before else {
            throw SmokeFailure.failed("Batch changed originals/existing destination")
        }
        for language in AppLanguage.allCases where language != .system {
            changeLanguage(language)
            guard batch.report == report, batch.window?.title == L10n.text("ocr.batch.title"), batch.table.numberOfRows == 3 else {
                throw SmokeFailure.failed("Batch language rebuild lost report")
            }
        }
        changeLanguage(.german); ExplorerStyle.preferences.setFontSize(24, for: .bars)
        if let content = batch.window?.contentView {
            content.layoutSubtreeIfNeeded()
            for view in descendants(of: content) where view.accessibilityIdentifier().hasPrefix("explorer.ocr.batch.") == true && view is NSButton {
                let rect = view.convert(view.bounds, to: content)
                guard content.bounds.insetBy(dx: -1, dy: -1).contains(rect) else { throw SmokeFailure.failed("Large-font German batch controls clipped") }
            }
        }
        ExplorerStyle.preferences.resetFonts(); changeLanguage(.portuguese)
        if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1), let content = batch.window?.contentView {
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let file = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path + "-ocr-batch.png"
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
            }
        }
        let cancelled = folder.appendingPathComponent("Cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelled, withIntermediateDirectories: false)
        batch.setDestination(cancelled); batch.startBatch(nil); batch.cancelBatch(nil)
        try await waitForCondition("Batch immediate cancellation") { !batch.isRunning }
        guard batch.report?.items.allSatisfy({ $0.state == .notStarted || $0.state == .cancelled }) == true,
              try FileManager.default.contentsOfDirectory(atPath: cancelled.path).isEmpty else { throw SmokeFailure.failed("Cancelled batch wrote output") }
        batch.startBatch(nil); batch.open([pdf]) // Running selection must remain stable.
        guard batch.table.numberOfRows == 3 else { throw SmokeFailure.failed("New selection replaced active batch") }
        let start = ContinuousClock.now; batch.close()
        guard start.duration(to: .now) < .milliseconds(250) else { throw SmokeFailure.failed("Batch close blocked UI") }
        try await Task.sleep(for: .milliseconds(150))
        guard try FileManager.default.contentsOfDirectory(atPath: cancelled.path).isEmpty else { throw SmokeFailure.failed("Closed pre-start batch published output") }
        batch.open(urls)
        try await waitForCondition("Batch rediscovery") { batch.languagePicker.numberOfItems > 1 }
        guard let content = batch.window?.contentView,
              let choose = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "explorer.ocr.batch.choose" }) as? NSButton else {
            throw SmokeFailure.failed("Missing batch destination chooser")
        }
        choose.performClick(nil)
        try await waitForCondition("Batch output folder chooser") { batch.window?.attachedSheet != nil }
        batch.close()
        try await waitForCondition("Batch chooser closes with window") { batch.window?.attachedSheet == nil }
        for denied in [FileEntry(url: folder, name: "folder", isDirectory: true), FileEntry(url: image, name: "alias", isDirectory: false, isAlias: true)] {
            guard !ExplorerWindowController.canBatchOCR([entries[0], denied]) else { throw SmokeFailure.failed("Batch allowed invalid mixed selection") }
        }
    }

    private func testAutomation(root: URL) async throws {
        let area = root.appendingPathComponent("AutomationSmoke", isDirectory: true)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: area) }
        let socket = area.appendingPathComponent("broker.sock")
        try await AppAutomation.shared.start(directory: area, socketURL: socket)
        guard let service = AppAutomation.shared.service else { throw SmokeFailure.failed("Missing automation service") }
        let token = "fixture-only-automation-token"
        let canonical = area.resolvingSymlinksInPath()
        let grant = AutomationGrant(name: "Fixture client", token: token, expires: Date().addingTimeInterval(60), operations: ["read", "copy", "preferences"], localRoots: [canonical.path], cloudScopes: [], recursive: true)
        try await service.grant(grant); try await service.setEnabled(true)
        for language: AppLanguage in [.english, .german, .japanese, .portuguese] {
            changeLanguage(language)
            guard let menu = NSApp.mainMenu?.item(withTitle: L10n.text("menu.view"))?.submenu,
                  menu.item(withTitle: L10n.text("automation.title")) == nil,
                  let options = menu.item(withTitle: L10n.text("options.title")), let action = options.action,
                  NSApp.sendAction(action, to: options.target, from: options),
                  let optionsContent = optionsSettings?.window?.contentView,
                  let tabs = descendants(of: optionsContent).compactMap({ $0 as? NSTabView }).first,
                  let integrations = tabs.tabViewItems.first(where: { $0.label == L10n.text("options.integrations") }) else {
                throw SmokeFailure.failed("Missing Options → Integrations path")
            }
            tabs.selectTabViewItem(integrations)
            guard let page = integrations.view,
                  let connect = descendants(of: page).first(where: { $0.accessibilityIdentifier() == "options.connectAssistant" }) as? NSButton,
                  connect.isEnabled, !connect.isHiddenOrHasHiddenAncestor, connect.title == L10n.text("automation.title") else {
                throw SmokeFailure.failed("Missing connect assistant action in the selected tab")
            }
            connect.performClick(nil)
            guard let window = automationSettings?.window, let content = window.contentView,
                  window.title == L10n.text("automation.title"),
                  let create = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "automation.create" }) as? NSButton,
                  create.title == L10n.text("automation.create"),
                  let ocrPermission = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "automation.permission.files.ocr" }) as? NSButton,
                  ocrPermission.state == .off, ocrPermission.title == L10n.text("automation.ocr"),
                  let pdfPermission = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "automation.permission.files.ocr.pdf" }) as? NSButton,
                  pdfPermission.state == .off, pdfPermission.title == L10n.text("automation.ocr_pdf") else { throw SmokeFailure.failed("Missing translated automation controls or OCR granted by default") }
            content.layoutSubtreeIfNeeded()
            if language == .portuguese {
                guard let name = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "automation.client" }) as? NSTextField else { throw SmokeFailure.failed("Missing client field") }
                name.stringValue = "GUI fixture"
                create.performClick(nil)
                for _ in 0..<100 {
                    if await service.grants().count == 2 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard await service.grants().count == 2,
                      FileManager.default.fileExists(atPath: area.appendingPathComponent("clients").path) else { throw SmokeFailure.failed("GUI grant was not created in isolated storage") }
                if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--preview"), ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                    let file = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1]).deletingPathExtension().path + "-automation.png"
                    content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
                    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                    }
                }
            }
        }
        automationSettings?.close(); automationSettings = nil
        optionsSettings?.close()
        let config = area.appendingPathComponent("client.json"), tokenFile = area.appendingPathComponent("token")
        try Data(token.utf8).write(to: tokenFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        let data = try JSONSerialization.data(withJSONObject: ["socketPath": socket.path, "clientID": grant.id.uuidString, "tokenFile": tokenFile.path])
        try data.write(to: config)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/myexplorer-cli")
        func call(_ method: String, _ arguments: JSONValue) async throws -> AutomationResponse {
            let input = try JSONEncoder().encode(arguments)
            let output = try await Self.helper(helper, arguments: ["--config", config.path, "call", method], input: input)
            return try JSONDecoder().decode(AutomationResponse.self, from: output)
        }
        let listed = try await call("locations.list", .object(["url": .string(canonical.absoluteString)]))
        guard listed.ok else { throw SmokeFailure.failed("Signed CLI did not reach broker: \(listed.error ?? "unknown")") }
        let outside = try await call("locations.list", .object(["url": .string(root.deletingLastPathComponent().absoluteString)]))
        guard !outside.ok, outside.error == "forbidden" else { throw SmokeFailure.failed("Automation escaped authorized root") }
        let source = canonical.appendingPathComponent("source.txt"), destination = canonical.appendingPathComponent("Output")
        try Data("automation bytes".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let plan = try await call("transfers.plan", .object(["sources": .array([.string(source.absoluteString)]), "destination": .string(destination.absoluteString)]))
        guard plan.ok, let planID = plan.result?["planID"]?.stringValue else { throw SmokeFailure.failed("CLI plan failed") }
        let started = try await call("transfers.start", .object(["planID": .string(planID), "idempotencyKey": .string("smoke-copy")]))
        guard started.ok, let jobID = started.result?["id"]?.stringValue else { throw SmokeFailure.failed("CLI copy did not start") }
        var succeeded = false
        for _ in 0..<100 {
            let response = try await call("transfers.status", .object(["jobID": .string(jobID)]))
            if response.result?["state"]?.stringValue == "succeeded" { succeeded = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard succeeded, try Data(contentsOf: destination.appendingPathComponent("source.txt")) == Data("automation bytes".utf8) else { throw SmokeFailure.failed("Broker copy failed") }
        let ocrPDF = canonical.appendingPathComponent("OCR.pdf")
        try makeOCRFixture(ocrPDF, text: "AUTOMATION OCR FIXTURE", pdf: true)
        let oldGrantOCR = try await call("files.ocr", .object(["url": .string(ocrPDF.absoluteString)]))
        guard !oldGrantOCR.ok else { throw SmokeFailure.failed("Legacy read grant allowed OCR payload access") }
        let ocrGrant = AutomationGrant(id: grant.id, name: grant.name, token: token, expires: Date().addingTimeInterval(60),
            operations: ["read", "copy", "preferences", "files.ocr"], localRoots: [canonical.path], cloudScopes: [], recursive: true)
        try await service.grant(ocrGrant)
        let searchablePDF = canonical.appendingPathComponent("CLI-searchable.pdf")
        let pdfArguments: JSONValue = .object(["url": .string(ocrPDF.absoluteString), "destination": .string(searchablePDF.absoluteString)])
        let legacyPDF = try await call("files.ocr.pdf", pdfArguments)
        guard !legacyPDF.ok, !FileManager.default.fileExists(atPath: searchablePDF.path) else { throw SmokeFailure.failed("Text-only OCR grant allowed PDF write") }
        let pdfGrant = AutomationGrant(id: grant.id, name: grant.name, token: token, expires: Date().addingTimeInterval(60),
            operations: ["read", "copy", "preferences", "files.ocr", "files.ocr.pdf"], localRoots: [canonical.path], cloudScopes: [], recursive: true)
        try await service.grant(pdfGrant)
        let languageResponse = try await call("ocr.languages", .object([:]))
        guard languageResponse.ok else { throw SmokeFailure.failed("CLI OCR language discovery failed") }
        let cliOCR = try await Self.helper(helper, arguments: ["--config", config.path, "ocr", ocrPDF.path, "--language", "en", "--pages", "1:1"], input: Data())
        let ocrStarted = try JSONDecoder().decode(AutomationResponse.self, from: cliOCR)
        guard ocrStarted.ok, let ocrJob = ocrStarted.result?["id"]?.stringValue else { throw SmokeFailure.failed("CLI OCR did not start") }
        var ocrSucceeded = false
        for _ in 0..<150 {
            let response = try await call("ocr.status", .object(["jobID": .string(ocrJob)]))
            if response.result?["state"]?.stringValue == "succeeded" {
                let result = response.result?["result"]
                let encoded = try JSONEncoder().encode(result)
                guard String(data: encoded, encoding: .utf8)?.contains("AUTOMATION OCR FIXTURE") == true else { throw SmokeFailure.failed("CLI OCR text mismatch") }
                ocrSucceeded = true; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard ocrSucceeded else { throw SmokeFailure.failed("CLI OCR job did not finish") }
        let outsideOCR = try await call("files.ocr", .object(["url": .string(root.appendingPathComponent("Example.pdf").absoluteString)]))
        guard !outsideOCR.ok else { throw SmokeFailure.failed("OCR escaped authorized root") }
        let cliPDF = try await Self.helper(helper, arguments: ["--config", config.path, "ocr", "pdf", ocrPDF.path, "--output", searchablePDF.path, "--language", "en"], input: Data())
        let pdfStarted = try JSONDecoder().decode(AutomationResponse.self, from: cliPDF)
        guard pdfStarted.ok, let pdfJob = pdfStarted.result?["id"]?.stringValue else { throw SmokeFailure.failed("CLI searchable PDF did not start") }
        var pdfSucceeded = false
        for _ in 0..<150 {
            let response = try await call("ocr.status", .object(["jobID": .string(pdfJob)]))
            if response.result?["state"]?.stringValue == "succeeded" { pdfSucceeded = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard pdfSucceeded, let cliDocument = PDFDocument(url: searchablePDF),
              cliDocument.findString("AUTOMATION OCR FIXTURE", withOptions: []).count == 1 else { throw SmokeFailure.failed("CLI searchable PDF failed") }
        let outsidePDF = try await call("files.ocr.pdf", .object(["url": .string(ocrPDF.absoluteString), "destination": .string(root.appendingPathComponent("outside-ocr.pdf").absoluteString)]))
        guard !outsidePDF.ok else { throw SmokeFailure.failed("PDF export escaped destination scope") }
        let batchImage = canonical.appendingPathComponent("Batch.png")
        try makeOCRFixture(batchImage, text: "BATCH AUTOMATION 2048", pdf: false)
        let batchDirectory = canonical.appendingPathComponent("CLIBatch", isDirectory: true)
        try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: false)
        let cliBatch = try await Self.helper(helper, arguments: ["--config", config.path, "ocr", "batch", ocrPDF.path, batchImage.path,
            "--output-directory", batchDirectory.path, "--language", "en"], input: Data())
        let batchStarted = try JSONDecoder().decode(AutomationResponse.self, from: cliBatch)
        guard batchStarted.ok, let batchJob = batchStarted.result?["id"]?.stringValue else { throw SmokeFailure.failed("CLI OCR batch did not start") }
        var batchFinished = false
        for _ in 0..<150 {
            let response = try await call("ocr.status", .object(["jobID": .string(batchJob)]))
            if response.result?["state"]?.stringValue == "succeeded" {
                guard response.result?["result"]?["items"]?.arrayValue?.count == 2 else { throw SmokeFailure.failed("CLI batch missing per-file results") }
                batchFinished = true; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard batchFinished, let batchDocument = PDFDocument(url: batchDirectory.appendingPathComponent("Batch-OCR.pdf")),
              !batchDocument.findString("BATCH AUTOMATION", withOptions: []).isEmpty else { throw SmokeFailure.failed("CLI batch PDF is not searchable") }
        let mcpPDF = canonical.appendingPathComponent("MCP-searchable.pdf")
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Smoke", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "capabilities_get", "arguments": [:]]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "ocr_status", "arguments": ["jobID": ocrJob]]],
            ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "files_ocr_pdf", "arguments": ["url": ocrPDF.absoluteString, "destination": mcpPDF.absoluteString]]]
        ]
        var input = Data()
        for message in messages { input.append(try JSONSerialization.data(withJSONObject: message)); input.append(10) }
        let output = try await Self.helper(helper, arguments: ["mcp", "--config", config.path], input: input)
        let responses = try output.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        guard responses.count == 5, responses.allSatisfy({ $0?["error"] == nil }), String(data: output, encoding: .utf8)?.contains(token) == false,
              String(data: output, encoding: .utf8)?.contains("files_ocr_pdf") == true,
              String(data: output, encoding: .utf8)?.contains("AUTOMATION OCR FIXTURE") == true else {
            throw SmokeFailure.failed("MCP handshake/tools call failed or leaked credentials")
        }
        try await waitForCondition("MCP searchable PDF publication") { FileManager.default.fileExists(atPath: mcpPDF.path) }
        guard let mcpDocument = PDFDocument(url: mcpPDF), mcpDocument.findString("AUTOMATION OCR FIXTURE", withOptions: []).count == 1 else {
            throw SmokeFailure.failed("MCP searchable PDF text mismatch")
        }
        let mcpBatchDirectory = canonical.appendingPathComponent("MCPBatch", isDirectory: true)
        try FileManager.default.createDirectory(at: mcpBatchDirectory, withIntermediateDirectories: false)
        let batchMessages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "BatchSmoke", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "files_ocr_pdf_batch", "arguments": ["urls": [ocrPDF.absoluteString, batchImage.absoluteString], "destination": mcpBatchDirectory.absoluteString]]]
        ]
        var batchInput = Data()
        for message in batchMessages { batchInput.append(try JSONSerialization.data(withJSONObject: message)); batchInput.append(10) }
        let batchOutput = try await Self.helper(helper, arguments: ["mcp", "--config", config.path], input: batchInput)
        let batchResponses = try batchOutput.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        guard batchResponses.count == 2, let mcpBatchJob = batchResponses.last?["result"]?["structuredContent"]?["result"]?["id"]?.stringValue else {
            throw SmokeFailure.failed("MCP batch did not return job metadata")
        }
        var mcpBatchFinished = false
        for _ in 0..<150 {
            let response = try await call("ocr.status", .object(["jobID": .string(mcpBatchJob)]))
            if response.result?["state"]?.stringValue == "succeeded" { mcpBatchFinished = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard mcpBatchFinished, let mcpBatchDocument = PDFDocument(url: mcpBatchDirectory.appendingPathComponent("Batch-OCR.pdf")),
              !mcpBatchDocument.findString("BATCH AUTOMATION", withOptions: []).isEmpty else { throw SmokeFailure.failed("MCP batch output missing") }
        try await service.revoke(grant.id)
        let denied = try await call("locations.list", .object(["url": .string(canonical.absoluteString)]))
        guard !denied.ok else { throw SmokeFailure.failed("Revoked client retained access") }
        let deniedOCR = try await call("ocr.status", .object(["jobID": .string(ocrJob)]))
        guard !deniedOCR.ok else { throw SmokeFailure.failed("Revoked client retained OCR output") }
        await AppAutomation.shared.shutdown()
    }
    nonisolated private static func helper(_ executable: URL, arguments: [String], input: Data) async throws -> Data {
        try await Task.detached {
            let process = Process(), incoming = Pipe(), outgoing = Pipe(), errors = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = errors
            try process.run()
            try incoming.fileHandleForWriting.write(contentsOf: input); try incoming.fileHandleForWriting.close()
            let result = outgoing.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return result
        }.value
    }

    private func testS3Drag(_ browser: ExplorerWindowController) async throws {
        let transport = SmokeS3DragTransport()
        let accounts = CloudAccounts.shared
        accounts.clientFactory = { try CloudStorageClient(connection: $0, credentials: $1, transport: transport) }
        let settings = CloudConnection(name: "S3 drag", provider: .s3, bucket: "smoke-bucket", region: "us-east-1")
        let id = try await accounts.save(settings, credentials: .init(accessKeyID: "TEST", secretAccessKey: "fixture"))
        let root = RemoteLocation.url(connectionID: id)
        browser.navigate(.visit(root))
        try await waitForListing(browser)
        let folder = RemoteLocation.url(connectionID: id, key: "Sub Pasta/")
        let file = RemoteLocation.url(connectionID: id, key: "clip.mov")
        let rows = 0..<browser.numberOfRows(in: browser.table)
        func displayName(_ row: Int) -> String? {
            browser.tableView(browser.table, typeSelectStringFor: nil, row: row)
        }
        guard let source = rows.first(where: { displayName($0)?.hasPrefix("clip") == true }),
              let target = rows.first(where: { displayName($0) == "Sub Pasta" }),
              let writer = browser.tableView(browser.table, pasteboardWriterForRow: source) else {
            throw SmokeFailure.failed("Missing S3 drag source or folder")
        }
        let board = NSPasteboard(name: .init("MyExplorer.S3DragSmoke.\(UUID())"))
        defer { board.releaseGlobally() }
        guard board.writeObjects([writer]) else { throw SmokeFailure.failed("Missing S3 pasteboard payload") }
        let info = SmokeDraggingInfo(pasteboard: board, window: browser.window, source: browser.table)
        let external = SmokeDraggingInfo(pasteboard: board, window: browser.window)
        guard browser.tableView(browser.table, validateDrop: external, proposedRow: target, proposedDropOperation: .on).isEmpty else {
            throw SmokeFailure.failed("External S3 move accepted")
        }
        guard browser.tableView(browser.table, validateDrop: info, proposedRow: source, proposedDropOperation: .on).isEmpty else {
            throw SmokeFailure.failed("Same-directory S3 move accepted")
        }
        guard browser.tableView(browser.table, validateDrop: info, proposedRow: target, proposedDropOperation: .on) == .move else {
            throw SmokeFailure.failed("Folder did not accept an internal S3 move")
        }
        guard browser.tableView(browser.table, acceptDrop: info, row: target, dropOperation: .on) else {
            throw SmokeFailure.failed("S3 folder did not start move")
        }
        try await waitForCondition("source removed from bucket root") {
            !FileCommands.shared.isBusy && browser.session.entries.contains { $0.url == folder } &&
                !browser.session.entries.contains { $0.url == file }
        }
        browser.navigate(.visit(folder))
        try await waitForListing(browser)
        let destination = RemoteLocation.url(connectionID: id, key: "Sub Pasta/clip.mov")
        guard browser.session.entries.contains(where: { $0.url == destination }), await transport.didMoveFile else {
            throw SmokeFailure.failed("S3 destination missing or incorrect contents")
        }
        ExplorerStyle.browserPreferences.confirmDeletion = false
        browser.window?.makeKeyAndOrderFront(nil)
        browser.window?.makeFirstResponder(browser.table)
        browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try sendKey("", code: 117, flags: [], to: browser)
        try await waitForCondition("Delete removed S3 file and recorded undo") {
            !FileCommands.shared.isBusy && FileCommands.shared.undoKind == .trash && browser.session.entries.isEmpty
        }
        browser.window?.makeKeyAndOrderFront(nil)
        browser.window?.makeFirstResponder(browser.table)
        try sendKey("z", code: 6, flags: .control, to: browser)
        try await waitForCondition("Ctrl+Z restored S3 file") {
            !FileCommands.shared.isBusy && browser.session.entries.contains { $0.url == destination }
        }
        guard await transport.didMoveFile, FileCommands.shared.undoKind == nil else {
            throw SmokeFailure.failed("Ctrl+Z did not restore original contents")
        }

        let commands = FileCommands.shared
        let previousBoard = commands.pasteboard
        let clipboard = NSPasteboard(name: .init("MyExplorer.S3CutSmoke.\(UUID())"))
        commands.pasteboard = clipboard
        defer { commands.pasteboard = previousBoard; clipboard.releaseGlobally() }
        guard let menu = browser.table.menu,
              let selected = browser.session.entries.first(where: { $0.url == destination }) else {
            throw SmokeFailure.failed("Missing S3 context menu or source")
        }
        func performMenu(_ key: String, for entries: [FileEntry]) throws {
            browser.rebuildContextMenu(menu, entries: entries)
            guard let item = menu.item(withTitle: L10n.text(key)), let action = item.action,
                  browser.validateMenuItem(item), NSApp.sendAction(action, to: item.target, from: item) else {
                throw SmokeFailure.failed("Disabled or unhandled S3 context action: \(key)")
            }
        }
        try performMenu("command.cut_files", for: [selected])
        try await waitForCondition("cut S3 file available to paste in bucket root") { commands.canPaste(into: root) }
        guard !commands.canPaste(into: folder), !commands.canPaste(into: RemoteLocation.url(connectionID: UUID())),
              await transport.didMoveFile else { throw SmokeFailure.failed("Invalid S3 cut destination or premature mutation") }
        browser.navigate(.visit(root))
        try await waitForListing(browser)
        browser.window?.makeKeyAndOrderFront(nil)
        browser.window?.makeFirstResponder(browser.table)
        try sendKey("v", code: 9, flags: .command, to: browser)
        try await waitForCondition("Command+V moved S3 file to bucket root") {
            !commands.isBusy && commands.pasteURLs.isEmpty && browser.session.entries.contains { $0.url == file }
        }
        guard let fileRow = (0..<browser.table.numberOfRows).first(where: { displayName($0)?.hasPrefix("clip") == true }),
              let folderEntry = browser.session.entries.first(where: { $0.url == folder }) else {
            throw SmokeFailure.failed("Missing S3 file or destination folder")
        }
        browser.window?.makeKeyAndOrderFront(nil)
        browser.window?.makeFirstResponder(browser.table)
        browser.table.selectRowIndexes(IndexSet(integer: fileRow), byExtendingSelection: false)
        try sendKey("x", code: 7, flags: .control, to: browser)
        try await waitForCondition("Ctrl+X prepared S3 file") { commands.canPaste(into: folder) }
        try performMenu("command.paste_files", for: [folderEntry])
        try await waitForCondition("context paste moved S3 file into selected folder") {
            !commands.isBusy && commands.pasteURLs.isEmpty && !browser.session.entries.contains { $0.url == file }
        }
        guard await transport.didMoveFile else { throw SmokeFailure.failed("Unexpected S3 contents after cut and paste") }
    }

    private func testS3FolderMenu(_ browser: ExplorerWindowController) async throws {
        let accounts = CloudAccounts.shared
        let transport = SmokeCloudListingTransport()
        accounts.clientFactory = { try CloudStorageClient(connection: $0, credentials: $1, transport: transport) }
        let connection = CloudConnection(name: "S3 fixture", provider: .s3, bucket: "smoke-bucket", region: "us-east-1")
        let id = try await accounts.save(connection, credentials: .init(accessKeyID: "TEST", secretAccessKey: "fixture"))
        let local = browser.session.history.current.url
        let cases = [(RemoteLocation.url(connectionID: id), true), (RemoteLocation.url(connectionID: id, key: "folder/"), true),
                     (URL(string: "myexplorer-cloud:///")!, false), (local, true)]
        guard let menu = browser.table.menu, let window = browser.window else { throw SmokeFailure.failed("Missing table menu") }
        for (url, enabled) in cases {
            browser.navigate(.visit(url))
            try await waitForListing(browser)
            browser.rebuildContextMenu(menu, entries: [])
            guard let item = menu.item(withTitle: L10n.text("command.new_folder")), let action = item.action,
                  browser.validateMenuItem(item) == enabled else { throw SmokeFailure.failed("Incorrect New Folder availability") }
            if enabled {
                NSApp.sendAction(action, to: item.target, from: item)
                try await waitForCondition("folder name prompt") { window.attachedSheet != nil }
                if let location = RemoteLocation.parse(url) {
                    guard let sheet = window.attachedSheet, let content = sheet.contentView,
                          let name = descendants(of: content).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable })
                    else { throw SmokeFailure.failed("Missing folder name field") }
                    name.stringValue = "NewFolderSmoke"
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    let expected = RemoteLocation.url(connectionID: id, key: location.key + "NewFolderSmoke/")
                    try await waitForCondition("new S3 folder in listing") {
                        browser.session.entries.contains { $0.isDirectory && $0.url == expected }
                    }
                } else {
                    window.endSheet(window.attachedSheet!, returnCode: .alertSecondButtonReturn)
                    try await waitForCondition("cancel folder creation") { window.attachedSheet == nil }
                }
            }
        }
    }

    private func testCloudReconnect(_ browser: ExplorerWindowController) async throws {
        let accounts = CloudAccounts.shared
        let backend = SmokeCloudListingTransport()
        accounts.clientFactory = { try CloudStorageClient(connection: $0, credentials: $1, transport: backend) }
        let settings = CloudConnection(name: "S3 smoke", provider: .s3, bucket: "smoke-bucket", region: "us-east-1")
        let creds = CloudCredentials(accessKeyID: "SMOKE", secretAccessKey: "MOCK")
        let id = try await accounts.save(settings, credentials: creds, reuseExistingS3: true)
        let root = RemoteLocation.url(connectionID: id)
        let localTab = browser.workspace.activeID!
        let cloudTab = browser.addTab(at: RemoteLocation.url(connectionID: id, key: "folder/"))
        browser.selectTab(id: localTab)
        browser.openConnectedBucket(root)
        guard browser.workspace.activeID == cloudTab.id, browser.workspace.tabs.count == 2,
              browser.session.history.current.url == RemoteLocation.url(connectionID: id, key: "folder/") else {
            throw SmokeFailure.failed("Reconnecting lost the open folder or created another tab")
        }
        let outline = browser.tree.outline
        guard let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? FolderNode)?.url == root }),
              let menu = outline.contextMenuForRow?(row), let item = menu.item(withTitle: L10n.text("volume.disconnect")),
              let action = item.action, let window = browser.window else { throw SmokeFailure.failed("Missing disconnect action") }
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn] {
            NSApp.sendAction(action, to: item.target, from: item)
            try await waitForCondition("disconnect sheet") { window.attachedSheet != nil }
            window.endSheet(window.attachedSheet!, returnCode: response)
            try await waitForCondition("disconnect sheet dismissed") { window.attachedSheet == nil }
            if response == .alertFirstButtonReturn && accounts.connections.isEmpty { throw SmokeFailure.failed("Cancel removed connection") }
        }
        try await waitForCondition("disconnect finished") { accounts.connections.isEmpty && browser.workspace.tabs.count == 1 }
        guard browser.workspace.activeID == localTab else { throw SmokeFailure.failed("Disconnect affected local tab") }
    }

    private func testCloudConnections(root: URL) async throws {
        guard let defaultsName = smokeDefaultsName, let defaults = UserDefaults(suiteName: defaultsName),
              let original = controller, let localID = original.workspace.activeID,
              CloudAccounts.shared.connections.isEmpty else { throw SmokeFailure.failed("Cloud smoke was not isolated") }
        let accounts = CloudAccounts.shared
        let overview = URL(string: "myexplorer-cloud:///")!
        original.navigate(.visit(overview)); try await waitForListing(original)
        guard original.table.numberOfRows == 0, original.session.history.current.url == overview else { throw SmokeFailure.failed("Empty cloud group retained previous directory rows") }
        original.navigate(.visit(root)); try await waitForListing(original)
        let transport = SmokeCloudListingTransport()
        accounts.clientFactory = { connection, credentials in
            try CloudStorageClient(connection: connection, credentials: credentials, transport: transport)
        }
        let connections = [
            CloudConnection(name: "Smoke S3", provider: .s3, bucket: "smoke-s3", region: "us-east-1"),
            CloudConnection(name: "Smoke Azure", provider: .azure, bucket: "smoke-container", account: "smokeaccount"),
            CloudConnection(name: "Smoke GCS", provider: .gcs, bucket: "smoke-gcs")
        ]
        let credentials = CloudCredentials(accessKeyID: "SMOKEACCESSKEY", secretAccessKey: "SMOKESECRET",
                                          sasToken: "sv=2023-11-03&sp=rl&sig=SMOKESAS", accessToken: "SMOKETOKEN")
        defer {
            cloudSettings?.close(); cloudSettings = nil
            for connection in connections { try? accounts.remove(connection.id) }
            accounts.clientFactory = nil
        }
        for connection in connections { try await accounts.save(connection, credentials: credentials) }
        let restored = CloudAccounts(defaults: defaults, useKeychain: false)
        guard Set(restored.connections.map(\.id)) == Set(connections.map(\.id)),
              let metadata = defaults.data(forKey: "cloudConnections"),
              let encoded = String(data: metadata, encoding: .utf8),
              !["SMOKESECRET", "SMOKESAS", "SMOKETOKEN"].contains(where: encoded.contains) else {
            throw SmokeFailure.failed("Cloud metadata did not preserve IDs or contained credentials")
        }
        let outline = original.tree.outline
        guard let cloudGroup = (0..<outline.numberOfRows).compactMap({ outline.item(atRow: $0) as? FolderNode }).first(where: \.isGroup) else {
            throw SmokeFailure.failed("Missing cloud tree group")
        }
        outline.expandItem(cloudGroup)
        guard Set(cloudGroup.children?.compactMap { RemoteLocation.parse($0.url)?.connectionID } ?? []) == Set(connections.map(\.id)) else {
            throw SmokeFailure.failed("Cloud tree did not show all connection IDs")
        }
        var objectIDs = Set<String>()
        for connection in connections {
            let location = RemoteLocation.url(connectionID: connection.id)
            let tab = original.addTab(at: location)
            try await waitForListing(original)
            guard original.session.history.current.url == location, original.table.numberOfRows == 2,
                  let entry = original.session.entries.first(where: { !$0.isDirectory }),
                  entry.name == "same.txt", RemoteLocation.parse(entry.url)?.connectionID == connection.id else {
                throw SmokeFailure.failed("Fake cloud listing failed for \(connection.provider.rawValue)")
            }
            objectIDs.insert(entry.id)
            original.closeTab(id: tab.id)
        }
        guard objectIDs.count == 3 else { throw SmokeFailure.failed("Objects from different connections share an identity") }
        original.selectTab(id: localID)
        try await testCloudClipboard(root: root, connection: connections[0], transport: transport)
        guard original.onManageCloud != nil else { throw SmokeFailure.failed("Missing cloud toolbar callback") }
        original.onManageCloud?()
        guard let settings = cloudSettings, let window = settings.window, let content = window.contentView,
              window.isVisible,
              let secret = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "cloud.secret" }) as? NSSecureTextField,
              let name = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "cloud.name" }) as? NSTextField else {
            throw SmokeFailure.failed("Cloud connection form did not open")
        }
        try await testS3CredentialImport(settings)
        secret.stringValue = "draft-smoke-secret"
        name.stringValue = "Draft connection"
        changeLanguage(.german)
        guard cloudSettings === settings, settings.window === window, window.title == L10n.text("cloud.manage"),
              secret.stringValue == "draft-smoke-secret", name.stringValue == "Draft connection",
              let saved = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "cloud.connections" }) as? NSPopUpButton,
              saved.item(at: 0)?.title == L10n.text("cloud.new") else {
            throw SmokeFailure.failed("Language switch lost cloud form draft or labels")
        }
        settings.close()
        changeLanguage(.portuguese)
        guard let rebuilt = controller, rebuilt.onManageCloud != nil else { throw SmokeFailure.failed("Cloud callback lost after rebuild") }
        rebuilt.onManageCloud?()
        guard cloudSettings?.window?.isVisible == true, cloudSettings !== settings,
              NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).contains(where: { $0.action == #selector(showCloudSettings) }) == true else {
            throw SmokeFailure.failed("Cloud menu or reopened form is missing")
        }
        cloudSettings?.close()
        rebuilt.window?.makeKeyAndOrderFront(nil)
        guard rebuilt.session.history.current.url.path == root.path else { throw SmokeFailure.failed("Cloud smoke changed local navigation") }
    }

    private func preserveClipboard(_ pasteboard: NSPasteboard) throws -> () -> Void {
        // Materialize every type from every item before replacing anything, including custom formats.
        let previous: [[(NSPasteboard.PasteboardType, Data)]] = try (pasteboard.pasteboardItems ?? []).map { item in
            try item.types.map { type in
                guard let data = item.data(forType: type) else { throw SmokeFailure.failed("Could not preserve complete clipboard") }
                return (type, data)
            }
        }
        return {
            pasteboard.clearContents()
            let restored = previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }

    private func testCloudClipboard(root: URL, connection: CloudConnection, transport: SmokeCloudListingTransport) async throws {
        let pasteboard = NSPasteboard.general
        let restore = try preserveClipboard(pasteboard)
        defer { restore() }
        let source = root.appendingPathComponent("Cloud-smoke-upload.txt")
        let destination = root.appendingPathComponent("Cloud-smoke-download")
        let payload = Data("Cloud smoke Unicode 日本語".utf8)
        try payload.write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        let commands = FileCommands.shared
        let remoteRoot = RemoteLocation.url(connectionID: connection.id)
        await commands.copy([FileEntry(url: source, name: source.lastPathComponent, isDirectory: false)], cut: false)?.value
        commands.paste(into: remoteRoot)
        guard let upload = commands.task else { throw SmokeFailure.failed("Cloud paste did not start upload") }
        await upload.value
        guard await transport.contents(key: source.lastPathComponent) == payload else { throw SmokeFailure.failed("Cloud paste upload did not preserve bytes") }
        // A second paste must present a conflict; choosing Skip must leave the remote object unchanged.
        try Data("changed source".utf8).write(to: source)
        await commands.copy([FileEntry(url: source, name: source.lastPathComponent, isDirectory: false)], cut: false)?.value
        commands.paste(into: remoteRoot)
        guard let conflictingUpload = commands.task else { throw SmokeFailure.failed("Conflict paste did not start") }
        var skipped = false
        for _ in 0..<500 {
            if let sheet = NSApp.windows.first(where: { $0.sheetParent is NSPanel && $0.contentView.map { content in
                descendants(of: content).contains { ($0 as? NSButton)?.title == L10n.text("cloud.conflict.skip") }
            } == true }), let content = sheet.contentView,
               let button = descendants(of: content).first(where: { ($0 as? NSButton)?.title == L10n.text("cloud.conflict.skip") }) as? NSButton {
                button.performClick(nil); skipped = true; break
            }
            if !commands.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard skipped else { commands.cancel(nil); throw SmokeFailure.failed("Cloud conflict confirmation did not appear") }
        await conflictingUpload.value
        guard await transport.contents(key: source.lastPathComponent) == payload,
              await transport.uploadCount == 1 else { throw SmokeFailure.failed("Skipped cloud conflict overwrote content") }
        let remote = RemoteLocation.url(connectionID: connection.id, key: source.lastPathComponent)
        await commands.copy([FileEntry(url: remote, name: source.lastPathComponent, isDirectory: false, size: Int64(payload.count))], cut: false)?.value
        commands.paste(into: destination)
        guard let download = commands.task else { throw SmokeFailure.failed("Cloud paste did not start download") }
        await download.value
        guard try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)) == payload,
              try !FileManager.default.contentsOfDirectory(atPath: destination.path).contains(where: { $0.hasPrefix(".my-explorer-") }) else {
            throw SmokeFailure.failed("Cloud download did not preserve bytes or left staging behind")
        }
        commands.trash([FileEntry(url: remote, name: source.lastPathComponent, isDirectory: false)])
        guard let deletion = commands.task else { throw SmokeFailure.failed("Cloud deletion did not start") }
        var confirmed = false
        for _ in 0..<500 {
            if let sheet = NSApp.windows.first(where: { $0.sheetParent is NSPanel && $0.contentView.map { content in
                descendants(of: content).contains { ($0 as? NSButton)?.title == L10n.text("command.delete") }
            } == true }), let content = sheet.contentView,
               let button = descendants(of: content).first(where: { ($0 as? NSButton)?.title == L10n.text("command.delete") }) as? NSButton {
                button.performClick(nil); confirmed = true; break
            }
            if !commands.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard confirmed else { commands.cancel(nil); throw SmokeFailure.failed("Deletion confirmation did not appear") }
        await deletion.value
        guard await transport.contents(key: source.lastPathComponent) == nil,
              try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)) == payload else {
            throw SmokeFailure.failed("Cloud deletion failed or changed downloaded local copy")
        }
    }

    private func testMobileDevicePanel(browser: ExplorerWindowController) async throws {
        let tree = browser.tree.outline
        guard let row = (0..<tree.numberOfRows).first(where: {
            (tree.item(atRow: $0) as? FolderNode)?.url.scheme == "myexplorer-devices"
        }) else { throw SmokeFailure.failed("Missing mobile devices in navigation") }
        for _ in 0..<2 {
            tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try await waitForCondition("mobile device panel") {
                NSApp.windows.contains { $0.title == L10n.text("devices.title") && $0.isVisible }
            }
            NSApp.windows.first { $0.title == L10n.text("devices.title") && $0.isVisible }?.close()
        }
    }

    private func testDisposableEjection(root: URL, browser: ExplorerWindowController) async throws {
        let token = try String(contentsOf: root.appendingPathComponent("eject-fixture"), encoding: .utf8)
        guard UUID(uuidString: token) != nil else { throw SmokeFailure.failed("Invalid ejection fixture") }
        let volume = URL(fileURLWithPath: "/Volumes/MyExplorer-" + token, isDirectory: true)
        guard try String(contentsOf: volume.appendingPathComponent("eject-fixture"), encoding: .utf8) == token,
              let original = browser.workspace.activeTab else { throw SmokeFailure.failed("Invalid disposable volume") }
        let tab = browser.addTab(at: volume)
        try await waitForListing(browser)
        let tree = browser.tree
        let node = (0..<tree.outline.numberOfRows).compactMap { tree.outline.item(atRow: $0) as? FolderNode }.first { $0.url.path == "/Volumes" }
        guard let node else { throw SmokeFailure.failed("Missing Volumes") }
        tree.outline.expandItem(node)
        try await waitForCondition("disposable disk in tree") { node.children?.contains { $0.url.path == volume.path } == true }
        guard let disk = node.children?.first(where: { $0.url.path == volume.path }), disk.volume?.removal == .eject,
              let menu = tree.outline.contextMenuForRow?(tree.outline.row(forItem: disk)),
              let eject = menu.item(withTitle: L10n.text("volume.eject")), let action = eject.action else {
            throw SmokeFailure.failed("No Eject command")
        }
        NSApp.sendAction(action, to: eject.target, from: eject)
        try await waitForCondition("volume removed", timeout: .seconds(30)) {
            !FileManager.default.fileExists(atPath: volume.path) && tab.session.history.current.url.path == "/Volumes"
        }
        guard original.session.history.current.url.explorerIdentity == root.explorerIdentity,
              browser.systemVolumes.notice(for: tab.id) != nil else { throw SmokeFailure.failed("Ejection did not isolate volume tabs") }
        if let sheet = browser.window?.attachedSheet { browser.window?.endSheet(sheet) }
    }

    private func testVolumeNavigation(root: URL) async throws {
        guard let browser = controller else { throw SmokeFailure.failed("Missing window") }
        let manager = FileManager.default
        let fixture = root.appendingPathComponent("VolumeNavigation")
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        let folder = fixture.appendingPathComponent("Folder link")
        let volume = fixture.appendingPathComponent("Macintosh HD")
        try manager.createSymbolicLink(at: folder, withDestinationURL: root.appendingPathComponent("Documents"))
        try manager.createSymbolicLink(at: volume, withDestinationURL: URL(fileURLWithPath: "/"))
        defer { try? manager.removeItem(at: fixture) }
        for link in [folder, volume] {
            browser.navigate(.visit(fixture))
            try await waitForListing(browser)
            guard let row = browser.session.entries.firstIndex(where: { $0.url.path == link.path }),
                  browser.session.entries[row].canNavigate, let action = browser.table.doubleAction else {
                throw SmokeFailure.failed("Directory link is not navigable")
            }
            browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            NSApp.sendAction(action, to: browser.table.target, from: browser.table)
            try await waitForListing(browser)
            guard browser.session.history.current.url.path == link.path,
                  !browser.session.entries.isEmpty,
                  browser.session.entries.allSatisfy({ $0.url.deletingLastPathComponent().path == link.path }) else {
                throw SmokeFailure.failed("Double-click link lost listing or path identity")
            }
            browser.goBack(nil)
            try await waitForListing(browser)
            guard browser.table.selectedRow == row else { throw SmokeFailure.failed("Back lost link selection") }
            browser.openSelectedInNewTab(nil)
            try await waitForListing(browser)
            let tabID = browser.workspace.activeID!
            guard browser.session.history.current.url.path == link.path else { throw SmokeFailure.failed("Link in new tab failed") }
            browser.goUp(nil)
            try await waitForListing(browser)
            guard browser.session.history.current.url.path == fixture.path,
                  browser.table.selectedRow == row else { throw SmokeFailure.failed("Up lost link parent/selection") }
            browser.closeTab(id: tabID)
            try await waitForListing(browser)
        }
        let outline = browser.tree.outline
        guard let volumes = (0..<outline.numberOfRows).compactMap({ outline.item(atRow: $0) as? FolderNode })
            .first(where: { $0.url.path == "/Volumes" }) else { throw SmokeFailure.failed("Missing volumes node") }
        outline.expandItem(volumes)
        try await waitForCondition("mounted disks in sidebar") { volumes.children?.contains { $0.volume != nil } == true }
        guard let window = browser.window else { throw SmokeFailure.failed("No browser window") }
        let disks = volumes.children?.filter { $0.volume != nil } ?? []
        for disk in [disks.first(where: { $0.volumeLink }), disks.first(where: { !$0.volumeLink })].compactMap({ $0 }) {
            guard let mount = disk.volume else { throw SmokeFailure.failed("Missing mount identity") }
            let total = try await Task.detached { try mount.capacity().total }.value
            let diskRow = outline.row(forItem: disk)
            let selected = outline.selectedRow, location = browser.session.history.current.url
            let rect = outline.rect(ofRow: diskRow)
            let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let item = outline.menu(for: event)?.item(withTitle: L10n.text("command.properties")), let action = item.action else {
                throw SmokeFailure.failed("Missing properties menu for clicked volume")
            }
            NSApp.sendAction(action, to: item.target, from: item)
            func labels(in view: NSView) -> [String] {
                ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { labels(in: $0) }
            }
            try await waitForCondition("capacity, used and free in volume sheet") {
                guard let content = window.attachedSheet?.contentView else { return false }
                let text = labels(in: content).joined(separator: " ")
                return text.contains(L10n.current.bytes(total)) && ["volume.total", "volume.used", "volume.free"].allSatisfy { text.contains(L10n.text($0)) }
            }
            guard let sheet = window.attachedSheet, outline.selectedRow == selected,
                  browser.session.history.current.url == location else { throw SmokeFailure.failed("Volume context changed navigation") }
            window.endSheet(sheet)
        }
        browser.navigate(.visit(root))
        try await waitForListing(browser)
    }

    private func testLanguages(root: URL, arguments: [String]) async throws {
        guard let original = controller else { throw SmokeFailure.failed("Missing window") }
        let workspace = original.workspace
        let activeID = workspace.activeID
        let tabIDs = workspace.tabs.map(\.id)
        guard let treeRoot = original.tree.outline.item(atRow: 0) as? FolderNode else { throw SmokeFailure.failed("Missing tree") }
        original.tree.outline.expandItem(treeRoot)
        for _ in 0..<1000 {
            if original.tree.outline.isItemExpanded(treeRoot) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard original.tree.outline.isItemExpanded(treeRoot) else { throw SmokeFailure.failed("Could not expand language fixture") }
        original.sidebarWidth = 270
        original.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("kind"))?.width = 180
        original.filter.stringValue = "Roadmap"
        original.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: original.filter))
        original.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        original.table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        for language in AppLanguage.allCases where language != .system {
            guard let previous = controller else { throw SmokeFailure.failed("Lost window") }
            previous.languagePicker.selectItem(at: AppLanguage.allCases.firstIndex(of: language)!)
            // Invoke the picker action without depending on a pop-up menu's mouse tracking loop.
            if let action = previous.languagePicker.action { NSApp.sendAction(action, to: previous.languagePicker.target, from: previous.languagePicker) }
            guard let current = controller, current.workspace === workspace,
                  workspace.activeID == activeID, workspace.tabs.map(\.id) == tabIDs,
                  current.address.stringValue == root.path,
                  current.filter.stringValue == "Roadmap", current.table.selectedRow == 0,
                  current.table.sortDescriptors.first?.key == "size",
                  current.table.sortDescriptors.first?.ascending == false,
                  current.tree === original.tree, current.tree.outline.isItemExpanded(treeRoot),
                  abs(current.sidebarWidth - 270) < 1,
                  current.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("kind"))?.width == 180,
                  current.table.tableColumns.first?.title == L10n.text("column.name"),
                  current.table.tableColumns.first?.title != "column.name",
                  L10n.preferences.selection == language else { throw SmokeFailure.failed("Language switch lost state: \(language)") }
            if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1) {
                let destination = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path + "-\(language.rawValue).png"
                try await Task.sleep(for: .milliseconds(80))
                try current.savePreview(to: URL(fileURLWithPath: destination))
            }
        }
        changeLanguage(.portuguese)
        guard let current = controller else { throw SmokeFailure.failed("Missing restored window") }
        current.filter.stringValue = ""
        current.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: current.filter))
        current.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        let long = current.addTab(at: root.appendingPathComponent("LongList"))
        try await waitForListing(current)
        current.table.selectRowIndexes(IndexSet(integer: 80), byExtendingSelection: false)
        current.table.scrollRowToVisible(80)
        let offset = current.fileScroll.contentView.bounds.minY
        guard offset > 500 else { throw SmokeFailure.failed("Language scroll fixture did not scroll") }
        changeLanguage(.japanese)
        guard let japanese = controller, japanese.table.selectedRow == 80,
              abs(japanese.fileScroll.contentView.bounds.minY - offset) < 1 else {
            throw SmokeFailure.failed("Language switch lost scroll position")
        }
        japanese.closeTab(id: long.id)
        changeLanguage(.portuguese)
        if let activeID { controller?.selectTab(id: activeID) }
        guard let beforePending = controller else { throw SmokeFailure.failed("Missing pending window") }
        beforePending.navigate(.visit(root.appendingPathComponent("Documents")))
        guard beforePending.session.isLoading else { throw SmokeFailure.failed("Expected pending read") }
        changeLanguage(.english)
        guard let afterPending = controller else { throw SmokeFailure.failed("Missing pending translation") }
        try await waitForListing(afterPending)
        guard afterPending.session.history.current.url.lastPathComponent == "Documents" else {
            throw SmokeFailure.failed("Language switch interrupted navigation")
        }
        afterPending.goBack(nil)
        try await waitForListing(afterPending)
        await afterPending.session.navigate(.visit(root.appendingPathComponent("Missing-Language-Fixture"))).value
        guard afterPending.session.failure != nil, !afterPending.errorLabel.isHidden else { throw SmokeFailure.failed("Expected inline error") }
        let englishError = afterPending.errorLabel.stringValue
        changeLanguage(.german)
        guard let afterError = controller, afterError.errorLabel.stringValue != englishError,
              afterError.errorLabel.stringValue == L10n.current.directoryError(afterError.session.failure) else {
            throw SmokeFailure.failed("Existing error was not relocalized")
        }
        afterError.refresh(nil)
        try await waitForListing(afterError)
        changeLanguage(.portuguese)
        controller?.sidebarWidth = 230
    }

    private func testTabs(_ controller: ExplorerWindowController, root: URL) async throws {
        let workspace = controller.workspace
        guard let original = workspace.activeTab else { throw SmokeFailure.failed("Missing original tab") }
        // Up selected Documents. Opening it in a new tab must not navigate the source tab.
        controller.openSelectedInNewTab(nil)
        guard controller.table.numberOfRows == 0,
              controller.address.stringValue == root.appendingPathComponent("Documents").path else {
            throw SmokeFailure.failed("New loading tab displayed the previous tab's content")
        }
        try await waitForListing(controller)
        guard let documents = workspace.activeTab, documents.id != original.id,
              documents.session.history.current.url.lastPathComponent == "Documents",
              original.session.history.current.url.path == root.path else {
            throw SmokeFailure.failed("Open folder in new tab altered the original")
        }
        controller.filter.stringValue = "Notes"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.filter))
        controller.selectTab(id: original.id)
        controller.session.toggleHidden()
        try await waitForListing(controller)
        controller.filter.stringValue = "Roadmap"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.filter))
        controller.table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.selectTab(id: documents.id)
        guard controller.filter.stringValue == "Notes", !controller.session.showHidden else {
            throw SmokeFailure.failed("Destination tab did not retain its filter/hidden state")
        }
        controller.selectTab(id: original.id)
        guard controller.filter.stringValue == "Roadmap", controller.table.selectedRow == 0,
              controller.table.sortDescriptors.first?.key == "size",
              controller.table.sortDescriptors.first?.ascending == false, controller.session.showHidden else {
            throw SmokeFailure.failed("Switching tabs lost original view state")
        }
        await documents.session.navigate(.reload).value
        guard controller.filter.stringValue == "Roadmap", controller.address.stringValue == root.path,
              controller.table.numberOfRows == 1, controller.table.selectedRow == 0 else {
            throw SmokeFailure.failed("Background tab completion altered the active interface")
        }
        // Commands are exercised through NSApplication's actual event routing.
        controller.focusAddress(nil)
        try sendKey("t", code: 17, flags: .command, to: controller)
        try await waitForListing(controller)
        guard workspace.tabs.count == 3, let third = workspace.activeID else {
            throw SmokeFailure.failed("Command+T failed from the address field")
        }
        try sendKey("\t", code: 48, flags: .control, to: controller)
        guard workspace.activeID == original.id else { throw SmokeFailure.failed("Control+Tab did not wrap") }
        try sendKey("\t", code: 48, flags: [.control, .shift], to: controller)
        guard workspace.activeID == third else { throw SmokeFailure.failed("Control+Shift+Tab failed") }
        try sendKey("w", code: 13, flags: .control, to: controller)
        guard workspace.tabs.count == 2, workspace.activeID == documents.id else {
            throw SmokeFailure.failed("Control+W did not close the active tab")
        }
        controller.selectTab(id: original.id)
        controller.closeTab(id: documents.id)
        guard workspace.activeID == original.id else { throw SmokeFailure.failed("Closing background tab changed active tab") }
        let long = controller.addTab(at: root.appendingPathComponent("LongList"))
        try await waitForListing(controller)
        guard controller.table.numberOfRows == 120 else { throw SmokeFailure.failed("Missing long-list fixture") }
        controller.table.selectRowIndexes(IndexSet(integer: 80), byExtendingSelection: false)
        controller.table.scrollRowToVisible(80)
        let offset = controller.fileScroll.contentView.bounds.minY
        guard offset > 500 else { throw SmokeFailure.failed("Scroll fixture did not scroll") }
        var extras: [UUID] = []
        for _ in 0..<7 { extras.append(controller.addTab(at: root.appendingPathComponent("Documents")).id) }
        try await waitForListing(controller)
        guard controller.activeTabIsVisible else { throw SmokeFailure.failed("New tab was hidden beyond overflow") }
        controller.selectTab(id: long.id)
        guard controller.table.selectedRow == 80,
              abs(controller.fileScroll.contentView.bounds.minY - offset) < 1,
              controller.activeTabIsVisible else { throw SmokeFailure.failed("Tab switch lost scroll/selection or did not reveal tab") }
        for id in extras { controller.closeTab(id: id) }
        controller.closeTab(id: long.id)
        controller.selectTab(id: original.id)
        controller.filter.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.filter))
        controller.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        controller.session.toggleHidden()
        try await waitForListing(controller)
        // Keep a second real tab visible in the preview.
        controller.addTab(at: root.appendingPathComponent("Documents"))
        try await waitForListing(controller)
        controller.selectTab(id: original.id)
    }

    private func testOutlinedButtons(root: URL, arguments: [String]) async throws {
        func select(_ name: String, in browser: ExplorerWindowController) throws {
            guard let row = (0..<browser.table.numberOfRows).first(where: {
                browser.tableView(browser.table, typeSelectStringFor: nil, row: $0) == name
            }) else { throw SmokeFailure.failed("Missing toolbar fixture") }
            browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let oldSize = ExplorerStyle.preferences.fontSize(for: .bars)
        let oldLanguage = L10n.preferences.selection
        for (size, language) in [(14.0, AppLanguage.portuguese), (24.0, AppLanguage.german)] {
            ExplorerStyle.preferences.setFontSize(size, for: .bars)
            changeLanguage(language)
            guard let browser = controller, let window = browser.window, let content = window.contentView else {
                throw SmokeFailure.failed("Missing button window")
            }
            browser.navigate(.visit(root)); try await waitForListing(browser)
            browser.filter.stringValue = ""
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filter))
            window.makeKeyAndOrderFront(nil)
            content.layoutSubtreeIfNeeded()
            let buttons = descendants(of: content).compactMap { $0 as? OutlinedButton }
            guard let open = buttons.first(where: { $0.accessibilityIdentifier() == "explorer.command.open" }),
                  let copy = buttons.first(where: { $0.accessibilityIdentifier() == "explorer.command.copyPath" }),
                  buttons.count >= 10 else { throw SmokeFailure.failed("Toolbar style or actions missing") }
            let previewWasVisible = browser.previewPaneVisible
            if !previewWasVisible { browser.togglePreviewPane(nil) }
            content.layoutSubtreeIfNeeded()
            let controls = descendants(of: content).compactMap { $0 as? NSButton }
            for id in ["explorer.viewMenu", "explorer.preview.ocr"] {
                guard let control = controls.first(where: { $0.accessibilityIdentifier() == id }),
                      let font = control.font, control.frame.height >= font.ascender - font.descender + 8,
                      control.frame.height <= ceil(font.ascender - font.descender) + 20 else {
                    throw SmokeFailure.failed("Insufficient vertical padding: " + id)
                }
            }
            if !previewWasVisible { browser.togglePreviewPane(nil) }
            for button in buttons {
                guard button.frame.height >= 28, button.target != nil, button.action != nil,
                      button.frame.height >= (button.font?.ascender ?? 0) - (button.font?.descender ?? 0) else {
                    throw SmokeFailure.failed("Button content clipped or action/focus missing")
                }
            }
            browser.table.deselectAll(nil)
            let clipboard = NSPasteboard.general.changeCount
            copy.performClick(nil); open.performClick(nil)
            guard !open.isEnabled, !copy.isEnabled, clipboard == NSPasteboard.general.changeCount,
                  browser.session.history.current.url.path == root.path else {
                throw SmokeFailure.failed("Disabled toolbar action executed")
            }
            try select("Documents", in: browser)
            guard open.isEnabled, copy.isEnabled else { throw SmokeFailure.failed("Selected file commands stayed disabled") }
            copy.performClick(nil)
            guard NSPasteboard.general.string(forType: .string) == root.appendingPathComponent("Documents").path else {
                throw SmokeFailure.failed("Outlined Copy path lost native action")
            }
            let shown = ExplorerStyle.preferences.showPreviewPane
            browser.previewButton.performClick(nil)
            guard ExplorerStyle.preferences.showPreviewPane != shown,
                  browser.previewButton.state == (shown ? .off : .on) else { throw SmokeFailure.failed("Preview toggle lost state") }
            if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1) {
                let base = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path
                try browser.savePreview(to: URL(fileURLWithPath: base + "-buttons-\(Int(size))-toggle.png"))
            }
            browser.previewButton.performClick(nil)
            guard window.makeFirstResponder(copy), window.firstResponder === copy else {
                throw SmokeFailure.failed("Toolbar button cannot receive keyboard focus")
            }
            let beforeSpace = NSPasteboard.general.changeCount
            try sendKey(" ", code: 49, flags: [], to: browser)
            guard NSPasteboard.general.changeCount > beforeSpace,
                  NSPasteboard.general.string(forType: .string) == root.appendingPathComponent("Documents").path else {
                throw SmokeFailure.failed("Focused button did not activate with Space")
            }
            if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1) {
                let base = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path
                try browser.savePreview(to: URL(fileURLWithPath: base + "-buttons-\(Int(size))-focus.png"))
                try sendKey("\t", code: 48, flags: [], to: browser)
                guard window.firstResponder !== copy else { throw SmokeFailure.failed("Tab did not leave focused button") }
                window.makeFirstResponder(browser.table)
                guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
                    throw SmokeFailure.failed("Missing hover event")
                }
                let frame = copy.frame
                copy.mouseEntered(with: event)
                guard copy.isHovered, copy.frame == frame else { throw SmokeFailure.failed("Hover changed layout") }
                try browser.savePreview(to: URL(fileURLWithPath: base + "-buttons-\(Int(size))-hover.png"))
                copy.mouseExited(with: event)
                guard !copy.isHovered else { throw SmokeFailure.failed("Hover did not end") }
                browser.table.deselectAll(nil)
                try browser.savePreview(to: URL(fileURLWithPath: base + "-buttons-\(Int(size))-disabled.png"))
            }
            try select("Documents", in: browser)
            open.performClick(nil); try await waitForListing(browser)
            guard browser.session.history.current.url.lastPathComponent == "Documents" else {
                throw SmokeFailure.failed("Outlined Open lost navigation action")
            }
            guard let parent = browser.breadcrumbs.arrangedSubviews.compactMap({ $0 as? BreadcrumbButton })
                .first(where: { $0.destination?.path == root.path }) else { throw SmokeFailure.failed("Parent breadcrumb missing") }
            parent.performClick(nil); try await waitForListing(browser)
            guard browser.session.history.current.url.path == root.path else { throw SmokeFailure.failed("Breadcrumb action failed") }
        }
        ExplorerStyle.preferences.setFontSize(oldSize, for: .bars)
        changeLanguage(oldLanguage)
        if let browser = controller { try await waitForListing(browser) }
    }

    private func testDisplaySettings(root: URL, arguments: [String]) async throws {
        guard let initial = controller else { throw SmokeFailure.failed("Missing display window") }
        guard ExplorerStyle.preferences.showFileExtensions else { throw SmokeFailure.failed("Extensions must be visible by default") }
        initial.filter.stringValue = "Roadmap.csv"
        initial.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: initial.filter))
        initial.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        initial.toggleFileExtensions(nil)
        guard initial.tableView(initial.table, typeSelectStringFor: nil, row: 0) == "Roadmap",
              initial.table.selectedRow == 0, initial.session.entries.contains(where: { $0.name == "Roadmap.csv" }) else {
            throw SmokeFailure.failed("Hiding extensions changed identity, selection or filtering")
        }
        showFontSettings(nil)
        func pickers(in view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { pickers(in: $0) }
        }
        guard let content = fontSettings?.window?.contentView else { throw SmokeFailure.failed("Missing font settings") }
        let sizes = [18, 16, 17, 18]
        for picker in pickers(in: content) {
            picker.selectItem(at: sizes[picker.tag] - 10)
            if let action = picker.action { NSApp.sendAction(action, to: picker.target, from: picker) }
        }
        changeLanguage(.german)
        guard let enlarged = controller, !ExplorerStyle.preferences.showFileExtensions,
              enlarged.tableView(enlarged.table, typeSelectStringFor: nil, row: 0) == "Roadmap",
              enlarged.table.rowHeight == 30, enlarged.tree.outline.rowHeight == 30,
              enlarged.table.tableColumns.last?.headerCell.alignment == .left,
              enlarged.table.tableColumns.allSatisfy({ $0.headerCell.lineBreakMode == .byTruncatingTail }),
              enlarged.table.menu?.font?.pointSize == 17,
              enlarged.address.font?.pointSize == 18 else { throw SmokeFailure.failed("Independent typography or language persistence failed") }
        if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1) {
            let path = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path + "-fonts.png"
            enlarged.window?.makeKeyAndOrderFront(nil)
            enlarged.window?.makeFirstResponder(enlarged.table)
            // Unselected content makes typography visible in AppKit's offscreen cache,
            // which does not reliably capture the layer-backed selection background.
            enlarged.table.deselectAll(nil)
            try await Task.sleep(for: .milliseconds(100))
            guard let nameCell = enlarged.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FileNameCell,
                  nameCell.label.stringValue == "Roadmap", nameCell.label.font?.pointSize == 16 else {
                throw SmokeFailure.failed("Visible filename did not adopt its font preference")
            }
            try enlarged.savePreview(to: URL(fileURLWithPath: path))
            // Exercise ellipsis with a long localized title, a narrow column, and its sort indicator.
            if let column = enlarged.table.tableColumns.first(where: { $0.identifier.rawValue == "modified" }) {
                let width = column.width, order = enlarged.table.sortDescriptors
                column.width = 75
                enlarged.table.sortDescriptors = [NSSortDescriptor(key: "modified", ascending: true)]
                enlarged.table.headerView?.needsDisplay = true
                let narrowPath = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path + "-columns.png"
                try enlarged.savePreview(to: URL(fileURLWithPath: narrowPath))
                column.width = width
                enlarged.table.sortDescriptors = order
            }
        }
        fontSettings?.close(); fontSettings = nil
        ExplorerStyle.preferences.resetFonts()
        ExplorerStyle.preferences.setShowFileExtensions(true)
        changeLanguage(.portuguese)
        guard let restored = controller else { throw SmokeFailure.failed("Missing restored display window") }
        restored.filter.stringValue = ""
        restored.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: restored.filter))
    }

    private func testFontShortcuts() throws {
        func sizes() -> [Double] { FontArea.allCases.map { ExplorerStyle.preferences.fontSize(for: $0) } }
        func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) throws {
            guard let controller else { throw SmokeFailure.failed("Missing shortcut window") }
            controller.window?.makeKeyAndOrderFront(nil)
            try sendKey(characters, code: code, flags: flags, to: controller)
        }
        guard let original = controller else { throw SmokeFailure.failed("Missing font shortcut window") }
        let tab = original.workspace.activeTab?.id
        original.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let selection = original.table.selectedRowIndexes
        original.togglePreviewPane(nil)
        original.previewPaneWidth = 280
        original.focusAddress(nil)
        original.address.stringValue = "/draft/unfinished"
        (original.window?.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 7, length: 3))
        try key("+", code: 24, flags: [.control, .shift])
        guard sizes() == [15, 15, 17, 15], let enlarged = controller,
              enlarged.workspace.activeTab?.id == tab, enlarged.table.selectedRowIndexes == selection,
              enlarged.previewPaneVisible, abs(enlarged.previewPaneWidth - 280) < 2,
              enlarged.address.stringValue == "/draft/unfinished",
              let editor = enlarged.window?.firstResponder as? NSTextView,
              editor.delegate as? NSTextField === enlarged.address,
              editor.selectedRange() == NSRange(location: 7, length: 3),
              enlarged.address.font?.pointSize == 15,
              enlarged.table.menu?.font?.pointSize == 17 else {
            throw SmokeFailure.failed("Control plus lost font step or presentation state")
        }
        try key("-", code: 27, flags: .control)
        guard sizes() == [14, 14, 16, 14] else { throw SmokeFailure.failed("Control minus did not restore sizes") }
        try key("=", code: 24, flags: .control)
        try key("+", code: 69, flags: [.control, .numericPad])
        guard sizes() == [16, 16, 18, 16] else { throw SmokeFailure.failed("Equals/keypad plus did not adjust fonts") }
        try key("-", code: 78, flags: [.control, .numericPad])
        guard sizes() == [15, 15, 17, 15] else { throw SmokeFailure.failed("Keypad minus did not adjust fonts") }
        controller?.window?.makeFirstResponder(controller?.table)
        try key("+", code: 24, flags: .command)
        try key("+", code: 24, flags: [.control, .option])
        guard sizes() == [15, 15, 17, 15] else { throw SmokeFailure.failed("Unrelated modifiers changed fonts") }
        ExplorerStyle.preferences.resetFonts()
        controller?.togglePreviewPane(nil)
        controller?.table.deselectAll(nil)
    }

    private func testFileCommandFocus() async throws {
        guard let browser = controller, let window = browser.window else { throw SmokeFailure.failed("Missing focus fixture") }
        try await waitForListing(browser)
        browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(browser.tree.outline)
        let clipboard = NSPasteboard.general.changeCount
        guard !browser.acceptsFileListCommands,
              !validateMenuItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")),
              !validateMenuItem(NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")) else {
            throw SmokeFailure.failed("Tree focus enabled commands for a residual file selection")
        }
        try sendKey("c", code: 8, flags: .control, to: browser)
        try sendKey("x", code: 7, flags: .command, to: browser)
        try sendKey("", code: 117, flags: [], to: browser)
        guard NSPasteboard.general.changeCount == clipboard, !FileCommands.shared.isBusy, window.attachedSheet == nil else {
            throw SmokeFailure.failed("Tree keyboard command affected the file list")
        }
        browser.filter.stringValue = "focus fixture"
        for (text, code, flags) in [("f", UInt16(3), NSEvent.ModifierFlags.command), ("f", 3, .control), ("", 99, [])] {
            window.makeFirstResponder(browser.tree.outline)
            try sendKey(text, code: code, flags: flags, to: browser)
            guard let editor = window.firstResponder as? NSTextView, editor.delegate as? NSTextField === browser.filter,
                  editor.selectedRange().length == browser.filter.stringValue.utf16.count else {
                throw SmokeFailure.failed("Find shortcut failed to focus and select filter")
            }
        }
        browser.filter.stringValue = ""
        window.makeFirstResponder(browser.table)
        browser.table.deselectAll(nil)
        guard browser.acceptsFileListCommands else { throw SmokeFailure.failed("Returning focus did not enable file commands") }
    }

    private func testFileSharing(root: URL) async throws {
        guard let controller, let menu = controller.table.menu else { throw SmokeFailure.failed("Missing sharing menu") }
        let apk = root.appendingPathComponent("Compartilhar 日本語.apk")
        let payload = Data([0x50, 0x4b, 0x03, 0x04, 0, 1, 2, 255])
        try payload.write(to: apk)
        let entry = FileEntry(url: apk, name: apk.lastPathComponent, isDirectory: false)
        let folder = FileEntry(url: root.appendingPathComponent("Documents"), name: "Documents", isDirectory: true)
        let remote = FileEntry(url: RemoteLocation.url(connectionID: UUID(), key: "example.apk"), name: "example.apk", isDirectory: false)
        let originalSharing = controller.fileSharing
        var received: [[URL]] = []
        controller.fileSharing = FileSharingController { urls, _, view in
            precondition(view === controller.table)
            received.append(urls)
        }
        let clipboardChangeCount = NSPasteboard.general.changeCount
        defer {
            controller.fileSharing.closePicker()
            controller.fileSharing = originalSharing
            try? FileManager.default.removeItem(at: apk)
        }
        func share(_ entries: [FileEntry], enabled: Bool = true) async throws {
            controller.rebuildContextMenu(menu, entries: entries)
            guard let item = menu.items.first(where: { $0.action == #selector(ExplorerWindowController.shareFiles) }),
                  item.title == L10n.text("command.share"), controller.validateMenuItem(item) == enabled,
                  NSApp.sendAction(item.action!, to: item.target, from: item) else {
                throw SmokeFailure.failed("Contextual Share action or validation failed")
            }
            await controller.sharingTask?.value
        }
        try await share([entry])
        try await share([entry, folder])
        guard received == [[apk], [apk, folder.url]], try Data(contentsOf: apk) == payload else {
            throw SmokeFailure.failed("Share did not receive the original local files in order")
        }
        try await share([remote], enabled: false)
        try await share([entry, remote], enabled: false)
        guard received.count == 2 else { throw SmokeFailure.failed("Sharing a remote URL was allowed") }
        try FileManager.default.removeItem(at: apk)
        try await share([entry])
        guard received.count == 2, !controller.errorLabel.isHidden,
              controller.errorLabel.stringValue == L10n.text("share.unavailable"),
              NSPasteboard.general.changeCount == clipboardChangeCount else {
            throw SmokeFailure.failed("Sharing an unavailable file did not fail cleanly or changed the clipboard")
        }
        controller.errorLabel.isHidden = true
        // Open and cancel the actual native picker with a disposable fixture, without choosing a service.
        try payload.write(to: apk)
        controller.fileSharing = originalSharing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { originalSharing.closePicker() }
        try await originalSharing.share([apk], relativeTo: controller.table.visibleRect, of: controller.table)
        try await Task.sleep(for: .milliseconds(1100))
        guard try Data(contentsOf: apk) == payload, NSPasteboard.general.changeCount == clipboardChangeCount else {
            throw SmokeFailure.failed("Opening/cancelling native sharing changed the file or clipboard")
        }
    }

    private func testLargeDirectory(root: URL) async throws {
        guard let browser = controller else { throw SmokeFailure.failed("Missing large-directory browser") }
        let folder = root.appendingPathComponent("LargeListing")
        var largestGap: Duration = .zero
        let heartbeat = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                let now = ContinuousClock.now
                largestGap = max(largestGap, last.duration(to: now))
                last = now
            }
        }
        defer { heartbeat.cancel() }
        let started = ContinuousClock.now
        browser.navigate(.visit(folder)); try await waitForListing(browser)
        try await Task.sleep(for: .milliseconds(50))
        guard browser.table.numberOfRows == 10_000 else { throw SmokeFailure.failed("Large listing incomplete") }
        let elapsed = started.duration(to: .now)
        browser.filter.stringValue = "09999"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filter))
        guard browser.table.numberOfRows == 1 else { throw SmokeFailure.failed("Large-folder filter failed") }
        browser.filter.stringValue = ""
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filter))
        try await Task.sleep(for: .milliseconds(40))
        heartbeat.cancel(); await heartbeat.value
        print("SMOKE METRIC: 10000 entries, load=\(elapsed), max main-thread interval=\(largestGap)")
        guard elapsed < .seconds(8), largestGap < .seconds(1) else { throw SmokeFailure.failed("Large-directory responsiveness budget exceeded") }
        browser.navigate(.visit(root)); try await waitForListing(browser)
        browser.navigate(.visit(folder))
        browser.navigate(.visit(root)); try await waitForListing(browser)
        try await Task.sleep(for: .milliseconds(250))
        guard browser.session.history.current.url.path == root.path,
              browser.session.entries.count < 100 else { throw SmokeFailure.failed("Cancelled large listing replaced current folder") }
    }

    private func testGitIntegration(root: URL, arguments: [String]) async throws {
        guard let browser = controller else { throw SmokeFailure.failed("Missing Git browser") }
        let parent = root.appendingPathComponent("GitFixtures")
        let repository = parent.appendingPathComponent("Git project")
        let worktree = parent.appendingPathComponent("Linked worktree")
        defer { try? Data("initial\n".utf8).write(to: repository.appendingPathComponent("clean.txt")) }
        func cell(_ name: String) throws -> FileNameCell {
            guard let row = (0..<browser.table.numberOfRows).first(where: {
                browser.tableView(browser.table, typeSelectStringFor: nil, row: $0) == name
            }), let cell = browser.table.view(atColumn: browser.table.column(withIdentifier: NSUserInterfaceItemIdentifier("name")), row: row, makeIfNecessary: true) as? FileNameCell else {
                throw SmokeFailure.failed("Missing Git fixture cell \(name)")
            }
            return cell
        }
        browser.navigate(.visit(parent)); try await waitForListing(browser)
        try await waitForCondition("Git root badges") {
            (try? cell("Git project").gitBadge.isHidden) == false && (try? cell("Linked worktree").gitBadge.isHidden) == false
        }
        let childMenu = NSMenu()
        let repoEntries = browser.session.entries.filter { $0.url.path == repository.path }
        browser.rebuildContextMenu(childMenu, entries: repoEntries)
        guard let action = childMenu.item(withTitle: "Git")?.submenu?.items.first,
              (action.representedObject as? GitSelection)?.root.path == repository.path else { throw SmokeFailure.failed("Missing child Git menu") }
        NSApp.sendAction(action.action!, to: action.target, from: action)
        try await waitForCondition("Git changes panel loaded") {
            NSApp.windows.contains { window in
                guard window.isVisible, window.windowController is GitReviewController,
                      let stack = window.contentView as? NSStackView else { return false }
                return stack.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first?.numberOfItems ?? 0 > 0
            }
        }
        browser.concealSecureFolders([repository])
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.windowController is GitReviewController }) else {
            throw SmokeFailure.failed("Lock retained a Git review of the concealed repository")
        }
        browser.navigate(.visit(repository)); try await waitForListing(browser)
        try await waitForCondition("Git main branch snapshot") { browser.gitSnapshot?.branch == "main" }
        guard let snapshot = browser.gitSnapshot else { throw SmokeFailure.failed("Missing Git snapshot") }
        guard let tableMenu = browser.table.menu, let window = browser.window,
              let file = browser.session.entries.first(where: { $0.name == "modified.txt" }) else {
            throw SmokeFailure.failed("Missing file properties fixture")
        }
        browser.rebuildContextMenu(tableMenu, entries: [file])
        guard let properties = tableMenu.item(withTitle: L10n.text("command.properties")),
              let selector = properties.action else { throw SmokeFailure.failed("Missing file properties command") }
        NSApp.sendAction(selector, to: properties.target, from: properties)
        guard let sheet = window.attachedSheet, let content = sheet.contentView else {
            throw SmokeFailure.failed("File properties window did not open")
        }
        func propertiesText(_ view: NSView) -> String? {
            if let text = view as? NSTextView, text.string.contains(file.url.path) { return text.string }
            return view.subviews.lazy.compactMap { propertiesText($0) }.first
        }
        guard let details = propertiesText(content), details.contains(L10n.text("column.modified")),
              details.contains(L10n.text("column.size")) else { throw SmokeFailure.failed("Incomplete file properties") }
        window.endSheet(sheet)
        let expected: [(String, GitStatusKind, Bool)] = [("clean.txt", .clean, false), ("modified.txt", .modified, false),
            ("staged.txt", .modified, false), ("new file.txt", .untracked, false), ("ignored.log", .ignored, false),
            ("conflict.txt", .conflicted, false), ("Nested", .modified, true), ("cache", .ignored, true), ("renamed 日本語.txt", .renamed, false)]
        for (name, kind, directory) in expected {
            guard snapshot.status(for: repository.appendingPathComponent(name), isDirectory: directory)?.kind == kind else {
                throw SmokeFailure.failed("Wrong Git state for \(name)")
            }
            let item = try cell(name)
            guard !item.gitBadge.isHidden, item.gitBadge.image != nil,
                  item.toolTip?.contains(L10n.text("git.status.\(kind.rawValue)")) == true else {
                throw SmokeFailure.failed("Missing localized Git decoration for \(name)")
            }
        }
        let outline = browser.tree.outline
        func expand(_ node: FolderNode) async throws {
            outline.expandItem(node)
            try await waitForCondition("Git tree expansion") { !node.loading && outline.isItemExpanded(node) }
        }
        guard let home = outline.item(atRow: 0) as? FolderNode else { throw SmokeFailure.failed("Missing Git tree home") }
        try await expand(home)
        guard let group = home.children?.first(where: { $0.url.path == parent.path }) else { throw SmokeFailure.failed("Missing Git tree fixtures") }
        try await expand(group)
        guard let repoNode = group.children?.first(where: { $0.url.path == repository.path }) else { throw SmokeFailure.failed("Missing repository tree node") }
        try await expand(repoNode)
        guard let nested = repoNode.children?.first(where: { $0.title == "Nested" }),
              let treeCell = outline.view(atColumn: 0, row: outline.row(forItem: nested), makeIfNecessary: true) as? FileNameCell,
              !treeCell.gitBadge.isHidden, treeCell.toolTip?.contains(L10n.text("git.status.modified")) == true else {
            throw SmokeFailure.failed("Missing aggregate Git state in tree")
        }
        guard browser.gitSummaryText.contains("main"), browser.gitSummaryText.contains(L10n.text("git.status.conflicted")) else {
            throw SmokeFailure.failed("Git branch or aggregate conflict missing from status bar")
        }
        if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1) {
            let path = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path + "-git.png"
            try browser.savePreview(to: URL(fileURLWithPath: path))
        }
        try Data("fresh local modification\n".utf8).write(to: repository.appendingPathComponent("clean.txt"))
        browser.refresh(nil)
        try await waitForListing(browser)
        try await waitForCondition("Git F5 bypassed cache") { browser.gitSnapshot?.status(for: repository.appendingPathComponent("clean.txt"), isDirectory: false)?.kind == .modified }
        browser.navigate(.visit(worktree))
        guard browser.gitSnapshot == nil, browser.gitSummaryText.isEmpty else { throw SmokeFailure.failed("Git state survived pending navigation") }
        try await waitForListing(browser)
        try await waitForCondition("linked worktree branch") { browser.gitSnapshot?.branch == "feature/ui" }
        browser.navigate(.visit(root)); try await waitForListing(browser)
        guard browser.gitSnapshot == nil, browser.gitSummaryText.isEmpty else { throw SmokeFailure.failed("Git status leaked to unrelated folder") }
        // A deliberately late provider cannot decorate the next directory or a closed browser.
        let slow = GitBrowserState(inspect: { url, _ in
            if url == repository {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { continuation.resume() }
                }
                return .repository(snapshot)
            }
            return .notRepository
        }, roots: { _ in [] })
        slow.update(directory: repository, entries: [])
        try await Task.sleep(for: .milliseconds(220))
        let heartbeat = ContinuousClock.now
        slow.update(directory: root, entries: [])
        try await Task.sleep(for: .milliseconds(20))
        guard heartbeat.duration(to: .now) < .milliseconds(250) else { throw SmokeFailure.failed("Git query blocked UI heartbeat") }
        try await Task.sleep(for: .milliseconds(400))
        guard slow.snapshot == nil else { throw SmokeFailure.failed("Late Git result replaced new folder") }
        slow.update(directory: repository, entries: [])
        try await Task.sleep(for: .milliseconds(220))
        slow.stop()
        try await Task.sleep(for: .milliseconds(400))
        guard slow.snapshot == nil, slow.result == nil else { throw SmokeFailure.failed("Git result survived stop") }
    }

    private func testFileTypeIcons(root: URL, arguments: [String]) async throws {
        guard let browser = controller else { throw SmokeFailure.failed("Missing icon browser") }
        let folder = root.appendingPathComponent("IconFixtures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["01-PDF.pdf", "02-Video.mp4", "03-Audio.mp3", "04-Image.png", "05-Presentation.pptx", "06-Spreadsheet.xlsx", "07-Archive.rar", "08-Text.log", "09-Code.swift"]
        for name in names { try Data("icon fixture".utf8).write(to: folder.appendingPathComponent(name)) }
        let original = folder.appendingPathComponent(names[0])
        let alias = folder.appendingPathComponent("10-Alias.pdf")
        try URL.writeBookmarkData(original.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil), to: alias)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("11-Link.pdf").path, withDestinationPath: original.path)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("12-Application.app"), withIntermediateDirectories: false)
        browser.navigate(.visit(folder)); try await waitForListing(browser)
        browser.window?.makeKeyAndOrderFront(nil)
        browser.table.deselectAll(nil)
        for entry in browser.session.entries {
            guard let row = (0..<browser.table.numberOfRows).first(where: {
                browser.tableView(browser.table, typeSelectStringFor: nil, row: $0)?.hasPrefix(String(entry.name.prefix(3))) == true
            }), let cell = browser.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileNameCell else {
                throw SmokeFailure.failed("Missing icon fixture cell")
            }
            cell.layoutSubtreeIfNeeded()
            guard cell.icon.image != nil, cell.icon.frame.width >= 22, cell.icon.frame.height >= 22,
                  cell.icon.frame.height <= browser.table.rowHeight,
                  cell.shortcutBadge.frame.width == 10, cell.shortcutBadge.frame.height == 10,
                  cell.shortcutBadge.isHidden == !(entry.isAlias || entry.isSymbolicLink) else {
                throw SmokeFailure.failed("File icon size or shortcut badge incorrect: \(entry.name), frame=\(cell.icon.frame), row=\(browser.table.rowHeight), badgeHidden=\(cell.shortcutBadge.isHidden), alias=\(entry.isAlias), link=\(entry.isSymbolicLink)")
            }
            if entry.isPackage { guard cell.icon.contentTintColor == nil else { throw SmokeFailure.failed("Application icon lost native colors") } }
            else {
                let descriptor = FileTypeIcon.appearance(for: entry)
                guard NSImage(systemSymbolName: descriptor.symbol, accessibilityDescription: nil) != nil,
                      cell.icon.contentTintColor != nil else { throw SmokeFailure.failed("Missing file type symbol") }
            }
        }
        guard browser.session.entries.first(where: { $0.url.lastPathComponent == "10-Alias.pdf" })?.isAlias == true else {
            throw SmokeFailure.failed("Finder alias badge was not based on file metadata")
        }
        if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1) {
            try browser.savePreview(to: URL(fileURLWithPath: URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path + "-icons.png"))
        }
        try FileManager.default.removeItem(at: folder)
        browser.navigate(.visit(root)); try await waitForListing(browser)
    }

    private func testMediaLoadingLifecycle(root: URL) async throws {
        try await waitForCondition("previous AV sessions retired") { MediaPlaybackSession.activeSessionCount == 0 }
        let url = root.appendingPathComponent("Media/03-Vídeo.mov")
        let entry = FileEntry(url: url, name: url.lastPathComponent, isDirectory: false)
        let offline = MediaViewerWindowController(availability: { _ in .needsDownload })
        offline.open(entries: [entry], selectedURL: url)
        try await waitForCondition("offline viewer message") { offline.message == L10n.text("media.needs_download") }
        guard offline.player == nil, MediaPlaybackSession.activeSessionCount == 0 else {
            throw SmokeFailure.failed("Offline media started an AV session")
        }
        offline.close()
        let delayedViewer = MediaViewerWindowController(availability: { url in
            Thread.sleep(forTimeInterval: 0.35)
            return .available(url)
        }, preparationTimeout: 0.05)
        delayedViewer.open(entries: [entry], selectedURL: url)
        try await waitForCondition("metadata deadline without waiting for IO") { delayedViewer.message == L10n.text("media.loading_timeout") }
        let closePending = ContinuousClock.now
        delayedViewer.close()
        try await Task.sleep(for: .milliseconds(20))
        guard closePending.duration(to: .now) < .milliseconds(250) else { throw SmokeFailure.failed("Closing metadata load blocked UI") }
        try await Task.sleep(for: .milliseconds(400))
        guard delayedViewer.player == nil, delayedViewer.window?.isVisible == false,
              MediaPlaybackSession.activeSessionCount == 0 else { throw SmokeFailure.failed("Late metadata load reopened a player") }
        let probes = (0..<3).map { _ in SmokePlaybackProbe() }
        var sessions: [MediaPlaybackSession] = []
        for (index, probe) in probes.enumerated() {
            guard let session = MediaPlaybackSession.start(url: url, timeout: index == 0 ? 0.05 : 5,
                loader: { _ in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { continuation.resume(returning: false) }
                    }
                }, beforeRelease: {
                    probe.beginRelease()
                    Thread.sleep(forTimeInterval: 0.3)
                }, completion: { _, outcome in probe.record(outcome) }) else {
                throw SmokeFailure.failed("Could not allocate bounded AV fixture session")
            }
            sessions.append(session)
        }
        defer { for session in sessions { session.retireAfterDetachingUI() } }
        guard MediaPlaybackSession.start(url: url, completion: { _, _ in }) == nil else {
            throw SmokeFailure.failed("AV session limit admitted excess work")
        }
        // Give all three injected readers time to enter their asynchronous load.
        try await Task.sleep(for: .milliseconds(30))
        let closeStarted = ContinuousClock.now
        sessions[1].retireAfterDetachingUI(); sessions[2].retireAfterDetachingUI()
        try await Task.sleep(for: .milliseconds(20))
        guard closeStarted.duration(to: .now) < .milliseconds(250) else {
            throw SmokeFailure.failed("Cancelling slow AV blocked the UI")
        }
        try await waitForCondition("AV timeout delivered without waiting for reader") { probes[0].outcome == .timedOut }
        guard probes[1].outcome == .cancelled, probes[2].outcome == .cancelled,
              MediaPlaybackSession.activeSessionCount == 3 else { throw SmokeFailure.failed("AV cancellation released a still-loading slot early") }
        try await waitForCondition("AV background release barriers") { probes.allSatisfy { $0.releaseStarted } }
        let heartbeat = ContinuousClock.now
        // Repeated retirement also must not acquire a lock held during AV final release.
        for session in sessions { session.retireAfterDetachingUI() }
        try await Task.sleep(for: .milliseconds(20))
        guard heartbeat.duration(to: .now) < .milliseconds(250), probes.allSatisfy({ $0.releasedOffMain }) else {
            throw SmokeFailure.failed("AV teardown or ownership lock blocked main thread")
        }
        try await waitForCondition("bounded AV fixtures released") { MediaPlaybackSession.activeSessionCount == 0 }
        guard sessions.allSatisfy({ $0.hasFinishedRetirement }), probes.allSatisfy({ $0.callbackCount == 1 }) else {
            throw SmokeFailure.failed("AV session retained resources or completed twice")
        }
        controller?.window?.makeKeyAndOrderFront(nil)
    }

    private func testImageZoom(viewer: MediaViewerWindowController, folder: URL, entries: [FileEntry], image: URL) async throws {
        guard let window = viewer.window, let content = window.contentView,
              let viewport = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "explorer.media.imageViewport" }) as? NSScrollView,
              let picture = descendants(of: viewport).first(where: { $0.accessibilityIdentifier() == "explorer.media.image" }) as? NSImageView,
              let actual = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "explorer.media.zoom.actual" }) as? NSButton,
              let fit = descendants(of: content).first(where: { $0.accessibilityIdentifier() == "explorer.media.zoom.fit" }) as? NSButton else {
            throw SmokeFailure.failed("Missing zoom controls")
        }
        guard viewer.nativeResolutionAvailable, viewer.imageIsFit else { throw SmokeFailure.failed("Image did not open in native-capable Fit mode") }
        actual.performClick(nil)
        guard viewer.imageZoomFactor == 1, !viewer.imageIsFit,
              abs(viewer.renderedImageSize.width * viewer.imageBackingScale - viewer.sourcePixelSize.width) < 0.01,
              abs(viewer.renderedImageSize.height * viewer.imageBackingScale - viewer.sourcePixelSize.height) < 0.01 else {
            throw SmokeFailure.failed("Actual size is not one image pixel per screen pixel")
        }
        viewer.zoomIn()
        guard abs(viewer.imageZoomFactor - 1.25) < 0.001 else { throw SmokeFailure.failed("Zoom In failed") }
        viewer.zoomOut()
        guard viewer.imageZoomFactor == 1 else { throw SmokeFailure.failed("Zoom Out failed") }
        for _ in 0..<10 { viewer.zoomIn() }
        guard viewer.imageZoomFactor == 8, viewport.documentView!.frame.width > viewport.contentSize.width else {
            throw SmokeFailure.failed("Zoom limit or scrollable document failed")
        }
        viewport.contentView.scroll(to: NSPoint(x: 150, y: 100)); viewport.reflectScrolledClipView(viewport.contentView)
        func center() -> NSPoint {
            NSPoint(x: (viewport.contentView.bounds.midX - picture.frame.minX) / picture.frame.width,
                    y: (viewport.contentView.bounds.midY - picture.frame.minY) / picture.frame.height)
        }
        let anchor = center()
        viewer.zoomOut()
        guard abs(center().x - anchor.x) < 0.01, abs(center().y - anchor.y) < 0.01 else {
            throw SmokeFailure.failed("Zoom did not preserve viewed center")
        }
        // A mouse-down in an inactive macOS window only activates it. Establish focus
        // before testing drag delivery, even if another app became active during the smoke.
        NSApp.activate(ignoringOtherApps: true)
        try await waitForCondition("application active for image drag") { NSApp.isActive }
        // Activation can restore the browser's previous key window asynchronously.
        // Choose the media window after activation has completed.
        window.makeKeyAndOrderFront(nil)
        try await waitForCondition("image window active for drag") { window.isKeyWindow }
        // Dragging the image pans the scrollable document without consuming file-navigation keys.
        let start = viewport.convert(NSPoint(x: viewport.bounds.midX, y: viewport.bounds.midY), to: nil)
        let beforePan = viewport.contentView.bounds.origin
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, NSPoint(x: start.x + 20, y: start.y)), (.leftMouseUp, NSPoint(x: start.x + 20, y: start.y))] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw SmokeFailure.failed("Cannot create image pan event") }
            NSApp.sendEvent(event)
        }
        guard viewport.contentView.bounds.origin.x < beforePan.x else { throw SmokeFailure.failed("Dragging did not pan image: before=\(beforePan), after=\(viewport.contentView.bounds.origin), windowKey=\(window.isKeyWindow), image=\(picture.frame), viewport=\(viewport.frame)") }
        let originalFrame = window.frame
        fit.performClick(nil)
        window.setContentSize(NSSize(width: 640, height: 440)); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        guard viewer.imageIsFit, viewer.renderedImageSize.width <= viewport.contentSize.width + 1,
              viewer.renderedImageSize.height <= viewport.contentSize.height + 1 else { throw SmokeFailure.failed("Fit did not follow window resize") }
        actual.performClick(nil)
        window.setFrame(originalFrame, display: true); window.contentView?.layoutSubtreeIfNeeded()
        guard viewer.imageZoomFactor == 1 else { throw SmokeFailure.failed("Resize changed manual zoom") }
        let zoomFolder = folder.appendingPathComponent("Zoom")
        for (name, width, height, native) in [("full-resolution.png", 4101.0, 2.0, true), ("oriented.jpg", 20.0, 30.0, true), ("limited-preview.png", 17000.0, 2.0, false)] {
            let file = zoomFolder.appendingPathComponent(name)
            viewer.open(entries: [FileEntry(url: file, name: name, isDirectory: false)], selectedURL: file)
            try await waitForCondition("zoom fixture \(name)") { viewer.imageLoaded }
            guard viewer.sourcePixelSize == NSSize(width: width, height: height), viewer.nativeResolutionAvailable == native,
                  actual.isEnabled == native else { throw SmokeFailure.failed("Image dimensions, orientation, or native-resolution limit failed: \(name)") }
            if native {
                actual.performClick(nil)
                guard abs(viewer.renderedImageSize.width * viewer.imageBackingScale - width) < 0.01 else { throw SmokeFailure.failed("Full resolution was silently reduced") }
                let physicalOrigin = picture.convert(NSPoint.zero, to: nil)
                for coordinate in [physicalOrigin.x, physicalOrigin.y] {
                    let pixel = coordinate * viewer.imageBackingScale
                    guard abs(pixel - pixel.rounded()) < 0.01 else { throw SmokeFailure.failed("Actual-size image is not aligned to physical pixels") }
                }
            } else {
                let before = viewer.imageZoomFactor
                viewer.actualSize()
                guard viewer.imageZoomFactor == before, !viewer.imageResolutionMessage.isEmpty else {
                    throw SmokeFailure.failed("Reduced preview offered fake actual size")
                }
            }
        }
        viewer.open(entries: entries, selectedURL: image)
        try await waitForCondition("image restored after zoom") { viewer.imageLoaded }
        guard viewer.imageIsFit else { throw SmokeFailure.failed("New file did not reset image fit") }
    }

    private func testMediaViewer(root: URL, arguments: [String]) async throws {
        guard let browser = controller else { throw SmokeFailure.failed("Missing media browser") }
        let folder = root.appendingPathComponent("Media")
        let image = folder.appendingPathComponent("01-Imagem 日本語.png")
        let audio = folder.appendingPathComponent("02-Áudio.wav")
        let video = folder.appendingPathComponent("03-Vídeo.mov")
        browser.navigate(.visit(folder)); try await waitForListing(browser)
        browser.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        guard let row = (0..<browser.table.numberOfRows).first(where: {
            browser.tableView(browser.table, typeSelectStringFor: nil, row: $0)?.hasPrefix("01-") == true
        }) else { throw SmokeFailure.failed("Missing image fixture row") }
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        browser.window?.makeKeyAndOrderFront(nil); browser.window?.makeFirstResponder(browser.table)
        try sendKey("\r", code: 36, flags: [], to: browser)
        guard let viewer = mediaViewer, let window = viewer.window else { throw SmokeFailure.failed("Enter did not open media viewer") }
        defer { viewer.close() }
        try await waitForCondition("media image") { viewer.imageLoaded }
        try await testImageZoom(viewer: viewer, folder: folder, entries: browser.session.entries, image: image)
        guard viewer.currentURL == image, !viewer.canPrevious, viewer.canNext,
              window.isVisible, browser.window?.isVisible == true else { throw SmokeFailure.failed("Media order or separate window failed") }
        func key(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { throw SmokeFailure.failed("Cannot create media key") }
            NSApp.sendEvent(event)
        }
        try key(123, characters: "\u{F702}")
        guard viewer.currentURL == image else { throw SmokeFailure.failed("Previous wrapped at start") }
        if let index = arguments.firstIndex(of: "--preview"), arguments.indices.contains(index + 1), let content = window.contentView {
            let path = URL(fileURLWithPath: arguments[index + 1]).deletingPathExtension().path + "-media.png"
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        try key(124, characters: "\u{F703}")
        try await waitForCondition("audio ready") { viewer.currentURL == audio && viewer.playbackReady }
        guard let audioPlayer = viewer.player, audioPlayer.rate == 0 else { throw SmokeFailure.failed("Audio autoplayed") }
        audioPlayer.play()
        try await waitForCondition("audio advances") { audioPlayer.currentTime().seconds > 0.05 }
        audioPlayer.pause()
        guard let nativeView = window.contentView.flatMap({ descendants(of: $0).first { $0.accessibilityIdentifier() == "explorer.media.player" } }) else {
            throw SmokeFailure.failed("Missing native media controls")
        }
        let nativeFocus = descendants(of: nativeView).first { $0 is NSSlider && $0.acceptsFirstResponder } ?? nativeView
        guard window.makeFirstResponder(nativeFocus) else { throw SmokeFailure.failed("Cannot focus native playback controls") }
        try key(123, characters: "\u{F702}")
        guard viewer.currentURL == audio else { throw SmokeFailure.failed("File navigation stole native playback control keys") }
        viewer.focusNavigation()
        try key(121, characters: "\u{F72D}")
        try await waitForCondition("video ready") { viewer.currentURL == video && viewer.playbackReady }
        guard audioPlayer.currentItem == nil, audioPlayer.rate == 0, let videoPlayer = viewer.player,
              !viewer.canNext, videoPlayer.rate == 0 else { throw SmokeFailure.failed("Switch retained prior audio or autoplayed video") }
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        videoPlayer.currentItem?.add(videoOutput)
        videoPlayer.play()
        try await waitForCondition("video decoded frame") {
            videoPlayer.currentTime().seconds > 0.05 && videoOutput.hasNewPixelBuffer(forItemTime: videoPlayer.currentTime())
        }
        guard videoOutput.copyPixelBuffer(forItemTime: videoPlayer.currentTime(), itemTimeForDisplay: nil) != nil else {
            throw SmokeFailure.failed("Video failed to decode pixels")
        }
        videoPlayer.pause()
        videoPlayer.currentItem?.remove(videoOutput)
        try key(121, characters: "\u{F72D}")
        guard viewer.currentURL == video else { throw SmokeFailure.failed("Next wrapped at end") }
        try key(116, characters: "\u{F72C}")
        try await waitForCondition("previous audio") { viewer.currentURL == audio && viewer.playbackReady }
        guard videoPlayer.currentItem == nil, videoPlayer.rate == 0 else { throw SmokeFailure.failed("Video survived navigation") }
        try key(123, characters: "\u{F702}")
        try await waitForCondition("previous image") { viewer.currentURL == image && viewer.imageLoaded }
        guard let next = window.contentView.flatMap({ descendants(of: $0).first { $0.accessibilityIdentifier() == "explorer.media.next" } }) as? NSButton,
              let previous = window.contentView.flatMap({ descendants(of: $0).first { $0.accessibilityIdentifier() == "explorer.media.previous" } }) as? NSButton else {
            throw SmokeFailure.failed("Missing accessible navigation buttons")
        }
        next.performClick(nil)
        try await waitForCondition("next button audio") { viewer.currentURL == audio && viewer.playbackReady }
        let stablePlayer = viewer.player
        let language = L10n.preferences.selection
        changeLanguage(language == .german ? .english : .german)
        guard viewer.player === stablePlayer, window.isVisible, window.title.contains(L10n.text("media.title")),
              next.toolTip == L10n.text("media.next") else { throw SmokeFailure.failed("Language rebuild lost media or translations") }
        let font = ExplorerStyle.preferences.fontSize(for: .files)
        ExplorerStyle.preferences.setFontSize(font < 24 ? font + 1 : font - 1, for: .files)
        guard viewer.player === stablePlayer else { throw SmokeFailure.failed("Font rebuild replaced active player") }
        ExplorerStyle.preferences.setFontSize(font, for: .files)
        changeLanguage(language)
        try await Task.sleep(for: .milliseconds(100))
        window.makeKeyAndOrderFront(nil)
        // An editable control owns its arrow keys instead of navigating files.
        let text = NSTextField(string: "fixture text")
        text.frame = NSRect(x: 20, y: 20, width: 160, height: 24)
        window.contentView?.addSubview(text)
        window.makeFirstResponder(text); text.selectText(nil)
        try key(123, characters: "\u{F702}")
        guard viewer.currentURL == audio else { throw SmokeFailure.failed("Media navigation stole editing keys") }
        text.removeFromSuperview(); viewer.focusNavigation()
        previous.performClick(nil)
        try await waitForCondition("previous button image") { viewer.imageLoaded && viewer.currentURL == image }
        viewer.next(); viewer.next(); viewer.previous(); viewer.previous()
        try await waitForCondition("rapid final image") { viewer.imageLoaded && viewer.currentURL == image }
        try await Task.sleep(for: .milliseconds(200))
        guard viewer.player == nil else { throw SmokeFailure.failed("Late player appeared after rapid navigation") }
        let broken = folder.appendingPathComponent("broken.png")
        let brokenVideo = folder.appendingPathComponent("broken.mov")
        let missing = folder.appendingPathComponent("missing.wav")
        let alias = folder.appendingPathComponent("image-link.png")
        try Data("invalid media".utf8).write(to: broken)
        try Data("invalid media".utf8).write(to: brokenVideo)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: image.path)
        defer { for url in [broken, brokenVideo, alias] { try? FileManager.default.removeItem(at: url) } }
        let fixtures = [broken, image, brokenVideo, missing, alias].map { FileEntry(url: $0, name: $0.lastPathComponent, isDirectory: false) }
        viewer.open(entries: fixtures, selectedURL: broken)
        try await waitForCondition("invalid image error") { viewer.message == L10n.text("media.unavailable") }
        viewer.next()
        try await waitForCondition("image after error") { viewer.imageLoaded }
        viewer.next()
        try await waitForCondition("invalid movie error") { viewer.message == L10n.text("media.unavailable") }
        viewer.next()
        try await waitForCondition("missing file error") { viewer.message == L10n.text("media.unavailable") }
        viewer.next()
        try await waitForCondition("symlink image") { viewer.currentURL == alias && viewer.imageLoaded }
        let audioEntry = FileEntry(url: audio, name: audio.lastPathComponent, isDirectory: false)
        viewer.open(entries: [audioEntry], selectedURL: audio)
        try await waitForCondition("audio for close") { viewer.playbackReady }
        let closingPlayer = viewer.player
        closingPlayer?.play()
        window.standardWindowButton(.closeButton)?.performClick(nil)
        guard !window.isVisible, viewer.player == nil, viewer.currentURL == nil,
              controller?.window?.isVisible == true else {
            throw SmokeFailure.failed("Closing viewer retained playback UI or closed browser")
        }
        try await waitForCondition("closed player released off main") { closingPlayer?.rate == 0 && closingPlayer?.currentItem == nil }
        viewer.open(entries: [audioEntry], selectedURL: audio)
        viewer.close()
        try await Task.sleep(for: .milliseconds(200))
        guard viewer.player == nil, !window.isVisible else { throw SmokeFailure.failed("Cancelled load reopened playback") }
        viewer.open(entries: [fixtures[1]], selectedURL: image)
        try await waitForCondition("image before Command-W") { viewer.imageLoaded }
        try key(13, characters: "w", flags: .command)
        guard !window.isVisible, controller?.workspace.activeTab != nil else { throw SmokeFailure.failed("Command-W closed browser tab instead of viewer") }
        guard let currentBrowser = controller else { throw SmokeFailure.failed("Browser lost after media") }
        currentBrowser.navigate(.visit(root)); try await waitForListing(currentBrowser)
        currentBrowser.window?.makeKeyAndOrderFront(nil)
        currentBrowser.window?.makeFirstResponder(currentBrowser.table)
    }

    private func checkDialog(_ dialog: NSWindow, named name: String, over main: NSWindow, visible: NSRect) throws {
        let expectedX = max(visible.minX, min(main.frame.midX - dialog.frame.width / 2, visible.maxX - dialog.frame.width))
        let expectedY = min(visible.maxY - dialog.frame.height, max(main.frame.midY - dialog.frame.height / 2, visible.minY))
        guard abs(dialog.frame.minX - expectedX) <= 2, abs(dialog.frame.minY - expectedY) <= 2 else {
            throw SmokeFailure.failed("\(name) origin \(dialog.frame.origin), expected \(expectedX), \(expectedY)")
        }
    }

    private func testDialogPlacement(browser: ExplorerWindowController) async throws {
        guard let main = browser.window, let visible = main.screen?.visibleFrame else {
            throw SmokeFailure.failed("Missing Explorer display")
        }
        let original = main.frame
        defer { main.setFrame(original, display: false) }
        main.setFrame(NSRect(x: visible.minX + 10, y: visible.minY + 10, width: 780, height: 590), display: true)
        showFontSettings(nil)
        guard let fonts = fontSettings?.window else { throw SmokeFailure.failed("Missing font settings") }
        try self.checkDialog(fonts, named: "Font settings", over: main, visible: visible)
        fonts.close()
        main.setFrameOrigin(NSPoint(x: main.frame.minX + 45, y: main.frame.minY + 25))
        showFontSettings(nil)
        try self.checkDialog(fonts, named: "Reopened font settings", over: main, visible: visible)
        fonts.close()

        let alert = NSAlert()
        alert.messageText = "Dialog placement"
        alert.beginSheetModal(for: main) { _ in }
        try await Task.sleep(for: .milliseconds(450))
        defer { if alert.window.sheetParent != nil { main.endSheet(alert.window) } }
        try self.checkDialog(alert.window, named: "Sheet", over: main, visible: visible)
        main.endSheet(alert.window)
        try await Task.sleep(for: .milliseconds(350))

        let ocr = OCRWindowController()
        ocr.showWindow(nil)
        defer { ocr.close() }
        guard let secondary = ocr.window else { throw SmokeFailure.failed("Missing OCR window") }
        secondary.setFrame(NSRect(x: main.frame.minX + 130, y: main.frame.minY + 90,
                                  width: main.frame.width, height: main.frame.height), display: true)
        let save = NSSavePanel()
        save.beginSheetModal(for: secondary) { _ in }
        defer { if save.sheetParent != nil { save.cancel(nil) } }
        try await waitForCondition("OCR save sheet") { save.isVisible && secondary.attachedSheet === save }
        try await Task.sleep(for: .milliseconds(450))
        try self.checkDialog(save, named: "Save sheet on displaced OCR window", over: main, visible: visible)
        save.cancel(nil)
        try await waitForCondition("OCR sheet cancellation") { secondary.attachedSheet == nil }
        ocr.close()

        func checkModal(_ dialog: NSWindow, _ name: String, run: () -> NSApplication.ModalResponse) throws {
            var failure: Error?
            var inspected = false
            let timer = Timer(timeInterval: 0.4, repeats: false) { _ in
                MainActor.assumeIsolated {
                    inspected = true
                    do { try self.checkDialog(dialog, named: name, over: main, visible: visible) } catch { failure = error }
                    if let picker = dialog as? NSSavePanel { picker.cancel(nil) } else { NSApp.abortModal() }
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            _ = DialogPlacement.runModal(dialog, present: run)
            if let failure { throw failure }
            if !inspected { throw SmokeFailure.failed("Modal did not open") }
        }
        let modal = NSAlert()
        modal.messageText = "Dialog placement"
        try checkModal(modal.window, "Modal alert") { modal.runModal() }
        let picker = NSOpenPanel()
        try checkModal(picker, "Folder picker") { picker.runModal() }
        showAbout(nil)
        guard let about = NSApp.keyWindow, about !== main else { throw SmokeFailure.failed("Missing About panel") }
        try self.checkDialog(about, named: "About", over: main, visible: visible)
        about.close()
    }

    private func testProtectFolderSetup(root: URL, browser: ExplorerWindowController) async throws {
        let service = SecureFolderService(directory: root.appendingPathComponent("VaultSettings"))
        let commands = SecureFolderCommands(service: service)
        let previous = browser.secureFolders
        browser.secureFolders = commands
        defer { browser.secureFolders = previous }
        let folder = root.appendingPathComponent("Selected folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        // /tmp fixtures inherit wheel. Use the account group for this user-owned folder.
        try FileManager.default.setAttributes([.groupOwnerAccountID: getegid()], ofItemAtPath: folder.path)
        let note = folder.appendingPathComponent("note")
        let contents = Data("disposable fixture".utf8)
        try contents.write(to: note)

        typealias Step = (title: String, values: [String], cancel: Bool)
        func selectProtect(_ steps: [Step], target: URL = folder) async throws {
            guard let menu = browser.table.menu else { throw SmokeFailure.failed("Missing file menu") }
            browser.rebuildContextMenu(menu, entries: [FileEntry(url: target, name: target.lastPathComponent, isDirectory: true)])
            guard let item = menu.item(withTitle: L10n.text("vault.protect")), let action = item.action else {
                throw SmokeFailure.failed("Missing Protect Folder")
            }
            var index = 0
            var rejectedWindow: NSWindow?
            var unexpected: String?
            let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let view = NSApp.modalWindow?.contentView else { return }
                    let views = self.descendants(of: view)
                    let fields = views.compactMap { $0 as? NSSecureTextField }
                    let labels = views.compactMap { ($0 as? NSTextField)?.stringValue }
                    guard index < steps.count, labels.contains(L10n.text(steps[index].title)),
                          fields.count == steps[index].values.count else {
                        unexpected = "step \(index), fields \(fields.count), labels \(labels.filter { !$0.isEmpty && !steps.flatMap(\.values).contains($0) })"
                        NSApp.abortModal()
                        return
                    }
                    for field in fields {
                        guard let label = views.compactMap({ $0 as? NSTextField }).first(where: {
                            !$0.isEditable && $0.stringValue == field.accessibilityLabel()
                        }) else {
                            unexpected = "Missing password field label"
                            NSApp.abortModal()
                            return
                        }
                        let labelRect = label.convert(label.bounds, to: nil)
                        let fieldRect = field.convert(field.bounds, to: nil)
                        guard labelRect.height >= label.intrinsicContentSize.height,
                              labelRect.minY - fieldRect.maxY >= 6 else {
                            unexpected = "Password label compressed or too close to focus ring: \(labelRect), \(fieldRect)"
                            NSApp.abortModal()
                            return
                        }
                    }
                    if let previous = rejectedWindow {
                        guard previous === view.window,
                              fields.first?.stringValue == steps[index - 1].values.first,
                              views.contains(where: { ($0 as? NSTextField)?.stringValue == L10n.text("vault.mismatch") && !$0.isHiddenOrHasHiddenAncestor }) else {
                            unexpected = "Mismatch dismissed the form or lost the entered password"
                            NSApp.abortModal()
                            return
                        }
                        rejectedWindow = nil
                    }
                    let step = steps[index]
                    index += 1
                    for (field, value) in zip(fields, step.values) where field.stringValue != value { field.stringValue = value }
                    if !step.cancel, step.values.last?.isEmpty == true || step.values.suffix(2).first != step.values.last {
                        rejectedWindow = view.window
                    }
                    let key = step.cancel ? "dialog.cancel" : "dialog.confirm"
                    guard let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.text(key) }) else {
                        unexpected = "Missing password form button"
                        NSApp.abortModal()
                        return
                    }
                    button.performClick(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            guard NSApp.sendAction(action, to: item.target, from: item) else { throw SmokeFailure.failed("Protect Folder dispatch") }
            try await waitForCondition("Protect Folder completion") { commands.validateMenuItem(item) }
            guard unexpected == nil, index == steps.count else {
                throw SmokeFailure.failed("Protect Folder dialogs: \(unexpected ?? "completed \(index) of \(steps.count)")")
            }
        }

        try await selectProtect([("vault.master", ["", ""], false), ("vault.master", ["master", "different"], false),
                                 ("vault.master", ["", ""], true)])
        guard !(await service.hasMasterPassword), try Data(contentsOf: note) == contents else {
            throw SmokeFailure.failed("Cancelling master setup changed the fixture")
        }
        try await selectProtect([("vault.master", ["master", "different"], false), ("vault.master", ["master", "master"], false), ("vault.protect", ["folder", "folder"], false)])
        let otherFolder = root.appendingPathComponent("Another folder")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: false)
        try await selectProtect([("vault.protect", ["", "", ""], true)], target: otherFolder)
        let vault = root.appendingPathComponent("Selected folder.myexplorervault")
        let mount = try await service.unlock(vault, password: "master")
        do {
            let recovered = try Data(contentsOf: mount.appendingPathComponent("note"))
            guard recovered == contents else { throw SmokeFailure.failed("Protected folder contents") }
            let alias = root.appendingPathComponent("Link to unlocked folder")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mount)
            let linkedTab = browser.addTab(at: alias)
            try await waitForListing(browser)
            guard linkedTab.session.entries.contains(where: { $0.name == "note" }) else {
                throw SmokeFailure.failed("Missing secure file in linked tab")
            }
            linkedTab.filterQuery = "note"
            showOCR(root.appendingPathComponent("Example.pdf"))
            secureFolders.onConceal?([mount])
            guard !browser.workspace.tabs.contains(where: { $0.id == linkedTab.id }),
                  ocrViewer?.window?.isVisible == true else {
                throw SmokeFailure.failed("Lock retained linked tab or closed unrelated OCR")
            }
            showOCR(alias.appendingPathComponent("note"))
            secureFolders.onConceal?([mount])
            guard ocrViewer?.window?.isVisible == false else {
                throw SmokeFailure.failed("Lock retained OCR from a linked path")
            }
            try await testLockDuringVaultAlert(commands: commands, mount: mount, ordinaryFolder: root)
        } catch {
            try await service.lockAll()
            throw error
        }
    }

    private func testLockDuringVaultAlert(commands: SecureFolderCommands, mount: URL, ordinaryFolder: URL) async throws {
        var requested = false
        var deadline: Date?
        var abortedByTest = false
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow != nil else { return }
                if !requested {
                    requested = true
                    deadline = Date().addingTimeInterval(3)
                    commands.lockAll()
                } else if let deadline, Date() > deadline {
                    abortedByTest = true
                    NSApp.abortModal()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        // This validation alert has no password fields. It must also yield to a lock.
        commands.unlock(ordinaryFolder)
        try await waitForCondition("vault detached while validation alert was open") {
            requested && !FileManager.default.fileExists(atPath: mount.appendingPathComponent("note").path)
        }
        guard !abortedByTest else { throw SmokeFailure.failed("Lock waited for the user to dismiss an alert") }
    }

    private func testTrashUndo(root: URL, browser: ExplorerWindowController) async throws {
        let folder = root.appendingPathComponent("Restore test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("Restore-" + UUID().uuidString + ".txt")
        let original = Data("Deleted file".utf8), other = Data("New occupant".utf8)
        try original.write(to: file)
        browser.navigate(.visit(folder))
        try await waitForListing(browser)
        let commands = FileCommands.shared
        func choose(_ key: String) throws {
            guard let content = NSApp.windows.first(where: { $0.sheetParent is NSPanel })?.contentView,
                  let button = descendants(of: content).compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.text(key) }) else {
                throw SmokeFailure.failed("Missing decision button " + key)
            }
            button.performClick(nil)
        }
        func remove() async throws {
            commands.trash([FileEntry(url: file, name: file.lastPathComponent, isDirectory: false)])
            try await waitForCondition("delete prompt") { commands.hasPendingDecision }
            try choose("command.delete")
            try await waitForCondition("trash recorded") { !commands.isBusy }
            guard commands.undoKind == .trash, !FileManager.default.fileExists(atPath: file.path) else {
                throw SmokeFailure.failed("Delete did not record local Trash URL")
            }
        }
        func undo(_ modifier: NSEvent.ModifierFlags) throws {
            browser.window?.makeKeyAndOrderFront(nil)
            browser.window?.makeFirstResponder(browser.table)
            try sendKey("z", code: 6, flags: modifier, to: browser)
        }
        try await remove()
        try undo(.control)
        try await waitForCondition("Ctrl+Z restored") { !commands.isBusy }
        guard try Data(contentsOf: file) == original else { throw SmokeFailure.failed("Wrong restored contents") }
        try await remove()
        try other.write(to: file)
        try undo(.command)
        try await waitForCondition("restore conflict") { commands.hasPendingDecision }
        try choose("cloud.conflict.cancel")
        try await waitForCondition("cancel restore") { !commands.isBusy }
        guard try Data(contentsOf: file) == other, commands.undoKind == .trash else { throw SmokeFailure.failed("Cancel lost a file") }
        try undo(.command)
        try await waitForCondition("restore conflict retry") { commands.hasPendingDecision }
        try choose("cloud.conflict.keep_both")
        try await waitForCondition("restore both") { !commands.isBusy }
        let restored = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + " (2).txt")
        guard try Data(contentsOf: restored) == original, try Data(contentsOf: file) == other, commands.undoKind == nil else {
            throw SmokeFailure.failed("Keep Both did not preserve both files")
        }

        // Exercise the sidebar and its independent permanent-delete confirmation using only this fixture.
        try await remove()
        let tree = browser.tree.outline
        guard let trashRow = (0..<tree.numberOfRows).first(where: {
            (tree.item(atRow: $0) as? FolderNode)?.url.scheme == "myexplorer-trash"
        }) else { throw SmokeFailure.failed("Missing Trash in sidebar") }
        tree.selectRowIndexes(IndexSet(integer: trashRow), byExtendingSelection: false)
        guard let trashWindow = NSApp.windows.first(where: { $0.isVisible && $0.title == L10n.text("trash.title") }) else {
            throw SmokeFailure.failed("Missing Trash window")
        }
        guard let content = trashWindow.contentView else { throw SmokeFailure.failed("Missing Trash content") }
        let controls = descendants(of: content)
        let buttons = controls.compactMap { $0 as? NSButton }
        guard let table = controls.compactMap({ $0 as? NSTableView }).first,
              let erase = buttons.first(where: { $0.title == L10n.text("trash.erase") }),
              let restore = buttons.first(where: { $0.title == L10n.text("trash.restore") }) else {
            throw SmokeFailure.failed("Missing Trash controls")
        }
        func fixtureRow() -> Int? {
            (0..<table.numberOfRows).first {
                (table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTextField)?.stringValue == file.lastPathComponent
            }
        }
        try await waitForCondition("Trash displays the deleted fixture") { fixtureRow() != nil }
        guard let row = fixtureRow() else { throw SmokeFailure.failed("Deleted fixture disappeared") }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard erase.isEnabled, restore.isEnabled else { throw SmokeFailure.failed("Missing Trash actions for known origin") }
        erase.performClick(nil)
        guard let sheet = trashWindow.attachedSheet, let sheetContent = sheet.contentView,
              let cancel = descendants(of: sheetContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.text("dialog.cancel") }) else {
            throw SmokeFailure.failed("Permanent deletion did not ask for confirmation")
        }
        cancel.performClick(nil)
        try await waitForCondition("permanent deletion cancelled") { trashWindow.attachedSheet == nil && restore.isEnabled }
        restore.performClick(nil)
        try await waitForCondition("Trash restored fixture") { !commands.isBusy && FileManager.default.fileExists(atPath: file.path) }
        guard try Data(contentsOf: file) == other, commands.undoKind == nil else { throw SmokeFailure.failed("Unexpected restored item or undo history") }
        trashWindow.close()
    }

    private func testAddressClipboard(_ browser: ExplorerWindowController) async throws {
        let table = browser.table
        guard let row = (0..<table.numberOfRows).first(where: {
            let name = browser.tableView(table, typeSelectStringFor: nil, row: $0)
            return name == "Notes.txt" || name == "Notes"
        }) else { throw SmokeFailure.failed("Missing selected file for address clipboard test") }
        browser.window?.makeKeyAndOrderFront(nil)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let window = browser.window else { throw SmokeFailure.failed("Missing browser window") }
        window.makeFirstResponder(table)
        let point = browser.address.convert(NSPoint(x: 14, y: browser.address.bounds.midY), to: nil)
        func clickAddress(count: Int = 1) throws {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: count, pressure: 1) else { throw SmokeFailure.failed("Address click event") }
                return event
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            window.sendEvent(try event(.leftMouseDown))
        }
        try clickAddress()
        guard let editor = browser.address.currentEditor() as? NSTextView, browser.window?.firstResponder === editor else {
            throw SmokeFailure.failed("Address did not receive text focus")
        }
        guard !editor.string.isEmpty, editor.selectedRange() == NSRange(location: 0, length: (editor.string as NSString).length) else {
            throw SmokeFailure.failed("First click did not select the address")
        }
        try clickAddress(count: 2)
        guard editor.selectedRange().length == 0 else { throw SmokeFailure.failed("Second click did not place the caret") }
        let board = NSPasteboard.general
        let restore = try preserveClipboard(board)
        defer { restore() }
        let path = editor.string
        for flags: NSEvent.ModifierFlags in [.control, .command] {
            editor.string = path
            let text = path as NSString
            let cursor = NSRange(location: text.length, length: 0)
            editor.setSelectedRange(cursor)
            board.clearContents()
            try sendKey("c", code: 8, flags: flags, to: browser)
            guard board.string(forType: .string) == path, editor.selectedRange() == cursor else {
                throw SmokeFailure.failed("Address copy at insertion point failed for \(flags)")
            }
            let fullRange = NSRange(location: 0, length: text.length)
            editor.setSelectedRange(NSRange(location: text.length / 2, length: 0))
            try sendKey("a", code: 0, flags: flags, to: browser)
            guard editor.selectedRange() == fullRange, browser.window?.firstResponder === editor,
                  table.selectedRowIndexes == IndexSet(integer: row) else {
                throw SmokeFailure.failed("Address select all failed for \(flags)")
            }
            let selection = flags == .control ? fullRange : text.range(of: text.lastPathComponent, options: .backwards)
            guard selection.location != NSNotFound, selection.length > 0 else { throw SmokeFailure.failed("Missing address text") }
            editor.setSelectedRange(selection)
            board.clearContents()
            try sendKey("c", code: 8, flags: flags, to: browser)
            guard board.string(forType: .string) == text.substring(with: selection),
                  editor.string == path else { throw SmokeFailure.failed("Address copy failed for \(flags)") }
            board.clearContents()
            try sendKey("x", code: 7, flags: flags, to: browser)
            let cutText = text.substring(with: selection)
            guard board.string(forType: .string) == cutText,
                  editor.string == text.replacingCharacters(in: selection, with: ""),
                  table.selectedRowIndexes == IndexSet(integer: row) else {
                throw SmokeFailure.failed("Address cut failed for \(flags)")
            }
            let changeCount = board.changeCount
            try sendKey("x", code: 7, flags: flags, to: browser)
            guard board.changeCount == changeCount else { throw SmokeFailure.failed("Empty cut changed clipboard") }
            try sendKey("v", code: 9, flags: flags, to: browser)
            try await waitForCondition("paste cut address back") { editor.string == path }
            editor.setSelectedRange(selection)
            let replacement = "Pasta Açúcar 日本語"
            board.clearContents()
            board.setString(replacement, forType: .string)
            try sendKey("v", code: 9, flags: flags, to: browser)
            let expected = text.replacingCharacters(in: selection, with: replacement)
            try await waitForCondition("address editor to finish pasting") { editor.string == expected }
            guard table.selectedRowIndexes == IndexSet(integer: row), !FileCommands.shared.isBusy else {
                throw SmokeFailure.failed("Address paste affected the file list for \(flags)")
            }
        }
        editor.string = path
    }

    private func testAddressCompletion(root: URL, browser: ExplorerWindowController) async throws {
        try await testAddressClipboard(browser)
        browser.focusAddress(nil)
        guard let editor = browser.address.currentEditor() as? NSTextView else {
            throw SmokeFailure.failed("Address editor missing")
        }
        func type(_ value: String) {
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        let currentAddress = CloudAccounts.shared.address(for: browser.session.history.current.url)
        func checkEscape(_ expected: String) throws {
            let location = browser.session.history.current.url
            try sendKey("\u{1b}", code: 53, flags: [], to: browser)
            guard !browser.addressSuggestions.isVisible, editor.string == expected,
                  browser.address.stringValue == expected, browser.window?.firstResponder === editor,
                  browser.session.history.current.url == location else {
                throw SmokeFailure.failed("Escape did not restore the current address in place")
            }
        }
        type("")
        try checkEscape(currentAddress)
        type("Down")
        try checkEscape(currentAddress)
        type("Doc")
        try await waitForCondition("address suggestions") { browser.addressSuggestions.isVisible }
        try sendKey("\t", code: 48, flags: [], to: browser)
        guard editor.string == "Documents/" else { throw SmokeFailure.failed("Tab completed the wrong path") }
        try await waitForCondition("nested suggestions") { browser.addressSuggestions.isVisible }
        try checkEscape(currentAddress)
        type("Documents/Pr")
        try await waitForCondition("nested prefix") { browser.addressSuggestions.isVisible }
        try sendKey("\u{f701}", code: 125, flags: [], to: browser)
        try sendKey("\r", code: 36, flags: [], to: browser)
        try await waitForListing(browser)
        guard browser.session.history.current.url.explorerIdentity == root.appendingPathComponent("Documents/Projects").explorerIdentity,
              !browser.addressSuggestions.isVisible else { throw SmokeFailure.failed("Enter did not open the selected folder") }
        browser.focusAddress(nil)
        type("../../Do")
        try checkEscape(CloudAccounts.shared.address(for: browser.session.history.current.url))
        type("../../Do")
        browser.window?.makeFirstResponder(browser.table)
        try await Task.sleep(for: .milliseconds(300))
        guard !browser.addressSuggestions.isVisible else { throw SmokeFailure.failed("Late suggestions after leaving address") }
    }

    private func testInlineRename(root: URL, browser: ExplorerWindowController) async throws {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("Inline rename " + UUID().uuidString)
        let child = folder.appendingPathComponent("Folder", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Original.txt")
        let renamed = folder.appendingPathComponent("Changed.txt")
        let contents = Data("rename fixture".utf8)
        try contents.write(to: file)
        browser.navigate(.visit(folder))
        try await waitForListing(browser)
        guard let window = browser.window else { throw SmokeFailure.failed("Missing browser") }
        window.makeKeyAndOrderFront(nil)
        let table = browser.table
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        func click(_ name: String, count: Int = 1) throws {
            guard let row = (0..<table.numberOfRows).first(where: {
                (table.view(atColumn: column, row: $0, makeIfNecessary: true) as? FileNameCell)?.label.stringValue == name
            }), let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? FileNameCell else {
                throw SmokeFailure.failed("Missing rename fixture: " + name)
            }
            let point = cell.label.convert(NSPoint(x: 6, y: cell.label.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                guard let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: count, pressure: 1) else { throw SmokeFailure.failed("Mouse event") }
                return e
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            window.sendEvent(try event(.leftMouseDown))
        }
        func settle() async throws { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15)) }
        func editor() -> NSTextView? { window.firstResponder as? NSTextView }
        ExplorerStyle.preferences.setShowFileExtensions(false)
        try click("Original")
        try await settle()
        guard table.numberOfSelectedRows == 1, editor() == nil else { throw SmokeFailure.failed("First click must select") }
        try click("Original")
        try await settle()
        guard let first = editor(), first.string == "Original.txt", first.selectedRange().length == 8 else {
            throw SmokeFailure.failed("Second click must edit the basename with the real extension visible")
        }
        let editedRow = table.selectedRow
        func originalLabelIsHidden() -> Bool? {
            (table.view(atColumn: column, row: editedRow, makeIfNecessary: true) as? FileNameCell)?.label.isHidden
        }
        guard originalLabelIsHidden() == true else { throw SmokeFailure.failed("Original label overlaps the inline editor") }
        guard let sibling = table.view(atColumn: column, row: editedRow == 0 ? 1 : 0, makeIfNecessary: true) as? FileNameCell,
              !sibling.label.isHidden else { throw SmokeFailure.failed("Rename hid another row") }
        first.insertText("Cancelled", replacementRange: first.selectedRange())
        table.reloadData(forRowIndexes: IndexSet(integer: editedRow), columnIndexes: IndexSet(integer: column))
        guard originalLabelIsHidden() == true, editor() === first, first.string == "Cancelled.txt" else {
            throw SmokeFailure.failed("Refreshing the name cell lost the draft or exposed the original label")
        }
        try sendKey("\u{1b}", code: 53, flags: [], to: browser)
        guard editor() == nil, originalLabelIsHidden() == false, try Data(contentsOf: file) == contents else { throw SmokeFailure.failed("Escape changed file") }
        try click("Original")
        try await settle()
        guard let second = editor() else { throw SmokeFailure.failed("Missing inline editor") }
        second.insertText("Changed", replacementRange: second.selectedRange())
        try sendKey("\r", code: 36, flags: [], to: browser)
        try await waitForCondition("inline rename committed") { fm.fileExists(atPath: renamed.path) && !FileCommands.shared.isBusy }
        guard !fm.fileExists(atPath: file.path), try Data(contentsOf: renamed) == contents else { throw SmokeFailure.failed("Renamed contents") }
        try await waitForListing(browser)
        try click("Changed")
        window.makeFirstResponder(table)
        try sendKey("", code: 120, flags: [], to: browser)
        func cancelRenameDialog() throws {
            guard let sheet = window.attachedSheet, let content = sheet.contentView,
                  let cancel = descendants(of: content).compactMap({ $0 as? NSButton }).first(where: {
                      $0.title == L10n.text("dialog.cancel")
                  }) else { throw SmokeFailure.failed("Missing rename dialog") }
            cancel.performClick(nil)
        }
        try cancelRenameDialog()
        try await waitForCondition("F2 sheet dismissed") { window.attachedSheet == nil }
        guard let menu = table.menu else { throw SmokeFailure.failed("Missing context menu") }
        browser.rebuildContextMenu(menu, entries: [FileEntry(url: renamed, name: renamed.lastPathComponent, isDirectory: false)])
        let index = menu.indexOfItem(withTitle: L10n.text("command.rename"))
        guard index >= 0 else { throw SmokeFailure.failed("Missing rename menu item") }
        menu.performActionForItem(at: index)
        try cancelRenameDialog()
        try await waitForCondition("context sheet dismissed") { window.attachedSheet == nil }
        try click("Folder")
        try await settle()
        try click("Folder")
        try click("Folder", count: 2)
        try await waitForListing(browser)
        try await settle()
        guard browser.session.history.current.url.explorerIdentity == child.explorerIdentity, editor() == nil else {
            throw SmokeFailure.failed("Double-click must open selected folder")
        }
    }

    private func testDeletionPreference(root: URL, browser: ExplorerWindowController) async throws {
        let folder = root.appendingPathComponent("Delete preference")
        let target = folder.appendingPathComponent("MyExplorer-smoke-" + UUID().uuidString)
        let sibling = folder.appendingPathComponent("Keep")
        let bytes = Data("Disposable deletion fixture".utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try bytes.write(to: target)
        try bytes.write(to: sibling)
        browser.navigate(.visit(folder))
        try await waitForListing(browser)
        let commands = FileCommands.shared
        func pressDelete() throws {
            guard let row = (0..<browser.table.numberOfRows).first(where: {
                browser.tableView(browser.table, typeSelectStringFor: nil, row: $0) == target.lastPathComponent
            }) else { throw SmokeFailure.failed("Missing disposable deletion target") }
            browser.window?.makeKeyAndOrderFront(nil)
            browser.window?.makeFirstResponder(browser.table)
            browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try sendKey("", code: 117, flags: [], to: browser)
        }

        showOptions(nil)
        guard let options = optionsSettings, options.confirmDeletion.state == .on else {
            throw SmokeFailure.failed("Delete confirmation must default to enabled")
        }
        options.close()
        try pressDelete()
        try await waitForCondition("Delete confirmation") { commands.hasPendingDecision }
        guard let sheet = NSApp.windows.first(where: { $0.sheetParent is NSPanel }),
              let content = sheet.contentView, let cancel = descendants(of: content).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == L10n.text("dialog.cancel") }) else {
            commands.cancel(nil)
            throw SmokeFailure.failed("Missing Cancel button on Delete confirmation")
        }
        cancel.performClick(nil)
        try await waitForCondition("Cancelled deletion") { !commands.isBusy }
        guard try Data(contentsOf: target) == bytes else { throw SmokeFailure.failed("Cancel changed the selection") }

        showOptions(nil)
        options.confirmDeletion.performClick(nil)
        options.close()
        try await waitForListing(browser)
        try pressDelete()
        try await waitForCondition("Delete with confirmation off") { !commands.isBusy || commands.hasPendingDecision }
        guard !commands.hasPendingDecision, !FileManager.default.fileExists(atPath: target.path),
              try Data(contentsOf: sibling) == bytes else {
            commands.cancel(nil)
            throw SmokeFailure.failed("Unchecked Delete must trash only the selected file without prompting")
        }
    }

    private func testLocalClipboard(root: URL) async throws {
        let commands = FileCommands.shared
        let previousBoard = commands.pasteboard
        let board = NSPasteboard(name: .init("MyExplorer.LocalClipboardSmoke.\(UUID())"))
        commands.pasteboard = board
        defer {
            commands.pasteboard = previousBoard
            board.releaseGlobally()
        }
        let area = root.appendingPathComponent("Local-clipboard-tests")
        let source = area.appendingPathComponent("Source"), destination = area.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: area) }
        await AppAutomation.files.clearLocalTransferHistory()
        let file = source.appendingPathComponent("Ação 日本語.txt")
        let target = destination.appendingPathComponent(file.lastPathComponent)
        let payload = Data("original clipboard fixture".utf8)
        try payload.write(to: file)
        let quarantine = Data("0083;665ede12;Safari;6C89D750-A56D-4B8F-A7CD-92ED627F7B3F".utf8)
        guard quarantine.withUnsafeBytes({ setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }) == 0 else {
            throw SmokeFailure.failed("Could not mark the disposable download")
        }
        let entry = FileEntry(url: file, name: file.lastPathComponent, isDirectory: false)
        func finish() async throws {
            guard let task = commands.task else { throw SmokeFailure.failed("Local clipboard job did not start") }
            await task.value
            if let controller { try await waitForListing(controller) }
        }
        await commands.copy([entry], cut: false)?.value
        commands.paste(into: destination)
        try await finish()
        guard try Data(contentsOf: target) == payload, getxattr(target.path, "com.apple.quarantine", nil, 0, 0, 0) > 0, commands.undoKind == .copy else { throw SmokeFailure.failed("Local paste or Undo history failed") }
        controller?.window?.makeKeyAndOrderFront(nil)
        controller?.window?.makeFirstResponder(controller?.table)
        guard let current = controller else { throw SmokeFailure.failed("Missing undo window") }
        try sendKey("z", code: 6, flags: .command, to: current)
        try await finish()
        guard !FileManager.default.fileExists(atPath: target.path), try Data(contentsOf: file) == payload else { throw SmokeFailure.failed("Command-Z did not undo copy") }
        // Pasting into the same directory creates an independent, uniquely named sibling.
        commands.paste(into: source)
        try await finish()
        let siblings = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".my-explorer") }
        guard siblings.count == 2, siblings.allSatisfy({ (try? Data(contentsOf: $0)) == payload }) else { throw SmokeFailure.failed("Same-folder paste did not duplicate") }
        commands.undo(); try await finish()
        // A URL-only clipboard produced by another macOS app can be moved with Command-Option-V.
        board.clearContents(); board.writeObjects([file as NSURL])
        current.navigate(.visit(destination)); try await waitForListing(current)
        current.window?.makeKeyAndOrderFront(nil); current.window?.makeFirstResponder(current.table)
        try sendKey("v", code: 9, flags: [.command, .option], to: current)
        try await finish()
        guard !FileManager.default.fileExists(atPath: file.path), try Data(contentsOf: target) == payload else { throw SmokeFailure.failed("Move Here failed with an external file URL") }
        commands.undo(); try await finish()
        guard try Data(contentsOf: file) == payload, !FileManager.default.fileExists(atPath: target.path) else { throw SmokeFailure.failed("Undo Move failed") }
        // Replacement keeps the previous destination recoverable via Undo.
        try Data("previous target".utf8).write(to: target)
        await commands.copy([entry], cut: false)?.value
        commands.paste(into: destination)
        var replaced = false
        for _ in 0..<500 {
            if let sheet = NSApp.windows.first(where: { $0.sheetParent is NSPanel }), let content = sheet.contentView,
               let button = descendants(of: content).first(where: { ($0 as? NSButton)?.title == L10n.text("cloud.conflict.replace") }) as? NSButton {
                button.performClick(nil); replaced = true; break
            }
            if !commands.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard replaced else { commands.cancel(nil); throw SmokeFailure.failed("Local replace confirmation missing") }
        try await finish()
        guard try Data(contentsOf: target) == payload else { throw SmokeFailure.failed("Replacement did not publish source") }
        commands.undo(); try await finish()
        guard try Data(contentsOf: target) == Data("previous target".utf8) else { throw SmokeFailure.failed("Undo did not restore overwritten file") }
        try FileManager.default.removeItem(at: target)
        // Pausing before the worker starts must be cancellable without publishing a partial file.
        commands.onIdle = {}
        commands.paste(into: destination)
        commands.togglePause(nil)
        try await Task.sleep(for: .milliseconds(70))
        guard commands.isBusy, !FileManager.default.fileExists(atPath: target.path) else { throw SmokeFailure.failed("Local pause did not hold the transfer") }
        commands.cancel(nil); try await finish()
        guard !FileManager.default.fileExists(atPath: target.path), try Data(contentsOf: file) == payload else { throw SmokeFailure.failed("Cancelled copy published a partial file") }
        // Drop delegates consume normal file URLs without using the general clipboard.
        let dragBoard = NSPasteboard(name: .init("MyExplorer.DragSmoke.\(UUID())"))
        defer { dragBoard.releaseGlobally() }
        dragBoard.writeObjects([file as NSURL])
        let info = SmokeDraggingInfo(pasteboard: dragBoard, window: current.window)
        guard FileDrop.allowedOperations(for: info) == .copy,
              current.tableView(current.table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on) == .copy,
              current.tableView(current.table, acceptDrop: info, row: -1, dropOperation: .on) else { throw SmokeFailure.failed("Native file drop rejected") }
        try await finish()
        guard try Data(contentsOf: target) == payload else { throw SmokeFailure.failed("File drop did not copy content") }
        commands.undo(); try await finish()
        // Moving B by internal drag must not consume an unrelated pending Cut of A.
        let other = source.appendingPathComponent("Other.txt"), otherTarget = destination.appendingPathComponent("Other.txt")
        try payload.write(to: other)
        await commands.copy([entry], cut: true)?.value
        let cutCount = board.changeCount
        dragBoard.clearContents(); dragBoard.writeObjects([other as NSURL])
        let internalInfo = SmokeDraggingInfo(pasteboard: dragBoard, window: current.window, source: current.table)
        guard current.tableView(current.table, acceptDrop: internalInfo, row: -1, dropOperation: .on) else { throw SmokeFailure.failed("Internal drag rejected") }
        try await finish()
        guard !FileManager.default.fileExists(atPath: other.path), try Data(contentsOf: otherTarget) == payload,
              board.changeCount == cutCount, FileClipboard.readURLs(from: board) == [file] else {
            throw SmokeFailure.failed("Dragging another file consumed the pending Cut clipboard")
        }
        commands.undo(); try await finish()
        guard FileDrop.operation(for: [file], to: destination, allowed: [.copy, .move], modifiers: []) == .move,
              FileDrop.operation(for: [file], to: destination, allowed: [.copy, .move], modifiers: .option) == .copy,
              FileDrop.operation(for: [source], to: source, allowed: [.copy, .move], modifiers: []) == [] else {
            throw SmokeFailure.failed("Drag operation selection is inconsistent")
        }
        current.navigate(.visit(root)); try await waitForListing(current)
        await AppAutomation.files.clearLocalTransferHistory()
    }

    private func testArchiveCommands(root: URL) async throws {
        guard let controller else { throw SmokeFailure.failed("Missing command window") }
        func select(_ name: String) throws {
            controller.window?.makeFirstResponder(controller.table)
            guard let row = (0..<controller.table.numberOfRows).first(where: {
                controller.tableView(controller.table, typeSelectStringFor: nil, row: $0) == name
            }) else { throw SmokeFailure.failed("Missing command fixture \(name)") }
            controller.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        try select("Notes.txt")
        controller.compressFiles(nil)
        try await waitForCondition("ZIP command") { !FileCommands.shared.isBusy && !controller.session.isLoading }
        let archive = root.appendingPathComponent("Notes.txt.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else { throw SmokeFailure.failed("ZIP command did not create archive") }
        try select("Notes.txt.zip")
        controller.extractFile(nil)
        try await waitForCondition("extract command") { !FileCommands.shared.isBusy && !controller.session.isLoading }
        let extracted = root.appendingPathComponent("Notes.txt (2)")
        let data = try Data(contentsOf: extracted.appendingPathComponent("Notes.txt"))
        guard data == Data("Plain text fixture\n".utf8), FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes.txt").path) else {
            throw SmokeFailure.failed("ZIP command round trip changed source or payload")
        }
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.removeItem(at: extracted)
        controller.refresh(nil)
        try await waitForListing(controller)
    }

    private func testFileUpdates(root: URL) async throws {
        guard let controller, let original = controller.workspace.activeTab,
              let background = controller.workspace.tabs.first(where: { $0.id != original.id }),
              let treeRoot = controller.tree.outline.item(atRow: 0) as? FolderNode else {
            throw SmokeFailure.failed("Missing observation fixture")
        }
        let manager = FileManager.default
        let liveFile = root.appendingPathComponent("Live-File.txt")
        controller.filter.stringValue = "Live"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.filter))
        controller.table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        try Data("first".utf8).write(to: liveFile)
        try await waitForCondition("file creation") {
            !controller.session.isLoading && controller.table.numberOfRows == 1 && controller.session.entries.contains { $0.url.path == liveFile.path }
        }
        controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.window?.makeFirstResponder(controller.filter)
        try Data(repeating: 65, count: 2048).write(to: liveFile)
        try await waitForCondition("file metadata") {
            !controller.session.isLoading && controller.session.entries.first(where: { $0.url.path == liveFile.path })?.size == 2048
        }
        guard controller.table.selectedRow == 0, controller.filter.stringValue == "Live",
              controller.table.sortDescriptors.first?.key == "size", controller.table.sortDescriptors.first?.ascending == false,
              (controller.window?.firstResponder as? NSTextView)?.delegate as? NSTextField === controller.filter else {
            throw SmokeFailure.failed("Automatic refresh lost active view state: row=\(controller.table.selectedRow), filter=\(controller.filter.stringValue), sort=\(controller.table.sortDescriptors), responder=\(String(describing: controller.window?.firstResponder)), delegate=\(String(describing: (controller.window?.firstResponder as? NSTextView)?.delegate))")
        }
        try Data(repeating: 66, count: 4096).write(to: liveFile)
        try await waitForCondition("repeated file metadata") {
            !controller.session.isLoading && controller.session.entries.first(where: { $0.url.path == liveFile.path })?.size == 4096
        }
        let backgroundFile = background.session.history.current.url.appendingPathComponent("Background-Update.txt")
        try Data("background".utf8).write(to: backgroundFile)
        try await waitForCondition("background tab update") {
            background.session.entries.contains { $0.url.path == backgroundFile.path }
        }
        guard controller.workspace.activeID == original.id, controller.filter.stringValue == "Live", controller.table.selectedRow == 0 else {
            throw SmokeFailure.failed("Background update changed active tab")
        }
        controller.tree.outline.expandItem(treeRoot)
        try await waitForCondition("tree expanded") { controller.tree.outline.isItemExpanded(treeRoot) }
        controller.focusAddress(nil)
        let draftAddress = root.appendingPathComponent("not-submitted").path
        controller.address.stringValue = draftAddress
        let folder = root.appendingPathComponent("Live-Folder")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try await waitForCondition("tree creation") { treeRoot.children?.contains { $0.url.path == folder.path } == true }
        try await waitForCondition("listing creation while editing address") { !controller.session.isLoading && controller.session.entries.contains { $0.url.path == folder.path } }
        guard controller.address.stringValue == draftAddress else { throw SmokeFailure.failed("Refresh replaced address draft") }
        controller.address.stringValue = root.path
        controller.window?.makeFirstResponder(controller.table)
        guard let child = treeRoot.children?.first(where: { $0.url.path == folder.path }) else { throw SmokeFailure.failed("Missing live node") }
        controller.tree.outline.expandItem(child)
        try await waitForCondition("empty folder expansion") { controller.tree.outline.isItemExpanded(child) }
        try manager.createDirectory(at: folder.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        try await waitForCondition("empty folder receives child") { child.children?.contains { $0.title == "Nested" } == true }
        controller.tree.outline.collapseItem(treeRoot)
        controller.tree.outline.expandItem(treeRoot)
        try await waitForCondition("descendant expansion restored") {
            !treeRoot.loading && controller.tree.outline.isItemExpanded(child) && child.watcher != nil
        }
        try manager.createDirectory(at: folder.appendingPathComponent("Nested-After-Reopen"), withIntermediateDirectories: true)
        try await waitForCondition("descendant observer restored") { child.children?.contains { $0.title == "Nested-After-Reopen" } == true }
        let renamed = root.appendingPathComponent("Live-Renamed")
        try manager.moveItem(at: folder, to: renamed)
        try await waitForCondition("tree rename") {
            treeRoot.children?.contains { $0.url.path == renamed.path } == true && treeRoot.children?.contains { $0.url.path == folder.path } == false
        }
        try manager.removeItem(at: liveFile)
        try await waitForCondition("selected file removal") {
            !controller.session.isLoading && !controller.session.entries.contains { $0.url.path == liveFile.path }
        }
        guard controller.table.selectedRowIndexes.isEmpty, controller.session.history.current.selectedPaths.isEmpty else {
            throw SmokeFailure.failed("Removed selection survived refresh")
        }
        controller.filter.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.filter))
        controller.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        let long = controller.addTab(at: root.appendingPathComponent("LongList"))
        try await waitForListing(controller)
        controller.table.selectRowIndexes(IndexSet(integer: 80), byExtendingSelection: false)
        controller.table.scrollRowToVisible(80)
        let offset = controller.fileScroll.contentView.bounds.minY
        let extra = root.appendingPathComponent("LongList/Z-External.txt")
        try Data("scroll".utf8).write(to: extra)
        try await waitForCondition("scroll refresh") { !controller.session.isLoading && controller.table.numberOfRows == 121 }
        guard controller.table.selectedRow == 80, abs(controller.fileScroll.contentView.bounds.minY - offset) < 1 else {
            throw SmokeFailure.failed("Automatic refresh lost scroll or selection")
        }
        controller.closeTab(id: long.id)
        controller.selectTab(id: original.id)
        let removed = root.appendingPathComponent("Live-Removed")
        try manager.createDirectory(at: removed, withIntermediateDirectories: true)
        let missingTab = controller.addTab(at: removed)
        try await waitForListing(controller)
        try manager.removeItem(at: removed)
        try await waitForCondition("open directory removed") { controller.session.failure != nil }
        guard !controller.errorLabel.isHidden else { throw SmokeFailure.failed("Missing deletion error") }
        try manager.createDirectory(at: removed, withIntermediateDirectories: true)
        try Data("recovered".utf8).write(to: removed.appendingPathComponent("Recovered.txt"))
        try await waitForCondition("directory recreated") { !controller.session.isLoading && controller.session.failure == nil && controller.table.numberOfRows == 1 }
        controller.closeTab(id: missingTab.id)
        controller.selectTab(id: original.id)
        for url in [renamed, removed, extra, backgroundFile] { try manager.removeItem(at: url) }
        controller.refresh(nil)
        try await waitForListing(controller)
        try await waitForCondition("tree refresh preserves expansion") {
            !treeRoot.loading && controller.tree.outline.isItemExpanded(treeRoot) && treeRoot.children?.contains { $0.url.path == renamed.path } == false
        }
    }

    private func waitForCondition(_ description: String, timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let state = controller.map { "path=\($0.session.history.current.url.path), loading=\($0.session.isLoading), error=\(String(describing: $0.session.errorMessage)), entries=\($0.session.entries.map(\.name))" } ?? "no controller"
        throw SmokeFailure.failed("Timed out waiting for \(description): \(state)")
    }

    private func sendKey(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags,
                         to controller: ExplorerWindowController) throws {
        guard let window = controller.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                  isARepeat: false, keyCode: code) else { throw SmokeFailure.failed("Could not create keyboard event") }
        NSApp.sendEvent(event)
    }

    private func waitForListing(_ controller: ExplorerWindowController) async throws {
        for _ in 0..<1000 {
            if !controller.session.isLoading {
                if let error = controller.session.errorMessage { throw SmokeFailure.failed(error) }
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SmokeFailure.failed("Listing timeout")
    }
}

enum SmokeFailure: Error { case failed(String) }

@MainActor
private final class SmokeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    // Older SDKs declare this deprecated protocol requirement nonisolated.
    nonisolated var draggedImage: NSImage? { nil }
    let draggingSource: Any?
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(pasteboard: NSPasteboard, window: NSWindow?, source: Any? = nil) {
        draggingPasteboard = pasteboard; draggingDestinationWindow = window; draggingSource = source
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Only injected into the isolated smoke account store; it never opens a network connection.
private actor SmokeCloudListingTransport: CloudTransport {
    private var uploaded: [String: Data] = [:]
    private(set) var uploadCount = 0
    func contents(key: String) -> Data? { uploaded[key] }
    func send(_ request: URLRequest) async throws -> CloudResponse {
        try Task.checkCancellation()
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CloudFailure(.io) }
        if request.httpMethod == "PUT", url.host?.hasSuffix(".amazonaws.com") == true,
           request.value(forHTTPHeaderField: "If-None-Match") == "*" {
            let key = String(components.path.dropFirst())
            guard key == "NewFolderSmoke/" || key == "folder/NewFolderSmoke/" else { throw CloudFailure(.invalidKey) }
            guard uploaded[key] == nil else { return CloudResponse(statusCode: 412) }
            uploaded[key] = Data()
            return CloudResponse(statusCode: 200, headers: ["ETag": "\"smoke-marker\""])
        }
        if request.httpMethod == "HEAD", url.host?.hasSuffix(".amazonaws.com") == true {
            let key = String(url.path.dropFirst())
            guard let data = uploaded[key] else { return CloudResponse(statusCode: 404) }
            return CloudResponse(statusCode: 200, headers: ["Content-Length": String(data.count), "ETag": "\"smoke-upload\""])
        }
        if request.httpMethod == "DELETE", url.host?.hasSuffix(".amazonaws.com") == true {
            guard request.value(forHTTPHeaderField: "If-Match") == "\"smoke-upload\"" else { throw CloudFailure(.preconditionFailed) }
            let removed = uploaded.removeValue(forKey: String(url.path.dropFirst()))
            return CloudResponse(statusCode: removed == nil ? 404 : 204)
        }
        guard request.httpMethod == "GET" else { throw CloudFailure(.io) }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let prefix = query["prefix"] ?? ""
        guard prefix.isEmpty || prefix == "folder/" else { throw CloudFailure(.invalidKey) }
        let key = prefix + "same.txt"
        let body: Data
        if url.host?.hasSuffix(".amazonaws.com") == true {
            var folder = prefix.isEmpty ? "<CommonPrefixes><Prefix>folder/</Prefix></CommonPrefixes>" : ""
            if uploaded[prefix + "NewFolderSmoke/"] != nil {
                folder += "<CommonPrefixes><Prefix>" + prefix + "NewFolderSmoke/</Prefix></CommonPrefixes>"
            }
            body = Data(("<ListBucketResult><IsTruncated>false</IsTruncated>" + folder +
                "<Contents><Key>\(key)</Key><Size>7</Size><ETag>\"smoke\"</ETag></Contents></ListBucketResult>").utf8)
        } else if url.host?.hasSuffix(".blob.core.windows.net") == true {
            let folder = prefix.isEmpty ? "<BlobPrefix><Name>folder/</Name></BlobPrefix>" : ""
            body = Data(("<EnumerationResults><Blobs>" + folder +
                "<Blob><Name>\(key)</Name><Properties><Content-Length>7</Content-Length><Etag>\"smoke\"</Etag></Properties></Blob>" +
                "</Blobs><NextMarker/></EnumerationResults>").utf8)
        } else if url.host == "storage.googleapis.com" {
            body = try JSONSerialization.data(withJSONObject: ["kind": "storage#objects", "prefixes": prefix.isEmpty ? ["folder/"] : [],
                "items": [["name": key, "size": "7", "generation": "1"]]])
        } else { throw CloudFailure(.invalidConfiguration) }
        return CloudResponse(statusCode: 200, body: body)
    }
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        try Task.checkCancellation()
        guard request.url?.host?.hasSuffix(".amazonaws.com") == true,
              request.value(forHTTPHeaderField: "If-None-Match") == "*" else { throw CloudFailure(.preconditionFailed) }
        let key = String((request.url?.path ?? "").dropFirst())
        guard uploaded[key] == nil else { return CloudResponse(statusCode: 412) }
        let data = try Data(contentsOf: fileURL)
        progress?(CloudTransferProgress(completedBytes: Int64(data.count / 2), totalBytes: Int64(data.count)))
        try await Task.sleep(for: .milliseconds(25))
        try Task.checkCancellation()
        uploaded[key] = data; uploadCount += 1
        return CloudResponse(statusCode: 200, headers: ["ETag": "\"smoke-upload\""])
    }
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        try Task.checkCancellation()
        let key = String((request.url?.path ?? "").dropFirst())
        guard let data = uploaded[key] else { return CloudResponse(statusCode: 404) }
        progress?(CloudTransferProgress(completedBytes: Int64(data.count / 2), totalBytes: Int64(data.count)))
        try await Task.sleep(for: .milliseconds(25))
        try Task.checkCancellation()
        try data.write(to: fileURL, options: .withoutOverwriting)
        return CloudResponse(statusCode: 200, headers: ["Content-Length": String(data.count), "ETag": "\"smoke-upload\""])
    }
}

/// Observes background AV teardown without making a synchronous callback to the main actor.
private final class SmokePlaybackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOutcome: MediaPlaybackSession.Outcome?
    private var storedCount = 0
    private var started = false
    private var offMain = false
    var outcome: MediaPlaybackSession.Outcome? { lock.withLock { storedOutcome } }
    var callbackCount: Int { lock.withLock { storedCount } }
    var releaseStarted: Bool { lock.withLock { started } }
    var releasedOffMain: Bool { lock.withLock { offMain } }
    func record(_ outcome: MediaPlaybackSession.Outcome) { lock.withLock { storedOutcome = outcome; storedCount += 1 } }
    func beginRelease() { lock.withLock { started = true; offMain = !Thread.isMainThread } }
}

@main
struct MyExplorerApp {
    @MainActor static func main() {
        let diagnosticArguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        if diagnosticArguments.contains(where: { ["--validate-s3", "--validate-s3-upload-cancellation", "--validate-s3-auth", "--list-s3-validation-connections", "--import-s3-validation-credentials", "--remove-s3-validation-connection"].contains($0) }) {
            Task { exit(await S3ValidationCommand.run(arguments: diagnosticArguments)) }
            dispatchMain()
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-localizations") {
            for language in AppLanguage.allCases where language != .system {
                let localization = Localization(language: language)
                guard localization.text("column.name") != "column.name" else { exit(1) }
                print("\(language.rawValue): \(localization.text("column.name"))")
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
