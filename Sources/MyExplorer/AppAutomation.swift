// SPDX-License-Identifier: Apache-2.0
import AppKit
import Security
import ExplorerCore
import ExplorerAutomation
import ExplorerLocalization

@MainActor
final class AppAutomation {
    static let shared = AppAutomation()
    nonisolated static let files = SharedFileOperations { try await CloudAccounts.shared.client(id: $0) }
    nonisolated static let deletion = StorageDeletionService(clientFactory: { try await CloudAccounts.shared.client(id: $0) }, trashLibrary: .shared)
    private(set) var service: AutomationService?
    private var broker: AutomationBroker?
    private var credentials: [UUID: (CloudCredentials, Date)] = [:]
    private var authenticationWindow: CloudSettingsController?
    var onLanguage: ((AppLanguage) -> Void)?
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MyExplorer/Automation", isDirectory: true)
    let socketURL = URL(fileURLWithPath: "/tmp/myexplorer-\(getuid())/automation.sock")
    private var effectiveDirectory: URL?
    private var effectiveSocket: URL?

    func start(directory override: URL? = nil, socketURL socketOverride: URL? = nil) async throws {
        guard service == nil else { return }
        let environment = AutomationEnvironment(connections: { await CloudAccounts.shared.connections }, revision: { await CloudAccounts.shared.revision.uuidString },
            authenticate: { connection in await self.authenticate(connection) },
            authenticated: { id in await self.hasCredentials(id) },
            apply: { connection in try await self.apply(connection) },
            preferences: { await self.preferences() }, updatePreferences: { args in try await self.updatePreferences(args) })
        let service = try AutomationService(files: Self.files, deletion: Self.deletion, environment: environment, stateURL: (override ?? directory).appendingPathComponent("state.json"))
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/myexplorer-cli")
        let broker = AutomationBroker(socketURL: socketOverride ?? socketURL, helperURL: helper, handler: { await service.handle($0) })
        try broker.start()
        effectiveDirectory = override ?? directory; effectiveSocket = socketOverride ?? socketURL
        self.service = service; self.broker = broker
    }
    func shutdown() async {
        broker?.stop(); await service?.shutdown()
        broker = nil; service = nil; credentials.removeAll()
    }
    private func hasCredentials(_ id: UUID) -> Bool {
        credentials = credentials.filter { $0.value.1 > Date() }
        return credentials[id] != nil
    }
    private func authenticate(_ connection: CloudConnection) {
        guard !hasCredentials(connection.id) else { return }
        if let window = authenticationWindow, window.automationConnectionID == connection.id { window.showWindow(nil); return }
        authenticationWindow?.close()
        let controller = CloudSettingsController(draft: connection)
        controller.onAuthenticate = { [weak self] connection, credentials in
            self?.credentials[connection.id] = (credentials, Date().addingTimeInterval(900))
        }
        authenticationWindow = controller
        controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func apply(_ connection: CloudConnection) async throws {
        guard hasCredentials(connection.id), let value = credentials[connection.id] else { throw AutomationError.needsInput }
        try await CloudAccounts.shared.save(connection, credentials: value.0)
        credentials[connection.id] = nil
    }
    private func preferences() -> JSONValue {
        .object(["language": .string(L10n.preferences.selection.rawValue), "showFileExtensions": .bool(ExplorerStyle.preferences.showFileExtensions),
                 "fonts": .object(Dictionary(uniqueKeysWithValues: FontArea.allCases.map { ($0.rawValue, .number(ExplorerStyle.preferences.fontSize(for: $0))) }))])
    }
    private func updatePreferences(_ args: JSONValue) throws -> JSONValue {
        if let language = args["language"]?.stringValue, let selection = AppLanguage(rawValue: language) { onLanguage?(selection) }
        if let visible = args["showFileExtensions"]?.boolValue { ExplorerStyle.preferences.setShowFileExtensions(visible) }
        if let fonts = args["fonts"]?.objectValue {
            for (key, value) in fonts { if let area = FontArea(rawValue: key), case .number(let size) = value { ExplorerStyle.preferences.setFontSize(size, for: area) } }
        }
        return preferences()
    }
    func createAccess(name: String, root: URL?, connection: CloudConnection?, prefix: String, operations: Set<String>, recursive: Bool) async throws -> URL {
        guard let service, !name.isEmpty, !operations.isEmpty, AutomationGrant.safeKey(prefix) else { throw AutomationError.invalidArguments }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AutomationError.io }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let grant = AutomationGrant(name: name, token: token, expires: Date().addingTimeInterval(86400), operations: operations,
            localRoots: root.map { [$0.resolvingSymlinksInPath().standardizedFileURL.path] } ?? [],
            cloudScopes: connection.map { [AutomationCloudScope(connectionID: $0.id, prefix: prefix)] } ?? [], recursive: recursive)
        let clientDirectory = (effectiveDirectory ?? directory).appendingPathComponent("clients/\(grant.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: clientDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tokenURL = clientDirectory.appendingPathComponent("access.token"), configURL = clientDirectory.appendingPathComponent("client.json")
        try Data(token.utf8).write(to: tokenURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        let config: [String: Any] = ["socketPath": (effectiveSocket ?? socketURL).path, "clientID": grant.id.uuidString, "tokenFile": tokenURL.path]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        let mcp: [String: Any] = ["mcpServers": ["my-explorer": ["command": Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/myexplorer-cli").path,
            "args": ["mcp", "--config", configURL.path]]]]
        try JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys]).write(to: clientDirectory.appendingPathComponent("mcp.json"))
        try await service.grant(grant)
        return configURL
    }
}
