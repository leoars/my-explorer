// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum GitStatusKind: String, Equatable, Sendable {
    case clean, modified, added, deleted, renamed, untracked, ignored, conflicted
    fileprivate var priority: Int {
        switch self {
        case .conflicted: 80
        case .modified: 70
        case .deleted: 60
        case .renamed: 50
        case .added: 40
        case .untracked: 30
        case .clean: 20
        case .ignored: 10
        }
    }
}

public struct GitFileStatus: Equatable, Sendable {
    public let kind: GitStatusKind
    public let staged: Bool
    public let unstaged: Bool
    public let originalPath: String?
    public init(kind: GitStatusKind, staged: Bool = false, unstaged: Bool = false, originalPath: String? = nil) {
        self.kind = kind; self.staged = staged; self.unstaged = unstaged; self.originalPath = originalPath
    }
}

/// Paths are repository-relative and retain Git's spelling. No filesystem reads occur in this model.
public struct GitStatusSnapshot: Sendable {
    public let rootURL: URL
    public let branch: String?
    public let isDetached: Bool
    public let isUnborn: Bool
    public let headOID: String?
    public let entries: [String: GitFileStatus]
    public let trackedPaths: Set<String>
    private let explicitDirectories: Set<String>
    private let directoryStatuses: [String: GitFileStatus]

    fileprivate init(rootURL: URL, branch: String?, isDetached: Bool, isUnborn: Bool, headOID: String?,
                     entries: [String: GitFileStatus], trackedPaths: Set<String>, explicitDirectories: Set<String>) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.branch = branch; self.isDetached = isDetached; self.isUnborn = isUnborn; self.headOID = headOID
        self.entries = entries; self.trackedPaths = trackedPaths; self.explicitDirectories = explicitDirectories
        var aggregated: [String: GitFileStatus] = [:]
        func include(_ status: GitFileStatus, at path: String, directory: Bool) throws {
            try Task.checkCancellation()
            // An ignored child never makes its parent ignored: only an explicit ! directory does.
            guard status.kind != .ignored else { return }
            var parts = path.split(separator: "/").map(String.init)
            if !directory { parts.removeLast() }
            while true {
                let key = parts.joined(separator: "/")
                let old = aggregated[key]
                guard old != nil || aggregated.count < 100_000 else { throw GitStatusParseError.limitExceeded }
                let kind = (old?.kind.priority ?? -1) > status.kind.priority ? old!.kind : status.kind
                aggregated[key] = GitFileStatus(kind: kind, staged: (old?.staged ?? false) || status.staged,
                                                unstaged: (old?.unstaged ?? false) || status.unstaged)
                if parts.isEmpty { break }
                parts.removeLast()
            }
        }
        for path in trackedPaths { try include(GitFileStatus(kind: .clean), at: path, directory: false) }
        for (path, status) in entries {
            try include(status, at: path, directory: explicitDirectories.contains(path))
            if status.kind == .renamed, let original = status.originalPath { try include(status, at: original, directory: false) }
        }
        directoryStatuses = aggregated
    }

    /// Unknown paths are not presumed clean; clean requires the separate ls-files inventory.
    public func status(for url: URL, isDirectory: Bool) -> GitFileStatus? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.query == nil, url.fragment == nil else { return nil }
        let root = rootURL.pathComponents, candidate = url.standardizedFileURL.pathComponents
        guard candidate.count >= root.count, Array(candidate.prefix(root.count)) == root else { return nil }
        let relative = Array(candidate.dropFirst(root.count))
        guard !relative.contains(where: { $0.lowercased() == ".git" }) else { return nil }
        let path = relative.joined(separator: "/")
        if isDirectory, let aggregate = directoryStatuses[path] { return aggregate }
        if let exact = entries[path] { return exact }
        if !isDirectory, trackedPaths.contains(path) { return GitFileStatus(kind: .clean) }
        var parts = relative
        while !parts.isEmpty {
            parts.removeLast()
            let ancestor = parts.joined(separator: "/")
            if explicitDirectories.contains(ancestor), let status = entries[ancestor],
               status.kind == .ignored || status.kind == .untracked { return status }
        }
        return nil
    }
}

public enum GitStatusParseError: Error, Equatable, Sendable { case malformed, limitExceeded }

/// Parser for git status --porcelain=v2 --branch -z. Unknown headers are deliberately ignored.
public enum GitStatusParser {
    private static let maximumBytes = 16 * 1024 * 1024
    private static let maximumPaths = 100_000

    public static func parse(_ data: Data, rootURL: URL, trackedPaths: Set<String> = []) throws -> GitStatusSnapshot {
        guard rootURL.isFileURL, rootURL.host == nil || rootURL.host == "" || rootURL.host?.lowercased() == "localhost",
              rootURL.query == nil, rootURL.fragment == nil else { throw GitStatusParseError.malformed }
        let records = try records(data)
        var entries: [String: GitFileStatus] = [:], directories: Set<String> = [], branch: String?, headOID: String?
        var detached = false, unborn = false, index = 0
        while index < records.count {
            try Task.checkCancellation()
            let record = records[index]; index += 1
            if record.hasPrefix("# ") {
                if record.hasPrefix("# branch.head ") {
                    let value = String(record.dropFirst(14))
                    guard !value.isEmpty else { throw GitStatusParseError.malformed }
                    detached = value == "(detached)"; branch = detached ? nil : value
                } else if record.hasPrefix("# branch.oid ") {
                    let value = String(record.dropFirst(13))
                    guard value == "(initial)" || validOID(value) else { throw GitStatusParseError.malformed }
                    unborn = value == "(initial)"; headOID = unborn ? nil : value
                }
                continue
            }
            let path: String, status: GitFileStatus, directory: Bool
            if record.hasPrefix("? ") || record.hasPrefix("! ") {
                let raw = String(record.dropFirst(2)); directory = raw.hasSuffix("/")
                path = try checkedPath(raw, allowDirectorySuffix: true)
                status = GitFileStatus(kind: record.first == "?" ? .untracked : .ignored)
            } else {
                let tag = record.first
                let count = tag == "1" ? 8 : tag == "2" ? 9 : tag == "u" ? 10 : 0
                guard count > 0 else { throw GitStatusParseError.malformed }
                let fields = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == count + 1, fields[0] == String(tag!), validXY(fields[1]), validSubmodule(fields[2]) else {
                    throw GitStatusParseError.malformed
                }
                let modes = tag == "u" ? 3...6 : 3...5
                let hashes = tag == "u" ? 7...9 : 6...7
                guard modes.allSatisfy({ fields[$0].count == 6 && fields[$0].allSatisfy({ "01234567".contains($0) }) }),
                      hashes.allSatisfy({ validOID(fields[$0]) }) else { throw GitStatusParseError.malformed }
                path = try checkedPath(fields[count]); directory = false
                var original: String?
                if tag == "2" {
                    guard index < records.count, let scoreKind = fields[8].first, scoreKind == "R" || scoreKind == "C",
                          let score = Int(fields[8].dropFirst()), (0...100).contains(score) else { throw GitStatusParseError.malformed }
                    original = try checkedPath(records[index]); index += 1
                }
                let xy = Array(fields[1]), submoduleChanged = fields[2] != "N..." && fields[2] != "S..."
                let kind: GitStatusKind = tag == "u" ? .conflicted : xy.contains("R") ? .renamed :
                    xy.contains("D") ? .deleted : xy.contains("A") || xy.contains("C") ? .added :
                    xy.contains("M") || xy.contains("T") || submoduleChanged ? .modified : .clean
                status = GitFileStatus(kind: kind, staged: tag != "u" && xy[0] != ".",
                                       unstaged: tag == "u" || xy[1] != "." || submoduleChanged, originalPath: original)
            }
            guard entries[path] == nil else { throw GitStatusParseError.malformed }
            entries[path] = status
            if directory { directories.insert(path) }
            guard entries.count <= maximumPaths else { throw GitStatusParseError.limitExceeded }
        }
        var tracked: Set<String> = []
        guard trackedPaths.count <= maximumPaths else { throw GitStatusParseError.limitExceeded }
        for path in trackedPaths { try Task.checkCancellation(); tracked.insert(try checkedPath(path)) }
        return try GitStatusSnapshot(rootURL: rootURL, branch: branch, isDetached: detached, isUnborn: unborn, headOID: headOID,
                                 entries: entries, trackedPaths: tracked, explicitDirectories: directories)
    }

    public static func trackedPaths(from data: Data) throws -> Set<String> {
        let values = try records(data)
        guard values.count <= maximumPaths else { throw GitStatusParseError.limitExceeded }
        return try Set(values.map { try checkedPath($0) })
    }

    private static func records(_ data: Data) throws -> [String] {
        guard data.count <= maximumBytes else { throw GitStatusParseError.limitExceeded }
        if data.isEmpty { return [] }
        guard data.last == 0 else { throw GitStatusParseError.malformed }
        let pieces = data.split(separator: 0, maxSplits: maximumPaths * 2 + 128, omittingEmptySubsequences: false)
        guard pieces.count <= maximumPaths * 2 + 128 else { throw GitStatusParseError.limitExceeded }
        return try pieces.dropLast().map {
            try Task.checkCancellation()
            guard !$0.isEmpty, let value = String(data: Data($0), encoding: .utf8) else { throw GitStatusParseError.malformed }
            return value
        }
    }
    private static func checkedPath(_ input: String, allowDirectorySuffix: Bool = false) throws -> String {
        let value = allowDirectorySuffix && input.hasSuffix("/") ? String(input.dropLast()) : input
        guard value.utf8.count <= 16_384 else { throw GitStatusParseError.limitExceeded }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 128 else { throw GitStatusParseError.limitExceeded }
        guard !parts.isEmpty, !value.utf8.contains(0), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw GitStatusParseError.malformed
        }
        return value
    }
    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
    }
    private static func validXY(_ value: String) -> Bool { value.count == 2 && value.allSatisfy { ".MTADRCU".contains($0) } }
    private static func validSubmodule(_ value: String) -> Bool {
        if value == "N..." { return true }
        let chars = Array(value)
        return chars.count == 4 && chars[0] == "S" && ".C".contains(chars[1]) && ".M".contains(chars[2]) && ".U".contains(chars[3])
    }
}
