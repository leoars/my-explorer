// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

struct StartupPreferencesTests {
    private struct Fixture {
        let name = "MyExplorer.StartupTests.\(UUID())"
        let root: URL
        let defaults: UserDefaults
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.StartupTests.\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defaults = UserDefaults(suiteName: name)!
        }
        func clean() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test @MainActor func disabledByDefaultDoesNotRemember() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let preferences = StartupPreferences(defaults: fixture.defaults)
        #expect(!preferences.restoreLastFolder)
        preferences.remember(url: fixture.root)
        #expect(fixture.defaults.object(forKey: "lastFolderURL") == nil)
        #expect(preferences.initialURL(fallback: fixture.root, availableConnectionIDs: []) == fixture.root)
    }

    @Test @MainActor func remembersLocalFolderAcrossInstancesAndDisablingClearsIt() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let selected = fixture.root.appendingPathComponent("Ação 日本語")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let preferences = StartupPreferences(defaults: fixture.defaults)
        preferences.setRestoreLastFolder(true)
        preferences.remember(url: selected)
        let restored = StartupPreferences(defaults: fixture.defaults)
        #expect(restored.restoreLastFolder)
        #expect(restored.initialURL(fallback: fixture.root, availableConnectionIDs: []).path == selected.path)
        #expect(fixture.defaults.object(forKey: "lastFolderURL") is String)
        restored.setRestoreLastFolder(false)
        #expect(fixture.defaults.object(forKey: "lastFolderURL") == nil)
        restored.setRestoreLastFolder(true)
        #expect(restored.initialURL(fallback: fixture.root, availableConnectionIDs: []) == fixture.root)
    }

    @Test @MainActor func unavailablePathsAreDeferredButApplicationPackagesAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let preferences = StartupPreferences(defaults: fixture.defaults)
        preferences.setRestoreLastFolder(true)
        let absent = fixture.root.appendingPathComponent("does-not-exist")
        let file = fixture.root.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: file)
        // Preferences now plan locations without filesystem probes. The asynchronous
        // directory reader, not this synchronous function, rejects missing/files later.
        for url in [absent, file] {
            preferences.remember(url: url)
            #expect(preferences.initialURL(fallback: fixture.root, availableConnectionIDs: []).path == url.path)
            #expect(fixture.defaults.object(forKey: "lastFolderURL") is String)
        }
        for path in ["Example.app", "Example.APP/Contents"] {
            let app = fixture.root.appendingPathComponent(path)
            preferences.remember(url: app)
            #expect(fixture.defaults.object(forKey: "lastFolderURL") == nil)
            fixture.defaults.set(app.absoluteString, forKey: "lastFolderURL")
            #expect(preferences.initialURL(fallback: fixture.root, availableConnectionIDs: []) == fixture.root)
            #expect(fixture.defaults.object(forKey: "lastFolderURL") == nil)
        }
    }

    @Test @MainActor func remoteLocationsRequireExistingConnectionButOverviewDoesNot() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let preferences = StartupPreferences(defaults: fixture.defaults)
        preferences.setRestoreLastFolder(true)
        let id = UUID(), remote = RemoteLocation.url(connectionID: id, key: "Ação 日本語/folder/")
        preferences.remember(url: remote)
        #expect(preferences.initialURL(fallback: fixture.root, availableConnectionIDs: [id]) == remote)
        #expect(preferences.initialURL(fallback: fixture.root, availableConnectionIDs: []) == fixture.root)
        let overview = URL(string: "myexplorer-cloud:///")!
        preferences.remember(url: overview)
        #expect(preferences.initialURL(fallback: fixture.root, availableConnectionIDs: []) == overview)
        preferences.remember(url: RemoteLocation.url(connectionID: id))
        #expect(preferences.initialURL(fallback: fixture.root, availableConnectionIDs: [id]) == RemoteLocation.url(connectionID: id))
    }

    @Test @MainActor func unsafeURLsAreNeverPersistedAndInjectedValuesAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let preferences = StartupPreferences(defaults: fixture.defaults)
        preferences.setRestoreLastFolder(true)
        let id = UUID(), remote = RemoteLocation.url(connectionID: id, key: "folder/").absoluteString
        let values = ["https://example.com/?token=secret", "file://user:secret@localhost/tmp/", "file://otherhost/tmp/",
                      fixture.root.absoluteString + "?secret=value", fixture.root.absoluteString + "#secret",
                      remote + "?access_token=secret", remote + "#secret", "myexplorer-cloud://user:secret@\(id)/",
                      "myexplorer-cloud://\(id):443/", "myexplorer-cloud://\(id)/../escape/", "not-a-url", "myexplorer-cloud:///other/"]
        for value in values {
            preferences.remember(url: fixture.root)
            if let url = URL(string: value) { preferences.remember(url: url) }
            #expect(fixture.defaults.object(forKey: "lastFolderURL") == nil)
            fixture.defaults.set(value, forKey: "lastFolderURL")
            #expect(preferences.initialURL(fallback: fixture.root, availableConnectionIDs: [id]) == fixture.root)
            #expect(fixture.defaults.object(forKey: "lastFolderURL") == nil)
        }
    }

    @Test @MainActor func inaccessibleFolderIsPlannedWithoutPermissionCheck() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let restricted = fixture.root.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: false)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        let preferences = StartupPreferences(defaults: fixture.defaults)
        preferences.setRestoreLastFolder(true)
        preferences.remember(url: restricted)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        #expect(preferences.initialURL(fallback: fixture.root, availableConnectionIDs: []).path == restricted.path)
    }

    @Test func syntaxIsPureAndNormalizesOnlyLexically() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let app = fixture.root.appendingPathComponent("Target.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let alias = fixture.root.appendingPathComponent("plain-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        // A filesystem-resolving validator would reject this alias because its target is
        // an app package. The pure planner intentionally leaves that check to navigation.
        #expect(StartupPreferences.safeLocation(alias)?.path == alias.path)
        #expect(StartupPreferences.safeLocation(URL(string: "file:///tmp/one/../two/./")!)?.path == "/tmp/two")
        #expect(StartupPreferences.safeLocation(URL(string: "file:///tmp/%00bad")!) == nil)
        let uuid = UUID().uuidString
        for path in [".my-explorer-undo-" + uuid + "/old", ".my-explorer-local-journal-v1", "TemporaryItems/private", ".TemporaryItems/private"] {
            #expect(StartupPreferences.safeLocation(fixture.root.appendingPathComponent(path)) == nil)
        }
        #expect(StartupPreferences.safeLocation(fixture.root.appendingPathComponent(".my-explorer-undo-user")) != nil)
    }
}
