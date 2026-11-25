// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

/// The direct build taking back the preferences macOS moved into the App Store build's container,
/// with a disposable domain and plist. The move itself is checked on the store build
/// (docs/APP-STORE.md, stage 3).
struct StorePreferencesRecoveryTests {
    private func fixture(_ contents: [String: Any]?) throws -> (source: URL, domain: String, defaults: UserDefaults, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrefsRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("container.plist")
        if let contents {
            try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0).write(to: source)
        }
        let domain = "MyExplorer.StorePreferencesRecoveryTests.\(UUID().uuidString)"
        return (source, domain, UserDefaults(suiteName: domain)!, root)
    }

    private func cleanUp(_ root: URL, _ domain: String) {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }

    @Test func emptyDomainTakesTheContainerCopyWithoutStoreOnlyKeys() throws {
        let f = try fixture(["display.fontSize": 14, "network.recentServers": ["smb://nas/share"],
                             "sandbox.folderGrants": [["path": "/"]], "sandbox.accessAnswered": true])
        defer { cleanUp(f.root, f.domain) }
        let before = try Data(contentsOf: f.source)
        #expect(StorePreferencesRecovery.recoverIfNeeded(domain: f.domain, defaults: f.defaults, source: f.source) == 2)
        let restored = UserDefaults.standard.persistentDomain(forName: f.domain) ?? [:]
        #expect(restored["display.fontSize"] as? Int == 14)
        #expect(restored["network.recentServers"] as? [String] == ["smb://nas/share"])
        #expect(restored.keys.allSatisfy { !$0.hasPrefix("sandbox.") })
        #expect(try Data(contentsOf: f.source) == before)
    }

    @Test func ownPreferencesAreNeverReplaced() throws {
        let f = try fixture(["display.fontSize": 14])
        defer { cleanUp(f.root, f.domain) }
        UserDefaults.standard.setPersistentDomain(["display.fontSize": 11], forName: f.domain)
        #expect(StorePreferencesRecovery.recoverIfNeeded(domain: f.domain, defaults: f.defaults, source: f.source) == 0)
        #expect(UserDefaults.standard.persistentDomain(forName: f.domain)?["display.fontSize"] as? Int == 11)
    }

    @Test func missingUnreadableOrStoreOnlySourcesChangeNothing() throws {
        let missing = try fixture(nil)
        defer { cleanUp(missing.root, missing.domain) }
        #expect(StorePreferencesRecovery.recoverIfNeeded(domain: missing.domain, defaults: missing.defaults, source: missing.source) == 0)
        try Data("not a plist".utf8).write(to: missing.source)
        #expect(StorePreferencesRecovery.recoverIfNeeded(domain: missing.domain, defaults: missing.defaults, source: missing.source) == 0)
        let storeOnly = try fixture(["sandbox.accessAnswered": true])
        defer { cleanUp(storeOnly.root, storeOnly.domain) }
        #expect(StorePreferencesRecovery.recoverIfNeeded(domain: storeOnly.domain, defaults: storeOnly.defaults, source: storeOnly.source) == 0)
        #expect((UserDefaults.standard.persistentDomain(forName: storeOnly.domain) ?? [:]).isEmpty)
    }

    @Test func containerPathFollowsTheIdentifier() {
        let home = URL(fileURLWithPath: "/Users/ana", isDirectory: true)
        #expect(StorePreferencesRecovery.containerPreferences(identifier: "io.github.leoars.myexplorer", home: home).path
                == "/Users/ana/Library/Containers/io.github.leoars.myexplorer/Data/Library/Preferences/io.github.leoars.myexplorer.plist")
    }
}
