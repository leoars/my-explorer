// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerCore

#if APP_STORE
/// The App Store build has no Git (docs/APP-STORE.md): nothing is inspected, so the list, the
/// tree and the status bar show no Git mark, summary or menu.
@MainActor
final class GitBrowserState {
    let snapshot: GitStatusSnapshot? = nil
    let repositoryRootPaths: Set<String> = []
    let result: GitInspectionResult? = nil
    var onChange: (() -> Void)?
    var shouldPoll: (() -> Bool)?
    func update(directory: URL, entries: [FileEntry], force: Bool = false) {}
    func beginNavigation(to url: URL) {}
    func stop() {}
}
#else
/// Presentation requests are coalesced and generation-checked; Git never blocks navigation.
@MainActor
final class GitBrowserState {
    typealias Inspect = @Sendable (URL, Bool) async -> GitInspectionResult
    typealias Roots = @Sendable ([URL]) async -> Set<URL>
    private static let service = GitStatusService()
    private let inspect: Inspect
    private let findRoots: Roots
    private var task: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var generation = 0
    private var directory: URL?
    private var entries: [FileEntry] = []
    private(set) var snapshot: GitStatusSnapshot?
    private(set) var repositoryRootPaths: Set<String> = []
    private(set) var result: GitInspectionResult?
    var onChange: (() -> Void)?
    var shouldPoll: (() -> Bool)?

    init(inspect: Inspect? = nil, roots: Roots? = nil) {
        let service = Self.service
        self.inspect = inspect ?? { await service.inspect(directory: $0, force: $1) }
        self.findRoots = roots ?? { await service.repositoryRoots(in: $0) }
    }

    func update(directory: URL, entries: [FileEntry], force: Bool = false) {
        let moved = self.directory != directory
        let changed = self.entries != entries
        guard moved || changed || force else { return }
        generation += 1
        task?.cancel(); task = nil
        self.directory = directory
        self.entries = entries
        if moved {
            snapshot = nil; repositoryRootPaths = []; result = nil
            poll?.cancel(); poll = nil
            onChange?()
        }
        guard directory.isFileURL else { return }
        let expected = generation, inspect = inspect, findRoots = findRoots
        let folders = entries.filter { $0.canNavigate && !$0.isSymbolicLink && !$0.isAlias }.map(\.url)
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            async let roots = findRoots(folders)
            let inspection = await inspect(directory, force || (!moved && changed))
            let candidates = await roots
            guard !Task.isCancelled, let self, self.generation == expected, self.directory == directory else { return }
            self.task = nil
            self.result = inspection
            self.repositoryRootPaths = Set(candidates.map { $0.standardizedFileURL.path })
            if case .repository(let snapshot) = inspection {
                self.snapshot = snapshot
                self.repositoryRootPaths.insert(snapshot.rootURL.standardizedFileURL.path)
            } else { self.snapshot = nil }
            self.onChange?()
            self.startPollingIfNeeded()
        }
    }

    /// Clear badges immediately when navigation begins, before the new listing completes.
    func beginNavigation(to url: URL) {
        guard directory != url else { return }
        stop()
        directory = nil
    }

    func stop() {
        generation += 1
        task?.cancel(); task = nil
        poll?.cancel(); poll = nil
        snapshot = nil; repositoryRootPaths = []; result = nil
        directory = nil; entries = []
        onChange?()
    }

    private func startPollingIfNeeded() {
        // Unavailable/limited locations retry only on listing changes or F5. Do not
        // continuously repeat a refused scan of a large/offline/custom-filter repository.
        guard case .repository = result else { poll?.cancel(); poll = nil; return }
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                guard self.task == nil, self.shouldPoll?() == true, let directory = self.directory else { continue }
                self.update(directory: directory, entries: self.entries, force: true)
            }
        }
    }
}
#endif
