// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct DirectoryFailure: Sendable {
    public enum Reason: Sendable { case permission, notFound, notDirectory, other }
    public let path: String
    public let reason: Reason
    public let diagnostic: String
    public let cloudReason: CloudFailure.Reason?

    public init(path: String, error: any Error) {
        self.path = path
        diagnostic = error.localizedDescription
        cloudReason = (error as? CloudFailure)?.reason
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileReadNoPermission.rawValue {
            reason = .permission
        } else if ns.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(ns.code) {
            reason = .notFound
        } else if (ns.domain == NSPOSIXErrorDomain && ns.code == Int(POSIXErrorCode.ENOTDIR.rawValue)) ||
                  (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(POSIXErrorCode.ENOTDIR.rawValue)) {
            reason = .notDirectory
        } else { reason = .other }
    }
}

/// Owns one navigation session. History is committed only after a successful listing.
@MainActor
public final class DirectorySession {
    public private(set) var history: NavigationHistory
    public private(set) var entries: [FileEntry] = []
    public private(set) var isLoading = false
    public private(set) var isAutoRefreshing = false
    public var blocksInteraction: Bool { isLoading && !isAutoRefreshing }
    public private(set) var failure: DirectoryFailure?
    public var errorMessage: String? { failure.map { "\($0.path): \($0.diagnostic)" } }
    public private(set) var showHidden = false
    public var onChange: (() -> Void)?
    public var onWillAutoRefresh: (() -> Void)?
    public var onWillApplyAutoRefresh: (() -> Void)?
    private let reader: any DirectoryReading
    private let observer: (any DirectoryChangeObserving)?
    private var watchedPath: String?
    private var watchGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshAfterLoading = false
    private var observationEnabled = true
    private var generation = 0
    private var task: Task<Void, Never>?

    public init(url: URL, reader: any DirectoryReading = DirectoryReader(), observer: (any DirectoryChangeObserving)? = nil, showHidden: Bool = false) {
        history = NavigationHistory(url: url)
        self.showHidden = showHidden
        self.reader = reader
        self.observer = observer
    }

    public func remember(selection: Set<String>, scrollOffset: Double) {
        history.remember(selection: selection, scrollOffset: scrollOffset)
    }

    public func cancelLoading() {
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
        isAutoRefreshing = false
        observationEnabled = false
        stopWatching()
    }

    @discardableResult
    public func navigate(_ action: NavigationAction) -> Task<Void, Never> {
        performNavigation(action, automatic: false)
    }

    /// Only used by the workspace's guarded first-restore fallback. The unavailable location
    /// must not become a Back entry, and a failed fallback must not revive its stale selection.
    @discardableResult
    func restoreInitialLocation(to url: URL) -> Task<Void, Never> {
        stopWatching()
        history = NavigationHistory(url: url)
        entries = []
        return navigate(.reload)
    }

    private func performNavigation(_ action: NavigationAction, automatic: Bool) -> Task<Void, Never> {
        var candidate = history
        switch action {
        case .visit(let url): candidate.visit(url)
        case .back: candidate.goBack()
        case .forward: candidate.goForward()
        case .up: candidate.goUp()
        case .reload: break
        }
        if candidate.current.url.explorerIdentity != history.current.url.explorerIdentity { stopWatching() }
        generation += 1
        let request = generation
        task?.cancel()
        isLoading = true
        isAutoRefreshing = automatic
        failure = nil
        ensureWatching(candidate.current.url)
        onChange?()
        let reader = reader, hidden = showHidden
        let destination = candidate
        let next = Task { [weak self] in
            do {
                let result = try await reader.entries(at: destination.current.url, showHidden: hidden)
                guard let self, request == self.generation else { return }
                var committed = destination
                if automatic {
                    self.onWillApplyAutoRefresh?()
                    committed.remember(selection: self.history.current.selectedPaths, scrollOffset: self.history.current.scrollOffset)
                }
                self.history = committed
                self.entries = result
                self.history.remember(selection: self.history.current.selectedPaths.intersection(Set(result.map(\.id))),
                                      scrollOffset: self.history.current.scrollOffset)
                self.isLoading = false
                self.isAutoRefreshing = false
                self.onChange?()
                self.resumeWatching()
            } catch {
                guard let self, request == self.generation else { return }
                if automatic { self.onWillApplyAutoRefresh?() }
                self.isLoading = false
                self.isAutoRefreshing = false
                self.failure = DirectoryFailure(path: destination.current.url.explorerIdentity, error: error)
                self.onChange?()
                self.resumeWatching()
            }
        }
        task = next
        return next
    }

    public func toggleHidden() {
        showHidden.toggle()
        navigate(.reload)
    }

    private func stopWatching() {
        watchGeneration += 1
        observer?.stop()
        watchedPath = nil
        refreshTask?.cancel(); refreshTask = nil
        refreshAfterLoading = false
    }

    private func resumeWatching() {
        ensureWatching(history.current.url)
        if refreshAfterLoading { refreshAfterLoading = false; scheduleRefresh() }
    }

    private func ensureWatching(_ url: URL) {
        guard url.isFileURL else { if watchedPath != nil { stopWatching() }; return }
        guard observationEnabled, let observer else { return }
        if watchedPath != url.path {
            stopWatching()
            let request = watchGeneration
            watchedPath = url.path
            observer.watch(url) { [weak self] in
                guard let self, self.observationEnabled, request == self.watchGeneration else { return }
                self.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        let request = watchGeneration
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.observationEnabled, request == self.watchGeneration else { return }
            self.refreshTask = nil
            if self.isLoading { self.refreshAfterLoading = true; return }
            self.onWillAutoRefresh?()
            _ = self.performNavigation(.reload, automatic: true)
        }
    }
}
