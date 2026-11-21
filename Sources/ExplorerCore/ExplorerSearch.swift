// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct ExplorerSearchSpec: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, CaseIterable, Sendable { case folder, computer, walkFolder }
    public enum Modified: String, Codable, CaseIterable, Sendable {
        case anytime, today, lastWeek, lastMonth
        func start(at now: Date) -> Date? {
            switch self {
            case .anytime: return nil
            case .today: return Calendar.current.startOfDay(for: now)
            case .lastWeek: return Calendar.current.date(byAdding: .day, value: -7, to: now)
            case .lastMonth: return Calendar.current.date(byAdding: .month, value: -1, to: now)
            }
        }
    }
    public var folder: URL
    public var scope: Scope = .folder
    public var name = ""
    public var fileExtension = ""
    public var content = ""
    public var tag = ""
    public var modified: Modified = .anytime
    public init(folder: URL) { self.folder = folder }

    public var hasCriteria: Bool {
        !name.isEmpty || !fileExtension.isEmpty || !content.isEmpty || !tag.isEmpty || modified != .anytime
    }

    /// Use predicate arguments rather than interpolating user text as Spotlight syntax.
    public func predicate(now: Date = Date()) -> NSPredicate {
        var parts = [NSPredicate]()
        if !name.isEmpty { parts.append(NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemFSName", name)) }
        if !fileExtension.isEmpty {
            parts.append(NSPredicate(format: "%K ENDSWITH[c] %@", "kMDItemFSName", "." + fileExtension))
        }
        if !content.isEmpty { parts.append(NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", content)) }
        if !tag.isEmpty { parts.append(NSPredicate(format: "ANY %K ==[c] %@", "kMDItemUserTags", tag)) }
        if let since = modified.start(at: now) {
            parts.append(NSPredicate(format: "%K >= %@", "kMDItemFSContentChangeDate", since as NSDate))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    public struct WalkResults: Sendable {
        public var urls: [URL] = []
        public var unreadable = 0
        public var truncated = false
    }

    /// The directory reader owns the bounded worker pool and never enters vault or transfer-recovery storage.
    public func walk(reader: any DirectoryReading = DirectoryReader(purpose: .background),
                     limit: Int = 2000, now: Date = Date()) async throws -> WalkResults {
        guard scope == .walkFolder, content.isEmpty, folder.isFileURL, Self.mayShow(folder), hasCriteria, limit > 0 else {
            throw CocoaError(.featureUnsupported)
        }
        var result = WalkResults()
        var pending = [folder]
        let since = modified.start(at: now)
        while let current = pending.popLast() {
            try Task.checkCancellation()
            let entries: [FileEntry]
            do { entries = try await reader.entries(at: current, showHidden: false) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if current == folder { throw error }
                result.unreadable += 1
                continue
            }
            for entry in entries {
                try Task.checkCancellation()
                if SecureFolderService.isSessionURL(entry.url) { continue }
                if entry.canNavigate && !entry.isSymbolicLink && !entry.isAlias { pending.append(entry.url) }
                guard name.isEmpty || entry.name.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                      fileExtension.isEmpty || entry.url.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame,
                      since.map({ (entry.modified ?? .distantPast) >= $0 }) ?? true else { continue }
                if !tag.isEmpty {
                    guard let tags = try? entry.url.resourceValues(forKeys: [.tagNamesKey]).tagNames,
                          tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { continue }
                }
                if result.urls.count == limit { result.truncated = true; return result }
                result.urls.append(entry.url)
            }
        }
        return result
    }

    /// Spotlight may index files inside packages. Keep protected contents out of results, even via a symlink.
    public static func mayShow(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        return url.isFileURL && !SecureFolderService.isSessionURL(resolved) && !resolved.deletingLastPathComponent().pathComponents.contains {
            $0.lowercased().hasSuffix(".myexplorervault")
        } && !LocalTransferRecovery.isProtected(url)
    }
}

public struct ExplorerSavedSearch: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let spec: ExplorerSearchSpec
    public init(title: String, spec: ExplorerSearchSpec) {
        self.id = UUID(); self.title = title; self.spec = spec
    }
}

@MainActor
public struct ExplorerSearchLibrary {
    private let defaults: UserDefaults
    private let key = "navigation.savedSearches.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var searches: [ExplorerSavedSearch] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ExplorerSavedSearch].self, from: data)) ?? []
    }
    public func add(_ search: ExplorerSavedSearch) throws {
        defaults.set(try JSONEncoder().encode(searches + [search]), forKey: key)
    }
    public func remove(_ id: UUID) throws {
        defaults.set(try JSONEncoder().encode(searches.filter { $0.id != id }), forKey: key)
    }
}

public enum FinderTags {
    public static func read(_ url: URL) throws -> [String] {
        guard url.isFileURL, ExplorerSearchSpec.mayShow(url) else { throw CocoaError(.fileReadNoPermission) }
        let fresh = URL(fileURLWithPath: url.path)
        return try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    /// Each operation touches just the requested tag and keeps other tag names.
    public static func change(_ tag: String, add: Bool, at url: URL) throws {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 255, !value.contains(where: { $0.isNewline }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var tags = try read(url)
        let contains = tags.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
        guard contains != add else { return }
        if add { tags.append(value) } else { tags.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame } }
        let destination = NSURL(fileURLWithPath: url.path)
        try destination.setResourceValue(tags, forKey: .tagNamesKey)
    }
}
