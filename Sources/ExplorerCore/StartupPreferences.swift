// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Remembers only a navigation URL. Cloud credentials remain owned by the account store.
@MainActor
public final class StartupPreferences {
    private let defaults: UserDefaults
    private static let enabledKey = "restoreLastFolder"
    private static let locationKey = "lastFolderURL"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var restoreLastFolder: Bool { defaults.bool(forKey: Self.enabledKey) }

    public func setRestoreLastFolder(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { defaults.removeObject(forKey: Self.locationKey) }
    }

    public func remember(url: URL) {
        guard restoreLastFolder else { return }
        guard let safe = Self.safeLocation(url) else {
            defaults.removeObject(forKey: Self.locationKey)
            return
        }
        defaults.set(safe.absoluteString, forKey: Self.locationKey)
    }

    /// Builds a syntactic startup location only. Existence, directory type, permissions and
    /// recovery-marker checks belong to asynchronous directory navigation, never this preference read.
    public func initialURL(fallback: URL, availableConnectionIDs: Set<UUID>) -> URL {
        guard restoreLastFolder else { return fallback }
        guard let value = defaults.string(forKey: Self.locationKey), value.utf8.count <= 16_384,
              let url = URL(string: value), let safe = Self.safeLocation(url) else {
            defaults.removeObject(forKey: Self.locationKey)
            return fallback
        }
        if let remote = RemoteLocation.parse(safe), !availableConnectionIDs.contains(remote.connectionID) {
            defaults.removeObject(forKey: Self.locationKey)
            return fallback
        }
        return safe
    }

    /// Pure URL validation: no stat, symlink resolution, readability probe or filesystem access.
    /// A valid local path can be absent, inaccessible or a regular file; the async reader
    /// validates those conditions and the GUI decides whether to show the startup fallback.
    public nonisolated static func safeLocation(_ url: URL) -> URL? {
        guard url.absoluteString.utf8.count <= 16_384,
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = parsed.percentEncodedPath.removingPercentEncoding, !path.utf8.contains(0) else { return nil }
        if url.isFileURL {
            guard !SecureFolderService.isSessionURL(url) else { return nil }
            guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost", path.hasPrefix("/") else { return nil }
            let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.contains(where: { $0.lowercased().hasSuffix(".app") || isPrivateTemporaryComponent($0) }) else { return nil }
            var normalized: [String] = []
            for component in components {
                if component == "." { continue }
                if component == ".." { if !normalized.isEmpty { normalized.removeLast() }; continue }
                normalized.append(component)
            }
            // Specifying isDirectory avoids Foundation's optional directory-type probe.
            return URL(fileURLWithPath: "/" + normalized.joined(separator: "/"), isDirectory: true)
        }
        // The favorites and the recent folders opened as a place of the list.
        if let group = FolderShortcutGroup(url: url) { return group.url }
        guard url.scheme == RemoteLocation.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if (components.host == nil || components.host == ""), components.path == "/" {
            return URL(string: "myexplorer-cloud:///")
        }
        guard let remote = RemoteLocation.parse(url), !remote.key.contains("\\"),
              !remote.key.utf8.contains(0) else { return nil }
        let parts = remote.key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.enumerated().allSatisfy({ index, part in
            part != "." && part != ".." && (!part.isEmpty || index == parts.count - 1)
        }) else { return nil }
        return RemoteLocation.url(connectionID: remote.connectionID, key: remote.key)
    }

    private nonisolated static func isPrivateTemporaryComponent(_ component: String) -> Bool {
        let lower = component.lowercased()
        if lower == ".my-explorer-local-journal-v1" || lower == "temporaryitems" || lower == ".temporaryitems" { return true }
        for kind in ["undo", "copy", "archive", "agent", "transfer", "cloud"] {
            let prefix = ".my-explorer-" + kind + "-"
            if lower.hasPrefix(prefix), UUID(uuidString: String(component.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }

}
