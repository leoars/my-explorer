// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

struct DisplayPreferencesTests {
    @Test @MainActor func adjustsAllFontsTogetherPersistsAndClampsEachArea() {
        let name = "MyExplorer.FontStepTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = DisplayPreferences(defaults: defaults)
        for (area, size) in zip(FontArea.allCases, [10.0, 14, 16, 24]) {
            preferences.setFontSize(size, for: area)
        }
        var snapshots: [[Double]] = []
        preferences.onChange = { if case .fonts = $0 {
            snapshots.append(FontArea.allCases.map { preferences.fontSize(for: $0) })
        } }
        preferences.adjustAllFontSizes(by: 1)
        #expect(snapshots == [[11, 15, 17, 24]])
        let restored = DisplayPreferences(defaults: defaults)
        #expect(FontArea.allCases.map { restored.fontSize(for: $0) } == [11, 15, 17, 24])
        preferences.adjustAllFontSizes(by: -1)
        #expect(snapshots.last == [10, 14, 16, 23])
        preferences.adjustAllFontSizes(by: -100)
        #expect(snapshots.last == [10, 10, 10, 10])
        let count = snapshots.count
        preferences.adjustAllFontSizes(by: -1)
        preferences.adjustAllFontSizes(by: .nan)
        preferences.adjustAllFontSizes(by: .infinity)
        #expect(snapshots.count == count)
        preferences.adjustAllFontSizes(by: 100)
        #expect(snapshots.last == [24, 24, 24, 24])
        preferences.adjustAllFontSizes(by: 1)
        #expect(snapshots.count == count + 1)
    }
    @Test @MainActor func extensionsDefaultToVisibleAndChoicePersists() {
        let name = "MyExplorer.DisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = DisplayPreferences(defaults: defaults)
        #expect(preferences.showFileExtensions)
        preferences.setShowFileExtensions(false)
        #expect(!DisplayPreferences(defaults: defaults).showFileExtensions)
        preferences.setShowFileExtensions(true)
        #expect(DisplayPreferences(defaults: defaults).showFileExtensions)
    }
    @Test @MainActor func previewDefaultsToHiddenPersistsAndNotifiesWithoutChangingOtherPreferences() {
        let name = "MyExplorer.PreviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = DisplayPreferences(defaults: defaults)
        #expect(!preferences.showPreviewPane)
        preferences.setShowFileExtensions(false)
        preferences.setFontSize(18, for: .files)
        var previewChanges = 0
        preferences.onChange = { if case .preview = $0 { previewChanges += 1 } }
        preferences.setShowPreviewPane(true)
        let restored = DisplayPreferences(defaults: defaults)
        #expect(restored.showPreviewPane)
        #expect(!restored.showFileExtensions)
        #expect(restored.fontSize(for: .files) == 18)
        preferences.setShowPreviewPane(false)
        #expect(!DisplayPreferences(defaults: defaults).showPreviewPane)
        #expect(previewChanges == 2)
    }
    @Test func hidesOnlyLastExtensionWithoutChangingIdentity() {
        for (name, expected) in [("report.pdf", "report"), ("archive.tar.gz", "archive.tar"),
                                 (".gitignore", ".gitignore"), (".config.json", ".config"),
                                 ("README", "README"), ("final.", "final."), ("資料.txt", "資料")] {
            let entry = FileEntry(url: URL(fileURLWithPath: "/fixture/\(name)"), name: name, isDirectory: false)
            #expect(entry.displayName(showExtensions: false) == expected)
            #expect(entry.displayName(showExtensions: true) == name)
            #expect(entry.id == "/fixture/\(name)")
        }
        let folder = FileEntry(url: URL(fileURLWithPath: "/folder.v2"), name: "folder.v2", isDirectory: true)
        #expect(folder.displayName(showExtensions: false) == "folder.v2")
        let app = FileEntry(url: URL(fileURLWithPath: "/Example.app"), name: "Example.app", isDirectory: true, isPackage: true)
        #expect(app.displayName(showExtensions: false) == "Example")
    }
    @Test @MainActor func fontAreasAreIndependentPersistedAndBounded() {
        let name = "MyExplorer.FontTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = DisplayPreferences(defaults: defaults)
        preferences.setFontSize(20, for: .tree)
        preferences.setFontSize(16, for: .files)
        let restored = DisplayPreferences(defaults: defaults)
        #expect(restored.fontSize(for: .tree) == 20)
        #expect(restored.fontSize(for: .files) == 16)
        #expect(restored.fontSize(for: .bars) == 14)
        #expect(restored.fontSize(for: .menus) == 16)
        preferences.setFontSize(100, for: .bars)
        #expect(preferences.fontSize(for: .bars) == 24)
        preferences.resetFonts()
        for area in FontArea.allCases { #expect(preferences.fontSize(for: area) == area.defaultSize) }
    }
}
