// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import ExplorerCore

public struct AutomationCloudScope: Codable, Sendable, Equatable {
    public var connectionID: UUID
    public var prefix: String
    public init(connectionID: UUID, prefix: String = "") { self.connectionID = connectionID; self.prefix = prefix }
}
public struct AutomationGrant: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var tokenHash: String
    public var expires: Date
    public var operations: Set<String>
    public var localRoots: [String]
    public var cloudScopes: [AutomationCloudScope]
    public var recursive: Bool
    public var maximumItems: Int
    public init(id: UUID = UUID(), name: String, token: String, expires: Date, operations: Set<String>, localRoots: [String], cloudScopes: [AutomationCloudScope], recursive: Bool = false, maximumItems: Int = 1000) {
        self.id = id; self.name = name; tokenHash = Self.hash(token); self.expires = expires
        self.operations = operations; self.localRoots = localRoots; self.cloudScopes = cloudScopes
        self.recursive = recursive; self.maximumItems = min(10_000, max(1, maximumItems))
    }
    public static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func authenticates(_ token: String) -> Bool {
        let actual = Array(Self.hash(token).utf8), expected = Array(tokenHash.utf8)
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    public func permits(_ operation: String, at url: URL? = nil) -> Bool {
        guard expires > Date(), operations.contains(operation) else { return false }
        guard let url else { return true }
        if let remote = RemoteLocation.parse(url) {
            guard Self.safeKey(remote.key) else { return false }
            return cloudScopes.contains { scope in
                guard scope.connectionID == remote.connectionID, Self.safeKey(scope.prefix) else { return false }
                let prefix = scope.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return prefix.isEmpty || remote.key == prefix || remote.key.hasPrefix(prefix + "/")
            }
        }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return false }
        let path = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        // Validate both names and resolved targets. A root symlink is frozen to its current target when granting.
        return localRoots.contains { root in
            Self.contains(root, path) && Self.contains(root, resolved)
        }
    }
    public static func contains(_ root: String, _ path: String) -> Bool { path == root || (root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/")) }
    public static func safeKey(_ key: String) -> Bool {
        if key.isEmpty { return true }
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        return !key.contains("\\") && !key.contains(":") && !key.utf8.contains(0) && parts.enumerated().allSatisfy { index, value in
            value != "." && value != ".." && (!value.isEmpty || index == parts.count - 1)
        }
    }
}
public enum AutomationError: String, Error, Sendable {
    case disabled, unauthenticated, forbidden, invalidArguments, notFound, expiredPlan, changedPlan
    case conflict, busy, limitExceeded, cancelled, interrupted, unavailable, unsupported, io, needsInput
}
