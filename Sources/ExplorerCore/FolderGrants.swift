// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A folder the person gave the App Store build access to, kept as a bookmark. In the sandbox the
/// bookmark carries a security scope (`files.bookmarks.app-scope`); the store logic does not depend
/// on it, so the tests use plain bookmarks on disposable folders (docs/APP-STORE.md, stage 2).
public struct FolderGrant: Sendable, Equatable {
    /// The folder's path when the bookmark was last made or resolved.
    public var path: String
    public var bookmark: Data

    public init(path: String, bookmark: Data) {
        self.path = path
        self.bookmark = bookmark
    }
}

/// Makes and resolves the bookmarks of `FolderGrantStore`.
public protocol FolderBookmarking: Sendable {
    func bookmark(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
}

/// App-scoped security-scoped bookmarks: what the sandboxed build keeps between launches.
public struct SecurityScopedBookmarks: FolderBookmarking {
    public init() {}

    public func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

/// Ordinary bookmarks, for tests and for anything outside the sandbox.
public struct PlainBookmarks: FolderBookmarking {
    public init() {}

    public func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

/// The folders the person granted, persisted in the app's preferences (in the sandbox, the
/// container's). It answers whether a path is covered and keeps the bookmarks fresh: a bookmark
/// that resolves stale, or to a folder that moved, is made again from the folder it points to.
@MainActor
public final class FolderGrantStore {
    public struct Resolution {
        public let grant: FolderGrant
        /// Where the bookmark points now; nil when it could not be resolved (a volume that is not
        /// connected, a folder that was deleted). The grant is kept until the person removes it.
        public let url: URL?
        public let error: (any Error)?
    }

    public static let grantsKey = "sandbox.folderGrants"
    public static let answeredKey = "sandbox.accessAnswered"
    public private(set) var grants: [FolderGrant]
    private let defaults: UserDefaults
    private let bookmarks: any FolderBookmarking

    public init(defaults: UserDefaults = .standard, bookmarks: any FolderBookmarking = SecurityScopedBookmarks()) {
        self.defaults = defaults
        self.bookmarks = bookmarks
        let stored = defaults.array(forKey: Self.grantsKey) as? [[String: Any]] ?? []
        grants = stored.compactMap { item in
            guard let path = item["path"] as? String, let bookmark = item["bookmark"] as? Data, path.hasPrefix("/") else { return nil }
            return FolderGrant(path: path, bookmark: bookmark)
        }
        grants = Self.ordered(grants)
    }

    /// Whether the person already answered the first-launch screen (granted something, or chose to
    /// go on without granting).
    public var answeredFirstLaunch: Bool {
        get { defaults.bool(forKey: Self.answeredKey) }
        set { defaults.set(newValue, forKey: Self.answeredKey) }
    }

    /// Adds (or replaces) the grant of a folder. In the sandbox the URL must be one the person just
    /// chose in an open panel, or one whose access is already started.
    @discardableResult
    public func add(_ url: URL) throws -> FolderGrant {
        let path = Self.normalized(url.path)
        let grant = FolderGrant(path: path, bookmark: try bookmarks.bookmark(for: url))
        grants.removeAll { $0.path == path }
        grants.append(grant)
        grants = Self.ordered(grants)
        save()
        return grant
    }

    public func remove(path: String) {
        let path = Self.normalized(path)
        grants.removeAll { $0.path == path }
        save()
    }

    public func removeAll() {
        grants = []
        save()
    }

    /// Resolves every bookmark. `access` is called with each resolved URL before a stale bookmark
    /// is made again (in the sandbox it starts the security-scoped access, which the new bookmark
    /// needs); it returns whether access was obtained.
    public func resolveAll(access: (URL) -> Bool) -> [Resolution] {
        var results: [Resolution] = []
        var changed = false
        for (index, grant) in grants.enumerated() {
            do {
                let resolved = try bookmarks.resolve(grant.bookmark)
                let allowed = access(resolved.url)
                let path = Self.normalized(resolved.url.path)
                var current = grant
                if resolved.isStale || path != grant.path, allowed, let fresh = try? bookmarks.bookmark(for: resolved.url) {
                    current = FolderGrant(path: path, bookmark: fresh)
                    grants[index] = current
                    changed = true
                }
                results.append(Resolution(grant: current, url: resolved.url, error: nil))
            } catch {
                results.append(Resolution(grant: grant, url: nil, error: error))
            }
        }
        if changed {
            // Two bookmarks that now point at the same folder become one.
            var seen = Set<String>()
            grants = Self.ordered(grants.filter { seen.insert($0.path).inserted })
            save()
        }
        return results
    }

    /// Whether `url` is inside one of the granted folders.
    public func covers(_ url: URL) -> Bool { Self.covers(url.path, roots: grants.map(\.path)) }

    /// The granted folder that holds `path`, the closest one when several do.
    public func grant(covering url: URL) -> FolderGrant? {
        let path = Self.normalized(url.path)
        return grants.filter { Self.covers(path, roots: [$0.path]) }.max { $0.path.count < $1.path.count }
    }

    public static func covers(_ path: String, roots: [String]) -> Bool {
        let path = normalized(path)
        return roots.map(normalized).contains { root in
            root == "/" || path == root || path.hasPrefix(root + "/")
        }
    }

    /// An absolute path without a trailing slash, with `.`/`..` and symbolic links in the path
    /// resolved (an open panel answers `/private/tmp` for `/tmp`).
    public static func normalized(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if resolved.count > 1 && resolved.hasSuffix("/") { return String(resolved.dropLast()) }
        return resolved.isEmpty ? "/" : resolved
    }

    private static func ordered(_ grants: [FolderGrant]) -> [FolderGrant] {
        grants.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func save() {
        defaults.set(grants.map { ["path": $0.path, "bookmark": $0.bookmark] as [String: Any] }, forKey: Self.grantsKey)
    }
}
