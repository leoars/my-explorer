// SPDX-License-Identifier: Apache-2.0
import AppKit
import Security
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
    static func load(id: UUID) throws -> CloudCredentials {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
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
    private(set) var revision = UUID()
    var onChange: (() -> Void)?
    var clientFactory: ((CloudConnection, CloudCredentials) throws -> CloudStorageClient)?
    init(defaults: UserDefaults = .standard, useKeychain: Bool = true) {
        self.defaults = defaults; self.useKeychain = useKeychain
        connections = defaults.data(forKey: "cloudConnections").flatMap { try? JSONDecoder().decode([CloudConnection].self, from: $0) } ?? []
    }
    func client(id: UUID) async throws -> CloudStorageClient {
        guard let connection = connections.first(where: { $0.id == id }) else { throw CloudFailure(.invalidConfiguration) }
        let credentials: CloudCredentials
        if useKeychain { credentials = try await Task.detached { try CloudKeychain.load(id: id) }.value }
        else if let stored = memoryCredentials[id] { credentials = stored }
        else { throw CloudFailure(.authenticationRequired) }
        if let clientFactory { return try clientFactory(connection, credentials) }
        return try CloudStorageClient(connection: connection, credentials: credentials)
    }
    func save(_ connection: CloudConnection, credentials: CloudCredentials) async throws {
        // Validate configuration before writing either metadata or a secret.
        _ = try CloudStorageClient(connection: connection, credentials: credentials)
        if useKeychain { try await Task.detached { try CloudKeychain.save(credentials, id: connection.id) }.value }
        else { memoryCredentials[connection.id] = credentials }
        connections.removeAll { $0.id == connection.id }
        connections.append(connection)
        revision = UUID()
        defaults.set(try JSONEncoder().encode(connections), forKey: "cloudConnections")
        onChange?()
    }
    func remove(_ id: UUID) throws {
        if useKeychain { try CloudKeychain.remove(id: id) }
        memoryCredentials[id] = nil
        connections.removeAll { $0.id == id }
        revision = UUID()
        defaults.set(try? JSONEncoder().encode(connections), forKey: "cloudConnections")
        onChange?()
    }
    func title(for url: URL) -> String {
        if url.scheme == RemoteLocation.scheme && (url.host == nil || url.host == "") { return L10n.text("cloud.title") }
        guard let location = RemoteLocation.parse(url), let connection = connections.first(where: { $0.id == location.connectionID }) else { return url.lastPathComponent }
        return location.key.isEmpty ? connection.name : url.lastPathComponent
    }
    func address(for url: URL) -> String {
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
        if url.isFileURL { return try await DirectoryReader(purpose: purpose).entries(at: url, showHidden: showHidden) }
        return try await AppAutomation.files.list(url, hidden: showHidden)
    }
}
