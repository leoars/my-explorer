// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import Testing
@testable import ExplorerCore

struct BrowserViewPreferencesTests {
    @Test @MainActor func defaultsAreCompleteAndIndependentOfOtherPreferences() throws {
        let suite = "MyExplorer.BrowserViewTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "showFileExtensions")
        let view = BrowserViewPreferences(defaults: defaults)
        #expect(view.columnOrder == ["name", "modified", "kind", "size"])
        #expect(view.columnWidths == ["name": 390, "modified": 165, "kind": 150, "size": 95])
        #expect(view.sortKey == .name && view.sortAscending && !view.showHidden)
        #expect(view.sidebarWidth == 230 && view.previewWidth == 300)
        #expect(view.windowFrame == nil)
        #expect(view.confirmDeletion)
        #expect(!defaults.bool(forKey: "showFileExtensions"))
    }

    @Test @MainActor func allValuesSurviveNewDefaultsAndPreferencesInstances() throws {
        let suite = "MyExplorer.BrowserViewTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = BrowserViewPreferences(defaults: defaults)
        view.setColumns(order: ["size", "name", "kind", "modified"], widths: ["name": 520, "modified": 200, "kind": 175, "size": 110])
        view.confirmDeletion = false
        view.sortKey = .modified; view.sortAscending = false; view.showHidden = true
        view.sidebarWidth = 280; view.previewWidth = 420
        let frame = CGRect(x: -1400, y: 80, width: 1400, height: 900)
        view.setWindowFrame(frame)
        let restored = BrowserViewPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(restored.columnOrder == ["size", "name", "kind", "modified"])
        #expect(restored.columnWidths == ["name": 520, "modified": 200, "kind": 175, "size": 110])
        #expect(restored.sortKey == .modified && !restored.sortAscending && restored.showHidden)
        #expect(restored.sidebarWidth == 280 && restored.previewWidth == 420)
        #expect(restored.windowFrame == frame)
        #expect(!restored.confirmDeletion)
    }

    @Test @MainActor func newTabsApplySavedDefaultsBeforeFirstReadAndRetainIndependentState() async throws {
        let suite = "MyExplorer.BrowserViewTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = BrowserViewPreferences(defaults: defaults)
        view.sortKey = .modified; view.sortAscending = false; view.showHidden = true
        let reader = BrowserPreferencesRecordingReader(), workspace = ExplorerWorkspace(reader: reader)
        let first = workspace.addTab(at: URL(fileURLWithPath: "/fixture/first"), sortKey: view.sortKey,
                                     sortAscending: view.sortAscending, showHidden: view.showHidden)
        #expect(first.sortKey == .modified && !first.sortAscending && first.session.showHidden)
        let firstCalls = await reader.waitForCalls(1)
        #expect(firstCalls[0].hidden)

        view.sortKey = .size; view.sortAscending = true; view.showHidden = false
        let second = workspace.addTab(at: URL(fileURLWithPath: "/fixture/second"), sortKey: view.sortKey,
                                      sortAscending: view.sortAscending, showHidden: view.showHidden)
        let calls = await reader.waitForCalls(2)
        #expect(calls.map(\.path) == ["/fixture/first", "/fixture/second"])
        #expect(calls.map(\.hidden) == [true, false])
        #expect(second.sortKey == .size && second.sortAscending && !second.session.showHidden)
        #expect(first.sortKey == .modified && !first.sortAscending && first.session.showHidden)
        second.sortKey = .kind
        workspace.select(first.id)
        #expect(workspace.activeTab?.sortKey == .modified)
        #expect(second.sortKey == .kind)
        workspace.close(first.id); workspace.close(second.id)
    }

    @Test @MainActor func columnsNormalizeOrderMissingWidthsAndInvalidDimensionsTogether() throws {
        let suite = "MyExplorer.BrowserViewTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = BrowserViewPreferences(defaults: defaults)
        view.setColumns(order: ["size", "unknown", "size", "kind"], widths: ["name": .nan, "modified": -10, "size": 9000, "unknown": 200])
        #expect(view.columnOrder == ["size", "kind", "name", "modified"])
        #expect(view.columnWidths == ["name": 390, "modified": 75, "kind": 150, "size": 3000])
        let snapshot = try #require(defaults.dictionary(forKey: BrowserViewPreferences.Keys.columns))
        #expect(Set(snapshot.keys) == ["order", "widths"])
        view.setColumns(order: ["modified"], widths: [:])
        #expect(view.columnOrder == ["modified", "name", "kind", "size"])
        #expect(view.columnWidths == BrowserViewPreferences.defaultColumnWidths)
    }

    @Test @MainActor func corruptedStoredValuesFallBackWithoutCoercingStringsOrBooleans() throws {
        let suite = "MyExplorer.BrowserViewTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["order": ["unknown", "kind", 99, "kind"],
                      "widths": ["name": "500", "modified": true, "kind": Double.infinity, "size": 50]] as [String: Any],
                     forKey: BrowserViewPreferences.Keys.columns)
        defaults.set("invalid", forKey: BrowserViewPreferences.Keys.sortKey)
        defaults.set("false", forKey: BrowserViewPreferences.Keys.sortAscending)
        defaults.set(2, forKey: BrowserViewPreferences.Keys.showHidden)
        defaults.set(2, forKey: BrowserViewPreferences.Keys.confirmDeletion)
        defaults.set(Double.nan, forKey: BrowserViewPreferences.Keys.sidebarWidth)
        defaults.set(true, forKey: BrowserViewPreferences.Keys.previewWidth)
        defaults.set(["x": 0, "y": 0, "width": 800, "height": 600], forKey: BrowserViewPreferences.Keys.windowFrame)
        let view = BrowserViewPreferences(defaults: defaults)
        #expect(view.columnOrder == ["kind", "name", "modified", "size"])
        #expect(view.columnWidths == ["name": 390, "modified": 165, "kind": 150, "size": 75])
        #expect(view.sortKey == .name && view.sortAscending && !view.showHidden)
        #expect(view.sidebarWidth == 230 && view.previewWidth == 300)
        #expect(view.windowFrame == nil)
        #expect(view.confirmDeletion)
    }

    @Test @MainActor func panelWidthsClampAndIgnoreNonFiniteAssignments() throws {
        let suite = "MyExplorer.BrowserViewTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = BrowserViewPreferences(defaults: defaults)
        view.sidebarWidth = -1; view.previewWidth = 9999
        #expect(view.sidebarWidth == 165 && view.previewWidth == 1200)
        view.sidebarWidth = .infinity; view.previewWidth = .nan
        #expect(view.sidebarWidth == 165 && view.previewWidth == 1200)
        view.sidebarWidth = 9999; view.previewWidth = -1
        #expect(view.sidebarWidth == 1000 && view.previewWidth == 220)
    }

    @Test @MainActor func windowFrameRejectsMalformedGeometryAndCanBeRemovedIndependently() throws {
        let suite = "MyExplorer.BrowserViewTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = BrowserViewPreferences(defaults: defaults)
        let valid = CGRect(x: -100, y: 20, width: 820, height: 480)
        view.setWindowFrame(valid)
        for invalid in [CGRect(x: CGFloat.nan, y: 0, width: 900, height: 600),
                        CGRect(x: 0, y: CGFloat.infinity, width: 900, height: 600),
                        CGRect(x: 0, y: 0, width: 819, height: 600),
                        CGRect(x: 0, y: 0, width: 900, height: 479),
                        CGRect(x: 0, y: 0, width: 10001, height: 600),
                        CGRect(x: 0, y: 0, width: 900, height: -600)] {
            view.setWindowFrame(invalid)
            #expect(view.windowFrame == valid)
        }
        view.showHidden = true
        view.setWindowFrame(nil)
        #expect(view.windowFrame == nil)
        #expect(view.showHidden)
    }
}

private actor BrowserPreferencesRecordingReader: DirectoryReading {
    struct Call: Sendable { let path: String; let hidden: Bool }
    private var calls: [Call] = []
    private var waiters: [(Int, CheckedContinuation<[Call], Never>)] = []
    func entries(at url: URL, showHidden: Bool) async throws -> [FileEntry] {
        calls.append(Call(path: url.path, hidden: showHidden))
        let ready = waiters.filter { $0.0 <= calls.count }
        waiters.removeAll { $0.0 <= calls.count }
        for (_, waiter) in ready { waiter.resume(returning: calls) }
        return []
    }
    func waitForCalls(_ count: Int) async -> [Call] {
        if calls.count >= count { return calls }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
