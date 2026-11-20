// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Only navigation and nonsecret per-tab presentation state belong in a session snapshot.
public struct SessionTabState: Equatable, Sendable {
    public let url: URL
    public let sortKey: EntrySortKey
    public let sortAscending: Bool
    public let showHidden: Bool

    public init(url: URL, sortKey: EntrySortKey = .name, sortAscending: Bool = true, showHidden: Bool = false) {
        self.url = url
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.showHidden = showHidden
    }
}

public enum SessionRestoreFallbackReason: String, Equatable, Sendable {
    case invalidLocation, missingConnection
}

/// A synchronous, filesystem-free plan. Local availability is checked only when the GUI
/// asynchronously opens a tab; inactive tabs need not start any directory or cloud requests.
public struct SessionRestorePlan: Equatable, Sendable {
    public let tabs: [SessionTabState]
    public let activeIndex: Int
    public let fallbackReasons: [Int: SessionRestoreFallbackReason]
}

@MainActor
public final class SessionPreferences {
    public static let maximumTabs = 32
    private static let version = 1
    private static let maximumSnapshotBytes = 600 * 1024
    private static let enabledKey = "restoreTabs"
    private static let snapshotKey = "sessionSnapshot"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var restoreTabs: Bool {
        guard let value = defaults.object(forKey: Self.enabledKey) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    public func setRestoreTabs(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { defaults.removeObject(forKey: Self.snapshotKey) }
    }

    /// Preserve a contiguous window of at most 32 tabs. It begins at zero unless the
    /// active tab is beyond that window; then the window ends at the active tab.
    /// Unsafe locations become nil placeholders, so no credential-bearing URL is stored
    /// and the tab order/active position can still be restored using an explicit fallback.
    public func remember(tabs: [SessionTabState], activeIndex: Int) {
        guard restoreTabs else { return }
        guard !tabs.isEmpty else { defaults.removeObject(forKey: Self.snapshotKey); return }
        let active = min(max(activeIndex, 0), tabs.count - 1)
        let start = max(0, active - Self.maximumTabs + 1)
        let end = min(tabs.count, start + Self.maximumTabs)
        let stored = tabs[start..<end].map { tab in
            StoredSessionTab(location: StartupPreferences.safeLocation(tab.url)?.absoluteString,
                sortKey: tab.sortKey.rawValue, sortAscending: tab.sortAscending, showHidden: tab.showHidden)
        }
        let payload = StoredSession(version: Self.version, tabs: stored, activeIndex: active - start)
        guard let data = try? JSONEncoder().encode(payload), data.count <= Self.maximumSnapshotBytes else {
            defaults.removeObject(forKey: Self.snapshotKey)
            return
        }
        defaults.set(data, forKey: Self.snapshotKey)
    }

    /// Unknown schema versions, malformed data and empty/oversized snapshots are discarded.
    /// A malformed individual URL or removed cloud connection keeps its tab position and
    /// presentation settings, replacing only the URL with the caller's safe fallback.
    public func restorationPlan(fallback: URL, availableConnectionIDs: Set<UUID>) -> SessionRestorePlan? {
        guard restoreTabs else { return nil }
        guard let data = defaults.data(forKey: Self.snapshotKey), data.count <= Self.maximumSnapshotBytes,
              let payload = try? JSONDecoder().decode(StoredSession.self, from: data), payload.version == Self.version,
              !payload.tabs.isEmpty, payload.tabs.count <= Self.maximumTabs else {
            defaults.removeObject(forKey: Self.snapshotKey)
            return nil
        }
        var safeFallback = StartupPreferences.safeLocation(fallback) ?? URL(fileURLWithPath: "/", isDirectory: true)
        if let remote = RemoteLocation.parse(safeFallback), !availableConnectionIDs.contains(remote.connectionID) {
            safeFallback = URL(fileURLWithPath: "/", isDirectory: true)
        }
        var reasons: [Int: SessionRestoreFallbackReason] = [:]
        var sanitized: [StoredSessionTab] = []
        let tabs = payload.tabs.enumerated().map { index, tab in
            let safe = tab.location.flatMap { $0.utf8.count <= 16_384 ? URL(string: $0) : nil }.flatMap(StartupPreferences.safeLocation)
            sanitized.append(StoredSessionTab(location: safe?.absoluteString,
                sortKey: (EntrySortKey(rawValue: tab.sortKey) ?? .name).rawValue,
                sortAscending: tab.sortAscending, showHidden: tab.showHidden))
            let restored: URL
            if let safe {
                if let remote = RemoteLocation.parse(safe), !availableConnectionIDs.contains(remote.connectionID) {
                    reasons[index] = .missingConnection
                    restored = safeFallback
                } else { restored = safe }
            } else {
                reasons[index] = .invalidLocation
                restored = safeFallback
            }
            return SessionTabState(url: restored, sortKey: EntrySortKey(rawValue: tab.sortKey) ?? .name,
                sortAscending: tab.sortAscending, showHidden: tab.showHidden)
        }
        let activeIndex = min(max(payload.activeIndex, 0), tabs.count - 1)
        // Rewrite only our schema fields, removing any injected unsafe URL or unknown
        // payload fields instead of leaving credential-bearing data in preferences.
        if let clean = try? JSONEncoder().encode(StoredSession(version: Self.version, tabs: sanitized, activeIndex: activeIndex)),
           clean.count <= Self.maximumSnapshotBytes { defaults.set(clean, forKey: Self.snapshotKey) }
        else { defaults.removeObject(forKey: Self.snapshotKey) }
        return SessionRestorePlan(tabs: tabs, activeIndex: activeIndex, fallbackReasons: reasons)
    }
}

private struct StoredSession: Codable {
    let version: Int
    let tabs: [StoredSessionTab]
    let activeIndex: Int
}

private struct StoredSessionTab: Codable {
    let location: String?
    let sortKey: String
    let sortAscending: Bool
    let showHidden: Bool
}
