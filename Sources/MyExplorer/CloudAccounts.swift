// SPDX-License-Identifier: Apache-2.0
import AppKit
import Security
import LocalAuthentication
import ExplorerCore

private enum CloudKeychain {
    static let service = "io.github.leoars.myexplorer.cloud"
    static func save(_ credentials: CloudCredentials, id: UUID) throws {
        let values = ["accessKeyID": credentials.accessKeyID, "secretAccessKey": credentials.secretAccessKey,
                      "sessionToken": credentials.sessionToken, "sasToken": credentials.sasToken,
                      "accessToken": credentials.accessToken].compactMapValues { $0 }
        let data = try JSONSerialization.data(withJSONObject: values)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CloudFailure(.io) }
        } else if status != errSecSuccess { throw CloudFailure(.io) }
    }
    static func load(id: UUID, allowInteraction: Bool = true) throws -> CloudCredentials {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw CloudFailure(.notFound) }
        guard status == errSecSuccess,
              let data = result as? Data,
              let values = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw CloudFailure(.authenticationRequired)
        }
        return CloudCredentials(accessKeyID: values["accessKeyID"], secretAccessKey: values["secretAccessKey"],
            sessionToken: values["sessionToken"], sasToken: values["sasToken"], accessToken: values["accessToken"])
    }
    static func remove(id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CloudFailure(.io) }
    }
}

@MainActor
final class CloudAccounts {
    static var shared = CloudAccounts()
    private let defaults: UserDefaults
    private let useKeychain: Bool
    private var memoryCredentials: [UUID: CloudCredentials] = [:]
    private(set) var connections: [CloudConnection]
    /// Old IDs are used only to restore UI navigation. They never grant cloud access.
    private(set) var connectionAliases: [UUID: UUID] = [:]
    private(set) var revision = UUID()
    var onChange: (() -> Void)?
    var clientFactory: ((CloudConnection, CloudCredentials) throws -> CloudStorageClient)?
    init(defaults: UserDefaults = .standard, useKeychain: Bool = true) {
        self.defaults = defaults; self.useKeychain = useKeychain
        connections = defaults.data(forKey: "cloudConnections").flatMap { try? JSONDecoder().decode([CloudConnection].self, from: $0) } ?? []
        for (key, value) in defaults.dictionary(forKey: "cloudConnectionAliases") ?? [:] {
            if let id = UUID(uuidString: key), let target = value as? String, let canonical = UUID(uuidString: target) {
                connectionAliases[id] = canonical
            }
        }
    }
    func client(id: UUID) async throws -> CloudStorageClient {
        guard let connection = connections.first(where: { $0.id == id }) else { throw CloudFailure(.invalidConfiguration) }
        let credentials: CloudCredentials
        if useKeychain {
            do { credentials = try await Task.detached { try CloudKeychain.load(id: id) }.value }
            catch let error as CloudFailure where error.reason == .notFound { throw CloudFailure(.authenticationRequired) }
        }
        else if let stored = memoryCredentials[id] { credentials = stored }
        else { throw CloudFailure(.authenticationRequired) }
        if let clientFactory { return try clientFactory(connection, credentials) }
        return try CloudStorageClient(connection: connection, credentials: credentials)
    }
    private func storedCredentials(_ id: UUID, allowInteraction: Bool) throws -> CloudCredentials {
        if useKeychain { return try CloudKeychain.load(id: id, allowInteraction: allowInteraction) }
        guard let saved = memoryCredentials[id] else { throw CloudFailure(.notFound) }
        return saved
    }

    private static func sameS3Destination(_ lhs: CloudConnection, _ rhs: CloudConnection) -> Bool {
        lhs.provider == .s3 && rhs.provider == .s3 && lhs.bucket == rhs.bucket &&
            (lhs.region ?? "us-east-1") == (rhs.region ?? "us-east-1")
    }

    private static func sameS3Credentials(_ lhs: CloudCredentials, _ rhs: CloudCredentials) -> Bool {
        guard let id = lhs.accessKeyID, !id.isEmpty, let secret = lhs.secretAccessKey, !secret.isEmpty,
              let otherID = rhs.accessKeyID, let otherSecret = rhs.secretAccessKey else { return false }
        return id.utf8.elementsEqual(otherID.utf8) && secret.utf8.elementsEqual(otherSecret.utf8) &&
            (lhs.sessionToken ?? "").utf8.elementsEqual((rhs.sessionToken ?? "").utf8)
    }

    /// Keep identity lookup and publication in one MainActor turn, including concurrent Connect requests.
    @discardableResult
    func save(_ connection: CloudConnection, credentials: CloudCredentials, reuseExistingS3: Bool = false) async throws -> UUID {
        _ = try CloudStorageClient(connection: connection, credentials: credentials)
        if reuseExistingS3 {
            var unavailable: Error?
            for candidate in connections where candidate.id != connection.id && Self.sameS3Destination(connection, candidate) {
                do {
                    let saved = try storedCredentials(candidate.id, allowInteraction: true)
                    if Self.sameS3Credentials(saved, credentials) { return candidate.id }
                } catch let error as CloudFailure where error.reason == .notFound { continue }
                catch { unavailable = error }
            }
            if let unavailable { throw unavailable }
        }
        var updated = connections
        if let index = updated.firstIndex(where: { $0.id == connection.id }) { updated[index] = connection }
        else { updated.append(connection) }
        let data = try JSONEncoder().encode(updated)
        if useKeychain { try CloudKeychain.save(credentials, id: connection.id) }
        else { memoryCredentials[connection.id] = credentials }
        if connectionAliases.removeValue(forKey: connection.id) != nil { persistAliases() }
        publish(updated, data: data)
        return connection.id
    }

    /// Compare credentials only for repeated S3 destinations. A locked Keychain defers their migration.
    @discardableResult
    func consolidateDuplicateS3Connections(allowInteraction: Bool = false) -> [UUID: UUID] {
        var aliases: [UUID: UUID] = [:]
        var keys: [UUID: CloudCredentials] = [:]
        var kept: [CloudConnection] = []
        for connection in connections {
            let candidates = kept.filter { Self.sameS3Destination($0, connection) }
            if !candidates.isEmpty, let current = try? storedCredentials(connection.id, allowInteraction: allowInteraction) {
                let match = candidates.first { candidate in
                    if keys[candidate.id] == nil {
                        keys[candidate.id] = try? storedCredentials(candidate.id, allowInteraction: allowInteraction)
                    }
                    return keys[candidate.id].map { Self.sameS3Credentials($0, current) } ?? false
                }
                if let match { aliases[connection.id] = match.id; continue }
                keys[connection.id] = current
            }
            kept.append(connection)
        }
        if !aliases.isEmpty, let data = try? JSONEncoder().encode(kept) {
            connectionAliases = connectionAliases.mapValues { aliases[$0] ?? $0 }
            connectionAliases.merge(aliases) { _, new in new }
            persistAliases()
            let pending = (defaults.stringArray(forKey: "cloudKeychainCleanup") ?? []) + aliases.keys.map(\.uuidString)
            defaults.set(pending, forKey: "cloudKeychainCleanup")
            publish(kept, data: data)
        }
        finishCredentialCleanup()
        return connectionAliases
    }

    private func persistAliases() {
        defaults.set(Dictionary(uniqueKeysWithValues: connectionAliases.map { ($0.key.uuidString, $0.value.uuidString) }),
                     forKey: "cloudConnectionAliases")
    }

    private func publish(_ updated: [CloudConnection], data: Data) {
        defaults.set(data, forKey: "cloudConnections")
        connections = updated
        revision = UUID()
        onChange?()
    }

    private func finishCredentialCleanup() {
        guard let pending = defaults.stringArray(forKey: "cloudKeychainCleanup"), !pending.isEmpty else { return }
        let remainder = pending.filter { raw in
            guard let id = UUID(uuidString: raw), !connections.contains(where: { $0.id == id }) else { return false }
            do {
                if useKeychain { try CloudKeychain.remove(id: id) }
                memoryCredentials[id] = nil
                return false
            } catch { return true }
        }
        if remainder.isEmpty { defaults.removeObject(forKey: "cloudKeychainCleanup") }
        else { defaults.set(remainder, forKey: "cloudKeychainCleanup") }
    }

    func remove(_ id: UUID) throws {
        let updated = connections.filter { $0.id != id }
        let data = try JSONEncoder().encode(updated)
        if useKeychain { try CloudKeychain.remove(id: id) }
        memoryCredentials[id] = nil
        connectionAliases = connectionAliases.filter { $0.key != id && $0.value != id }
        persistAliases()
        publish(updated, data: data)
    }
    func title(for url: URL) -> String {
        if let group = FolderShortcutGroup(url: url) { return group.title }
        if url.scheme == RemoteLocation.scheme && (url.host == nil || url.host == "") { return L10n.text("cloud.title") }
        guard let location = RemoteLocation.parse(url), let connection = connections.first(where: { $0.id == location.connectionID }) else { return url.lastPathComponent }
        return location.key.isEmpty ? connection.name : url.lastPathComponent
    }
    func address(for url: URL) -> String {
        if let group = FolderShortcutGroup(url: url) { return group.title }
        if url.scheme == RemoteLocation.scheme && (url.host == nil || url.host == "") { return L10n.text("cloud.title") }
        guard let location = RemoteLocation.parse(url), let connection = connections.first(where: { $0.id == location.connectionID }) else { return url.isFileURL ? url.path : url.absoluteString }
        let base: String
        switch connection.provider {
        case .s3: base = "s3://\(connection.bucket)"
        case .azure: base = "azure://\(connection.account ?? "")/\(connection.bucket)"
        case .gcs: base = "gs://\(connection.bucket)"
        }
        return base + "/" + location.key
    }
    func resolve(_ text: String) -> URL? {
        for connection in connections {
            let root = address(for: RemoteLocation.url(connectionID: connection.id))
            if text == String(root.dropLast()) { return RemoteLocation.url(connectionID: connection.id) }
            if text.hasPrefix(root) { return RemoteLocation.url(connectionID: connection.id, key: String(text.dropFirst(root.count))) }
        }
        return nil
    }
}

struct ApplicationDirectoryReader: DirectoryReading {
    let purpose: DirectoryReader.Purpose
    init() { self.init(purpose: .foreground) }
    init(purpose: DirectoryReader.Purpose) { self.purpose = purpose }

    func entries(at url: URL, showHidden: Bool) async throws -> [FileEntry] {
        if url.scheme == RemoteLocation.scheme && (url.host == nil || url.host == "") {
            return await CloudAccounts.shared.connections.map { connection in
                FileEntry(url: RemoteLocation.url(connectionID: connection.id), name: connection.name, isDirectory: true)
            }
        }
        if let group = FolderShortcutGroup(url: url) { return try await Self.entries(of: group) }
        if url.isFileURL { return try await DirectoryReader(purpose: purpose).entries(at: url, showHidden: showHidden) }
        return try await AppAutomation.files.list(url, hidden: showHidden)
    }

    /// The folders of the favorites or of the recent folders, in the tree's order: the favorites
    /// as the person put them, the recent folders as the tree shows them. A favorite that is gone
    /// stays, as in the tree; a recent folder that is gone is not one any more.
    @MainActor
    private static func folders(of group: FolderShortcutGroup) -> (folders: [URL], missing: Set<String>) {
        let shortcuts = ExplorerStyle.folderShortcuts, presence = FolderPresence.shared
        switch group {
        case .favorites:
            let favorites = shortcuts.favorites
            return (favorites, Set(favorites.filter { !presence.exists($0) }.map(\.path)))
        case .recents:
            let recents = shortcuts.visibleRecents(exists: presence.exists)
            return (FolderShortcutGroup.stableRecents(recents, shown: FolderTreeController.recentsAsShown ?? []), [])
        }
    }

    private static func entries(of group: FolderShortcutGroup) async throws -> [FileEntry] {
        let (folders, missing) = await folders(of: group)
        return try await FolderShortcutGroup.entries(for: folders, missing: missing)
    }
}

extension FolderShortcutGroup {
    /// The group's name in the person's language, as in the tree.
    @MainActor var title: String { L10n.text(self == .favorites ? "tree.favorites" : "tree.recents") }
}
