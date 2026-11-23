// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The folders the person keeps at hand: the favorites, in the order they chose, and the folders
/// opened most recently, newest first. Both are paths of this Mac; which folders may be recorded
/// is the application's decision (protected folders, the Trash and searches never are).
@MainActor
public final class FolderShortcuts {
    public static let didChange = Notification.Name("MyExplorer.FolderShortcuts.didChange")
    static let favoritesKey = "folderShortcuts.favorites"
    static let recentsKey = "folderShortcuts.recents"
    static let showFavoritesKey = "folderShortcuts.showFavorites"
    static let showRecentsKey = "folderShortcuts.showRecents"
    static let recentLimitKey = "folderShortcuts.recentLimit"
    /// How many recent folders the person can choose to see.
    public static let recentLimits = [5, 10, 15, 20]
    public static let defaultRecentLimit = 10
    /// More than the largest choice is never kept, so raising the limit shows folders already known.
    static let storedRecents = 20
    /// Plenty for a list meant to be read at a glance, and a bound on what the preferences hold.
    public static let favoritesLimit = 100

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: Settings

    public var showFavorites: Bool {
        get { defaults.object(forKey: Self.showFavoritesKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showFavoritesKey); changed() }
    }

    public var showRecents: Bool {
        get { defaults.object(forKey: Self.showRecentsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showRecentsKey); changed() }
    }

    public var recentLimit: Int {
        get {
            let value = defaults.integer(forKey: Self.recentLimitKey)
            return Self.recentLimits.contains(value) ? value : Self.defaultRecentLimit
        }
        set {
            defaults.set(Self.recentLimits.contains(newValue) ? newValue : Self.defaultRecentLimit, forKey: Self.recentLimitKey)
            changed()
        }
    }

    // MARK: Favorites

    /// In the person's order.
    public var favorites: [URL] { paths(Self.favoritesKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }

    public func isFavorite(_ url: URL) -> Bool {
        guard let path = Self.path(url) else { return false }
        return paths(Self.favoritesKey).contains(path)
    }

    /// Adds the folder at the end, or at `index`. A folder already there stays where it is.
    @discardableResult
    public func addFavorite(_ url: URL, at index: Int? = nil) -> Bool {
        guard let path = Self.path(url) else { return false }
        var list = paths(Self.favoritesKey)
        guard !list.contains(path), list.count < Self.favoritesLimit else { return false }
        list.insert(path, at: min(max(index ?? list.count, 0), list.count))
        store(list, Self.favoritesKey)
        return true
    }

    public func removeFavorite(_ url: URL) {
        guard let path = Self.path(url) else { return }
        let list = paths(Self.favoritesKey)
        guard list.contains(path) else { return }
        store(list.filter { $0 != path }, Self.favoritesKey)
    }

    /// Moves a favorite so that it ends up at `index` of the list as it is now (the position a drop
    /// between two rows names), counting the folder itself.
    public func moveFavorite(_ url: URL, to index: Int) {
        guard let path = Self.path(url) else { return }
        var list = paths(Self.favoritesKey)
        guard let from = list.firstIndex(of: path) else { return }
        var target = min(max(index, 0), list.count)
        if target > from { target -= 1 }
        guard target != from else { return }
        list.remove(at: from)
        list.insert(path, at: target)
        store(list, Self.favoritesKey)
    }

    /// Puts dropped folders at `index` of the favorites as they are now: folders already there move,
    /// new ones are added, in the order they were dragged. Says whether anything changed.
    @discardableResult
    public func placeFavorites(_ urls: [URL], at index: Int) -> Bool {
        let before = paths(Self.favoritesKey)
        let known = Set(before)
        let dropped = urls.compactMap(Self.path).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !dropped.isEmpty else { return false }
        // Folders that move leave their place first; those above the drop point shift it up.
        var position = min(max(index, 0), before.count)
        position -= before[..<position].filter { dropped.contains($0) }.count
        var list = before.filter { !dropped.contains($0) }
        // New folders fit only while there is room; moving never needs any.
        var room = Self.favoritesLimit - list.count - dropped.filter(known.contains).count
        let placed = dropped.filter { path in
            if known.contains(path) { return true }
            room -= 1
            return room >= 0
        }
        list.insert(contentsOf: placed, at: position)
        guard list != before else { return false }
        store(list, Self.favoritesKey)
        return true
    }

    // MARK: Recent folders

    /// Records that the folder was opened: it goes to the top of the recent folders.
    public func recordVisit(_ url: URL) {
        guard let path = Self.path(url) else { return }
        let list = paths(Self.recentsKey)
        guard list.first != path else { return }
        store(Array(([path] + list.filter { $0 != path }).prefix(Self.storedRecents)), Self.recentsKey)
    }

    /// The recent folders to show, newest first: no favorites, nothing that no longer exists as a
    /// folder, at most `recentLimit`.
    public func visibleRecents(exists: (URL) -> Bool = FolderShortcuts.folderExists) -> [URL] {
        let favorites = Set(paths(Self.favoritesKey))
        return paths(Self.recentsKey).lazy
            .filter { !favorites.contains($0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter(exists)
            .prefix(recentLimit)
            .map { $0 }
    }

    public func clearRecents() { store([], Self.recentsKey) }

    /// Forgets the recent folders inside any of `roots` (a protected folder that was locked, say).
    public func forgetRecents(inside roots: [URL]) {
        let prefixes = roots.compactMap(Self.path)
        guard !prefixes.isEmpty else { return }
        let list = paths(Self.recentsKey)
        let kept = list.filter { path in !prefixes.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") } }
        if kept.count != list.count { store(kept, Self.recentsKey) }
    }

    /// Places that are never kept, whatever the application knows about them: anything inside a
    /// Trash (the home folder's, a volume's, iCloud Drive's) or inside a protected folder's package.
    nonisolated public static func isExcludedPlace(_ url: URL) -> Bool {
        guard let path = path(url) else { return true }
        return path.split(separator: "/").contains { component in
            component == ".Trash" || component == ".Trashes" || component.lowercased().hasSuffix(".myexplorervault")
        }
    }

    nonisolated public static func folderExists(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    // MARK: Storage

    /// The one form a folder is kept in: an absolute path of this Mac with its links resolved
    /// (/tmp and /private/tmp are one folder), its accents composed (a name dragged from the Finder
    /// arrives decomposed, one typed or listed may not) and no trailing slash. Anything that is not
    /// a file URL has none.
    nonisolated static func path(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
        guard path.hasPrefix("/") else { return nil }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func paths(_ key: String) -> [String] {
        var seen = Set<String>()
        return (defaults.array(forKey: key) as? [Any] ?? []).compactMap { ($0 as? String)?.precomposedStringWithCanonicalMapping }
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    private func store(_ list: [String], _ key: String) {
        defaults.set(list, forKey: key)
        changed()
    }

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
