// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import ExplorerLocalization
import ExplorerClipboard
import UniformTypeIdentifiers

private final class AddressField: NSTextField {
    /// Called when the field takes the keyboard: the trail of folders gives way to the path.
    var onFocus: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }
}

private final class ExplorerWindow: NSWindow {
    weak var addressField: NSTextField?
    private var selectedAddressOnClick = false

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown else {
            super.sendEvent(event)
            return
        }
        let previousClickSelectedAddress = selectedAddressOnClick
        selectedAddressOnClick = false
        // The folders of the trail lie over the field: a click on one of them is theirs.
        if contentView?.hitTest(event.locationInWindow) is NSButton { super.sendEvent(event); return }
        guard let field = addressField, field.isEnabled, attachedSheet == nil,
              event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty,
              field.bounds.contains(field.convert(event.locationInWindow, from: nil)) else {
            super.sendEvent(event)
            return
        }
        let entering = field.currentEditor() == nil && event.clickCount == 1
        let placingCaret = previousClickSelectedAddress && event.clickCount == 2
        guard entering || placingCaret,
              // Leave drags in the queue so AppKit can track a normal text selection.
              let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                   inMode: .eventTracking, dequeue: false),
              next.type == .leftMouseUp, makeFirstResponder(field),
              let editor = field.currentEditor() as? NSTextView else {
            super.sendEvent(event)
            return
        }
        _ = nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true)
        if entering {
            editor.selectAll(nil)
            selectedAddressOnClick = true
        } else {
            let point = editor.convert(event.locationInWindow, from: nil)
            editor.setSelectedRange(NSRange(location: editor.characterIndexForInsertion(at: point), length: 0))
        }
    }
}

@MainActor
final class ExplorerWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSMenuDelegate, NSSplitViewDelegate {
    let workspace: ExplorerWorkspace
    var session: DirectorySession { workspace.activeTab!.session }
    let table = ExplorerTableView()
    let fileScroll = NSScrollView()
    /// The list in the view modes other than details; the table stays loaded behind it and
    /// keeps the selection, so every command reads it from one place.
    let grid = FileGridView()
    let gridScroll = NSScrollView()
    private let galleryStage = GalleryStage()
    private(set) var viewMode: FileViewMode = .details
    private var gridTop: NSLayoutConstraint!
    private var gridHeight: NSLayoutConstraint!
    /// Modes chosen inside unlocked protected folders: kept for this window only, never saved.
    private var transientViewModes: [String: FileViewMode] = [:]
    let address: NSTextField = AddressField()
    let addressSuggestions = AddressSuggestions()
    let filter = NSSearchField()
    let breadcrumbs = NSStackView()
    let status = ExplorerStyle.label("", color: .secondaryLabelColor)
    let message = ExplorerStyle.label("", size: 13, color: .secondaryLabelColor)
    let errorLabel = ExplorerStyle.label("", color: .systemRed)
    let progress = NSProgressIndicator()
    private(set) var vaultPresentationGeneration = 0
    private var gitReview: GitReviewController?
    private let gitState = GitBrowserState()
    private let gitSummary = ExplorerStyle.label("", color: .secondaryLabelColor)
    var gitSummaryText: String { gitSummary.stringValue }
    var gitSnapshot: GitStatusSnapshot? { gitState.snapshot }
    private var forceGitRefresh = false
    private(set) lazy var systemVolumes = SystemVolumeController(browser: self)
    private var trashBrowser: TrashBrowserController?
    let tree: FolderTreeController
    weak var secureFolders: SecureFolderCommands?
    let sidebarHome: URL?
    var onLanguageChange: ((AppLanguage) -> Void)?
    var onShowFontSettings: (() -> Void)?
    var onManageCloud: (() -> Void)?
    var onShowOptions: (() -> Void)?
    var onClose: ((URL) -> Void)?
    var onSessionChange: (() -> Void)?
    var restorationFallbackTabs: Set<UUID> = []
    var onOpenMedia: (([FileEntry], URL) -> Void)?
    var onExtractText: ((URL) -> Void)?
    var onBatchOCR: (([URL]) -> Void)?
    private(set) var lastLocation: URL
    let tabStrip = NSStackView()
    /// "New tab" stands right after the last tab, where a new one will appear.
    private var newTabButton: NSButton!
    private let tabScroll = NSScrollView()
    private let split = NSSplitView()
    private let previewPane = PreviewPaneController()
    let previewButton = OutlinedButton()
    private var lastPreviewWidth: CGFloat = 300
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var upButton: NSButton!
    /// The command bar: what is done to the selection, then how the folder is shown.
    private let commandBar = NSStackView()
    /// The menus inside the window, as in the other applications of the suite.
    private let menuStrip = NSStackView()
    private var selectionButtons: [(button: NSButton, needs: SelectionNeed)] = []
    private var pasteButton: NSButton!
    private let newButton = ToolbarMenuButton()
    private let sortButton = ToolbarMenuButton()
    private let viewButton = ToolbarMenuButton()
    private let moreButton = ToolbarMenuButton()
    private enum SelectionNeed { case any, oneLocal, shareable }
    private var visibleEntries: [FileEntry] = []
    private var inlineRename: (entry: FileEntry, field: NSTextField)?
    private var contextEntries: [FileEntry] = []
    private var renderedTabID: UUID?
    private var renderedPath: String?
    /// The folder last recorded as a recent folder, so that one stay is recorded once.
    private var lastRecordedVisit: String?
    private var rendering = false
    private var restoringLayout = true
    private var presentationSaveTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var searchWindow: FileSearchController?
    var fileSharing = FileSharingController()
    init(initialURL: URL, sidebarHome: URL? = nil, existingWorkspace: ExplorerWorkspace? = nil,
         existingTree: FolderTreeController? = nil) {
        let workspace = existingWorkspace ?? ExplorerWorkspace(reader: ApplicationDirectoryReader(), observerFactory: { DirectoryWatcher() })
        let preferences = ExplorerStyle.browserPreferences
        if workspace.tabs.isEmpty {
            workspace.addTab(at: initialURL, sortKey: preferences.sortKey, sortAscending: preferences.sortAscending, showHidden: preferences.showHidden)
        }
        self.workspace = workspace
        lastLocation = initialURL
        self.sidebarHome = sidebarHome
        tree = existingTree ?? FolderTreeController(home: sidebarHome ?? FileManager.default.homeDirectoryForCurrentUser)
        tree.relocalize()
        let window = ExplorerWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "My Explorer"
        window.minSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = ExplorerSurface(frame: NSRect(x: 0, y: 0, width: 1160, height: 740))
        super.init(window: window)
        window.addressField = address
        window.delegate = self
        FileCommands.shared.owner = self
        gitState.onChange = { [weak self] in self?.renderGit() }
        gitState.shouldPoll = { [weak self] in self?.window?.isVisible == true && NSApp.isActive }
        buildInterface()
        window.contentView?.layoutSubtreeIfNeeded()
        restoreWindowFrame()
        lastPreviewWidth = preferences.previewWidth
        split.setPosition(max(165, min(preferences.sidebarWidth, split.bounds.width - 431)), ofDividerAt: 0)
        updatePreviewVisibility()
        applySavedColumns()
        workspace.onChange = { [weak self] changedID in
            guard let self else { return }
            guard self.workspace.activeTab != nil else { self.window?.performClose(nil); return }
            self.onSessionChange?()
            self.renderTabs()
            if changedID == nil || changedID == self.workspace.activeID { self.renderSession() }
        }
        workspace.onWillAutoRefresh = { [weak self] id in
            guard let self, self.workspace.activeID == id else { return }
            self.rememberView()
            self.forceGitRefresh = true
        }
        tree.onNavigate = { [weak self] url in self?.navigate(.visit(url)) }
        tree.canBeFavorite = { [weak self] url in self?.canKeepAsShortcut(url) ?? false }
        systemVolumes.start()
        tree.onDisconnectCloud = { [weak self] id in self?.promptToDisconnect(id) }
        tree.onRemoveMount = { [weak self] mount in self?.systemVolumes.remove(mount) }
        tree.onSavedSearch = { [weak self] in self?.presentSearch(saved: $0) }
        tree.onVolumeProperties = { [weak self] url, mount in self?.showVolumeProperties(at: url, mount: mount) }
        tree.onShowTrash = { [weak self] in
            guard let self else { return }
            if self.trashBrowser == nil { self.trashBrowser = TrashBrowserController() }
            self.trashBrowser?.showWindow(nil)
            self.trashBrowser?.refresh()
            self.tree.show(self.session.history.current.url)
        }
        tree.onManageCloud = { [weak self] in self?.onManageCloud?() }
        previewPane.onExtractText = { [weak self] url in self?.onExtractText?(url) }
        table.openSelection = { [weak self] in self?.openSelected(nil) }
        table.goBack = { [weak self] in self?.goBack(nil) }
        installKeyboardNavigation()
        rebuildMenuStrip()
        renderTabs()
        renderSession()
        // The list has the keyboard from the start: the address shows the trail of folders
        // until it is clicked.
        window.contentView?.layoutSubtreeIfNeeded()
        refitTrail()
        showTrail(true)
        restoringLayout = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        tabStrip.orientation = .horizontal
        tabStrip.alignment = .centerY
        tabStrip.spacing = 6
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.documentView = tabStrip
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.drawsBackground = false
        tabScroll.heightAnchor.constraint(equalToConstant: 36 + max(0, ExplorerStyle.preferences.fontSize(for: .bars) - 12)).isActive = true
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabStrip.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStrip.heightAnchor.constraint(equalTo: tabScroll.contentView.heightAnchor),
            tabStrip.widthAnchor.constraint(greaterThanOrEqualTo: tabScroll.contentView.widthAnchor)
        ])
        menuStrip.orientation = .horizontal; menuStrip.alignment = .centerY; menuStrip.spacing = 2
        menuStrip.setAccessibilityIdentifier("explorer.menuStrip")
        let stripSpacer = NSView()
        stripSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addBar(ExplorerStyle.stack([menuStrip, stripSpacer], spacing: 0), to: root, height: 28)
        let newTab = ExplorerStyle.button("plus", title: L10n.text("tab.new_tooltip"), target: self, action: #selector(newTab), outlined: true)
        newTabButton = newTab
        addBar(ExplorerStyle.stack([tabScroll], spacing: 6), to: root, height: 44)
        addLine(to: root)

        backButton = ExplorerStyle.button("arrow.left", title: L10n.text("navigation.back"), target: self, action: #selector(goBack), outlined: true)
        forwardButton = ExplorerStyle.button("arrow.right", title: L10n.text("navigation.forward"), target: self, action: #selector(goForward), outlined: true)
        upButton = ExplorerStyle.button("arrow.up", title: L10n.text("navigation.up"), target: self, action: #selector(goUp), outlined: true)
        let refresh = ExplorerStyle.button("arrow.clockwise", title: L10n.text("navigation.refresh"), target: self, action: #selector(refresh), outlined: true)
        // The navigation buttons carry the drawn icons; AppKit dims them by itself when disabled.
        let drawn: [(NSButton?, ExplorerIcon)] = [(newTab, .newTab), (backButton, .back), (forwardButton, .forward), (upButton, .up), (refresh, .refresh)]
        for case let (button?, icon) in drawn {
            button.image = PremiumIcons.image(icon, side: 22, description: button.toolTip)
            button.imageScaling = .scaleProportionallyDown
        }
        address.placeholderString = L10n.text("address.placeholder")
        address.font = .systemFont(ofSize: 13)
        address.bezelStyle = .roundedBezel
        address.delegate = self
        addressSuggestions.submit = { [weak self] in self?.addressSubmitted(nil) }
        address.target = self; address.action = #selector(addressSubmitted)
        address.setAccessibilityLabel(L10n.text("address.accessibility"))
        address.setAccessibilityIdentifier("explorer.address")
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filter.placeholderString = L10n.text("filter.placeholder")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.setAccessibilityLabel(L10n.text("filter.accessibility"))
        filter.setAccessibilityIdentifier("explorer.filter")
        filter.widthAnchor.constraint(equalToConstant: 225).isActive = true
        // One bar for the place: the trail of folders lies over the address field and gives way
        // to the path in text when the field is clicked or takes the keyboard.
        let place = NSView()
        address.controlSize = .large
        filter.controlSize = .large
        breadcrumbs.orientation = .horizontal; breadcrumbs.alignment = .centerY; breadcrumbs.spacing = 1
        breadcrumbs.setAccessibilityLabel(L10n.text("breadcrumbs.accessibility"))
        for view in [address, breadcrumbs] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; place.addSubview(view) }
        place.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            address.leadingAnchor.constraint(equalTo: place.leadingAnchor), address.trailingAnchor.constraint(equalTo: place.trailingAnchor),
            address.topAnchor.constraint(equalTo: place.topAnchor), address.bottomAnchor.constraint(equalTo: place.bottomAnchor),
            breadcrumbs.leadingAnchor.constraint(equalTo: place.leadingAnchor, constant: 5),
            breadcrumbs.trailingAnchor.constraint(equalTo: place.trailingAnchor, constant: -5),
            breadcrumbs.centerYAnchor.constraint(equalTo: place.centerYAnchor)
        ])
        (address as? AddressField)?.onFocus = { [weak self] in self?.addressTookKeyboard() }
        showTrail(true)
        let navigation = ExplorerStyle.stack([backButton, forwardButton, upButton, refresh, place, filter], spacing: 6)
        addBar(navigation, to: root, height: 54)
        addLine(to: root)

        func command(_ icon: ExplorerIcon, _ key: String, _ action: Selector, id: String) -> NSButton {
            let title = L10n.text(key).replacingOccurrences(of: "…", with: "")
            let button = ExplorerStyle.button("circle", title: title, target: self, action: action, outlined: true)
            button.image = PremiumIcons.image(icon, side: 22, description: title)
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityIdentifier("explorer.command." + id)
            return button
        }
        func menuButton(_ button: ToolbarMenuButton, _ icon: ExplorerIcon, _ key: String, id: String) {
            let title = L10n.text(key)
            button.title = title
            button.image = PremiumIcons.image(icon, side: 20, description: title)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.setAccessibilityIdentifier(id)
            button.dropMenu.delegate = self
            button.dropMenu.autoenablesItems = true
        }
        func item(_ menu: NSMenu, _ key: String, _ action: Selector, _ icon: ExplorerIcon? = nil, id: String? = nil) {
            let entry = menu.addItem(withTitle: L10n.text(key), action: action, keyEquivalent: "")
            entry.target = self
            if let icon { entry.image = PremiumIcons.image(icon, side: 18) }
            if let id { entry.identifier = NSUserInterfaceItemIdentifier(id) }
        }
        menuButton(newButton, .newItem, "command.new", id: "explorer.command.new")
        item(newButton.dropMenu, "command.new_folder", #selector(newFolder), .folder)
        item(newButton.dropMenu, "command.new_tab", #selector(newTab(_:)), .newTab)
        let cut = command(.cut, "command.cut_files", #selector(cutFiles), id: "cut")
        let copy = command(.copy, "command.copy_files", #selector(copyFiles), id: "copy")
        pasteButton = command(.paste, "command.paste_files", #selector(pasteFiles), id: "paste")
        let rename = command(.rename, "command.rename", #selector(renameInList), id: "rename")
        let share = command(.share, "command.share", #selector(shareFiles), id: "share")
        let delete = command(.delete, "command.delete", #selector(trashFiles), id: "delete")
        selectionButtons = [(cut, .any), (copy, .any), (rename, .oneLocal), (share, .shareable), (delete, .any)]

        menuButton(sortButton, .sort, "view.sort", id: "explorer.sortMenu")
        for entry in Self.sortItems(target: self) { sortButton.dropMenu.addItem(entry) }
        menuButton(viewButton, .view, "menu.view", id: "explorer.viewMenu")
        for entry in Self.viewModeItems(target: self) { viewButton.dropMenu.addItem(entry) }
        viewButton.dropMenu.addItem(.separator())
        item(viewButton.dropMenu, "view.hidden", #selector(toggleHidden))
        item(viewButton.dropMenu, "view.extensions", #selector(toggleFileExtensions))
        item(viewButton.dropMenu, "preview.title", #selector(togglePreviewPane))

        moreButton.title = ""
        moreButton.image = PremiumIcons.image(.more, side: 20, description: L10n.text("menu.more"))
        moreButton.imagePosition = .imageOnly
        moreButton.toolTip = L10n.text("menu.more")
        moreButton.setAccessibilityLabel(L10n.text("menu.more"))
        moreButton.setAccessibilityIdentifier("explorer.moreMenu")
        moreButton.dropMenu.delegate = self
        moreButton.widthAnchor.constraint(equalToConstant: 46).isActive = true
        item(moreButton.dropMenu, "command.copy_path", #selector(copyPath), .copy, id: "explorer.command.copyPath")
        item(moreButton.dropMenu, "ocr.title", #selector(extractText), .text, id: "explorer.toolbar.extractText")
        item(moreButton.dropMenu, "ocr.create_pdf", #selector(batchOCR), .pdf, id: "explorer.toolbar.searchablePDF")
        moreButton.dropMenu.addItem(.separator())
        item(moreButton.dropMenu, "font.title", #selector(showFontSettings))
        item(moreButton.dropMenu, "options.title", #selector(showOptions))
        item(moreButton.dropMenu, "cloud.manage", #selector(manageCloud), .cloud)

        previewButton.title = L10n.text("preview.title")
        previewButton.image = PremiumIcons.image(.previewPane, side: 22, description: previewButton.title)
        previewButton.imageScaling = .scaleProportionallyDown
        previewButton.imagePosition = .imageOnly
        previewButton.setButtonType(.pushOnPushOff)
        previewButton.showsSelection = true
        previewButton.target = self; previewButton.action = #selector(togglePreviewPane)
        previewButton.toolTip = previewButton.title
        previewButton.setAccessibilityLabel(previewButton.title)
        previewButton.setAccessibilityIdentifier("explorer.preview.toggle")
        previewButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        previewButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        func divider() -> NSView {
            let line = NSBox(); line.boxType = .custom; line.borderWidth = 0
            line.fillColor = .separatorColor
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            line.heightAnchor.constraint(equalToConstant: 20).isActive = true
            return line
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [newButton, divider(), cut, copy, pasteButton, rename, share, delete, spacer,
                     sortButton, viewButton, previewButton, moreButton] as [NSView] { commandBar.addArrangedSubview(view) }
        commandBar.orientation = .horizontal; commandBar.alignment = .centerY; commandBar.spacing = 6
        commandBar.setCustomSpacing(10, after: newButton)
        commandBar.setCustomSpacing(10, after: commandBar.arrangedSubviews[1])
        for menu in toolbarMenus { ExplorerStyle.configureMenu(menu) }
        addBar(commandBar, to: root, height: 46)
        addLine(to: root)

        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true
        root.addArrangedSubview(errorLabel)
        errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16).isActive = true
        errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16).isActive = true

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        let sidebar = NSView()
        sidebar.wantsLayer = true
        let heading = ExplorerStyle.label(L10n.text("view.navigation"), size: 10, color: .secondaryLabelColor)
        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        for view in [heading, tree.scrollView] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            tree.scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            tree.scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 4),
            tree.scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),
            tree.scrollView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 165)
        ])
        let details = NSView()
        configureTable()
        fileScroll.documentView = table
        fileScroll.hasVerticalScroller = true; fileScroll.hasHorizontalScroller = true
        fileScroll.autohidesScrollers = true
        fileScroll.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(fileScroll)
        configureGrid()
        for view in [galleryStage, gridScroll] { view.translatesAutoresizingMaskIntoConstraints = false; details.addSubview(view) }
        gridTop = gridScroll.topAnchor.constraint(equalTo: details.topAnchor)
        gridHeight = gridScroll.heightAnchor.constraint(equalToConstant: FileGridMetrics.galleryStripHeight)
        gridHeight.priority = NSLayoutConstraint.Priority(999) // a very short window squeezes the strip, not the layout
        message.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(message)
        NSLayoutConstraint.activate([
            gridScroll.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: details.bottomAnchor),
            gridTop,
            galleryStage.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            galleryStage.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            galleryStage.topAnchor.constraint(equalTo: details.topAnchor),
            galleryStage.bottomAnchor.constraint(equalTo: gridScroll.topAnchor),
            fileScroll.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            fileScroll.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            fileScroll.topAnchor.constraint(equalTo: details.topAnchor),
            fileScroll.bottomAnchor.constraint(equalTo: details.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: details.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: details.centerYAnchor),
            details.widthAnchor.constraint(greaterThanOrEqualToConstant: 430)
        ])
        split.addArrangedSubview(sidebar); split.addArrangedSubview(details)
        root.addArrangedSubview(split)
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        sidebar.frame.size.width = 230

        addLine(to: root)
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gitSummary.lineBreakMode = .byTruncatingTail
        gitSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gitSummary.setAccessibilityIdentifier("explorer.git.summary")
        gitSummary.isHidden = true
        addBar(ExplorerStyle.stack([progress, status, statusSpacer, gitSummary]), to: root, height: 30)
        applyBarFonts(to: root)
    }

    private func applyBarFonts(to view: NSView) {
        guard view !== split else { return }
        if let field = view as? NSTextField { field.font = ExplorerStyle.font(.bars) }
        if let button = view as? NSButton { button.font = ExplorerStyle.font(.bars) }
        if let picker = view as? NSPopUpButton, let font = picker.font {
            picker.bezelStyle = .regularSquare
            picker.heightAnchor.constraint(greaterThanOrEqualToConstant: ceil(font.ascender - font.descender) + 12).isActive = true
            picker.setContentCompressionResistancePriority(.required, for: .vertical)
            if let menu = picker.menu { ExplorerStyle.configureMenu(menu) }
        }
        for child in view.subviews { applyBarFonts(to: child) }
    }

    private func addBar(_ bar: NSView, to root: NSStackView, height: CGFloat) {
        let wrapper = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(bar)
        root.addArrangedSubview(wrapper)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalTo: root.widthAnchor),
            wrapper.heightAnchor.constraint(equalToConstant: height + max(0, ExplorerStyle.preferences.fontSize(for: .bars) - 12)),
            bar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
            bar.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
        ])
    }

    static let cloudColumn = NSUserInterfaceItemIdentifier("icloud")
    private let cloudDownloads = ICloudDownloadMonitor()
    /// Items this window saw finish downloading and the listing still reports as online-only: a
    /// large folder takes seconds to read again, and the cloud must not come back meanwhile.
    private var cloudDownloaded: Set<String> = []
    /// Where a deletion left the list without a selection: the items that now stand just below
    /// and just above what was removed, so the arrow keys carry on from there.
    private var deletionAnchor: (below: String?, above: String?, folder: String)?
    private lazy var cloudBatch = ICloudBatchDownloader(monitor: cloudDownloads)
    private var cloudBatchPreparing = false
    private var cloudBatchPrepare: Task<Void, Never>?
    private var cloudBatchRefresh: Task<Void, Never>?

    /// A narrow column with the iCloud state of each item; shown only in folders that are in iCloud.
    private func makeCloudColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: Self.cloudColumn)
        let title = L10n.text("icloud.batch.header_tip")
        column.title = ""
        column.headerToolTip = title
        column.width = 30; column.minWidth = 26; column.maxWidth = 44
        column.headerCell = SortHeaderCell(textCell: "")
        column.headerCell.lineBreakMode = .byTruncatingTail
        column.headerCell.attributedStringValue = Self.cloudHeader(symbol: "icloud", description: title)
        column.isHidden = true
        return column
    }

    private static func cloudHeader(symbol name: String, description: String) -> NSAttributedString {
        guard let symbol = ExplorerStyle.symbol(name, description: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) else { return NSAttributedString(string: "") }
        let attachment = NSTextAttachment()
        attachment.image = symbol
        let header = NSMutableAttributedString(attachment: attachment)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        header.addAttributes([.paragraphStyle: paragraph, .foregroundColor: NSColor.headerTextColor],
                             range: NSRange(location: 0, length: header.length))
        return header
    }

    /// The header of the iCloud column is a command: download everything, or stop while that runs.
    private func updateCloudHeader() {
        guard let column = table.tableColumn(withIdentifier: Self.cloudColumn) else { return }
        let running = cloudBatch.isRunning
        let tip = L10n.text(running ? "icloud.batch.stop_tip" : "icloud.batch.header_tip")
        column.headerToolTip = tip
        column.headerCell.attributedStringValue = Self.cloudHeader(symbol: running ? "stop.circle" : "icloud", description: tip)
        table.headerView?.needsDisplay = true
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard tableColumn.identifier == Self.cloudColumn else { return }
        if cloudBatch.isRunning { cloudBatch.stop(); return }
        // A second click while the folders are still being looked through gives up.
        if cloudBatchPreparing { cloudBatchPrepare?.cancel(); return }
        let selected = selectedTableEntries()
        startCloudBatch(selected.count > 1 ? selected : visibleEntries)
    }

    @objc private func downloadSelectionFromICloud(_ sender: Any?) { startCloudBatch(commandEntries(sender)) }
    @objc private func downloadAllFromICloud(_ sender: Any?) { startCloudBatch(visibleEntries) }
    @objc private func stopCloudBatch(_ sender: Any?) { cloudBatchPrepare?.cancel(); cloudBatch.stop() }

    private func startCloudBatch(_ scope: [FileEntry]) {
        guard !cloudBatch.isRunning, !cloudBatchPreparing, !session.blocksInteraction,
              session.history.current.url.isFileURL, window != nil else { return }
        cloudBatchPreparing = true
        cloudBatchPrepare = Task { [weak self] in
            await self?.prepareCloudBatch(scope)
            guard let self else { return }
            self.cloudBatchPreparing = false
            self.cloudBatchPrepare = nil
            if self.workspace.activeTab != nil { self.renderStatusText() }
        }
    }

    /// Finds out what there is to download, asks what has to be asked (subfolders, a large
    /// number of files, a disk without room for all of it) and starts the queue.
    private func prepareCloudBatch(_ scope: [FileEntry]) async {
        guard let window else { return }
        let location = session.history.current.url, activeSession = session
        let number: (Int) -> String = { $0.formatted(.number.locale(L10n.current.locale)) }
        func ask(_ title: String, _ message: String, buttons: [String], style: NSAlert.Style = .informational) async -> Int {
            let alert = NSAlert()
            alert.alertStyle = style
            alert.messageText = title
            alert.informativeText = message
            for button in buttons { alert.addButton(withTitle: button) }
            let response = await alert.beginSheetModal(for: window)
            return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        }
        let cancel = L10n.text("dialog.cancel")
        var includeFolders = false
        let folders = scope.filter(ICloudBatch.isFolder).count
        if folders > 0 {
            switch await ask(L10n.text("icloud.batch.subfolders_title"), L10n.format("icloud.batch.subfolders_message", number(folders)),
                             buttons: [L10n.text("icloud.batch.include"), L10n.text("icloud.batch.files_only"), cancel]) {
            case 0: includeFolders = true
            case 1: break
            default: return
            }
        }
        renderStatusText()
        let folderContents = includeFolders
        let worker = Task.detached(priority: .userInitiated) {
            (ICloudBatch.plan(scope, includingFolders: folderContents), ICloudBatch.volume(at: location))
        }
        var (items, volume) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, workspace.activeTab != nil, session === activeSession,
              session.history.current.url == location, !cloudBatch.isRunning else { return }
        guard !items.isEmpty else {
            _ = await ask(L10n.text("icloud.batch.nothing"), "", buttons: [L10n.text("dialog.confirm")])
            return
        }
        // Without the disk's figures there is no telling what fits: nothing is downloaded.
        guard let space = volume else {
            _ = await ask(L10n.text("icloud.batch.space_unknown"), "", buttons: [L10n.text("dialog.confirm")], style: .warning)
            return
        }
        // What is already on its way, asked for one by one or left by a stopped batch, takes room too.
        let total = ICloudBatch.totalSize(items), bytes = L10n.current.bytes, arriving = cloudDownloads.pendingBytes
        let room = ICloudBatch.Volume(available: space.available - arriving, total: space.total)
        volume = room
        if let space = volume, !space.fits(total) {
            let fitting = ICloudBatch.countThatFits(items, in: space)
            guard fitting > 0 else {
                _ = await ask(L10n.text("icloud.batch.space_title"),
                              L10n.format("icloud.batch.no_space_message", bytes(total), bytes(space.available), bytes(space.reserve)),
                              buttons: [L10n.text("dialog.confirm")], style: .warning)
                return
            }
            let message = L10n.format("icloud.batch.space_message", number(items.count), bytes(total), bytes(space.available),
                                      bytes(space.reserve), number(fitting))
            guard await ask(L10n.text("icloud.batch.space_title"), message,
                            buttons: [L10n.text("icloud.batch.download_fitting"), cancel], style: .warning) == 0 else { return }
            items = Array(items.prefix(fitting))
        } else if items.count > ICloudBatch.confirmationThreshold {
            let message = L10n.format("icloud.batch.confirm_message", bytes(total), bytes(volume?.available ?? 0))
            guard await ask(L10n.format("icloud.batch.confirm_title", number(items.count)), message,
                            buttons: [L10n.text("icloud.batch.download"), cancel]) == 0 else { return }
        }
        guard !Task.isCancelled, workspace.activeTab != nil, session === activeSession, !cloudBatch.isRunning else { return }
        cloudBatch.start(items, folder: location)
    }

    /// Whether the list shows the folder the running (or just ended) batch was started from.
    private var showsCloudBatchFolder: Bool {
        guard workspace.activeTab != nil, let folder = cloudBatch.folder else { return false }
        let location = session.history.current.url
        return location.isFileURL && location.standardizedFileURL.path == folder.standardizedFileURL.path
    }

    private func cloudBatchEnded(_ end: ICloudBatchDownloader.End) {
        cloudBatchRefresh?.cancel(); cloudBatchRefresh = nil
        guard workspace.activeTab != nil else { return }
        updateCloudHeader()
        renderStatusText()
        if showsCloudBatchFolder { session.refreshKeepingView() }
        guard let window else { return }
        let number: (Int) -> String = { $0.formatted(.number.locale(L10n.current.locale)) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch end {
        case .outOfSpace(let remaining, let volume):
            alert.messageText = L10n.text("icloud.batch.stopped_space_title")
            alert.informativeText = L10n.format("icloud.batch.stopped_space_message", number(remaining),
                                                L10n.current.bytes(volume.available), L10n.current.bytes(volume.reserve))
        case .spaceUnknown:
            alert.messageText = L10n.text("icloud.batch.space_unknown")
        case .finished(let failed) where failed > 0:
            alert.messageText = L10n.format("icloud.batch.failed_message", number(failed))
        default: return
        }
        alert.addButton(withTitle: L10n.text("dialog.confirm"))
        alert.beginSheetModal(for: window) { _ in }
    }

    /// While a batch runs the folder is read again every few seconds, not at every file.
    private func scheduleCloudBatchRefresh() {
        guard cloudBatchRefresh == nil else { return }
        cloudBatchRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            self.cloudBatchRefresh = nil
            if self.showsCloudBatchFolder, !self.session.blocksInteraction { self.session.refreshKeepingView() }
        }
    }

    @objc private func cloudStatusClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard visibleEntries.indices.contains(row), !session.blocksInteraction else { return }
        startICloudDownload(visibleEntries[row])
    }

    /// The iCloud state of one row: the download in progress when this window asked for it,
    /// otherwise the state the listing read.
    private func cloudState(of entry: FileEntry) -> (state: ICloudAvailability?, download: ICloudDownloadMonitor.Status?) {
        var state = entry.secureFolderURL == nil ? entry.iCloudAvailability : nil
        let download = state == nil ? nil : cloudDownloads.status(for: entry.url)
        if download == nil, state != nil, state != .available, cloudDownloaded.contains(entry.url.path) { state = .available }
        return (state, download)
    }

    private func configureCloudCell(_ cell: CloudStatusCell, for entry: FileEntry) {
        let (state, download) = cloudState(of: entry)
        var description = state.map { L10n.text("icloud." + $0.rawValue) }
        switch download {
        case .waiting?: description = L10n.text("icloud.downloading")
        case .fraction(let value)?:
            let percent = value.formatted(.percent.precision(.fractionLength(0)).locale(L10n.current.locale))
            description = L10n.format("icloud.downloading_progress", percent)
        case nil: break
        }
        cell.configure(state: state, description: description,
                       canDownload: (state == .onlineOnly || state == .failed) && download == nil, download: download)
    }

    /// Updates the status cell of one item where it stands, without reloading the list.
    private func updateCloudCell(for url: URL) {
        let path = url.path
        if viewMode != .details {
            if let row = visibleEntries.firstIndex(where: { $0.url.path == path }),
               let item = grid.item(at: IndexPath(item: row, section: 0)) as? FileGridItem { configureGridItem(item, for: visibleEntries[row]) }
            return
        }
        let column = table.column(withIdentifier: Self.cloudColumn)
        guard column >= 0, let row = visibleEntries.firstIndex(where: { $0.url.path == path }),
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? CloudStatusCell else { return }
        configureCloudCell(cell, for: visibleEntries[row])
    }

    private func observeCloudDownloads() {
        cloudDownloads.onProgress = { [weak self] url in self?.updateCloudCell(for: url) }
        cloudBatch.onProgress = { [weak self] in self?.updateCloudHeader(); self?.renderStatusText() }
        cloudBatch.onEnd = { [weak self] end in self?.cloudBatchEnded(end) }
        cloudDownloads.onFinish = { [weak self] url, downloaded in
            guard let self else { return }
            if downloaded { self.cloudDownloaded.insert(url.path) }
            self.updateCloudCell(for: url)
            self.updateGalleryStage()
            // The batch reports its own outcome and reads the folder at its own pace; an item
            // asked for on its own while a batch runs is treated as usual, below.
            if self.cloudBatch.itemFinished(url, downloaded: downloaded) {
                if self.cloudBatch.isRunning { self.scheduleCloudBatchRefresh() }
                return
            }
            // The tab may show another folder by now: only the folder that holds the item is
            // refreshed, and only there is a failure worth a message.
            let location = self.session.history.current.url
            guard location.isFileURL, location.standardizedFileURL.path == url.deletingLastPathComponent().standardizedFileURL.path else { return }
            if !downloaded {
                self.errorLabel.stringValue = L10n.format("icloud.download_failed", url.lastPathComponent)
                self.errorLabel.isHidden = false
            }
            self.session.refreshKeepingView()
        }
    }

    /// Asks iCloud for the item and refreshes its state in place. Nothing moves, so the list keeps
    /// its scroll position and selection, and no progress panel is shown: the download itself runs
    /// in iCloud and shows in the status column.
    private func startICloudDownload(_ entry: FileEntry) {
        guard entry.iCloudAvailability != nil, !session.blocksInteraction else { return }
        let url = entry.url, name = entry.name, activeSession = session
        // The icon answers the click at once; the progress follows when iCloud reports it.
        let started = cloudDownloads.begin(url, size: entry.size ?? 0)
        Task { [weak self] in
            // One file is held to the same rule as a batch: the disk's reserve is not touched.
            let space = await Task.detached { ICloudBatch.volume(at: url.deletingLastPathComponent()) }.value
            if let self, let space, !space.fits(self.cloudDownloads.pendingBytes) {
                if started { self.cloudDownloads.cancel(url) }
                guard self.workspace.activeTab != nil, self.session === activeSession else { return }
                self.errorLabel.stringValue = L10n.format("icloud.batch.no_room", name)
                self.errorLabel.isHidden = false
                return
            }
            do { try await Task.detached { try ICloudAvailability.request(.download, at: url) }.value }
            catch {
                if started { self?.cloudDownloads.cancel(url) }
                guard let self, self.session === activeSession else { return }
                self.errorLabel.stringValue = L10n.format("icloud.download_failed", name)
                self.errorLabel.isHidden = false
                return
            }
            // No reload here: the cell already follows the download, and reading a large folder
            // now would only delay the reading that follows its end.
        }
    }

    private func applySavedColumns() {
        let preferences = ExplorerStyle.browserPreferences
        for (index, identifier) in preferences.columnOrder.enumerated() {
            let current = table.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
            if current >= 0 { table.moveColumn(current, toColumn: index) }
        }
        // The iCloud column is not part of the saved layout: it always goes right after the name.
        let cloud = table.column(withIdentifier: Self.cloudColumn), name = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        if cloud >= 0, name >= 0 { table.moveColumn(cloud, toColumn: cloud > name ? name + 1 : name) }
        for column in table.tableColumns {
            if let width = preferences.columnWidths[column.identifier.rawValue] { column.width = width }
        }
    }

    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        DialogPlacement.sheetAnchor(sheet, in: window)
    }

    private func restoreWindowFrame() {
        guard let window else { return }
        guard var frame = ExplorerStyle.browserPreferences.windowFrame,
              let main = NSScreen.main else { window.center(); return }
        let screen = NSScreen.screens.max { left, right in
            let a = left.visibleFrame.intersection(frame), b = right.visibleFrame.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        let visible = screen.flatMap { $0.visibleFrame.intersects(frame) ? $0.visibleFrame : nil } ?? main.visibleFrame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func schedulePresentationSave() {
        guard !restoringLayout else { return }
        presentationSaveTask?.cancel()
        presentationSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.savePresentation()
        }
    }

    func savePresentation() {
        presentationSaveTask?.cancel(); presentationSaveTask = nil
        guard !restoringLayout else { return }
        let preferences = ExplorerStyle.browserPreferences
        preferences.setColumns(order: table.tableColumns.map { $0.identifier.rawValue },
            widths: Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) }))
        preferences.sidebarWidth = sidebarWidth
        preferences.previewWidth = previewPaneWidth
        if let window, !window.styleMask.contains(.fullScreen) { preferences.setWindowFrame(window.frame) }
    }

    func tableViewColumnDidMove(_ notification: Notification) { positionRenameField(); schedulePresentationSave() }
    func tableViewColumnDidResize(_ notification: Notification) { positionRenameField(); schedulePresentationSave() }
    func splitViewDidResizeSubviews(_ notification: Notification) { schedulePresentationSave() }
    func windowDidMove(_ notification: Notification) { schedulePresentationSave() }
    func windowDidResize(_ notification: Notification) { schedulePresentationSave(); refitTrail() }

    private func addLine(to root: NSStackView) {
        let separator = ExplorerStyle.separator()
        root.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func configureTable() {
        let columns: [(String, String, CGFloat)] = [("name", L10n.text("column.name"), 390), ("modified", L10n.text("column.modified"), 165),
                                                   ("kind", L10n.text("column.kind"), 150), ("size", L10n.text("column.size"), 95)]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = 75
            column.headerCell = SortHeaderCell(textCell: title)
            column.headerToolTip = title
            column.headerCell.alignment = .left
            column.headerCell.lineBreakMode = .byTruncatingTail
            column.headerCell.font = ExplorerStyle.font(.files)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byTruncatingTail
            column.headerCell.attributedStringValue = NSAttributedString(string: title,
                attributes: [.font: ExplorerStyle.font(.files), .foregroundColor: NSColor.headerTextColor,
                             .paragraphStyle: paragraph])
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
            if key == "name" { table.addTableColumn(makeCloudColumn()) }
        }
        observeCloudDownloads()
        table.style = .plain
        table.rowHeight = FileTypeIcon.listRowHeight
        table.headerView?.frame.size.height = max(24, ExplorerStyle.preferences.fontSize(for: .files) + 12)
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes(FileClipboard.dragTypes)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.serviceSelection = { [weak self] in
            guard let self, !self.session.blocksInteraction else { return [] }
            return self.commandEntries(nil).map(\.url)
        }
        table.renameCandidate = { [weak self] point in self?.renameCandidate(at: point) }
        table.action = #selector(completedTableClick)
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel(L10n.text("table.accessibility"))
        table.setAccessibilityIdentifier("explorer.files")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        ExplorerStyle.configureMenu(menu)
    }

    @objc func showFileSearch(_ sender: Any?) { presentSearch(saved: nil) }

    private func presentSearch(saved: ExplorerSavedSearch?) {
        searchWindow?.close()
        let base = session.history.current.url
        let next = FileSearchController(folder: base.isFileURL ? base : FileManager.default.homeDirectoryForCurrentUser,
                                        saved: saved, onReveal: { [weak self] url in
            self?.navigate(.visit(url.explorerParent), revealing: url)
        }, onSave: { [weak self] search in
            try self?.tree.saveSearch(search)
        })
        searchWindow = next
        next.showWindow(nil)
    }

    @objc private func editFinderTags(_ sender: Any?) {
        guard let window else { return }
        SearchTagEditor.present(urls: commandEntries(sender).map(\.url), owner: window)
    }

    /// Folders that may be kept as favorites and recent folders: real folders of this Mac, but not
    /// a protected folder (open or locked), nor anything inside an open one, nor the Trash.
    func canKeepAsShortcut(_ url: URL) -> Bool {
        guard url.isFileURL, !FolderShortcuts.isExcludedPlace(url), !SecureFolderService.isSessionURL(url) else { return false }
        if secureFolders?.isInsideUnlockedVault(url) == true || SecureFolderService.isVault(url) { return false }
        return FolderShortcuts.folderExists(url)
    }

    /// Adds the folder open in the list to the favorites, or takes it out.
    @objc func toggleCurrentFolderFavorite(_ sender: Any?) {
        let url = session.history.current.url
        let shortcuts = ExplorerStyle.folderShortcuts
        if shortcuts.isFavorite(url) { shortcuts.removeFavorite(url) }
        else if canKeepAsShortcut(url) { shortcuts.addFavorite(url) }
    }

    @objc private func toggleFavoriteEntry(_ sender: Any?) {
        guard let url = commandEntries(sender).first?.url else { return }
        let shortcuts = ExplorerStyle.folderShortcuts
        if shortcuts.isFavorite(url) { shortcuts.removeFavorite(url) }
        else if canKeepAsShortcut(url) { shortcuts.addFavorite(url) }
    }

    func navigate(_ action: NavigationAction, revealing file: URL? = nil) {
        endInlineRename()
        // Prevent accidental actions on stale rows while a new destination is pending.
        if !session.blocksInteraction { rememberView() }
        workspace.activeTab?.prepareForUserNavigation()
        if let id = workspace.activeID { restorationFallbackTabs.remove(id); systemVolumes.clearNotice(for: id) }
        if file != nil {
            workspace.activeTab?.filterQuery = ""
            filter.stringValue = ""
        }
        session.navigate(action, selecting: file.map { [$0.explorerIdentity] })
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard !session.blocksInteraction, visibleEntries.indices.contains(row) else { return nil }
        return FileClipboard.pasteboardWriter(for: visibleEntries[row].url)
    }
    private func dropDestination(row: Int, operation: NSTableView.DropOperation) -> URL? {
        if operation == .on, visibleEntries.indices.contains(row), visibleEntries[row].secureFolderURL != nil { return nil }
        if operation == .on, visibleEntries.indices.contains(row), visibleEntries[row].canNavigate {
            return visibleEntries[row].url
        }
        return session.history.current.url
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !session.blocksInteraction else { return [] }
        guard let destination = dropDestination(row: row, operation: operation) else { return [] }
        if !(operation == .on && visibleEntries.indices.contains(row) && visibleEntries[row].canNavigate) {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return FileDrop.operation(for: FileDrop.readURLs(from: info), to: destination,
                                  allowed: FileDrop.allowedOperations(for: info))
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard !session.blocksInteraction else { return false }
        let urls = FileDrop.readURLs(from: info)
        guard let destination = dropDestination(row: row, operation: operation) else { return false }
        let action = FileDrop.operation(for: urls, to: destination, allowed: FileDrop.allowedOperations(for: info))
        guard action == .copy || action == .move else { return false }
        FileCommands.shared.transfer(urls, to: destination, move: action == .move)
        return FileCommands.shared.task != nil
    }

    private func rememberView() {
        guard let tab = workspace.activeTab else { return }
        tab.filterQuery = filter.stringValue
        session.remember(selection: selectedPaths(), scrollOffset: listOffset)
    }

    private func selectedPaths() -> Set<String> {
        Set(table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0].id : nil })
    }

    private func renderSession() {
        guard let tab = workspace.activeTab else { return }
        lastLocation = tab.session.history.current.url
        let changedTab = renderedTabID != tab.id
        if changedTab || tab.session.blocksInteraction { endInlineRename() }
        if tab.session.blocksInteraction { gitState.stop() }
        else { gitState.beginNavigation(to: tab.session.history.current.url) }
        renderedTabID = tab.id
        rendering = true
        filter.stringValue = tab.filterQuery
        table.sortDescriptors = [NSSortDescriptor(key: tab.sortKey.rawValue, ascending: tab.sortAscending)]
        rendering = false
        backButton.isEnabled = !session.history.back.isEmpty
        forwardButton.isEnabled = !session.history.forward.isEmpty
        upButton.isEnabled = !session.history.current.url.explorerIsRoot
        table.isEnabled = !session.blocksInteraction
        grid.isSelectable = !session.blocksInteraction
        gridScroll.alphaValue = session.blocksInteraction ? 0.5 : 1
        let restoredFallback = tab.restorationUnavailableURL != nil || restorationFallbackTabs.contains(tab.id)
        errorLabel.stringValue = L10n.directoryError(session.failure) ?? systemVolumes.notice(for: tab.id) ?? (restoredFallback ? L10n.text("options.restore_unavailable") : "")
        errorLabel.toolTip = errorLabel.stringValue
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        tree.setShowHidden(session.showHidden)
        let url = session.history.current.url
        if changedTab || renderedPath != url.explorerIdentity { addressSuggestions.dismiss() }
        let editingAddress = (window?.firstResponder as? NSTextView)?.delegate as? NSTextField === address
        if changedTab || renderedPath != url.explorerIdentity || !editingAddress { address.stringValue = CloudAccounts.shared.address(for: url) }
        renderedPath = url.explorerIdentity
        window?.title = L10n.format("window.title", url.isFileURL ? (url.path == "/" ? L10n.text("tree.computer") : url.lastPathComponent) : CloudAccounts.shared.title(for: url))
        // No represented URL: with one, AppKit fetches the folder's icon for the title bar on the
        // main thread, and for that the system counts the folder's items. In a huge iCloud folder
        // that held the window back for seconds at every launch, and at times for good.
        rebuildBreadcrumbs(url)
        if changedTab || !session.isLoading {
            applyViewMode(viewMode(for: url))
            rebuildRows(selection: session.history.current.selectedPaths, scroll: session.history.current.scrollOffset)
            tree.show(url)
        }
        filter.isEnabled = !session.blocksInteraction
        updatePreviewSelection()
        if session.isLoading {
            progress.startAnimation(nil)
            if session.blocksInteraction {
                status.stringValue = L10n.text("status.loading")
                updateCommandBar()
                message.isHidden = true
            }
            return
        }
        progress.stopAnimation(nil)
        if session.failure == nil, lastRecordedVisit != url.explorerIdentity {
            lastRecordedVisit = url.explorerIdentity
            if canKeepAsShortcut(url) { ExplorerStyle.folderShortcuts.recordVisit(url) }
        }
        gitState.update(directory: url, entries: session.entries, force: forceGitRefresh)
        forceGitRefresh = false
    }

    private func renderGit() {
        gitSummary.stringValue = GitDecoration.summary(gitState.result)
        gitSummary.isHidden = gitSummary.stringValue.isEmpty
        gitSummary.toolTip = gitSummary.stringValue
        gitSummary.setAccessibilityLabel(gitSummary.stringValue)
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        if column >= 0 {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: column))
        }
        refreshVisibleGridItems()
        tree.updateGit(snapshot: gitState.snapshot, roots: gitState.repositoryRootPaths)
    }

    private func rebuildRows(selection: Set<String>, scroll: Double? = nil) {
        let query = filter.stringValue
        let nameFilter = NameFilter(query)
        let entries = session.entries.filter { nameFilter.matches($0.name) }
        let descriptor = table.sortDescriptors.first
        let localization = L10n.current
        visibleEntries = EntryOrdering.sorted(entries, by: EntrySortKey(rawValue: descriptor?.key ?? "name") ?? .name,
                                              ascending: descriptor?.ascending ?? true, kindName: localization.fileKind)
        if !cloudDownloaded.isEmpty {
            // Kept only for items of this folder that the listing has not caught up with.
            let pending = Set(session.entries.lazy.filter { $0.iCloudAvailability != nil && $0.iCloudAvailability != .available }.map(\.url.path))
            cloudDownloaded.formIntersection(pending)
        }
        rendering = true
        table.tableColumn(withIdentifier: Self.cloudColumn)?.isHidden = !visibleEntries.contains { $0.iCloudAvailability != nil }
        table.reloadData()
        let indexes = IndexSet(visibleEntries.indices.filter { selection.contains(visibleEntries[$0].id) })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        if viewMode != .details {
            grid.reloadData()
            syncGridSelection()
            if let scroll { restoreGridOffset(scroll, selection: indexes.first) }
        } else if let scroll {
            table.layoutSubtreeIfNeeded()
            let top = -fileScroll.contentView.contentInsets.top
            let maximum = max(top, table.bounds.height - fileScroll.contentView.bounds.height)
            fileScroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(top, scroll == 0 ? top : scroll))))
            fileScroll.reflectScrolledClipView(fileScroll.contentView)
            if scroll == 0, let first = indexes.first { table.scrollRowToVisible(first) }
        }
        rendering = false
        positionRenameField()
        let location = session.history.current.url
        let cloudOverview = location.scheme == RemoteLocation.scheme && (location.host == nil || location.host == "")
        message.stringValue = query.isEmpty ? L10n.text(cloudOverview ? "cloud.empty" : "empty.folder") : L10n.text("empty.filter")
        message.isHidden = !visibleEntries.isEmpty || session.errorMessage != nil
        updateStatus()
    }

    /// The trail shows every folder of the path. Only when they do not fit in the bar are the
    /// ones in the middle replaced by "…", as few of them as it takes.
    private func rebuildBreadcrumbs(_ url: URL) {
        for view in breadcrumbs.arrangedSubviews { breadcrumbs.removeArrangedSubview(view); view.removeFromSuperview() }
        var paths: [URL] = [], current = url
        while true {
            paths.insert(current, at: 0)
            if current.explorerIsRoot { break }
            current = current.explorerParent
        }
        func views(_ shown: [URL], elided: Bool) -> [NSView] {
            var result: [NSView] = []
            for (index, path) in shown.enumerated() {
                if index > 0 { result.append(ExplorerStyle.label(index == 1 && elided ? "› … ›" : "›", color: .tertiaryLabelColor)) }
                let title = path.isFileURL ? (path.path == "/" ? L10n.text("tree.computer") : path.lastPathComponent) : CloudAccounts.shared.title(for: path)
                let button = BreadcrumbButton(title: title, target: self, action: #selector(breadcrumbClicked))
                button.destination = path; button.isBordered = false
                button.quiet = true
                button.setContentCompressionResistancePriority(path == url ? .defaultHigh : .defaultLow, for: .horizontal)
                button.font = ExplorerStyle.font(.bars, weight: path == url ? .semibold : .regular)
                button.lineBreakMode = .byTruncatingMiddle
                button.toolTip = CloudAccounts.shared.address(for: path)
                button.setAccessibilityLabel(L10n.format("breadcrumbs.go_to", CloudAccounts.shared.address(for: path)))
                result.append(button)
            }
            return result
        }
        func width(_ views: [NSView]) -> CGFloat {
            views.reduce(0) { $0 + $1.intrinsicContentSize.width } + CGFloat(max(0, views.count - 1)) * breadcrumbs.spacing
        }
        let room = address.bounds.width - 16
        var chosen = views(paths, elided: false)
        if room > 0, width(chosen) > room, paths.count > 2 {
            // Keep the first folder and as many of the last ones as fit.
            for tail in stride(from: paths.count - 2, through: 1, by: -1) {
                chosen = views([paths[0]] + Array(paths.suffix(tail)), elided: true)
                if width(chosen) <= room { break }
            }
        }
        trailWidth = address.bounds.width
        for view in chosen { breadcrumbs.addArrangedSubview(view) }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        breadcrumbs.addArrangedSubview(spacer)
    }

    /// The width of the address bar the trail was last fitted to.
    private var trailWidth: CGFloat = 0
    private func refitTrail() {
        guard workspace.activeTab != nil, abs(address.bounds.width - trailWidth) > 1 else { return }
        rebuildBreadcrumbs(session.history.current.url)
    }

    private func updateStatus() {
        let count = table.selectedRowIndexes.count
        renderStatusText()
        _ = count
        updateCommandBar()
        updatePreviewSelection()
    }

    /// Fills the strip with the titles of the application's menus (all but the first, which is
    /// the application's own). Called again whenever the menus are built anew.
    func rebuildMenuStrip() {
        for view in menuStrip.arrangedSubviews { menuStrip.removeArrangedSubview(view); view.removeFromSuperview() }
        // The application's own menu comes first, under the application's name: Options, updates,
        // hiding and quitting have no other place in the window.
        for (index, item) in (NSApp.mainMenu?.items ?? []).enumerated() {
            guard let menu = item.submenu, !item.isHidden else { continue }
            let button = MenuStripButton()
            button.title = index == 0 ? "My Explorer" : item.title
            button.font = ExplorerStyle.font(.menus)
            button.stripMenu = menu
            button.setAccessibilityLabel(item.title)
            menuStrip.addArrangedSubview(button)
        }
    }

    /// The menu of the "More" button of the command bar.
    var moreMenu: NSMenu { moreButton.dropMenu }

    private var toolbarMenus: [NSMenu] { [newButton.dropMenu, sortButton.dropMenu, viewButton.dropMenu, moreButton.dropMenu] }

    /// Whether a command came from the command bar: it acts on the selection of the list even
    /// though the list may not have the keyboard at that moment.
    private func fromToolbar(_ sender: Any?) -> Bool {
        if let item = sender as? NSMenuItem, let menu = item.menu { return toolbarMenus.contains { $0 === menu } }
        return (sender as? NSView)?.isDescendant(of: commandBar) == true
    }

    /// The commands of the bar that need a selection are dimmed without one, not hidden: nothing
    /// in the bar changes place.
    private func updateCommandBar() {
        let blocked = session.blocksInteraction, entries = blocked ? [] : selectedTableEntries()
        for (button, needs) in selectionButtons {
            switch needs {
            case .any: button.isEnabled = !entries.isEmpty
            case .oneLocal: button.isEnabled = entries.count == 1 && entries[0].url.isFileURL
            case .shareable: button.isEnabled = !entries.isEmpty && FileSharingController.supports(entries.map(\.url))
            }
        }
        pasteButton.isEnabled = !blocked
        newButton.isEnabled = !blocked
        sortButton.isEnabled = !blocked
    }

    /// The trail of folders shows while the address is not being edited; the text of the field
    /// is still there underneath, unseen, for everything that reads it.
    private func showTrail(_ show: Bool) {
        breadcrumbs.isHidden = !show
        address.textColor = show ? .clear : .labelColor
    }

    @objc func renameInList(_ sender: Any?) {
        guard !session.blocksInteraction else { return }
        window?.makeFirstResponder(fileListView)
        renameSelectionInPlace()
    }

    private func renderStatusText() {
        var text = L10n.current.listingStatus(visible: visibleEntries.count, total: session.entries.count,
                                              filtered: !filter.stringValue.isEmpty, selected: table.selectedRowIndexes.count)
        if cloudBatch.isRunning {
            let progress = cloudBatch.progress
            let number: (Int) -> String = { $0.formatted(.number.locale(L10n.current.locale)) }
            text += " · " + L10n.format("icloud.batch.status", number(progress.done), number(progress.total),
                                        L10n.current.bytes(progress.doneBytes), L10n.current.bytes(progress.totalBytes))
        } else if cloudBatchPreparing {
            text += " · " + L10n.text("icloud.batch.checking")
        }
        status.stringValue = text
    }

    // MARK: View modes

    /// The view that shows the files now: the table of details or the grid of the other modes.
    var fileListView: NSView { viewMode == .details ? table : grid }
    private var activeScroll: NSScrollView { viewMode == .details ? fileScroll : gridScroll }
    private var listScrollsSideways: Bool { viewMode == .list || viewMode == .gallery }
    /// How far the list is scrolled, along the direction it scrolls in.
    var listOffset: Double {
        let origin = activeScroll.contentView.bounds.origin
        return listScrollsSideways ? origin.x : origin.y
    }
    /// The row under the secondary click that opened the context menu, or -1.
    private var clickedListRow: Int { viewMode == .details ? table.clickedRow : (grid.clickedIndex ?? -1) }

    /// The entries of the "View" menus that choose the mode and the order; with no target they
    /// go to the window in front.
    static func viewModeItems(target: AnyObject?) -> [NSMenuItem] {
        let keys: [FileViewMode: String] = [.details: "view.mode.details", .list: "view.mode.list", .smallIcons: "view.mode.small_icons",
                                            .largeIcons: "view.mode.large_icons", .gallery: "view.mode.gallery"]
        let items = FileViewMode.allCases.enumerated().map { index, mode in
            let item = NSMenuItem(title: L10n.text(keys[mode] ?? ""), action: #selector(changeViewMode(_:)), keyEquivalent: "")
            item.tag = index
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier("view.mode." + mode.rawValue)
            return item
        }
        return items
    }

    /// The order of the list: by which column, and in which direction.
    static func sortItems(target: AnyObject?) -> [NSMenuItem] {
        var items = BrowserViewPreferences.defaultColumnOrder.map { key in
            let item = NSMenuItem(title: L10n.text("column." + key), action: #selector(sortByColumn(_:)), keyEquivalent: "")
            item.representedObject = key
            item.target = target
            return item
        }
        items.append(.separator())
        for (tag, key) in [(1, "view.sort.ascending"), (0, "view.sort.descending")] {
            let item = NSMenuItem(title: L10n.text(key), action: #selector(sortInDirection(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = target
            items.append(item)
        }
        return items
    }

    @objc func changeViewMode(_ sender: NSMenuItem) {
        guard FileViewMode.allCases.indices.contains(sender.tag) else { return }
        setViewMode(FileViewMode.allCases[sender.tag])
    }

    /// The grids have no column headers: the order is chosen in the "View" menu.
    @objc func sortByColumn(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, !session.blocksInteraction else { return }
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: table.sortDescriptors.first?.ascending ?? true)]
    }

    @objc func sortInDirection(_ sender: NSMenuItem) {
        guard !session.blocksInteraction else { return }
        table.sortDescriptors = [NSSortDescriptor(key: table.sortDescriptors.first?.key ?? "name", ascending: sender.tag == 1)]
    }

    private func viewMode(for url: URL) -> FileViewMode {
        let identity = url.explorerIdentity
        return transientViewModes[identity] ?? ExplorerStyle.folderViewModes.mode(for: identity)
    }

    /// Chooses how the open folder is shown and remembers it for that folder.
    func setViewMode(_ mode: FileViewMode) {
        let url = session.history.current.url, identity = url.explorerIdentity
        // The name of what is inside a protected folder is not written to the preferences.
        if url.isFileURL, SecureFolderService.isSessionURL(url) { transientViewModes[identity] = mode }
        else { ExplorerStyle.folderViewModes.set(mode, for: identity) }
        applyViewMode(mode)
        // The selection stays in sight in the new mode, whichever way the change was applied.
        if let first = table.selectedRowIndexes.first {
            reveal(first)
            if mode != .details { grid.revealAfterLayout(first) }
        }
    }

    private func applyViewMode(_ mode: FileViewMode) {
        guard mode != viewMode else { return }
        let renaming = inlineRename.map { window?.firstResponder === $0.field.currentEditor() } ?? false
        let focused = acceptsFileListCommands || renaming
        endInlineRename()
        if viewMode == .gallery { galleryStage.show(nil, name: "", local: false) }
        viewMode = mode
        let gallery = mode == .gallery
        fileScroll.isHidden = mode != .details
        gridScroll.isHidden = mode == .details
        galleryStage.isHidden = !gallery
        if gallery { gridTop.isActive = false; gridHeight.isActive = true } else { gridHeight.isActive = false; gridTop.isActive = true }
        if mode != .details {
            grid.grid.metrics = FileGridMetrics.metrics(for: mode)
            gridScroll.hasHorizontalScroller = listScrollsSideways
            gridScroll.hasVerticalScroller = !listScrollsSideways
            gridScroll.superview?.layoutSubtreeIfNeeded()
        }
        rendering = true
        grid.reloadData()
        rendering = false
        syncGridSelection()
        if focused { window?.makeFirstResponder(fileListView) }
    }

    /// Runs once the grid has laid its items out again after a change of mode or of contents;
    /// until then it cannot be scrolled past its previous size. Dropped if the list moved on.
    private func afterGridLayout(_ work: @escaping @MainActor (ExplorerWindowController) -> Void) {
        guard viewMode != .details else { return }
        let mode = viewMode, path = renderedPath, tab = renderedTabID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewMode == mode, self.renderedPath == path, self.renderedTabID == tab else { return }
            work(self)
        }
    }

    private func configureGrid() {
        grid.dataSource = self; grid.delegate = self
        grid.menu = table.menu
        grid.registerForDraggedTypes(FileClipboard.dragTypes)
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.serviceSelection = table.serviceSelection
        grid.openSelection = { [weak self] in self?.openSelected(nil) }
        grid.goBack = { [weak self] in self?.goBack(nil) }
        grid.typeSelectName = { [weak self] index in
            guard let self, self.visibleEntries.indices.contains(index) else { return nil }
            return self.visibleEntries[index].displayName(showExtensions: ExplorerStyle.preferences.showFileExtensions)
        }
        grid.renameCandidate = { [weak self] index, point in self?.renameCandidate(at: point, row: index) }
        grid.onSelectionChange = { [weak self] in self?.gridSelectionChanged() }
        grid.setAccessibilityLabel(L10n.text("table.accessibility"))
        grid.setAccessibilityIdentifier("explorer.files.grid")
        gridScroll.documentView = grid
        gridScroll.autohidesScrollers = true
        gridScroll.drawsBackground = true
        gridScroll.backgroundColor = .controlBackgroundColor
        gridScroll.isHidden = true
        galleryStage.isHidden = true
        grid.watchViewport(of: gridScroll)
    }

    /// The user changed the selection in the grid: the table, which every command reads, follows.
    private func gridSelectionChanged() {
        guard viewMode != .details, !rendering else { return }
        let indexes = grid.selectedIndexes.filteredIndexSet { $0 < table.numberOfRows }
        if indexes != table.selectedRowIndexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
    }

    /// The selection changed in the table, by a command or by the grid itself: the grid shows it.
    private func syncGridSelection() {
        guard viewMode != .details else { return }
        grid.setSelection(table.selectedRowIndexes.filteredIndexSet { $0 < visibleEntries.count })
        updateGalleryStage()
    }

    private func isOnThisMac(_ entry: FileEntry) -> Bool {
        entry.iCloudAvailability == nil || entry.iCloudAvailability == .available || cloudDownloaded.contains(entry.url.path)
    }

    private func updateGalleryStage() {
        guard viewMode == .gallery else { return }
        let row = table.selectedRow
        guard !session.blocksInteraction, visibleEntries.indices.contains(row) else { galleryStage.show(nil, name: "", local: false); return }
        let entry = visibleEntries[row]
        galleryStage.show(entry, name: entry.displayName(showExtensions: ExplorerStyle.preferences.showFileExtensions), local: isOnThisMac(entry))
    }

    private func reveal(_ row: Int) {
        if viewMode == .details { table.scrollRowToVisible(row) } else { grid.reveal(row) }
    }

    private func restoreGridOffset(_ offset: Double, selection first: Int?, settled: Bool = false) {
        grid.settle()
        let clip = gridScroll.contentView
        let content = grid.currentGeometry.contentSize
        let limit = listScrollsSideways ? content.width - clip.bounds.width : content.height - clip.bounds.height
        let value = min(max(0, limit), max(0, offset))
        clip.scroll(to: listScrollsSideways ? NSPoint(x: value, y: 0) : NSPoint(x: 0, y: value))
        gridScroll.reflectScrolledClipView(clip)
        if offset == 0, let first { grid.reveal(first) }
        if !settled, offset != 0, abs(listOffset - value) > 1 {
            afterGridLayout { $0.restoreGridOffset(offset, selection: first, settled: true) }
        }
    }

    private func configureGridItem(_ item: FileGridItem, for entry: FileEntry) {
        let metrics = grid.grid.metrics, cell = item.cell
        item.represent(entry)
        cell.arrange(metrics.arrangement)
        cell.label.isHidden = inlineRename?.entry.id == entry.id
        cell.label.stringValue = entry.displayName(showExtensions: ExplorerStyle.preferences.showFileExtensions)
        cell.label.font = ExplorerStyle.font(.files)
        FileTypeIcon.configure(cell, for: entry, side: metrics.icon)
        GitDecoration.apply(to: cell, url: entry.url, directory: entry.canNavigate,
            snapshot: gitState.snapshot, roots: gitState.repositoryRootPaths, baseTooltip: CloudAccounts.shared.address(for: entry.url))
        let cloud = cloudState(of: entry)
        item.showCloud(state: cloud.state, downloading: cloud.download != nil, description: cloud.state.map { L10n.text("icloud." + $0.rawValue) })
        if metrics.thumbnails, isOnThisMac(entry), entry.secureFolderURL == nil, let kind = MediaKind.detect(entry), kind != .audio {
            item.showThumbnail(of: entry, kind: kind, side: metrics.icon)
        }
    }

    /// Draws again what is on screen in the grid, where it stands: Git marks, focus, names.
    /// Only the marks: the pictures already on screen are left alone, not read again.
    private func refreshVisibleGridItems() {
        guard viewMode != .details else { return }
        for case let item as FileGridItem in grid.visibleItems() {
            guard let row = grid.indexPath(for: item)?.item, visibleEntries.indices.contains(row) else { continue }
            let entry = visibleEntries[row]
            guard item.entryID == entry.id else { configureGridItem(item, for: entry); continue }
            GitDecoration.apply(to: item.cell, url: entry.url, directory: entry.canNavigate,
                snapshot: gitState.snapshot, roots: gitState.repositoryRootPaths, baseTooltip: CloudAccounts.shared.address(for: entry.url))
        }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewMode == .details ? 0 : visibleEntries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath)
        if let item = item as? FileGridItem, visibleEntries.indices.contains(indexPath.item) {
            configureGridItem(item, for: visibleEntries[indexPath.item])
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { gridSelectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { gridSelectionChanged() }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        !session.blocksInteraction
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard !session.blocksInteraction, visibleEntries.indices.contains(indexPath.item) else { return nil }
        return FileClipboard.pasteboardWriter(for: visibleEntries[indexPath.item].url)
    }

    /// Where something dropped on the grid goes: into the folder under the pointer, else into
    /// the open folder. Nil over a protected folder, which takes nothing.
    private func gridDrop(_ info: any NSDraggingInfo) -> (destination: URL, folderRow: Int?)? {
        let row = grid.currentGeometry.index(at: grid.convert(info.draggingLocation, from: nil)) ?? -1
        let onFolder = visibleEntries.indices.contains(row) && visibleEntries[row].canNavigate
        guard let destination = dropDestination(row: row, operation: .on) else { return nil }
        return (destination, onFolder ? row : nil)
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard !session.blocksInteraction, let drop = gridDrop(draggingInfo) else { return [] }
        if let row = drop.folderRow {
            proposedDropIndexPath.pointee = NSIndexPath(forItem: row, inSection: 0)
            proposedDropOperation.pointee = .on
        } else {
            proposedDropIndexPath.pointee = NSIndexPath(forItem: visibleEntries.count, inSection: 0)
            proposedDropOperation.pointee = .before
        }
        return FileDrop.operation(for: FileDrop.readURLs(from: draggingInfo), to: drop.destination,
                                  allowed: FileDrop.allowedOperations(for: draggingInfo))
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard !session.blocksInteraction, let drop = gridDrop(draggingInfo) else { return false }
        let urls = FileDrop.readURLs(from: draggingInfo)
        let action = FileDrop.operation(for: urls, to: drop.destination, allowed: FileDrop.allowedOperations(for: draggingInfo))
        guard action == .copy || action == .move else { return false }
        FileCommands.shared.transfer(urls, to: drop.destination, move: action == .move)
        return FileCommands.shared.task != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        visibleEntries.indices.contains(row) ? visibleEntries[row].displayName(showExtensions: ExplorerStyle.preferences.showFileExtensions) : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row), let column = tableColumn else { return nil }
        let entry = visibleEntries[row]
        if column.identifier.rawValue == "name" {
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? FileNameCell) ?? FileNameCell()
            cell.identifier = column.identifier
            cell.label.isHidden = inlineRename?.entry.id == entry.id
            cell.label.stringValue = entry.displayName(showExtensions: ExplorerStyle.preferences.showFileExtensions)
            cell.label.font = ExplorerStyle.font(.files)
            FileTypeIcon.configure(cell, for: entry, rowHeight: tableView.rowHeight)
            GitDecoration.apply(to: cell, url: entry.url, directory: entry.canNavigate,
                snapshot: gitState.snapshot, roots: gitState.repositoryRootPaths, baseTooltip: CloudAccounts.shared.address(for: entry.url))
            return cell
        }
        if column.identifier == Self.cloudColumn {
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? CloudStatusCell) ?? CloudStatusCell()
            cell.identifier = column.identifier
            configureCloudCell(cell, for: entry)
            cell.button.target = self
            cell.button.action = #selector(cloudStatusClicked(_:))
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField) ?? ExplorerStyle.label("", area: .files)
        cell.identifier = column.identifier
        cell.font = ExplorerStyle.font(.files)
        cell.textColor = .secondaryLabelColor
        switch column.identifier.rawValue {
        case "modified": cell.stringValue = entry.modified.map { L10n.current.date($0) } ?? "—"
        case "kind": cell.stringValue = L10n.current.fileKind(entry)
        case "size":
            cell.alignment = .left
            cell.stringValue = entry.isDirectory ? "—" : entry.size.map { L10n.current.bytes($0) } ?? "—"
        default: break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !rendering, let tab = workspace.activeTab else { return }
        tab.sortKey = EntrySortKey(rawValue: table.sortDescriptors.first?.key ?? "name") ?? .name
        tab.sortAscending = table.sortDescriptors.first?.ascending ?? true
        if !restoringLayout {
            ExplorerStyle.browserPreferences.sortKey = tab.sortKey
            ExplorerStyle.browserPreferences.sortAscending = tab.sortAscending
        }
        rebuildRows(selection: selectedPaths())
        onSessionChange?()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rendering else { return }
        syncGridSelection()
        if table.selectedRow >= 0 { deletionAnchor = nil }
        endInlineRename()
        updateStatus()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === address {
            addressSuggestions.update(address, base: session.history.current.url, showHidden: session.showHidden)
            return
        }
        guard (obj.object as? NSSearchField) === filter else { return }
        workspace.activeTab?.filterQuery = filter.stringValue
        rebuildRows(selection: selectedPaths(), scroll: 0)
    }

    @objc func goBack(_ sender: Any?) { navigate(.back) }
    @objc func goForward(_ sender: Any?) { navigate(.forward) }
    @objc func goUp(_ sender: Any?) { navigate(.up) }
    /// Applies the tree option right away, without waiting for the next navigation.
    func syncTreeToOpenFolder() { tree.show(session.history.current.url) }

    @objc func refresh(_ sender: Any?) { forceGitRefresh = true; tree.refresh(); navigate(.reload) }
    @objc func toggleFileExtensions(_ sender: Any?) {
        ExplorerStyle.preferences.setShowFileExtensions(!ExplorerStyle.preferences.showFileExtensions)
    }
    @objc func togglePreviewPane(_ sender: Any?) {
        ExplorerStyle.preferences.setShowPreviewPane(!ExplorerStyle.preferences.showPreviewPane)
        updatePreviewVisibility()
    }

    func updatePreviewVisibility() {
        let show = ExplorerStyle.preferences.showPreviewPane
        previewButton.state = show ? .on : .off
        guard show != previewPaneVisible else { updatePreviewSelection(); return }
        let sidebar = sidebarWidth
        let scroll = activeScroll.contentView.bounds.origin
        if show {
            previewPane.view.frame.size.width = lastPreviewWidth
            split.addArrangedSubview(previewPane.view)
            window?.contentView?.layoutSubtreeIfNeeded()
            let availableSidebar = split.bounds.width - 430 - 220 - 2 * split.dividerThickness
            split.setPosition(max(165, min(sidebar, availableSidebar)), ofDividerAt: 0)
            previewPaneWidth = lastPreviewWidth
        } else {
            lastPreviewWidth = previewPane.view.frame.width
            if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: previewPane.view) {
                window?.makeFirstResponder(fileListView)
            }
            previewPane.closePreview()
            split.removeArrangedSubview(previewPane.view)
            previewPane.view.removeFromSuperview()
            window?.contentView?.layoutSubtreeIfNeeded()
            split.setPosition(sidebar, ofDividerAt: 0)
        }
        split.adjustSubviews()
        activeScroll.contentView.scroll(to: scroll)
        activeScroll.reflectScrolledClipView(activeScroll.contentView)
        updatePreviewSelection()
    }

    var previewPaneVisible: Bool { previewPane.isViewLoaded && previewPane.view.superview === split }
    var previewedURL: URL? { previewPane.previewedURL }
    var previewImageLoaded: Bool { previewPane.previewImageLoaded }
    var previewMessage: String { previewPane.message }
    var previewPaneWidth: CGFloat {
        get { previewPaneVisible ? previewPane.view.frame.width : lastPreviewWidth }
        set {
            lastPreviewWidth = max(220, newValue)
            guard previewPaneVisible else { return }
            let maximum = max(220, split.bounds.width - sidebarWidth - 430 - 2 * split.dividerThickness)
            let width = min(lastPreviewWidth, maximum)
            split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 1)
        }
    }

    func pausePreviewPlayback() { previewPane.pausePlayback() }

    private func updatePreviewSelection() {
        guard previewPaneVisible else { return }
        let entries = session.blocksInteraction ? [] : table.selectedRowIndexes.compactMap {
            visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil
        }
        previewPane.update(entries: entries)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        splitView.subviews.count > 1 && view === splitView.subviews[1]
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 { return max(proposedMinimumPosition, 165) }
        return max(proposedMinimumPosition, sidebarWidth + splitView.dividerThickness + 430)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 {
            let reserved: CGFloat = previewPaneVisible ? 430 + 220 + 2 * splitView.dividerThickness : 430 + splitView.dividerThickness
            return min(proposedMaximumPosition, splitView.bounds.width - reserved)
        }
        return min(proposedMaximumPosition, splitView.bounds.width - 220 - splitView.dividerThickness)
    }

    @objc private func showFontSettings(_ sender: Any?) { onShowFontSettings?() }
    @objc private func manageCloud(_ sender: Any?) { onManageCloud?() }
    func refreshFileNames() {
        if !session.blocksInteraction { rememberView() }
        renderSession()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleCurrentFolderFavorite(_:)) {
            let url = session.history.current.url
            return ExplorerStyle.folderShortcuts.isFavorite(url) || canKeepAsShortcut(url)
        }
        if menuItem.action == #selector(toggleFileExtensions) {
            menuItem.state = ExplorerStyle.preferences.showFileExtensions ? .on : .off
        }
        if menuItem.action == #selector(togglePreviewPane) {
            menuItem.state = ExplorerStyle.preferences.showPreviewPane ? .on : .off
        }
        if menuItem.action == #selector(toggleHidden) {
            menuItem.state = session.showHidden ? .on : .off
            return !session.blocksInteraction
        }
        if menuItem.action == #selector(batchOCR), fromToolbar(menuItem) {
            menuItem.title = L10n.text(selectedTableEntries().count > 1 ? "ocr.create_pdfs" : "ocr.create_pdf")
        }
        switch menuItem.action {
        case #selector(changeViewMode(_:)):
            menuItem.state = FileViewMode.allCases.indices.contains(menuItem.tag) && FileViewMode.allCases[menuItem.tag] == viewMode ? .on : .off
            return true
        case #selector(sortByColumn(_:)):
            menuItem.state = menuItem.representedObject as? String == table.sortDescriptors.first?.key ? .on : .off
            return !session.blocksInteraction
        case #selector(sortInDirection(_:)):
            menuItem.state = (menuItem.tag == 1) == (table.sortDescriptors.first?.ascending ?? true) ? .on : .off
            return !session.blocksInteraction
        default: break
        }
        let entries = commandEntries(menuItem)
        let local = entries.allSatisfy { $0.url.isFileURL }
        switch menuItem.action {
        case #selector(undoFileOperation):
            menuItem.title = FileCommands.shared.undoTitle
            return !FileCommands.shared.isBusy && FileCommands.shared.undoKind != nil
        case #selector(cutFiles): return !session.blocksInteraction && FileCommands.shared.canCut(entries)
        case #selector(compressFiles):
            return local && !entries.isEmpty && !session.blocksInteraction && !FileCommands.shared.isBusy
        case #selector(trashFiles): return !entries.isEmpty && !session.blocksInteraction && !FileCommands.shared.isBusy
        case #selector(copyFiles): return !entries.isEmpty && !session.blocksInteraction
        case #selector(editFinderTags): return local && !entries.isEmpty && !session.blocksInteraction
        case #selector(shareFiles): return FileSharingController.supports(entries.map(\.url)) && !session.blocksInteraction
        case #selector(extractText): return !session.blocksInteraction && Self.canExtractText(entries)
        case #selector(batchOCR): return !session.blocksInteraction && Self.canBatchOCR(entries)
        case #selector(renameFile), #selector(renameInList): return local && entries.count == 1 && !session.blocksInteraction && !FileCommands.shared.isBusy
        case #selector(pasteFiles):
            guard menuItem.menu === table.menu || acceptsFileListCommands || fromToolbar(menuItem) else { return false }
            let destination = menuItem.menu === table.menu && entries.count == 1 && entries[0].canNavigate ? entries[0].url : session.history.current.url
            return FileCommands.shared.canPaste(into: destination) && !session.blocksInteraction && !FileCommands.shared.isBusy
        case #selector(newFolder): return (menuItem.menu === table.menu || acceptsFileListCommands || fromToolbar(menuItem)) && !session.blocksInteraction && FileCommands.shared.canCreateFolder(in: session.history.current.url)
        case #selector(extractFile): return local && entries.count == 1 && !entries[0].isDirectory && entries[0].url.pathExtension.lowercased() == "zip" && !FileCommands.shared.isBusy
        case #selector(properties), #selector(openSelected): return entries.count == 1 && !session.blocksInteraction
        case #selector(openWith): return local && !entries.isEmpty && entries.allSatisfy { !$0.canNavigate }
        case #selector(editWithSuiteEditor(_:)): return !session.blocksInteraction
        case #selector(openSelectedInNewTab): return entries.count == 1 && entries[0].canNavigate
        case #selector(copyPath): return !entries.isEmpty
        default: return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else { return }
        endInlineRename()
        let clicked = clickedListRow
        if clicked >= 0, visibleEntries.indices.contains(clicked) {
            if !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
            contextEntries = table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil }
        } else { contextEntries = [] }
        rebuildContextMenu(menu, entries: contextEntries)
    }

    func rebuildContextMenu(_ menu: NSMenu, entries: [FileEntry]) {
        contextEntries = entries
        menu.removeAllItems()
        func item(_ key: String, _ action: Selector, _ symbol: String) {
            let entry = menu.addItem(withTitle: L10n.text(key), action: action, keyEquivalent: "")
            entry.target = self
            entry.image = ExplorerStyle.symbol(symbol, description: entry.title)
        }
        if !contextEntries.isEmpty {
            item("command.cut_files", #selector(cutFiles), "scissors")
            item("command.copy_files", #selector(copyFiles), "doc.on.doc")
            if contextEntries.allSatisfy({ $0.url.isFileURL }) { item("search.tags_edit", #selector(editFinderTags), "tag") }
            item("command.share", #selector(shareFiles), "square.and.arrow.up")
            if contextEntries.count == 1 && contextEntries[0].canNavigate {
                item("command.paste_files", #selector(pasteFiles), "doc.on.clipboard")
            }
            if contextEntries.count == 1, let entry = contextEntries.first, entry.url.isFileURL {
                if let vault = entry.secureFolderURL {
                    if secureFolders?.isUnlocked(vault) == true {
                        item("vault.lock_one", #selector(lockVault), "lock")
                    }
                    item("vault.unlock", #selector(unlockVault), "lock.open")
                    item("vault.reset", #selector(resetVault), "key")
                } else if entry.isDirectory && !entry.isSymbolicLink && !entry.isPackage {
                    item("vault.protect", #selector(protectFolder), "lock")
                }
            }
            item("command.rename", #selector(renameFile), "pencil")
            item(contextEntries.allSatisfy { $0.url.isFileURL } ? "command.trash" : "command.delete", #selector(trashFiles), "trash")
            menu.addItem(.separator())
            item(contextEntries.count == 1 && !contextEntries[0].url.isFileURL && !contextEntries[0].canNavigate ? "cloud.open_copy" : "command.open", #selector(openSelected), "arrow.up.forward.square")
            item("command.open_new_tab", #selector(openSelectedInNewTab), "plus.square.on.square")
            if contextEntries.count == 1, let entry = contextEntries.first, entry.isDirectory, !entry.isPackage,
               entry.secureFolderURL == nil, canKeepAsShortcut(entry.url) {
                let favorite = ExplorerStyle.folderShortcuts.isFavorite(entry.url)
                item(favorite ? "favorites.remove" : "favorites.add", #selector(toggleFavoriteEntry), favorite ? "star.slash" : "star")
            }
            item("command.open_with", #selector(openWith), "app")
            addSuiteEditors(to: menu)
            if entries.count == 1, let entry = entries.first, let state = entry.iCloudAvailability, entry.secureFolderURL == nil {
                if state == .onlineOnly || state == .failed { item("icloud.download", #selector(downloadFromICloud), "icloud.and.arrow.down") }
                if entry.canRemoveICloudDownload { item("icloud.remove", #selector(removeLocalDownload), "icloud") }
                item("icloud.finder", #selector(manageICloudInFinder), "folder")
            }
            if cloudBatch.isRunning || cloudBatchPreparing {
                item("icloud.batch.stop_tip", #selector(stopCloudBatch), "stop.circle")
            } else if entries.count > 1, entries.contains(where: ICloudBatch.concerns) {
                item("icloud.batch.download_selected", #selector(downloadSelectionFromICloud), "icloud.and.arrow.down")
            }
            if let actions = QuickActionCommands.menu(for: contextEntries, in: window) {
                menu.addItem(withTitle: actions.title, action: nil, keyEquivalent: "").submenu = actions
            }
            item("ocr.title", #selector(extractText), "text.viewfinder")
            item("ocr.batch.title", #selector(batchOCR), "doc.on.doc")
            menu.addItem(.separator())
            item("command.compress", #selector(compressFiles), "archivebox")
            if contextEntries.count == 1 && contextEntries[0].url.pathExtension.lowercased() == "zip" {
                item("command.extract", #selector(extractFile), "shippingbox")
            }
            item("command.copy_path", #selector(copyPath), "link")
            menu.addItem(.separator())
            item("command.properties", #selector(properties), "info.circle")
        } else {
            item("command.new_folder", #selector(newFolder), "folder.badge.plus")
            item("command.paste_files", #selector(pasteFiles), "doc.on.clipboard")
            item("command.undo_files", #selector(undoFileOperation), "arrow.uturn.backward")
            menu.addItem(.separator())
            item("command.refresh", #selector(refresh), "arrow.clockwise")
            if cloudBatch.isRunning || cloudBatchPreparing {
                item("icloud.batch.stop_tip", #selector(stopCloudBatch), "stop.circle")
            } else if visibleEntries.contains(where: ICloudBatch.concerns) {
                item("icloud.batch.header_tip", #selector(downloadAllFromICloud), "icloud.and.arrow.down")
            }
        }
        addGitMenu(to: menu, entries: entries)
        ExplorerStyle.configureMenu(menu)
    }

    /// "Edit with My Notepad" and "Edit with My Paint": shown only when that application is
    /// installed and declares it can open every selected file.
    private func addSuiteEditors(to menu: NSMenu) {
        let files = contextEntries.filter { $0.url.isFileURL && !$0.isDirectory }
        guard !files.isEmpty, files.count == contextEntries.count else { return }
        for editor in SuiteEditor.allCases {
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier) else { continue }
            let types = SuiteEditor.documentTypes(ofApplicationAt: application)
            guard files.allSatisfy({ SuiteEditor.supports($0.url, documentTypes: types) }) else { continue }
            let title = L10n.text(editor == .notepad ? "command.edit_with_notepad" : "command.edit_with_paint")
            let entry = menu.addItem(withTitle: title, action: #selector(editWithSuiteEditor(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = application
            entry.identifier = NSUserInterfaceItemIdentifier("suite." + editor.rawValue)
            entry.image = ExplorerStyle.symbol(editor == .notepad ? "square.and.pencil" : "paintbrush", description: title)
        }
    }

    @objc private func editWithSuiteEditor(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? URL else { return }
        let urls = contextEntries.filter { $0.url.isFileURL && !$0.isDirectory }.map(\.url)
        FileCommands.shared.open(urls, withApplicationAt: application)
    }

    private func addGitMenu(to menu: NSMenu, entries: [FileEntry]) {
        let directory = session.history.current.url
        guard directory.isFileURL, !session.blocksInteraction else { return }
        let childRoots = entries.filter { gitState.repositoryRootPaths.contains($0.url.standardizedFileURL.path) }
        let root: URL
        if let child = childRoots.first {
            guard entries.count == 1 else { return }
            root = child.url
        } else if let active = gitSnapshot?.rootURL { root = active }
        else { return }
        guard let selection = GitSelection(root: root, urls: entries.isEmpty ? [directory] : entries.map(\.url)) else { return }
        let submenu = NSMenu(title: "Git")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Git", action: nil, keyEquivalent: "").submenu = submenu
        for command in ["changes", "history", "copy_branch", "terminal", "root"] + GitInteractiveAction.allCases.map(\.rawValue) {
            if ["stage", "createBranch", "fetch"].contains(command) { submenu.addItem(.separator()) }
            let item = submenu.addItem(withTitle: L10n.text("git." + command), action: #selector(openGitAction(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(command)
            item.representedObject = selection
        }
    }

    @objc private func openGitAction(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? GitSelection else { return }
        let command = sender.identifier?.rawValue
        if command == "history" || command == "changes" {
            gitReview?.close()
            gitReview = GitReviewController(selection: selection, history: command == "history")
            gitReview?.showWindow(self)
            return
        }
        if let command, let action = GitInteractiveAction(rawValue: command) {
            prepareGitOperation(action, selection: selection)
            return
        }
        let generation = vaultPresentationGeneration
        Task {
            let result = await GitStatusService().inspect(directory: selection.root, force: true)
            guard generation == vaultPresentationGeneration else { return }
            guard case .repository(let snapshot) = result, snapshot.rootURL.path == selection.root.path else {
                showGitMessage(L10n.text("git.unavailable")); return
            }
            switch command {
            case "copy_branch":
                guard let branch = snapshot.branch else { showGitMessage(L10n.text("git.detached")); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(branch, forType: .string)
            case "terminal":
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    showGitMessage(L10n.text("git.reason.commandFailed")); return
                }
                do { _ = try await NSWorkspace.shared.open([selection.root], withApplicationAt: terminal, configuration: .init()) }
                catch { showGitMessage(error.localizedDescription) }
            case "root": navigate(.visit(selection.root))
            default: break
            }
        }
    }

    private func showVolumeProperties(at url: URL, mount: VolumeMount?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = url.path == "/" ? L10n.text("command.properties") : url.lastPathComponent
        alert.informativeText = L10n.text("status.loading")
        alert.addButton(withTitle: L10n.text("dialog.confirm"))
        let query = Task {
            let result = await Task.detached(priority: .userInitiated) {
                let capacity = try (mount ?? VolumeMount.identify(at: url)).capacity()
                let name = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
                return (capacity, name)
            }.result
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let (capacity, name)):
                if let name { alert.messageText = name }
                alert.informativeText = [("volume.total", capacity.total), ("volume.used", capacity.used), ("volume.free", capacity.free)]
                    .map { L10n.text($0.0) + "   " + L10n.current.bytes($0.1) }
                    .joined(separator: "\n")
            case .failure: alert.informativeText = L10n.text("volume.unavailable")
            }
            alert.layout()
        }
        let escape = alert.closingOnEscape(over: window)
        alert.beginSheetModal(for: window) { _ in escape.stop(); query.cancel() }
    }

    func showGitMessage(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Git"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    /// File-list shortcuts must never act on its retained selection while the tree or
    /// another control is focused. An explicitly clicked table context menu is separate.
    var acceptsFileListCommands: Bool {
        guard let responder = window?.firstResponder, !(responder is NSTextView) else { return false }
        return responder === fileListView || (responder as? NSView)?.isDescendant(of: fileListView) == true
    }

    private func commandEntries(_ sender: Any?) -> [FileEntry] {
        if let item = sender as? NSMenuItem, item.menu === table.menu { return contextEntries }
        if fromToolbar(sender) { return selectedTableEntries() }
        guard acceptsFileListCommands else { return [] }
        return selectedTableEntries()
    }

    private func selectedTableEntries() -> [FileEntry] {
        table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil }
    }
    @objc func cutFiles(_ sender: Any?) {
        guard !session.blocksInteraction else { return }
        FileCommands.shared.copy(commandEntries(sender), cut: true)
    }
    @objc func copyFiles(_ sender: Any?) { FileCommands.shared.copy(commandEntries(sender), cut: false) }
    static func canExtractText(_ entries: [FileEntry]) -> Bool {
        entries.count == 1 && !entries[0].isDirectory && !entries[0].isPackage && !entries[0].isAlias
            && !entries[0].isSymbolicLink && OCRService.canRecognize(entries[0].url)
    }
    static func canBatchOCR(_ entries: [FileEntry]) -> Bool {
        (1...50).contains(entries.count) && entries.allSatisfy { canExtractText([$0]) }
    }
    @objc func batchOCR(_ sender: Any?) {
        let entries = commandEntries(sender)
        guard !session.blocksInteraction, Self.canBatchOCR(entries) else { return }
        onBatchOCR?(entries.map(\.url))
    }
    @objc private func downloadFromICloud(_ sender: Any?) {
        guard let entry = commandEntries(sender).first else { return }
        startICloudDownload(entry)
    }

    @objc private func removeLocalDownload(_ sender: Any?) {
        guard let entry = commandEntries(sender).first, entry.canRemoveICloudDownload, let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("icloud.remove")
        alert.informativeText = L10n.format("icloud.remove_help", entry.name)
        alert.addButton(withTitle: L10n.text("icloud.remove"))
        alert.addButton(withTitle: L10n.text("dialog.cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            FileCommands.shared.run("icloud.remove") {
                try await Task.detached { try ICloudAvailability.request(.removeDownload, at: entry.url) }.value
                return [entry.url]
            }
        }
    }

    @objc private func manageICloudInFinder(_ sender: Any?) {
        guard let entry = commandEntries(sender).first, entry.iCloudAvailability != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    @objc func extractText(_ sender: Any?) {
        let entries = commandEntries(sender)
        guard !session.blocksInteraction, Self.canExtractText(entries) else { return }
        onExtractText?(entries[0].url)
    }
    private(set) var sharingTask: Task<Void, Never>?
    @objc func shareFiles(_ sender: Any?) {
        let urls = commandEntries(sender).map(\.url)
        guard !session.blocksInteraction, FileSharingController.supports(urls) else { return }
        let row = clickedListRow >= 0 ? clickedListRow : table.selectedRow
        let view = fileListView
        let rowRect = viewMode == .details ? (row >= 0 ? table.rect(ofRow: row) : .zero) : (grid.frame(of: row) ?? .zero)
        let anchor = rowRect.intersection(view.visibleRect)
        sharingTask?.cancel()
        sharingTask = Task {
            do {
                try await fileSharing.share(urls, relativeTo: anchor.isEmpty ? view.visibleRect : anchor, of: view)
            } catch is CancellationError {
                return
            } catch {
                errorLabel.stringValue = L10n.text("share.unavailable")
                errorLabel.toolTip = errorLabel.stringValue
                errorLabel.isHidden = false
            }
        }
    }

    @objc func pasteFiles(_ sender: Any?) {
        let entries = commandEntries(sender)
        let insideFolder = (sender as? NSMenuItem)?.menu === table.menu && entries.count == 1 && entries[0].canNavigate
        FileCommands.shared.paste(into: insideFolder ? entries[0].url : session.history.current.url)
    }
    @objc func moveFilesHere(_ sender: Any?) { FileCommands.shared.paste(into: session.history.current.url, move: true) }
    @objc func undoFileOperation(_ sender: Any?) { FileCommands.shared.undo() }
    @objc private func completedTableClick() { table.completedClick() }

    private func nameCell(at row: Int, make: Bool = true) -> FileNameCell? {
        guard viewMode == .details else { return visibleEntries.indices.contains(row) ? grid.nameCell(at: row) : nil }
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0, row >= 0, row < table.numberOfRows else { return nil }
        return table.view(atColumn: column, row: row, makeIfNecessary: make) as? FileNameCell
    }

    /// A slow second click on the name of the only selected item renames it where it is. The
    /// point is in the coordinates of the list that was clicked: the table or the grid.
    private func renameCandidate(at point: NSPoint, row clicked: Int? = nil) -> (() -> Void)? {
        let row = clicked ?? table.row(at: point)
        guard row >= 0, table.selectedRowIndexes == IndexSet(integer: row),
              visibleEntries.indices.contains(row), let cell = nameCell(at: row),
              visibleEntries[row].url.isFileURL else { return nil }
        let label = cell.label
        var textRect = label.bounds
        textRect.size.width = min(textRect.width, label.intrinsicContentSize.width)
        if label.alignment == .center { textRect.origin.x = (label.bounds.width - textRect.width) / 2 }
        guard textRect.contains(label.convert(point, from: fileListView)) else { return nil }
        let entry = visibleEntries[row]
        let tabID = workspace.activeID
        return { [weak self] in
            guard let self, self.workspace.activeID == tabID, self.window?.isKeyWindow == true,
                  self.acceptsFileListCommands, self.window?.attachedSheet == nil,
                  !self.session.blocksInteraction, !FileCommands.shared.isBusy,
                  self.selectedPaths() == [entry.id] else { return }
            self.beginInlineRename(entry)
        }
    }

    /// F2: the name of the selected item becomes editable where it is, as in Windows. What cannot
    /// be edited in the list goes to the rename dialog.
    private func renameSelectionInPlace() {
        let row = table.selectedRow
        guard table.numberOfSelectedRows == 1, visibleEntries.indices.contains(row), visibleEntries[row].url.isFileURL,
              window?.attachedSheet == nil, !session.blocksInteraction, !FileCommands.shared.isBusy else { renameFile(nil); return }
        reveal(row)
        fileListView.layoutSubtreeIfNeeded()
        guard nameCell(at: row) != nil else { renameFile(nil); return }
        endInlineRename()
        beginInlineRename(visibleEntries[row])
    }

    private func beginInlineRename(_ entry: FileEntry) {
        let field = NSTextField(string: entry.name)
        field.font = ExplorerStyle.font(.files)
        field.usesSingleLineMode = true
        field.setAccessibilityLabel(L10n.text("dialog.name"))
        field.delegate = self
        inlineRename = (entry, field)
        activeScroll.contentView.addSubview(field)
        positionRenameField()
        guard inlineRename != nil, window?.makeFirstResponder(field) == true else { endInlineRename(); return }
        let stem = entry.isDirectory ? entry.name : (entry.name as NSString).deletingPathExtension
        (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
    }

    private func positionRenameField() {
        guard let edit = inlineRename else { return }
        let row = table.selectedRow
        guard table.numberOfSelectedRows == 1, visibleEntries.indices.contains(row),
              visibleEntries[row].id == edit.entry.id, let cell = nameCell(at: row) else { endInlineRename(); return }
        cell.label.isHidden = true
        edit.field.alignment = cell.label.alignment
        edit.field.frame = cell.label.convert(cell.label.bounds, to: activeScroll.contentView).insetBy(dx: -2, dy: -2)
    }

    private func endInlineRename() {
        table.cancelRenameClick()
        grid.cancelRenameClick()
        guard let edit = inlineRename else { return }
        inlineRename = nil
        edit.field.delegate = nil
        edit.field.abortEditing()
        edit.field.removeFromSuperview()
        if let row = visibleEntries.firstIndex(where: { $0.id == edit.entry.id }) { nameCell(at: row, make: false)?.label.isHidden = false }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if control === address {
            if command == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
                addressSuggestions.dismiss()
                let currentAddress = CloudAccounts.shared.address(for: session.history.current.url)
                address.stringValue = currentAddress
                textView.string = currentAddress
                textView.selectAll(nil)
                return true
            }
            return addressSuggestions.handle(command, editor: textView) { path in
                textView.insertText(path, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
            }
        }
        guard let edit = inlineRename, control === edit.field, !textView.hasMarkedText() else { return false }
        let confirm = command == #selector(NSResponder.insertNewline(_:))
        guard confirm || command == #selector(NSResponder.cancelOperation(_:)) else { return false }
        let name = textView.string
        endInlineRename()
        window?.makeFirstResponder(fileListView)
        if confirm, name != edit.entry.name { FileCommands.shared.rename(edit.entry, to: name) }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === address { addressSuggestions.dismiss(); showTrail(true) }
        if let field = inlineRename?.field, notification.object as? NSTextField === field { endInlineRename() }
    }

    @objc func renameFile(_ sender: Any?) { if let entry = commandEntries(sender).first { FileCommands.shared.rename(entry) } }
    @objc func newFolder(_ sender: Any?) { FileCommands.shared.newFolder(in: session.history.current.url) }
    @objc func trashFiles(_ sender: Any?) { FileCommands.shared.trash(commandEntries(sender)) }
    @objc func compressFiles(_ sender: Any?) { FileCommands.shared.compress(commandEntries(sender), in: session.history.current.url) }
    @objc func extractFile(_ sender: Any?) { if let entry = commandEntries(sender).first { FileCommands.shared.extract(entry, in: session.history.current.url) } }
    @objc func properties(_ sender: Any?) { if let entry = commandEntries(sender).first { FileCommands.shared.properties(entry) } }
    @objc private func openWith(_ sender: Any?) { FileCommands.shared.openWith(commandEntries(sender)) }
    /// Takes items that were just deleted out of the lists at once, where they stand; the reading
    /// of the folder that follows confirms it.
    func itemsRemoved(_ ids: Set<String>) {
        for tab in workspace.tabs where tab.id != workspace.activeID { tab.session.forget(ids) }
        guard session.forget(ids) else { return }
        let rows = IndexSet(visibleEntries.indices.filter { ids.contains(visibleEntries[$0].id) })
        guard !rows.isEmpty else { return }
        endInlineRename()
        rendering = true
        visibleEntries.removeAll { ids.contains($0.id) }
        table.removeRows(at: rows, withAnimation: [])
        if viewMode != .details { grid.reloadData(); syncGridSelection() }
        rendering = false
        if table.selectedRow < 0, let first = rows.first {
            deletionAnchor = (below: visibleEntries.indices.contains(first) ? visibleEntries[first].id : nil,
                              above: first > 0 && visibleEntries.indices.contains(first - 1) ? visibleEntries[first - 1].id : nil,
                              folder: session.history.current.url.explorerIdentity)
        }
        message.isHidden = !visibleEntries.isEmpty || session.errorMessage != nil
        updateStatus()
        updatePreviewSelection()
    }

    /// Shows an item's new name at once, in its new place in the order, keeping the scroll; the
    /// reading of the folder that follows confirms it.
    /// Shows a rename before it is carried out, when nothing in the list says it will fail.
    /// False leaves the list as it is, for the outcome to be shown when it comes.
    func showRename(of entry: FileEntry, as name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), name != entry.name,
              !session.blocksInteraction, session.entries.contains(where: { $0.id == entry.id }),
              !session.entries.contains(where: { $0.id != entry.id && $0.name.compare(name, options: .caseInsensitive) == .orderedSame })
        else { return false }
        itemRenamed(entry, to: name)
        return true
    }

    func itemRenamed(_ entry: FileEntry, to name: String) {
        let renamed = entry.renamed(to: name)
        for tab in workspace.tabs where tab.id != workspace.activeID { tab.session.replace(entry.id, with: renamed) }
        guard !session.blocksInteraction, session.replace(entry.id, with: renamed) else { return }
        endInlineRename()
        var selection = selectedPaths()
        if selection.remove(entry.id) != nil { selection.insert(renamed.id) }
        let scroll = listOffset
        rebuildRows(selection: selection, scroll: scroll == 0 ? nil : scroll)
        if let row = visibleEntries.firstIndex(where: { $0.id == renamed.id }) { reveal(row) }
        updatePreviewSelection()
    }

    func operationFinished(urls: [URL], tabID: UUID?, refreshing directories: Set<String> = []) {
        if trashBrowser?.window?.isVisible == true { trashBrowser?.refresh() }
        tree.refresh()
        for tab in workspace.tabs where tab.id != workspace.activeID && !tab.pendingInitialLoad &&
            directories.contains(tab.session.history.current.url.explorerIdentity) && !tab.session.isLoading {
            tab.session.navigate(.reload)
        }
        if !directories.isEmpty {
            guard directories.contains(session.history.current.url.explorerIdentity), !session.blocksInteraction else { return }
        } else if workspace.activeID != tabID { return }
        if !session.blocksInteraction { rememberView() }
        let location = session.history.current.url
        let selected = urls.compactMap { url -> URL? in
            if url.isFileURL, location.isFileURL {
                guard url.explorerParent.resolvingSymlinksInPath().standardizedFileURL == location.resolvingSymlinksInPath().standardizedFileURL else { return nil }
                return location.appendingPathComponent(url.lastPathComponent)
            }
            return url.explorerParent.explorerIdentity == location.explorerIdentity ? url : nil
        }
        // With nothing new to select and show (an item sent to the Trash, say), the folder is
        // read again without blocking the list or moving it; in a large folder a blocking reload
        // greys the whole list out for seconds.
        guard !selected.isEmpty else { session.refreshKeepingView(); return }
        // Already in the list (a rename shown at once): select it where it is, no blocking reload.
        let listed = Set(session.entries.map(\.id)), wanted = Set(selected.map(\.explorerIdentity))
        if wanted.isSubset(of: listed), !session.blocksInteraction {
            let rows = IndexSet(visibleEntries.indices.filter { wanted.contains(visibleEntries[$0].id) })
            if let first = rows.first { table.selectRowIndexes(rows, byExtendingSelection: false); reveal(first) }
            session.refreshKeepingView()
            return
        }
        session.remember(selection: Set(selected.map(\.explorerIdentity)), scrollOffset: 0)
        session.navigate(.reload)
    }
    func copyAddressText(_ editor: NSTextView) {
        if editor.selectedRange().length > 0 {
            editor.copy(nil)
        } else if !editor.string.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(editor.string, forType: .string)
        }
    }

    @objc func focusAddress(_ sender: Any?) { window?.makeFirstResponder(address); address.selectText(nil) }

    /// Clicking a folder of the trail while the path is being edited is not possible (the trail
    /// is hidden then), so this only ever puts the trail back.

    @objc private func breadcrumbClicked(_ sender: BreadcrumbButton) {
        if let url = sender.destination { navigate(.visit(url)) }
    }

    @objc private func addressSubmitted(_ sender: Any?) {
        addressSuggestions.dismiss()
        if address.stringValue.lowercased().hasPrefix("smb:") {
            systemVolumes.connect(address.stringValue)
            return
        }
        guard let url = CloudAccounts.shared.resolve(address.stringValue) ?? AddressParser.resolve(address.stringValue, relativeTo: session.history.current.url) else {
            errorLabel.stringValue = L10n.text("error.address")
            errorLabel.isHidden = false
            return
        }
        navigate(.visit(url))
        window?.makeFirstResponder(fileListView)
    }

    @objc func toggleHidden(_ sender: Any?) {
        if !session.blocksInteraction { rememberView() }
        workspace.activeTab?.prepareForUserNavigation()
        session.toggleHidden()
        onSessionChange?()
        ExplorerStyle.browserPreferences.showHidden = session.showHidden
    }

    /// The installed My Suite editor that takes a double click on this file: My Notepad for plain
    /// text. Nil keeps the usual way of opening the file, which for images is the built-in viewer.
    private func suiteEditorApplication(opening entry: FileEntry) -> URL? {
        guard entry.url.isFileURL, !entry.isDirectory, !ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return nil }
        for editor in SuiteEditor.allCases {
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier) else { continue }
            if editor.opensByDefault(entry.url, documentTypes: SuiteEditor.documentTypes(ofApplicationAt: application)) { return application }
        }
        return nil
    }

    @objc func openSelected(_ sender: Any?) {
        guard !session.blocksInteraction else { return }
        let row = sender is NSMenuItem && clickedListRow >= 0 ? clickedListRow : table.selectedRow
        guard visibleEntries.indices.contains(row) else { return }
        let entry = visibleEntries[row]
        if let vault = entry.secureFolderURL { secureFolders?.unlock(vault) }
        else if entry.canNavigate { navigate(.visit(entry.url)) }
        else if !entry.url.isFileURL { FileCommands.shared.openRemote(entry) }
        else if let application = suiteEditorApplication(opening: entry) {
            FileCommands.shared.open([entry.url], withApplicationAt: application)
        }
        else if MediaKind.detect(entry) != nil, let onOpenMedia {
            onOpenMedia(visibleEntries, entry.url)
        }
        else if !NSWorkspace.shared.open(entry.url) {
            errorLabel.stringValue = L10n.format("error.open_file", entry.name)
            errorLabel.isHidden = false
        }
    }

    @objc func openSelectedInNewTab(_ sender: Any?) {
        guard !session.blocksInteraction else { return }
        let row = sender is NSMenuItem && clickedListRow >= 0 ? clickedListRow : table.selectedRow
        guard visibleEntries.indices.contains(row), visibleEntries[row].canNavigate else { return }
        addTab(at: visibleEntries[row].url)
    }

    @discardableResult
    func addTab(at url: URL) -> ExplorerTab {
        if !session.blocksInteraction { rememberView() }
        let preferences = ExplorerStyle.browserPreferences
        return workspace.addTab(at: url, sortKey: preferences.sortKey, sortAscending: preferences.sortAscending, showHidden: preferences.showHidden)
    }

    func openConnectedBucket(_ url: URL) {
        guard let id = RemoteLocation.parse(url)?.connectionID else { addTab(at: url); return }
        func belongs(_ tab: ExplorerTab) -> Bool {
            RemoteLocation.parse(tab.session.history.current.url)?.connectionID == id
        }
        if let current = workspace.activeTab, belongs(current) { window?.makeKeyAndOrderFront(nil); return }
        if let existing = workspace.tabs.first(where: belongs) { selectTab(id: existing.id) }
        else { addTab(at: url) }
        window?.makeKeyAndOrderFront(nil)
    }

    private func promptToDisconnect(_ id: UUID) {
        guard let window, let connection = CloudAccounts.shared.connections.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.format("cloud.disconnect_prompt", connection.name)
        alert.informativeText = L10n.text("cloud.disconnect_help")
        alert.addButton(withTitle: L10n.text("dialog.cancel"))
        alert.addButton(withTitle: L10n.text("volume.disconnect"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            guard !FileCommands.shared.isBusy else {
                SearchTagEditor.showError(L10n.text("trash.busy"), owner: window)
                return
            }
            do {
                try CloudAccounts.shared.remove(id)
                let affected = self.workspace.tabs.filter { RemoteLocation.parse($0.session.history.current.url)?.connectionID == id }
                if !affected.isEmpty && affected.count == self.workspace.tabs.count {
                    self.addTab(at: self.sidebarHome ?? FileManager.default.homeDirectoryForCurrentUser)
                }
                for tab in affected { self.closeTab(id: tab.id) }
                for tab in self.workspace.tabs { tab.session.forgetCloudHistory(id) }
                self.refresh(nil)
            } catch {
                SearchTagEditor.showError(L10n.text("cloud.error.io"), owner: window)
            }
        }
    }

    func selectTab(id: UUID) {
        if !session.blocksInteraction { rememberView() }
        workspace.select(id)
        window?.makeFirstResponder(fileListView)
    }

    func closeTab(id: UUID) {
        if !session.blocksInteraction { rememberView() }
        workspace.close(id)
    }

    @objc func newTab(_ sender: Any?) { addTab(at: session.history.current.url) }
    @objc func closeCurrentTab(_ sender: Any?) {
        if let id = workspace.activeID { closeTab(id: id) }
    }

    func cycleTab(backwards: Bool = false) {
        if !session.blocksInteraction { rememberView() }
        workspace.selectNext(backwards: backwards)
        window?.makeFirstResponder(fileListView)
    }

    var activeTabIsVisible: Bool {
        guard let index = workspace.tabs.firstIndex(where: { $0.id == workspace.activeID }),
              tabStrip.arrangedSubviews.indices.contains(index) else { return false }
        let view = tabStrip.arrangedSubviews[index]
        return view.visibleRect.width >= view.bounds.width - 1
    }

    var sidebarWidth: CGFloat {
        get { split.subviews.first?.frame.width ?? 230 }
        set { split.setPosition(newValue, ofDividerAt: 0) }
    }

    @objc private func tabSelected(_ sender: TabActionButton) {
        if let id = sender.tabID { selectTab(id: id) }
    }

    @objc private func tabClosed(_ sender: TabActionButton) {
        if let id = sender.tabID { closeTab(id: id) }
    }

    private func renderTabs() {
        for view in tabStrip.arrangedSubviews { tabStrip.removeArrangedSubview(view); view.removeFromSuperview() }
        var selectedSurface: NSView?
        for tab in workspace.tabs {
            let url = tab.session.history.current.url
            let title = url.isFileURL ? (url.path == "/" ? L10n.text("tree.computer") : url.lastPathComponent) : CloudAccounts.shared.title(for: url)
            let select = TabActionButton(title: title, target: self, action: #selector(tabSelected))
            select.tabID = tab.id; select.isBordered = false
            select.lineBreakMode = .byTruncatingMiddle
            select.alignment = .left
            select.font = ExplorerStyle.font(.bars)
            select.image = ExplorerStyle.symbol(tab.session.isLoading ? "clock" : url.isFileURL ? "folder" : "cloud", description: L10n.text("kind.folder"))
            select.imagePosition = .imageLeading
            select.toolTip = CloudAccounts.shared.address(for: url)
            select.setAccessibilityLabel(L10n.format(tab.id == workspace.activeID ? "tab.selected_accessibility" : "tab.accessibility", title))
            let close = TabActionButton(image: ExplorerStyle.symbol("xmark", description: L10n.text("command.close_tab"))!, target: self, action: #selector(tabClosed))
            close.tabID = tab.id; close.isBordered = false
            close.setAccessibilityLabel(L10n.format("tab.close_accessibility", title))
            close.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let row = ExplorerStyle.stack([select, close], spacing: 6)
            let surface = TabSurface()
            surface.selected = tab.id == workspace.activeID
            if surface.selected { selectedSurface = surface }
            row.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(row)
            NSLayoutConstraint.activate([
                surface.widthAnchor.constraint(equalToConstant: 210),
                surface.heightAnchor.constraint(equalToConstant: 32 + max(0, ExplorerStyle.preferences.fontSize(for: .bars) - 12)),
                row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
                row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6),
                row.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
            ])
            tabStrip.addArrangedSubview(surface)
        }
        tabStrip.addArrangedSubview(newTabButton)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStrip.addArrangedSubview(spacer)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let selectedSurface { selectedSurface.scrollToVisible(selectedSurface.bounds) }
    }

    @objc func copyPath(_ sender: Any?) {
        guard !session.blocksInteraction else { return }
        var indexes = table.selectedRowIndexes
        if sender is NSMenuItem, clickedListRow >= 0, !indexes.contains(clickedListRow) {
            indexes = IndexSet(integer: clickedListRow)
        }
        let paths = indexes.compactMap { visibleEntries.indices.contains($0) ? CloudAccounts.shared.address(for: visibleEntries[$0].url) : nil }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func focusFilter(_ sender: Any?) {
        guard filter.isEnabled, window?.attachedSheet == nil, NSApp.modalWindow == nil,
              (window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        window?.makeFirstResponder(filter)
        filter.selectText(nil)
    }

    private func installKeyboardNavigation() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard self.workspace.activeTab != nil else { return event }
            self.table.cancelRenameClick()
            self.grid.cancelRenameClick()
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if (flags == .control || flags == [.control, .shift]),
               self.window?.attachedSheet == nil, NSApp.modalWindow == nil,
               (self.window?.firstResponder as? NSTextView)?.hasMarkedText() != true {
                if key == "+" || key == "=" {
                    ExplorerStyle.preferences.adjustAllFontSizes(by: 1); return nil
                }
                if key == "-" {
                    ExplorerStyle.preferences.adjustAllFontSizes(by: -1); return nil
                }
            }
            if flags == .command || flags == .control {
                if key == "t" { self.newTab(nil); return nil }
                if key == "w" { self.closeCurrentTab(nil); return nil }
            }
            if event.keyCode == 48 && (flags == .control || flags == [.control, .shift]) {
                self.cycleTab(backwards: flags.contains(.shift)); return nil
            }
            if (flags == .command || flags == .control) && key == "l" { self.focusAddress(nil); return nil }
            let editor = self.window?.firstResponder as? NSTextView
            let searchShortcut = ((flags == .command || flags == .control) && key == "f")
                || (event.keyCode == 99 && flags.isEmpty) // F3
            let browserFieldEditor = editor?.delegate as? NSTextField === self.address
                || editor?.delegate as? NSTextField === self.filter
            if searchShortcut, self.filter.isEnabled, self.window?.attachedSheet == nil, NSApp.modalWindow == nil,
               editor?.hasMarkedText() != true,
               editor == nil || (browserFieldEditor && flags != .control) {
                self.focusFilter(nil)
                return nil
            }
            // The Windows editing keys with Control are the same in every text field of the
            // application (ControlEditingKeys). Here only what is particular to the address bar:
            // copying with nothing selected copies the whole path.
            if let editor, !editor.hasMarkedText(), self.window?.attachedSheet == nil, NSApp.modalWindow == nil {
                if editor === self.address.currentEditor(), flags == .control || flags == .command, key == "c",
                   editor.selectedRange().length == 0 {
                    self.copyAddressText(editor); return nil
                }
                if ControlEditingKeys.handle(event) { return nil }
            }
            // Leave other editing commands, including input-method composition, to AppKit.
            if editor != nil { return event }
            if flags == [.command, .option] && key == "v" {
                if self.acceptsFileListCommands { self.moveFilesHere(nil) }
                return nil
            }
            if flags == .command || flags == .control {
                if key == "z" { FileCommands.shared.undo(); return nil }
                if key == "c" { if self.acceptsFileListCommands { self.copyFiles(nil) }; return nil }
                if key == "x" { if self.acceptsFileListCommands { self.cutFiles(nil) }; return nil }
                if key == "v" { if self.acceptsFileListCommands { self.pasteFiles(nil) }; return nil }
            }
            // After a deletion nothing is selected; the arrows go on from where the item was,
            // not from the top of the list: down takes what stood below it, up what stood above.
            // In the grids the items also follow one another sideways: right goes on like down.
            let onward = event.keyCode == 125 || (self.viewMode != .details && event.keyCode == 124)
            let backward = event.keyCode == 126 || (self.viewMode != .details && event.keyCode == 123)
            if flags.isEmpty, onward || backward, self.acceptsFileListCommands,
               self.table.selectedRow < 0, let anchor = self.deletionAnchor {
                self.deletionAnchor = nil
                let wanted = onward ? (anchor.below ?? anchor.above) : (anchor.above ?? anchor.below)
                if anchor.folder == self.session.history.current.url.explorerIdentity, let wanted,
                   let row = self.visibleEntries.firstIndex(where: { $0.id == wanted }) {
                    self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.reveal(row)
                    return nil
                }
            }
            if event.keyCode == 120 && flags.isEmpty {
                if self.acceptsFileListCommands { self.renameSelectionInPlace() }
                return nil
            }
            if event.keyCode == 117 && flags.isEmpty {
                if self.acceptsFileListCommands { self.trashFiles(nil) }
                return nil
            }
            if flags == .option {
                switch event.keyCode {
                case 123: self.goBack(nil); return nil
                case 124: self.goForward(nil); return nil
                case 126: self.goUp(nil); return nil
                default: break
                }
            }
            if event.keyCode == 96 && flags.isEmpty { self.refresh(nil); return nil }
            // The Control shortcuts for what the menus offer with Command: new folder, refresh
            // and, with Option+Return, the properties of the selection.
            if flags == [.control, .shift], key == "n" {
                if !self.session.blocksInteraction { self.newFolder(nil) }
                return nil
            }
            if flags == .control, key == "r" { self.refresh(nil); return nil }
            if flags == .option, event.keyCode == 36 || event.keyCode == 76 {
                if self.acceptsFileListCommands { self.properties(nil) }
                return nil
            }
            // Command+A too: the App Shortcuts of the system can take it away from the menu.
            if (flags == .control || flags == .command) && key == "a" {
                if self.acceptsFileListCommands { self.table.selectAll(nil) }
                return nil
            }
            return event
        }
    }

    @objc private func protectFolder(_ sender: NSMenuItem) {
        if let url = commandEntries(sender).first?.url { secureFolders?.protect(url) }
    }

    @objc private func unlockVault(_ sender: NSMenuItem) {
        if let url = commandEntries(sender).first?.secureFolderURL { secureFolders?.unlock(url) }
    }

    @objc private func lockVault(_ sender: NSMenuItem) {
        if let url = commandEntries(sender).first?.secureFolderURL { secureFolders?.lock(url) }
    }

    @objc private func resetVault(_ sender: NSMenuItem) {
        if let url = commandEntries(sender).first?.secureFolderURL { secureFolders?.reset(url) }
    }

    func concealSecureFolders(_ roots: [URL]) {
        searchWindow?.close(); searchWindow = nil
        vaultPresentationGeneration += 1
        for sheet in window?.sheets ?? [] {
            if let url = sheet.representedURL, roots.contains(where: { SecureFolderCommands.contains(url, in: $0) }) {
                window?.endSheet(sheet, returnCode: .cancel)
            }
        }
        if let review = gitReview, roots.contains(where: { SecureFolderCommands.contains(review.repositoryRoot, in: $0) }) {
            review.close()
            gitReview = nil
        }
        let affected = workspace.tabs.filter { tab in
            if tab.session.isLoading { return true }
            let history = tab.session.history
            return ([history.current] + history.back + history.forward).contains { snapshot in
                roots.contains { SecureFolderCommands.contains(snapshot.url, in: $0) }
            }
        }
        if !affected.isEmpty {
            window?.makeFirstResponder(fileListView)
            if affected.count == workspace.tabs.count {
                workspace.addTab(at: sidebarHome ?? FileManager.default.homeDirectoryForCurrentUser)
            }
            for tab in affected { workspace.close(tab.id) }
        }
        contextEntries.removeAll()
        previewPane.closePreview()
        galleryStage.show(nil, name: "", local: false)
        updateGalleryStage()
        tree.resetListing()
    }

    func prepareForLanguageChange() {
        searchWindow?.close(); searchWindow = nil
        trashBrowser?.close(); trashBrowser = nil
        systemVolumes.stop()
        addressSuggestions.dismiss()
        gitReview?.close()
        gitState.stop()
        savePresentation()
        restoringLayout = true // The retired window must not overwrite its replacement.
        previewPane.closePreview()
        sharingTask?.cancel(); sharingTask = nil
        fileSharing.closePicker()
        onClose = nil // Closing a replaced window must not quit the application.
        if !session.blocksInteraction { rememberView() }
        onSessionChange = nil
        workspace.onChange = nil
        workspace.onWillAutoRefresh = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    func windowDidResignKey(_ notification: Notification) { addressSuggestions.dismiss(); endInlineRename(); grid.redrawSelection() }
    func windowDidBecomeKey(_ notification: Notification) { grid.redrawSelection() }

    /// The first time the window shows, AppKit hands the keyboard to the first control of its
    /// key loop, the address field. Nobody asked for that: the list takes it back, so the
    /// address shows the trail. The key loop itself stays AppKit's, for Tab to walk the controls.
    private var gaveListTheKeyboard = false
    private func addressTookKeyboard() {
        showTrail(false)
        guard !gaveListTheKeyboard else { return }
        gaveListTheKeyboard = true
        let cause = NSApp.currentEvent?.type
        guard cause != .leftMouseDown, cause != .keyDown else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.address.currentEditor() != nil, self.window?.attachedSheet == nil else { return }
            self.window?.makeFirstResponder(self.fileListView)
        }
    }

    func windowWillClose(_ notification: Notification) {
        searchWindow?.close(); searchWindow = nil
        trashBrowser?.close(); trashBrowser = nil
        systemVolumes.stop()
        addressSuggestions.dismiss()
        endInlineRename()
        gitState.stop()
        savePresentation()
        previewPane.closePreview()
        sharingTask?.cancel(); sharingTask = nil
        fileSharing.closePicker()
        onClose?(workspace.activeTab?.session.history.current.url ?? lastLocation)
    }

    @objc private func showOptions(_ sender: Any?) { onShowOptions?() }

    func restorePresentation(from previous: ExplorerWindowController) {
        restoringLayout = true
        defer { restoringLayout = false; schedulePresentationSave() }
        let editor = previous.window?.firstResponder as? NSTextView
        let textSelection = editor?.selectedRange()
        window?.contentView?.layoutSubtreeIfNeeded()
        split.setPosition(previous.split.subviews.first?.frame.width ?? 230, ofDividerAt: 0)
        previewPaneWidth = previous.previewPaneWidth
        for (index, column) in previous.table.tableColumns.enumerated() {
            let current = table.column(withIdentifier: column.identifier)
            if current >= 0 {
                table.moveColumn(current, toColumn: index)
                table.tableColumns[index].width = column.width
            }
        }
        renderSession()
        if viewMode != .details {
            if previous.viewMode == viewMode { restoreGridOffset(previous.listOffset, selection: nil) }
        } else if previous.viewMode == .details, table.rowHeight != previous.table.rowHeight {
            let offset = previous.fileScroll.contentView.bounds.minY / previous.table.rowHeight * table.rowHeight
            fileScroll.contentView.scroll(to: NSPoint(x: 0, y: max(-fileScroll.contentView.contentInsets.top, offset)))
            fileScroll.reflectScrolledClipView(fileScroll.contentView)
        }
        if editor?.delegate as? NSTextField === previous.address {
            address.stringValue = previous.address.stringValue
            window?.makeFirstResponder(address)
        } else if editor?.delegate as? NSTextField === previous.filter {
            window?.makeFirstResponder(filter)
        } else { window?.makeFirstResponder(fileListView) }
        if let textSelection, let restoredEditor = window?.firstResponder as? NSTextView {
            restoredEditor.setSelectedRange(textSelection)
        }
    }

    /// Renders the application's own content view, without accessing other windows or the desktop.
    func savePreview(to url: URL) throws {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}
