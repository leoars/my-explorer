// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum OperationInterruptionCode: String, Codable, CaseIterable, Sendable {
    case partialOperation, recoveryRequired, cloudCancellationUncertain, deletionPartial
}

public struct OperationInterruptionNotice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let code: OperationInterruptionCode
    /// Only local recovery-directory paths are retained; source/destination and remote URLs are omitted.
    public let recoveryPaths: [String]
    public let additionalRecoveryLocations: Bool
}

/// Notices survive shutdown. Recovery notices remain until explicit acknowledgement;
/// informational notices expire after seven days. Persistence never reads file contents.
@MainActor
public final class OperationInterruptionStore {
    static let storageKey = "operationInterruptionNotices.v1"
    private struct Record: Codable {
        let id: UUID
        let code: OperationInterruptionCode
        let recoveryPaths: [String]
        let additionalRecoveryLocations: Bool
        let createdAt: Date
        var notice: OperationInterruptionNotice {
            OperationInterruptionNotice(id: id, code: code, recoveryPaths: recoveryPaths,
                                        additionalRecoveryLocations: additionalRecoveryLocations)
        }
    }
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private static let maximumRecords = 8
    private static let maximumPaths = 128
    private static let retention: TimeInterval = 7 * 24 * 60 * 60

    public init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { Date() }) {
        self.defaults = defaults; self.now = now
    }

    public var pendingNotices: [OperationInterruptionNotice] { records().map(\.notice) }

    public func append(code: OperationInterruptionCode, recoveryLocations: [URL] = []) {
        var values = records()
        if code == .recoveryRequired {
            let previous = values.filter { $0.code == .recoveryRequired }
            var seen: Set<String> = []
            let paths = (previous.flatMap(\.recoveryPaths) + recoveryLocations.compactMap(Self.safePath))
                .filter { seen.insert($0).inserted }
            values.removeAll { $0.code == .recoveryRequired }
            // A new ID prevents acknowledging an older visible notice from removing newly added paths.
            values.append(Record(id: UUID(), code: code, recoveryPaths: Array(paths.prefix(Self.maximumPaths)),
                additionalRecoveryLocations: paths.count > Self.maximumPaths || previous.contains(where: \.additionalRecoveryLocations), createdAt: now()))
        } else {
            values.removeAll { $0.code == code }
            values.append(Record(id: UUID(), code: code, recoveryPaths: [], additionalRecoveryLocations: false, createdAt: now()))
        }
        save(values)
    }

    /// Call only after the user has actually seen and acknowledged these notices.
    public func acknowledge(ids: Set<UUID>) { save(records().filter { !ids.contains($0.id) }) }

    private func save(_ values: [Record]) {
        let critical = values.filter { $0.code == .recoveryRequired }
        let informational = values.filter { $0.code != .recoveryRequired }.suffix(max(0, Self.maximumRecords - critical.count))
        let bounded = Array(informational) + critical
        if bounded.isEmpty { defaults.removeObject(forKey: Self.storageKey) }
        else if let data = try? JSONEncoder().encode(bounded) { defaults.set(data, forKey: Self.storageKey) }
    }

    private func records() -> [Record] {
        guard let data = defaults.data(forKey: Self.storageKey), data.count <= 1024 * 1024,
              let decoded = try? JSONDecoder().decode([Record].self, from: data), decoded.count <= Self.maximumRecords else { return [] }
        let date = now()
        return decoded.compactMap { record in
            let age = date.timeIntervalSince(record.createdAt)
            guard record.code == .recoveryRequired || (age.isFinite && age >= -300 && age <= Self.retention) else { return nil }
            var seen: Set<String> = []
            let paths = record.code == .recoveryRequired ? record.recoveryPaths.compactMap { path -> String? in
                guard path.hasPrefix("/") else { return nil }
                return Self.safePath(URL(fileURLWithPath: path, isDirectory: false))
            }.filter { seen.insert($0).inserted } : []
            return Record(id: record.id, code: record.code, recoveryPaths: Array(paths.prefix(Self.maximumPaths)),
                additionalRecoveryLocations: record.code == .recoveryRequired && (record.additionalRecoveryLocations || paths.count > Self.maximumPaths),
                createdAt: record.createdAt)
        }
    }

    private static func safePath(_ url: URL) -> String? {
        guard url.isFileURL, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let decoded = components.percentEncodedPath.removingPercentEncoding,
              decoded.hasPrefix("/"), !decoded.utf8.contains(0), decoded.utf8.count <= 4096 else { return nil }
        // Pure lexical normalization: do not resolve symlinks, query the filesystem or hydrate files.
        var parts: [Substring] = []
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        let path = "/" + parts.joined(separator: "/")
        return path == "/" ? nil : path
    }
}
