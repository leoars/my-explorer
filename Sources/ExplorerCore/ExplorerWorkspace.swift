// SPDX-License-Identifier: Apache-2.0
import Foundation

@MainActor
public final class ExplorerTab: Identifiable {
    public let id = UUID()
    public let session: DirectorySession
    public var filterQuery = ""
    public var sortKey: EntrySortKey = .name
    public var sortAscending = true
    public private(set) var displayedPath: String?
    public private(set) var pendingInitialLoad: Bool
    public private(set) var restorationUnavailableURL: URL?
    private var restorationCandidate: (original: URL, fallback: URL)?
    private var restorationRevision = 0
    private var restorationTask: Task<Void, Never>?

    init(url: URL, reader: any DirectoryReading, observer: (any DirectoryChangeObserving)?, sortKey: EntrySortKey,
         sortAscending: Bool, showHidden: Bool, restorationFallback: URL?) {
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        pendingInitialLoad = true
        session = DirectorySession(url: url, reader: reader, observer: observer, showHidden: showHidden)
        if url.isFileURL, let fallback = restorationFallback, fallback.isFileURL,
           fallback.explorerIdentity != session.history.current.url.explorerIdentity {
            restorationCandidate = (session.history.current.url, fallback)
        }
    }

    /// Call before explicit navigation/reload/hidden-item changes so a stale restore cannot take over.
    public func prepareForUserNavigation() {
        pendingInitialLoad = false
        restorationRevision += 1
        restorationCandidate = nil
        restorationUnavailableURL = nil
        restorationTask?.cancel(); restorationTask = nil
    }

    fileprivate func loadIfPending() {
        guard pendingInitialLoad else { return }
        pendingInitialLoad = false
        session.navigate(.reload)
    }

    fileprivate func recoverInitialFailure(ifStillPresent: @escaping @MainActor () -> Bool) {
        guard !pendingInitialLoad, !session.isLoading, let candidate = restorationCandidate else { return }
        restorationCandidate = nil // A restore gets exactly one initial attempt, successful or not.
        guard session.failure?.path == candidate.original.explorerIdentity,
              session.history.current.url.explorerIdentity == candidate.original.explorerIdentity else { return }
        let revision = restorationRevision
        restorationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.restorationRevision == revision, ifStillPresent(),
                  !self.session.isLoading, self.session.failure?.path == candidate.original.explorerIdentity,
                  self.session.history.current.url.explorerIdentity == candidate.original.explorerIdentity else { return }
            self.restorationTask = nil
            self.restorationUnavailableURL = candidate.original
            self.session.restoreInitialLocation(to: candidate.fallback)
        }
    }

    /// A new directory starts with an empty filter; changing tabs does not clear it.
    public func reconcileLocation() {
        guard !session.isLoading else { return }
        let path = session.history.current.url.explorerIdentity
        if displayedPath != nil && displayedPath != path { filterQuery = "" }
        displayedPath = path
    }
}

@MainActor
public final class ExplorerWorkspace {
    public private(set) var tabs: [ExplorerTab] = []
    public private(set) var activeID: UUID?
    public var activeTab: ExplorerTab? { tabs.first { $0.id == activeID } }
    /// An ID identifies the session that changed. Nil means the tab structure/selection changed.
    public var onChange: ((UUID?) -> Void)?
    public var onWillAutoRefresh: ((UUID) -> Void)?
    private let reader: any DirectoryReading
    private let observerFactory: @MainActor () -> (any DirectoryChangeObserving)?

    public init(reader: any DirectoryReading = DirectoryReader(),
                observerFactory: @escaping @MainActor () -> (any DirectoryChangeObserving)? = { nil }) {
        self.reader = reader
        self.observerFactory = observerFactory
    }

    @discardableResult
    public func addTab(at url: URL, select: Bool = true, sortKey: EntrySortKey = .name, sortAscending: Bool = true,
                       showHidden: Bool = false, startLoading: Bool = true, restorationFallback: URL? = nil) -> ExplorerTab {
        let tab = ExplorerTab(url: url, reader: reader, observer: DeferredTabObserver(factory: observerFactory),
                              sortKey: sortKey, sortAscending: sortAscending, showHidden: showHidden,
                              restorationFallback: restorationFallback)
        tabs.append(tab)
        if select || activeID == nil { activeID = tab.id }
        tab.session.onChange = { [weak self, weak tab] in
            guard let self, let tab, self.tabs.contains(where: { $0.id == tab.id }) else { return }
            tab.reconcileLocation()
            tab.recoverInitialFailure { [weak self, weak tab] in
                guard let self, let tab else { return false }
                return self.tabs.contains(where: { $0.id == tab.id })
            }
            self.onChange?(tab.id)
        }
        tab.session.onWillAutoRefresh = { [weak self, weak tab] in
            if let self, let tab { self.onWillAutoRefresh?(tab.id) }
        }
        tab.session.onWillApplyAutoRefresh = tab.session.onWillAutoRefresh
        onChange?(nil)
        if startLoading { tab.loadIfPending() }
        return tab
    }

    public func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if activeID != id {
            activeID = id
            onChange?(nil)
        }
        tab.loadIfPending()
    }

    public func selectNext(backwards: Bool = false) {
        guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        select(tabs[(index + (backwards ? tabs.count - 1 : 1)) % tabs.count].id)
    }

    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.prepareForUserNavigation()
        tab.session.onChange = nil
        tab.session.onWillAutoRefresh = nil
        tab.session.onWillApplyAutoRefresh = nil
        tab.session.cancelLoading()
        if activeID == id { activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        onChange?(nil)
        activeTab?.loadIfPending()
    }
}

/// Creating inactive restored tabs must not create filesystem observers or inspect their paths.
@MainActor
private final class DeferredTabObserver: DirectoryChangeObserving {
    private let factory: @MainActor () -> (any DirectoryChangeObserving)?
    private var observer: (any DirectoryChangeObserving)?
    private var created = false
    init(factory: @escaping @MainActor () -> (any DirectoryChangeObserving)?) { self.factory = factory }
    func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        if !created { observer = factory(); created = true }
        observer?.watch(url, onChange: onChange)
    }
    func stop() { observer?.stop() }
}
