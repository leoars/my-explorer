// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

@MainActor
struct FolderShortcutsTests {
    private func store() throws -> (FolderShortcuts, UserDefaults, String) {
        let suite = "MyExplorer.FolderShortcuts.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (FolderShortcuts(defaults: defaults), defaults, suite)
    }
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }
    private let always: (URL) -> Bool = { _ in true }

    @Test func favoritesKeepThePersonsOrderAndSurviveNewInstances() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(shortcuts.addFavorite(url("/Users/a/Projetos")))
        #expect(shortcuts.addFavorite(url("/Users/a/Fotos/")))          // trailing slash: same folder
        #expect(!shortcuts.addFavorite(url("/Users/a/Fotos")))           // already there
        #expect(shortcuts.addFavorite(url("/Users/a/Notas"), at: 0))
        #expect(!shortcuts.addFavorite(URL(string: "myexplorer-trash:///")!))
        let restored = FolderShortcuts(defaults: defaults)
        #expect(restored.favorites.map(\.path) == ["/Users/a/Notas", "/Users/a/Projetos", "/Users/a/Fotos"])
        #expect(restored.isFavorite(url("/Users/a/Projetos/")) && !restored.isFavorite(url("/Users/a")))
        restored.removeFavorite(url("/Users/a/Projetos"))
        #expect(restored.favorites.map(\.path) == ["/Users/a/Notas", "/Users/a/Fotos"])
    }

    @Test func movingAFavoriteUsesTheDropPositionBetweenRows() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        for name in ["a", "b", "c", "d"] { shortcuts.addFavorite(url("/f/" + name)) }
        shortcuts.moveFavorite(url("/f/a"), to: 3)      // dropped between c and d
        #expect(shortcuts.favorites.map(\.lastPathComponent) == ["b", "c", "a", "d"])
        shortcuts.moveFavorite(url("/f/d"), to: 0)      // dropped above the first row
        #expect(shortcuts.favorites.map(\.lastPathComponent) == ["d", "b", "c", "a"])
        shortcuts.moveFavorite(url("/f/c"), to: 99)     // dropped below the last row
        #expect(shortcuts.favorites.map(\.lastPathComponent) == ["d", "b", "a", "c"])
        shortcuts.moveFavorite(url("/f/b"), to: 1)      // dropped on its own place
        #expect(shortcuts.favorites.map(\.lastPathComponent) == ["d", "b", "a", "c"])
        shortcuts.moveFavorite(url("/f/zzz"), to: 0)    // not a favorite
        #expect(shortcuts.favorites.count == 4)
    }

    @Test func recentFoldersAreNewestFirstWithoutRepeatsFavoritesOrMissingFolders() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        for name in ["a", "b", "c", "b"] { shortcuts.recordVisit(url("/r/" + name)) }
        #expect(shortcuts.visibleRecents(exists: always).map(\.lastPathComponent) == ["b", "c", "a"])
        shortcuts.addFavorite(url("/r/c"))
        #expect(shortcuts.visibleRecents(exists: always).map(\.lastPathComponent) == ["b", "a"])
        #expect(shortcuts.visibleRecents(exists: { $0.lastPathComponent != "b" }).map(\.lastPathComponent) == ["a"])
        shortcuts.recordVisit(URL(string: "s3://bucket/folder")!)   // not on this Mac: ignored
        #expect(shortcuts.visibleRecents(exists: always).count == 2)
        shortcuts.clearRecents()
        #expect(shortcuts.visibleRecents(exists: always).isEmpty && shortcuts.favorites.count == 1)
    }

    @Test func theLimitIsAChoiceAndRaisingItShowsFoldersAlreadyKnown() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        for index in 1...25 { shortcuts.recordVisit(url("/n/\(index)")) }
        #expect(shortcuts.recentLimit == 10)
        #expect(shortcuts.visibleRecents(exists: always).map(\.lastPathComponent) == (16...25).reversed().map(String.init))
        shortcuts.recentLimit = 20
        #expect(shortcuts.visibleRecents(exists: always).count == 20)
        shortcuts.recentLimit = 7       // not one of the choices
        #expect(shortcuts.recentLimit == 10)
        defaults.set(3, forKey: FolderShortcuts.recentLimitKey)
        #expect(shortcuts.recentLimit == 10)
        #expect((defaults.array(forKey: FolderShortcuts.recentsKey) ?? []).count == 20)
    }

    @Test func lockingAProtectedFolderForgetsTheRecentFoldersInsideIt() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        for path in ["/Volumes/Cofre", "/Volumes/Cofre/Contas", "/Volumes/Cofre 2", "/Users/a"] { shortcuts.recordVisit(url(path)) }
        shortcuts.forgetRecents(inside: [url("/Volumes/Cofre")])
        #expect(shortcuts.visibleRecents(exists: always).map(\.path) == ["/Users/a", "/Volumes/Cofre 2"])
    }

    @Test func settingsDefaultToShowingBothAndDamagedValuesAreIgnored() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(shortcuts.showFavorites && shortcuts.showRecents)
        shortcuts.showRecents = false
        #expect(FolderShortcuts(defaults: defaults).showRecents == false)
        defaults.set(["/x", 42, "relative", "/x", "/y"], forKey: FolderShortcuts.favoritesKey)
        #expect(shortcuts.favorites.map(\.path) == ["/x", "/y"])
        defaults.set("not a list", forKey: FolderShortcuts.recentsKey)
        #expect(shortcuts.visibleRecents(exists: always).isEmpty)
    }

    @Test func everyChangeIsAnnounced() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        let token = NotificationCenter.default.addObserver(forName: FolderShortcuts.didChange, object: shortcuts, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        shortcuts.addFavorite(url("/a"))
        shortcuts.recordVisit(url("/b"))
        shortcuts.recordVisit(url("/b"))   // already on top: nothing changes
        shortcuts.showFavorites = false
        #expect(count == 3)
    }

    @Test func oneFolderIsOneEntryWhateverTheAccentsOrLinksOfItsPath() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let composed = "/Users/a/Or\u{E7}amentos", decomposed = "/Users/a/Orc\u{327}amentos"
        shortcuts.recordVisit(url(composed))
        shortcuts.addFavorite(url(decomposed))              // as the Finder hands it over in a drag
        #expect(shortcuts.isFavorite(url(composed)))
        #expect(shortcuts.visibleRecents(exists: always).isEmpty)
        #expect(!shortcuts.addFavorite(url(composed)))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FolderShortcuts-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let link = temporary.appendingPathComponent("link")
        let target = temporary.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        shortcuts.addFavorite(target)
        #expect(shortcuts.isFavorite(link) && !shortcuts.addFavorite(link))
    }

    @Test func droppingSeveralFoldersMovesTheKnownOnesAndAddsTheRest() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        func names() -> [String] { shortcuts.favorites.map(\.lastPathComponent) }
        for name in ["a", "b", "c", "d"] { shortcuts.addFavorite(url("/f/" + name)) }
        #expect(shortcuts.placeFavorites([url("/f/a"), url("/f/d")], at: 2))      // between b and c
        #expect(names() == ["b", "a", "d", "c"])
        #expect(shortcuts.placeFavorites([url("/f/c"), url("/f/x")], at: 0))      // one known, one new, on top
        #expect(names() == ["c", "x", "b", "a", "d"])
        #expect(!shortcuts.placeFavorites([url("/f/c")], at: 0))                  // already there
        #expect(!shortcuts.placeFavorites([URL(string: "s3://bucket/a")!], at: 0))
        #expect(shortcuts.placeFavorites([url("/f/b"), url("/f/b")], at: 99))     // repeated, at the end
        #expect(names() == ["c", "x", "a", "d", "b"])
    }

    @Test func theFavoritesHaveALimit() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        for index in 0..<FolderShortcuts.favoritesLimit { #expect(shortcuts.addFavorite(url("/l/\(index)"))) }
        #expect(!shortcuts.addFavorite(url("/l/extra")))
        #expect(!shortcuts.placeFavorites([url("/l/extra")], at: 0))
        #expect(shortcuts.placeFavorites([url("/l/5")], at: 0))                   // moving still works
        #expect(shortcuts.favorites.count == FolderShortcuts.favoritesLimit && shortcuts.favorites.first?.lastPathComponent == "5")
    }

    @Test func trashesAndProtectedPackagesAreNeverKept() {
        #expect(FolderShortcuts.isExcludedPlace(url("/Users/a/.Trash")))
        #expect(FolderShortcuts.isExcludedPlace(url("/Users/a/.Trash/old")))
        #expect(FolderShortcuts.isExcludedPlace(url("/Volumes/Disk/.Trashes/501")))
        #expect(FolderShortcuts.isExcludedPlace(url("/Users/a/Library/Mobile Documents/com~apple~CloudDocs/.Trash")))
        #expect(FolderShortcuts.isExcludedPlace(url("/Users/a/Contas.myexplorervault/inner")))
        #expect(FolderShortcuts.isExcludedPlace(URL(string: "myexplorer-trash:///")!))
        #expect(!FolderShortcuts.isExcludedPlace(url("/Users/a/Trash notes")))
        #expect(!FolderShortcuts.isExcludedPlace(url("/Users/a/Documents")))
    }

    @Test func forgettingEverythingUnderTheRootEmptiesTheRecentFolders() throws {
        let (shortcuts, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        for path in ["/a", "/b/c"] { shortcuts.recordVisit(url(path)) }
        shortcuts.forgetRecents(inside: [url("/")])
        #expect(shortcuts.visibleRecents(exists: always).isEmpty)
    }

    @Test func realFoldersOnlyCountWhenTheyExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderShortcuts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)
        #expect(FolderShortcuts.folderExists(root))
        #expect(!FolderShortcuts.folderExists(file))
        #expect(!FolderShortcuts.folderExists(root.appendingPathComponent("gone")))
    }

    @Test func groupLocationsAreRecognizedOnlyInTheirExactForm() {
        #expect(FolderShortcutGroup(url: URL(string: "myexplorer-favorites:///")!) == .favorites)
        #expect(FolderShortcutGroup(url: URL(string: "myexplorer-recents:///")!) == .recents)
        #expect(FolderShortcutGroup(url: FolderShortcutGroup.favorites.url) == .favorites)
        for value in ["myexplorer-favorites:///Users/a", "myexplorer-favorites://host/", "myexplorer-recents:///?q=1",
                      "myexplorer-recents:///#x", "myexplorer-cloud:///", "myexplorer-search:///", "file:///"] {
            #expect(FolderShortcutGroup(url: URL(string: value)!) == nil, "\(value)")
        }
        #expect(FolderShortcutGroup(url: url("/Users/a")) == nil)
        // A tab left on a group is restored there, and nothing else is let through with it.
        #expect(StartupPreferences.safeLocation(URL(string: "myexplorer-favorites:///")!) == FolderShortcutGroup.favorites.url)
        #expect(StartupPreferences.safeLocation(URL(string: "myexplorer-recents:///")!) == FolderShortcutGroup.recents.url)
        #expect(StartupPreferences.safeLocation(URL(string: "myexplorer-favorites:///etc/")!) == nil)
        #expect(StartupPreferences.safeLocation(URL(string: "myexplorer-recents://user:secret@x/")!) == nil)
        // The group is a place of its own, with no folder above it.
        #expect(FolderShortcutGroup.favorites.url.explorerIsRoot)
    }

    @Test func recentFoldersKeepTheirRowsAndNewOnesGoOnTop() {
        let a = url("/r/a"), b = url("/r/b"), c = url("/r/c"), d = url("/r/d")
        #expect(FolderShortcutGroup.stableRecents([a, b, c], shown: []) == [a, b, c])
        // b opened again: it stays where it was.
        #expect(FolderShortcutGroup.stableRecents([b, a, c], shown: [a, b, c]) == [a, b, c])
        // d is new: on top; c is no longer recent: gone.
        #expect(FolderShortcutGroup.stableRecents([d, b, a], shown: [a, b, c]) == [d, a, b])
    }

    @Test func groupEntriesAreFoldersInTheGivenOrderWithMissingOnesKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.ShortcutEntries.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let zeta = root.appendingPathComponent("Zeta"), alpha = root.appendingPathComponent("Alpha")
        try FileManager.default.createDirectory(at: zeta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        let gone = root.appendingPathComponent("Gone")
        let entries = try await FolderShortcutGroup.entries(for: [zeta, gone, alpha], missing: [gone.path])
        #expect(entries.map(\.name) == ["Zeta", "Gone", "Alpha"])
        #expect(entries.allSatisfy { $0.isDirectory && $0.canNavigate && $0.kind == "Folder" && $0.url.isFileURL })
        #expect(entries[0].modified != nil && entries[1].modified == nil && entries[2].modified != nil)
        #expect(entries.map(\.id) == [zeta.path, gone.path, alpha.path])
        #expect(FolderShortcutGroup.entry(for: url("/"), missing: true).name == "/")
    }
}
