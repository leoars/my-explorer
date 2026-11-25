// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import ExplorerClipboard

@MainActor
final class FolderOutlineView: NSOutlineView {
    var contextMenuForRow: ((Int) -> NSMenu?)?
    var onDragEnded: (() -> Void)?
    private var dragInside = false { didSet { if oldValue && !dragInside { onDragEnded?() } } }
    /// True only while a drag hovers the tree with the button still held, so a missed
    /// end-of-drag event can never leave manual expansion blocked.
    var dragActive: Bool { dragInside && NSEvent.pressedMouseButtons != 0 }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragInside = true
        return super.draggingEntered(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragInside = false
        super.draggingExited(sender)
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dragInside = false
        // The method is optional and NSOutlineView does not implement it on every macOS: calling
        // it unchecked ended every drag released over the tree with a crash.
        if NSOutlineView.instancesRespond(to: #selector(NSDraggingDestination.draggingEnded(_:))) {
            super.draggingEnded(sender)
        }
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragInside = false
        return super.performDragOperation(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuForRow?(row(at: point))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.contains(.shift),
           selectedRow >= 0, let menu = contextMenuForRow?(selectedRow) {
            let rect = rect(ofRow: selectedRow)
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 20, y: rect.maxY), in: self)
        } else { super.keyDown(with: event) }
    }
}

@MainActor
final class FolderNode: NSObject {
    let url: URL
    var title: String
    let symbol: String
    var volume: VolumeMount?
    var savedSearch: ExplorerSavedSearch?
    var volumeLink = false
    let isGroup: Bool
    var children: [FolderNode]?
    var loading = false
    var needsRefresh = false
    var failure: DirectoryFailure?
    var request = 0
    var task: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var watcher: DirectoryWatcher?

    init(url: URL, title: String? = nil, symbol: String = "folder", isGroup: Bool = false) {
        self.url = url
        self.title = title ?? url.lastPathComponent
        self.symbol = symbol
        self.isGroup = isGroup
    }

    func stopObserving() {
        request += 1
        task?.cancel(); task = nil
        refreshTask?.cancel(); refreshTask = nil
        watcher?.stop(); watcher = nil
        loading = false
        needsRefresh = false
        children?.forEach { $0.stopObserving() }
    }
}

@MainActor
final class FolderTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = FolderOutlineView()
    let scrollView = NSScrollView()
    var onNavigate: ((URL) -> Void)?
    var onDisconnectCloud: ((UUID) -> Void)?
    var onRemoveMount: ((VolumeMount) -> Void)?
    var onVolumeProperties: ((URL, VolumeMount?) -> Void)?
    var onShowTrash: (() -> Void)?
    private let trashRoot = FolderNode(url: URL(string: "myexplorer-trash:///")!, title: L10n.text("trash.title"), symbol: "trash", isGroup: true)
    var onManageCloud: (() -> Void)?
    /// Called whenever the selection of the tree changes, for the commands that act on it; true
    /// when the tree itself moved it (following the list), false when the person did.
    var onSelectionChange: ((Bool) -> Void)?
    /// The menu of file commands for a folder of the tree, built by the window as for the list.
    var fileMenuForFolder: ((FileEntry, Bool) -> NSMenu?)?
    /// Whether a folder may be a favorite: a real folder of this Mac, outside protected folders.
    var canBeFavorite: ((URL) -> Bool)?
    /// The places that are always there, from the home folder to the Trash.
    private var fixedRoots: [FolderNode]
    /// The person's favorite folders and the folders opened most recently, above the places.
    let favoritesRoot = FolderNode(url: URL(string: "myexplorer-favorites:///")!, title: L10n.text("tree.favorites"), symbol: "favorite", isGroup: true)
    let recentsRoot = FolderNode(url: URL(string: "myexplorer-recents:///")!, title: L10n.text("tree.recents"), symbol: "recent", isGroup: true)
    private var shortcutsShown: [FolderNode] = []
    private var shortcutsExpandedOnce = Set<ObjectIdentifier>()
    private var roots: [FolderNode] { shortcutsShown + fixedRoots }
    private let mobileRoot = FolderNode(url: URL(string: "myexplorer-devices:///")!, title: L10n.text("devices.title"), symbol: "iphone", isGroup: true)
    private var mobileDevices: AppleMobileDevices?
    var onSavedSearch: ((ExplorerSavedSearch) -> Void)?
    private let searchLibrary = ExplorerSearchLibrary()
    private let searchRoot = FolderNode(url: URL(string: "myexplorer-search:///")!,
                                        title: L10n.text("search.saved"), symbol: "folder.badge.gearshape", isGroup: true)
    private let cloudRoot: FolderNode
    private var hidden = false
    private var generation = 0
    private var selecting = false
    /// Hover time over one folder before a drag expands it; AppKit's own spring-loading is far too eager.
    static let dragExpandDelay: TimeInterval = 1.0
    /// Tall enough for the tree's font and for icons the same size as the file list's.
    private static var rowHeight: CGFloat {
        max(30, ExplorerStyle.preferences.fontSize(for: .tree) + 12, FileTypeIcon.listIconSide + 7)
    }
    /// The folder the tree is opening its way to, while branches are still being read.
    private var revealTarget: URL?
    /// Where the way to `revealTarget` starts when it runs inside a favorite or recent folder.
    private var revealStart: FolderNode?
    private var dragHoverNode: FolderNode?
    private var dragHoverTimer: Timer?
    private var dragExpansionAllowed = false
    private var gitSnapshot: GitStatusSnapshot?
    private var gitRoots: Set<String> = []
    func updateGit(snapshot: GitStatusSnapshot?, roots: Set<String>) {
        gitSnapshot = snapshot; gitRoots = roots
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    init(home: URL) {
        cloudRoot = FolderNode(url: URL(string: "myexplorer-cloud:///")!, title: L10n.text("cloud.title"), symbol: "cloud.fill", isGroup: true)
        fixedRoots = [
            FolderNode(url: home, title: L10n.text("tree.home"), symbol: "house"),
            FolderNode(url: home.appendingPathComponent("Desktop"), title: L10n.text("tree.desktop"), symbol: "desktopcomputer"),
            FolderNode(url: home.appendingPathComponent("Downloads"), title: L10n.text("tree.downloads"), symbol: "arrow.down.circle"),
            FolderNode(url: home.appendingPathComponent("Documents"), title: L10n.text("tree.documents"), symbol: "doc"),
            FolderNode(url: home.appendingPathComponent("Pictures"), title: L10n.text("tree.pictures"), symbol: "photo.fill"),
            FolderNode(url: home.appendingPathComponent("Music"), title: L10n.text("tree.music"), symbol: "music.note"),
            FolderNode(url: home.appendingPathComponent("Movies"), title: L10n.text("tree.videos"), symbol: "film.fill"),
            FolderNode(url: URL(fileURLWithPath: "/"), title: L10n.text("tree.computer"), symbol: "internaldrive"),
            FolderNode(url: URL(fileURLWithPath: "/Volumes"), title: L10n.text("tree.volumes"), symbol: "externaldrive")
        ]
        fixedRoots.append(cloudRoot)
        fixedRoots.append(searchRoot)
        fixedRoots.append(mobileRoot)
        fixedRoots.append(trashRoot)
        super.init()
        outline.contextMenuForRow = { [weak self] row in self?.contextMenu(for: row) }
        outline.onDragEnded = { [weak self] in self?.cancelDragHover() }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folders"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = Self.rowHeight
        outline.indentationPerLevel = 16
        outline.style = .plain
        outline.backgroundColor = .windowBackgroundColor
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes(FileClipboard.dragTypes)
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setAccessibilityLabel(L10n.text("tree.accessibility"))
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        outline.setAccessibilityIdentifier("explorer.tree")
        reloadCloudConnections()
        reloadSavedSearches()
        reloadShortcuts()
        CloudAccounts.shared.onChange = { [weak self] in self?.reloadCloudConnections() }
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: FolderShortcuts.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(presenceChanged), name: FolderPresence.didChange, object: nil)
    }

    @objc private func shortcutsChanged(_ notification: Notification) {
        guard notification.object as AnyObject? === ExplorerStyle.folderShortcuts else { return }
        reloadShortcuts()
    }

    @objc private func presenceChanged(_ notification: Notification) { reloadShortcuts() }

    /// Rebuilds the two groups from the preferences, keeping the nodes (and so their open
    /// branches) of the folders that are still there. Each group opens by itself the first time
    /// it appears; after that it stays as the person left it.
    ///
    /// The recent folders do not change places while they are in use: a folder opened again stays
    /// where it is (walking down the group with the keyboard, or clicking one row after another,
    /// would otherwise make the rows jump), and only folders new to the group go on top. The full
    /// order comes back when the tree is built again.
    func reloadShortcuts() {
        let shortcuts = ExplorerStyle.folderShortcuts
        var recents = shortcuts.visibleRecents(exists: FolderPresence.shared.exists)
        if let shown = recentsRoot.children?.map(\.url.explorerIdentity), !shown.isEmpty {
            let current = Set(recents.map(\.explorerIdentity))
            let staying = shown.filter(current.contains)
            let fresh = recents.filter { !shown.contains($0.explorerIdentity) }
            let byIdentity = Dictionary(recents.map { ($0.explorerIdentity, $0) }, uniquingKeysWith: { first, _ in first })
            recents = fresh + staying.compactMap { byIdentity[$0] }
        }
        func fill(_ group: FolderNode, with urls: [URL]) {
            let previous = Dictionary((group.children ?? []).map { ($0.url.explorerIdentity, $0) }, uniquingKeysWith: { first, _ in first })
            let nodes = urls.map { url in
                previous[url.explorerIdentity] ?? FolderNode(url: url, title: Self.displayName(url))
            }
            let kept = Set(nodes.map(ObjectIdentifier.init))
            for node in previous.values where !kept.contains(ObjectIdentifier(node)) { node.stopObserving() }
            group.children = nodes
        }
        fill(favoritesRoot, with: shortcuts.favorites)
        fill(recentsRoot, with: recents)
        // An empty favorites group stays, as the place to drop folders on; an empty recents one goes.
        let shown = (shortcuts.showFavorites ? [favoritesRoot] : []) + (shortcuts.showRecents && !recents.isEmpty ? [recentsRoot] : [])
        let selectedNode = outline.item(atRow: outline.selectedRow) as? FolderNode
        let selectedURL = selectedNode?.url
        selecting = true
        if shown.map(ObjectIdentifier.init) != shortcutsShown.map(ObjectIdentifier.init) {
            for group in shortcutsShown where !shown.contains(where: { $0 === group }) { group.children?.forEach { $0.stopObserving() } }
            shortcutsShown = shown
            // Before the tree is on screen it has no rows to redo; reloading the whole outline then
            // would also leave its one column at its first, narrow width.
            if outline.window != nil { outline.reloadData() } else { outline.reloadItem(nil, reloadChildren: true) }
        } else {
            for group in shown { outline.reloadItem(group, reloadChildren: true) }
        }
        for group in shown where shortcutsExpandedOnce.insert(ObjectIdentifier(group)).inserted {
            expandFromCode { outline.expandItem(group) }
        }
        selecting = false
        restoreSelection(selectedNode, url: selectedURL)
    }

    /// Selects again, after a branch was read again, the row that was selected: the same node
    /// while it is still in the tree, so that a folder browsed inside the favorites or the recent
    /// folders stays there, and otherwise the folder wherever it shows.
    private func restoreSelection(_ node: FolderNode?, url: URL?) {
        if let node, outline.row(forItem: node) >= 0 {
            selecting = true
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false)
            selecting = false
        } else if let url { selectIfVisible(url) }
    }

    /// The name the Finder shows for a folder (Documents in the person's language, say). Asked of
    /// the system only inside the home folder: elsewhere, a volume that stopped answering could hold
    /// the window back.
    static func displayName(_ url: URL) -> String {
        if url.path == "/" { return L10n.text("tree.computer") }
        let home = RealHome.url.standardizedFileURL.path
        guard url.path.hasPrefix(home + "/") || url.path == home else { return url.lastPathComponent }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? url.lastPathComponent : name
    }

    /// The folder selected in the tree, for the file commands; see `folder(for:)`.
    var selectedFolder: (entry: FileEntry, isPlace: Bool)? {
        (outline.item(atRow: outline.selectedRow) as? FolderNode).flatMap(folder(for:))
    }

    /// A folder of the tree as an item the file commands can act on, as they would in the list:
    /// a folder of this Mac or of a cloud connection, but not a group, a saved search, the Trash,
    /// a volume, the computer or a connection itself. `isPlace` marks the places at the top of
    /// the tree (the home folder, Documents, ...): they can be copied and looked at, but not moved,
    /// renamed or deleted from there.
    private func folder(for node: FolderNode) -> (entry: FileEntry, isPlace: Bool)? {
        guard !node.isGroup, node.savedSearch == nil, node.volume == nil, !node.volumeLink,
              node !== trashRoot, node !== mobileRoot else { return nil }
        if node.url.isFileURL {
            // The computer and the list of volumes keep their own menu; so does a favorite or recent
            // folder that is gone, which can only be taken out of its group.
            guard node.url.path != "/", node.url.standardizedFileURL.path != "/Volumes" else { return nil }
            if outline.parent(forItem: node) as AnyObject? === favoritesRoot || outline.parent(forItem: node) as AnyObject? === recentsRoot,
               !FolderPresence.shared.exists(node.url) { return nil }
        } else {
            guard let location = RemoteLocation.parse(node.url), !location.key.isEmpty else { return nil }
        }
        // A place is protected wherever it shows: at the top, as a favorite or inside the home folder.
        let isPlace = fixedRoots.contains { !$0.isGroup && $0.url.isFileURL && $0.url.explorerIdentity == node.url.explorerIdentity }
        return (FileEntry(url: node.url, name: node.url.lastPathComponent, isDirectory: true, kind: "Folder"), isPlace)
    }

    /// Whether the node is one of the favorites or recent folders, or a folder inside one of them.
    private func isInShortcutGroup(_ node: FolderNode) -> Bool {
        var parent = outline.parent(forItem: node) as? FolderNode
        while let current = parent {
            if current === favoritesRoot || current === recentsRoot { return true }
            parent = outline.parent(forItem: current) as? FolderNode
        }
        return false
    }

    func saveSearch(_ search: ExplorerSavedSearch) throws {
        try searchLibrary.add(search)
        reloadSavedSearches()
    }

    private func reloadSavedSearches() {
        searchRoot.children = searchLibrary.searches.map { search in
            let node = FolderNode(url: searchRoot.url.appendingPathComponent(search.id.uuidString), title: search.title, symbol: "magnifyingglass")
            node.savedSearch = search
            return node
        }
        selecting = true
        outline.reloadItem(searchRoot, reloadChildren: true)
        if searchRoot.children?.isEmpty == false { expandFromCode { outline.expandItem(searchRoot) } }
        selecting = false
    }

    @objc private func forgetSavedSearch(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        do { try searchLibrary.remove(id); reloadSavedSearches() }
        catch { if let window = outline.window { SearchTagEditor.showError(error.localizedDescription, owner: window) } }
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        if row >= 0, let node = outline.item(atRow: row) as? FolderNode,
           let location = RemoteLocation.parse(node.url), location.key.isEmpty {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: L10n.text("volume.disconnect"), action: #selector(disconnectCloud(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = location.connectionID
            ExplorerStyle.configureMenu(menu)
            return menu
        }
        if row >= 0, let search = (outline.item(atRow: row) as? FolderNode)?.savedSearch {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: L10n.text("search.forget"), action: #selector(forgetSavedSearch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = search.id
            return menu
        }
        guard row >= 0, let node = outline.item(atRow: row) as? FolderNode, !node.isGroup else { return nil }
        // An ordinary folder gets the same commands as in the list.
        if let folder = folder(for: node), let menu = fileMenuForFolder?(folder.entry, folder.isPlace) { return menu }
        let favorite = favoriteItem(for: node)
        guard node.volume != nil || node.url.path == "/" && node.url.isFileURL else {
            guard let favorite else { return nil }
            let menu = NSMenu()
            menu.addItem(favorite)
            ExplorerStyle.configureMenu(menu)
            return menu
        }
        let menu = NSMenu()
        if let favorite { menu.addItem(favorite); menu.addItem(.separator()) }
        let item = menu.addItem(withTitle: L10n.text("command.properties"), action: #selector(volumeProperties(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = (node.url, node.volume)
        if let mount = node.volume, let removal = mount.removal {
            let remove = menu.addItem(withTitle: L10n.text(removal == .eject ? "volume.eject" : "volume.disconnect"),
                                      action: #selector(removeMount(_:)), keyEquivalent: "")
            remove.representedObject = mount
            remove.target = self
        }
        ExplorerStyle.configureMenu(menu)
        return menu
    }

    /// "Add to favorites" or "Remove from favorites", for a folder that can be one.
    private func favoriteItem(for node: FolderNode) -> NSMenuItem? {
        guard node.url.isFileURL, node.savedSearch == nil, canBeFavorite?(node.url) ?? false else { return nil }
        let isFavorite = ExplorerStyle.folderShortcuts.isFavorite(node.url)
        let item = NSMenuItem(title: L10n.text(isFavorite ? "favorites.remove" : "favorites.add"),
                              action: #selector(toggleFavorite(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = node.url
        item.image = ExplorerStyle.symbol(isFavorite ? "star.slash" : "star", description: item.title)
        return item
    }

    @objc private func toggleFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let shortcuts = ExplorerStyle.folderShortcuts
        if shortcuts.isFavorite(url) { shortcuts.removeFavorite(url) } else { shortcuts.addFavorite(url) }
    }

    @objc private func disconnectCloud(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onDisconnectCloud?(id) }
    }

    @objc private func removeMount(_ sender: NSMenuItem) {
        if let mount = sender.representedObject as? VolumeMount { onRemoveMount?(mount) }
    }

    @objc private func volumeProperties(_ sender: NSMenuItem) {
        guard let (url, mount) = sender.representedObject as? (URL, VolumeMount?) else { return }
        onVolumeProperties?(url, mount)
    }

    private func reloadCloudConnections() {
        let previous = Dictionary((cloudRoot.children ?? []).map { ($0.url.explorerIdentity, $0) }, uniquingKeysWith: { first, _ in first })
        cloudRoot.children = CloudAccounts.shared.connections.map { connection in
            let url = RemoteLocation.url(connectionID: connection.id)
            let node = previous[url.explorerIdentity] ?? FolderNode(url: url, symbol: "cloud.\(connection.provider.rawValue)")
            node.title = connection.name
            return node
        }
        selecting = true
        outline.reloadItem(cloudRoot, reloadChildren: true)
        if !(cloudRoot.children?.isEmpty ?? true) { expandFromCode { outline.expandItem(cloudRoot) } }
        selecting = false
    }

    func setShowHidden(_ value: Bool) {
        guard hidden != value else { return }
        hidden = value
        resetListing()
    }

    func resetListing() {
        generation += 1
        roots.forEach { $0.stopObserving() }
        for root in roots { root.children = nil; root.loading = false; root.failure = nil }
        reloadCloudConnections()
        reloadSavedSearches()
        selecting = true
        outline.collapseItem(nil, collapseChildren: true)
        outline.reloadData()
        selecting = false
        shortcutsExpandedOnce.removeAll()
        reloadShortcuts()
    }

    func relocalize() {
        let keys = ["tree.home", "tree.desktop", "tree.downloads", "tree.documents", "tree.pictures", "tree.music", "tree.videos", "tree.computer", "tree.volumes"]
        for (node, key) in zip(fixedRoots, keys) { node.title = L10n.text(key) }
        favoritesRoot.title = L10n.text("tree.favorites")
        recentsRoot.title = L10n.text("tree.recents")
        for node in (favoritesRoot.children ?? []) + (recentsRoot.children ?? []) { node.title = Self.displayName(node.url) }
        mobileDevices?.relocalize()
        mobileRoot.title = L10n.text("devices.title")
        searchRoot.title = L10n.text("search.saved")
        cloudRoot.title = L10n.text("cloud.title")
        trashRoot.title = L10n.text("trash.title")
        outline.setAccessibilityLabel(L10n.text("tree.accessibility"))
        outline.rowHeight = Self.rowHeight
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    /// Follows the folder open in the list: selects it and, when the option is on, first opens the
    /// branches that lead to it.
    func show(_ url: URL) {
        // Inside a favorite or recent folder, the tree goes on from there and does not jump to the
        // folder's own place.
        if let branch = shortcutBranch(holding: url) {
            if branch.url.explorerIdentity == url.explorerIdentity {
                revealTarget = nil; revealStart = nil
                select(branch)
                return
            }
            if ExplorerStyle.browserPreferences.expandTreeToOpenFolder,
               !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                revealTarget = url; revealStart = branch
                continueReveal()
                return
            }
            revealTarget = nil; revealStart = nil
            select(visibleNode(for: url, under: branch) ?? branch)
            return
        }
        revealStart = nil
        // The graphical tests drive the tree by hand and expect it to stay as they left it.
        if ExplorerStyle.browserPreferences.expandTreeToOpenFolder, url.isFileURL,
           !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            revealTarget = url
            continueReveal()
        } else {
            revealTarget = nil
            selectIfVisible(url)
        }
    }

    /// The folder of the selected favorite or recent branch that holds `url`: the selected folder
    /// itself or one of the folders above it, up to the favorite. Nil outside such a branch.
    private func shortcutBranch(holding url: URL) -> FolderNode? {
        guard url.isFileURL, let selected = outline.item(atRow: outline.selectedRow) as? FolderNode,
              !selected.isGroup, isInShortcutGroup(selected) else { return nil }
        var node: FolderNode? = selected
        while let current = node, current !== favoritesRoot, current !== recentsRoot {
            if Self.contains(current.url, url) { return current }
            node = outline.parent(forItem: current) as? FolderNode
        }
        return nil
    }

    /// The row of `url` among the open folders under `branch`, if it is there.
    private func visibleNode(for url: URL, under branch: FolderNode) -> FolderNode? {
        let first = outline.row(forItem: branch)
        guard first >= 0 else { return nil }
        let level = outline.level(forRow: first)
        var row = first + 1
        while row < outline.numberOfRows, outline.level(forRow: row) > level {
            if let node = outline.item(atRow: row) as? FolderNode, node.url.explorerIdentity == url.explorerIdentity { return node }
            row += 1
        }
        return nil
    }

    private func select(_ node: FolderNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        selecting = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selecting = false
        outline.scrollRowToVisible(row)
    }

    private static func contains(_ ancestor: URL, _ url: URL) -> Bool {
        let base = ancestor.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    /// One step of the way to `revealTarget`: expands the deepest loaded ancestor and waits for its
    /// folders when they are still being read; `load` calls back here when they arrive.
    private func continueReveal() {
        guard let target = revealTarget else { return }
        // Start from the most specific location of the tree that holds the folder (Documents before
        // the home folder, the home folder before the computer).
        let candidates = roots.filter { !$0.isGroup && $0.savedSearch == nil && $0.url.isFileURL && Self.contains($0.url, target) }
        let start = revealStart.flatMap { outline.row(forItem: $0) >= 0 && Self.contains($0.url, target) ? $0 : nil }
        guard var node = start ?? candidates.max(by: { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }) else {
            revealTarget = nil; revealStart = nil
            selectIfVisible(target)
            return
        }
        while node.url.standardizedFileURL.path != target.standardizedFileURL.path {
            if !outline.isItemExpanded(node) {
                guard outline.isExpandable(node) else { break }
                expandFromCode { outline.expandItem(node) }
                // Not expanded yet means its folders are still being read: resume from `load`.
                if !outline.isItemExpanded(node) { if node.loading { return } else { break } }
            }
            guard let next = node.children?.first(where: { Self.contains($0.url, target) }) else { break }
            node = next
        }
        revealTarget = nil; revealStart = nil
        let row = outline.row(forItem: node)
        guard row >= 0 else { selectIfVisible(target); return }
        selecting = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selecting = false
        outline.scrollRowToVisible(row)
    }

    /// Selects the folder's row. Its place among the folders comes before a favorite or recent
    /// shortcut to it, which is chosen only when the place is not open in the tree.
    func selectIfVisible(_ url: URL) {
        selecting = true
        defer { selecting = false }
        var shortcut: Int?
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? FolderNode, !node.isGroup,
                  node.url.explorerIdentity == url.explorerIdentity else { continue }
            if isInShortcutGroup(node) { shortcut = shortcut ?? row; continue }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }
        if let shortcut { outline.selectRowIndexes(IndexSet(integer: shortcut), byExtendingSelection: false); return }
        outline.deselectAll(nil)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FolderNode)?.children?.count ?? (item == nil ? roots.count : 0)
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FolderNode, !node.isGroup, node.savedSearch == nil, !node.url.explorerIsRoot else { return nil }
        return FileClipboard.pasteboardWriter(for: node.url)
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        trackDragHover(info)
        if (item as? FolderNode) === favoritesRoot {
            let folders = favoriteCandidates(info)
            guard !folders.isEmpty else { return [] }
            outlineView.setDropItem(favoritesRoot, dropChildIndex: index == NSOutlineViewDropOnItemIndex ? (favoritesRoot.children?.count ?? 0) : index)
            // Reordering moves; anything new is added (a copy of the shortcut, never of the folder).
            let allowed = FileDrop.allowedOperations(for: info)
            let reorder = folders.allSatisfy(ExplorerStyle.folderShortcuts.isFavorite)
            if reorder, allowed.contains(.move) { return .move }
            return allowed.contains(.copy) ? .copy : allowed.contains(.move) ? .move : []
        }
        guard let node = item as? FolderNode, !node.isGroup, node.savedSearch == nil else { return [] }
        // A favorite dragged onto another favorite is being put in order, not moved into it: the
        // drop goes between the two rows, never into the folder.
        if outline.parent(forItem: node) as AnyObject? === favoritesRoot, let siblings = favoritesRoot.children,
           let position = siblings.firstIndex(where: { $0 === node }) {
            let dragged = FileDrop.readURLs(from: info)
            if !dragged.isEmpty, dragged.allSatisfy(ExplorerStyle.folderShortcuts.isFavorite) {
                let rect = outline.rect(ofRow: outline.row(forItem: node))
                let point = outline.convert(info.draggingLocation, from: nil)
                outlineView.setDropItem(favoritesRoot, dropChildIndex: point.y > rect.midY ? position + 1 : position)
                return FileDrop.allowedOperations(for: info).contains(.move) ? .move : []
            }
        }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return FileDrop.operation(for: FileDrop.readURLs(from: info), to: node.url,
                                  allowed: FileDrop.allowedOperations(for: info))
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if (item as? FolderNode) === favoritesRoot {
            let folders = favoriteCandidates(info)
            guard !folders.isEmpty else { return false }
            let shortcuts = ExplorerStyle.folderShortcuts
            return shortcuts.placeFavorites(folders, at: index == NSOutlineViewDropOnItemIndex ? shortcuts.favorites.count : index)
        }
        guard let node = item as? FolderNode, !node.isGroup, node.savedSearch == nil else { return false }
        let urls = FileDrop.readURLs(from: info)
        let action = FileDrop.operation(for: urls, to: node.url, allowed: FileDrop.allowedOperations(for: info))
        guard action == .copy || action == .move else { return false }
        FileCommands.shared.transfer(urls, to: node.url, move: action == .move)
        return FileCommands.shared.task != nil
    }

    /// The dragged items that can be favorites: folders of this Mac, outside protected folders.
    private func favoriteCandidates(_ info: any NSDraggingInfo) -> [URL] {
        FileDrop.readURLs(from: info).filter { $0.isFileURL && (canBeFavorite?($0) ?? false) }
    }

    private func cancelDragHover() {
        dragHoverTimer?.invalidate()
        dragHoverTimer = nil
        dragHoverNode = nil
    }

    /// Expands a folder only after the drag rests on that same row for `dragExpandDelay`.
    private func trackDragHover(_ info: any NSDraggingInfo) {
        let row = outline.row(at: outline.convert(info.draggingLocation, from: nil))
        let node = row >= 0 ? outline.item(atRow: row) as? FolderNode : nil
        guard node !== dragHoverNode else { return }
        cancelDragHover()
        dragHoverNode = node
        guard let node, outline.isExpandable(node), !outline.isItemExpanded(node) else { return }
        let timer = Timer(timeInterval: Self.dragExpandDelay, repeats: false) { [weak self, weak node] _ in
            MainActor.assumeIsolated {
                guard let self, let node, self.outline.dragActive, self.dragHoverNode === node else { return }
                self.dragHoverTimer = nil
                self.expandFromCode { self.outline.expandItem(node) }
            }
        }
        dragHoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func expandFromCode(_ body: () -> Void) {
        let previous = dragExpansionAllowed
        dragExpansionAllowed = true
        body()
        dragExpansionAllowed = previous
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FolderNode { return node.children![index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? FolderNode, node === mobileRoot || node.savedSearch != nil { return false }
        // Empty folders can receive new children; keep them retryable and observable.
        return (item as? FolderNode).map { $0 !== trashRoot && !$0.volumeLink } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        // While a drag hovers the tree, only our delayed hover timer (or a pending reload) may expand.
        if outline.dragActive && !dragExpansionAllowed { return false }
        if node === trashRoot || node === mobileRoot || node.savedSearch != nil || node.volumeLink { return false }
        if node.isGroup { return true }
        if node.children != nil {
            let stale = node.url.isFileURL && node.watcher == nil
            observe(node)
            if stale { load(node, expand: false) }
            return true
        }
        guard !node.loading else { return false }
        load(node, expand: true)
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? FolderNode)?.stopObserving()
        return true
    }

    private func observe(_ node: FolderNode) {
        guard node.url.isFileURL else { return }
        guard node.watcher == nil else { return }
        let watcher = DirectoryWatcher()
        node.watcher = watcher
        watcher.watch(node.url) { [weak self, weak node] in
            guard let self, let node, self.outline.isItemExpanded(node) || node.loading, node.refreshTask == nil else { return }
            node.refreshTask = Task { [weak self, weak node] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, let node else { return }
                node.refreshTask = nil
                guard self.outline.isItemExpanded(node) || node.loading else { return }
                self.load(node, expand: !self.outline.isItemExpanded(node))
            }
        }
    }

    private func expandedNodes(under nodes: [FolderNode]) -> [FolderNode] {
        nodes.flatMap { node in
            (outline.isItemExpanded(node) ? [node] : []) + expandedNodes(under: node.children ?? [])
        }
    }

    private static func showsLock(_ failure: DirectoryFailure?) -> Bool {
        #if APP_STORE
        return failure?.reason == .permission
        #else
        return false
        #endif
    }

    /// After folder access changes (App Store build), reads again every folder that had failed,
    /// without expanding it: a folder now granted gets its normal icon, one still refused its lock.
    func retryFailures() {
        func visit(_ node: FolderNode) {
            if node.failure != nil, !node.isGroup, node.url.isFileURL {
                node.failure = nil
                outline.reloadItem(node)
                if outline.row(forItem: node) >= 0 { load(node, expand: false) }
            }
            node.children?.forEach(visit)
        }
        roots.forEach(visit)
    }

    /// Refresh expanded nodes and invalidate collapsed caches without losing valid expansion identities.
    func refresh() {
        func refreshNode(_ node: FolderNode) {
            if node.isGroup { node.children?.forEach { refreshNode($0) }; return }
            if outline.isItemExpanded(node) {
                load(node, expand: false)
                node.children?.forEach { refreshNode($0) }
            } else {
                node.stopObserving()
                node.children = nil
            }
        }
        roots.forEach { refreshNode($0) }
    }

    private func load(_ node: FolderNode, expand: Bool) {
        // Watcher installation and rapid events may request another read while open() is
        // blocked. Keep one active read per node and reconcile once after it completes.
        guard !node.loading else { node.needsRefresh = true; return }
        node.task?.cancel()
        node.request += 1
        let nodeRequest = node.request
        node.loading = true
        observe(node)
        let request = generation, showHidden = hidden, url = node.url
        node.task = Task { [weak self, weak node] in
            do {
                let entries = try await ApplicationDirectoryReader(purpose: .background).entries(at: url, showHidden: showHidden)
                var mounts: [String: VolumeMount] = [:]
                if url.isFileURL && url.path == "/Volumes" {
                    mounts = await Task.detached(priority: .utility) {
                        var found: [String: VolumeMount] = [:]
                        for entry in entries where entry.canNavigate {
                            if let mount = try? VolumeMount.identify(at: entry.url) { found[entry.id] = mount }
                        }
                        return found
                    }.value
                }
                guard let self, let node, request == self.generation, nodeRequest == node.request else { return }
                let expanded = self.expandedNodes(under: [node])
                let selectedNode = self.outline.item(atRow: self.outline.selectedRow) as? FolderNode
                let selectedURL = selectedNode?.url
                let previous = Dictionary((node.children ?? []).map { ($0.url.explorerIdentity, $0) }, uniquingKeysWith: { first, _ in first })
                // Directory symlinks remain navigable in Details, but never recursively expand the tree.
                node.children = entries.filter { $0.canNavigate && (!$0.isSymbolicLink || mounts[$0.id] != nil) }
                    .map { entry in
                        let child = previous[entry.id] ?? FolderNode(url: entry.url)
                        child.volume = mounts[entry.id]
                        child.volumeLink = entry.isSymbolicLink
                        return child
                    }
                let remaining = Set(node.children?.map { $0.url.explorerIdentity } ?? [])
                for child in previous.values where !remaining.contains(child.url.explorerIdentity) { child.stopObserving() }
                node.loading = false
                node.failure = nil
                if expand || !expanded.isEmpty { self.observe(node) }
                self.selecting = true
                self.outline.reloadItem(node, reloadChildren: true)
                self.expandFromCode {
                    if expand { self.outline.expandItem(node) }
                    for item in expanded where item === node || self.outline.row(forItem: item) >= 0 {
                        self.outline.expandItem(item)
                        if item.watcher == nil && item.url.isFileURL {
                            self.observe(item)
                            self.load(item, expand: false)
                        }
                    }
                }
                self.selecting = false
                self.restoreSelection(selectedNode, url: selectedURL)
                if self.outline.isItemExpanded(node) { self.observe(node) }
                if node.needsRefresh {
                    node.needsRefresh = false
                    self.load(node, expand: false)
                }
                self.continueReveal()
            } catch {
                guard let self, let node, request == self.generation, nodeRequest == node.request else { return }
                node.loading = false
                node.needsRefresh = false
                node.failure = DirectoryFailure(path: url.explorerIdentity, error: error)
                self.outline.reloadItem(node)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("folder"), owner: self)
                    as? FileNameCell) ?? FileNameCell()
        cell.identifier = NSUserInterfaceItemIdentifier("folder")
        cell.label.stringValue = node.title
        // A favorite whose folder is gone (renamed, moved, on a volume that is not there) stays,
        // faded, until the person removes it.
        let missingFavorite = outline.parent(forItem: node) as AnyObject? === favoritesRoot && !FolderPresence.shared.exists(node.url)
        cell.alphaValue = missingFavorite ? 0.45 : 1
        cell.label.font = ExplorerStyle.font(.tree)
        let icon: ExplorerIcon
        switch node.symbol {
        case "magnifyingglass", "folder.badge.gearshape": icon = .search
        case "house": icon = .home
        case "desktopcomputer": icon = .desktop
        case "arrow.down.circle": icon = .downloads
        case "doc": icon = .document
        case "photo.fill": icon = .image
        case "music.note": icon = .audio
        case "film.fill": icon = .video
        case "iphone": icon = .iphone
        case "internaldrive": icon = .computer
        case "externaldrive": icon = .disk
        case "trash": icon = .trash
        case "cloud.s3": icon = .cloudOrange
        case "cloud.azure": icon = .cloudBlue
        case "cloud.gcs": icon = .cloudGreen
        case "cloud.fill": icon = .cloud
        case "favorite": icon = .favorite
        case "recent": icon = .recent
        default: icon = .folder
        }
        // Same icon size as the file list, so the two panes read as one.
        let side = FileTypeIcon.listIconSide
        cell.setIconSize(side)
        cell.icon.imageScaling = .scaleProportionallyUpOrDown
        cell.icon.imageAlignment = .alignCenter
        // A favorite or recent folder the sandbox refuses shows its lock before it is ever opened.
        let shortcutParent = outline.parent(forItem: node) as AnyObject?
        let refusedShortcut = node.failure == nil && (shortcutParent === favoritesRoot || shortcutParent === recentsRoot)
            && FolderPresence.shared.isRefused(node.url)
        if node.failure == nil && !refusedShortcut {
            cell.icon.image = PremiumIcons.image(icon, side: side, description: node.title)
            cell.icon.contentTintColor = nil
        } else if refusedShortcut || Self.showsLock(node.failure) {
            // The sandbox refused the folder (App Store build): a lock, not a warning; the tooltip
            // and the list explain it and offer to grant access.
            let lock = ExplorerStyle.symbol("lock.fill", description: node.title)
            cell.icon.image = lock?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side * 0.8, weight: .regular)) ?? lock
            cell.icon.contentTintColor = .secondaryLabelColor
        } else {
            let warning = ExplorerStyle.symbol("exclamationmark.triangle.fill", description: node.title)
            cell.icon.image = warning?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side, weight: .regular)) ?? warning
            cell.icon.contentTintColor = .systemOrange
        }
        cell.shortcutBadge.isHidden = true
        GitDecoration.apply(to: cell, url: node.url, directory: true, snapshot: gitSnapshot, roots: gitRoots,
            baseTooltip: L10n.directoryError(node.failure) ?? CloudAccounts.shared.address(for: node.url))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(selecting)
        guard !selecting, let node = outline.item(atRow: outline.selectedRow) as? FolderNode else { return }
        if node === trashRoot {
            selecting = true; outline.deselectAll(nil); selecting = false
            onShowTrash?()
            return
        }
        if node === mobileRoot {
            selecting = true; outline.deselectAll(nil); selecting = false
            if mobileDevices == nil { mobileDevices = AppleMobileDevices() }
            mobileDevices?.showWindow(nil)
            return
        }
        if node === searchRoot || node === favoritesRoot || node === recentsRoot { outline.expandItem(node); return }
        if let saved = node.savedSearch { onSavedSearch?(saved); return }
        if node.isGroup { onNavigate?(node.url); return }
        onNavigate?(node.url)
    }
}
