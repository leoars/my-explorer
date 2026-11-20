// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

@MainActor
struct SessionPreferencesTests {
    private func isolated(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "MyExplorer.SessionTests.\(UUID())"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        try body(suite)
    }
    private var fallback: URL { URL(fileURLWithPath: "/syntactic/fallback", isDirectory: true) }

    @Test func optInIsIndependentAndDisablingErasesSnapshot() throws {
        try isolated { defaults in
            let startup = StartupPreferences(defaults: defaults), sessions = SessionPreferences(defaults: defaults)
            startup.setRestoreLastFolder(true)
            #expect(!sessions.restoreTabs)
            sessions.remember(tabs: [SessionTabState(url: fallback)], activeIndex: 0)
            #expect(defaults.data(forKey: "sessionSnapshot") == nil)
            #expect(sessions.restorationPlan(fallback: fallback, availableConnectionIDs: []) == nil)
            sessions.setRestoreTabs(true)
            sessions.remember(tabs: [SessionTabState(url: fallback)], activeIndex: 0)
            #expect(defaults.data(forKey: "sessionSnapshot") != nil)
            sessions.setRestoreTabs(false)
            #expect(defaults.object(forKey: "sessionSnapshot") == nil)
            #expect(startup.restoreLastFolder)
            sessions.setRestoreTabs(true)
            #expect(sessions.restorationPlan(fallback: fallback, availableConnectionIDs: []) == nil)
        }
    }

    @Test func roundTripPreservesOrderActiveTabAndPresentation() throws {
        try isolated { defaults in
            let preferences = SessionPreferences(defaults: defaults)
            preferences.setRestoreTabs(true)
            let tabs = [
                SessionTabState(url: URL(fileURLWithPath: "/not-mounted/Ação 日本語", isDirectory: true), sortKey: .size, sortAscending: false, showHidden: true),
                SessionTabState(url: URL(fileURLWithPath: "/not-mounted/Other", isDirectory: true), sortKey: .modified),
                SessionTabState(url: URL(string: "myexplorer-cloud:///")!, sortKey: .kind, sortAscending: false)
            ]
            preferences.remember(tabs: tabs, activeIndex: 1)
            let plan = try #require(SessionPreferences(defaults: defaults).restorationPlan(fallback: fallback, availableConnectionIDs: []))
            #expect(plan.tabs == tabs)
            #expect(plan.activeIndex == 1)
            #expect(plan.fallbackReasons.isEmpty)
        }
    }

    @Test func maximumTabsKeepsActiveTabAndRelativeOrder() throws {
        try isolated { defaults in
            let preferences = SessionPreferences(defaults: defaults)
            preferences.setRestoreTabs(true)
            let tabs = (0..<50).map { SessionTabState(url: URL(fileURLWithPath: "/tabs/\($0)", isDirectory: true)) }
            preferences.remember(tabs: tabs, activeIndex: 40)
            let plan = try #require(preferences.restorationPlan(fallback: fallback, availableConnectionIDs: []))
            #expect(plan.tabs.count == 32)
            #expect(plan.tabs.map(\.url) == Array(tabs[9...40]).map(\.url))
            #expect(plan.activeIndex == 31)
            #expect(plan.tabs[plan.activeIndex].url == tabs[40].url)
            preferences.remember(tabs: tabs, activeIndex: -999)
            #expect(preferences.restorationPlan(fallback: fallback, availableConnectionIDs: [])?.activeIndex == 0)
            preferences.remember(tabs: tabs, activeIndex: Int.max)
            #expect(preferences.restorationPlan(fallback: fallback, availableConnectionIDs: [])?.tabs.last?.url == tabs.last?.url)
        }
    }

    @Test func unsafeLocationsBecomeSecretFreePlaceholdersAtTheirOriginalIndex() throws {
        try isolated { defaults in
            let preferences = SessionPreferences(defaults: defaults)
            preferences.setRestoreTabs(true)
            let unsafe = URL(string: "file://user:super-secret@localhost/private?token=secret")!
            preferences.remember(tabs: [SessionTabState(url: fallback), SessionTabState(url: unsafe, sortKey: .size, sortAscending: false)], activeIndex: 1)
            let encoded = String(decoding: try #require(defaults.data(forKey: "sessionSnapshot")), as: UTF8.self)
            #expect(!encoded.contains("super-secret"))
            #expect(!encoded.contains("token"))
            let plan = try #require(preferences.restorationPlan(fallback: fallback, availableConnectionIDs: []))
            #expect(plan.tabs.count == 2)
            #expect(plan.activeIndex == 1)
            #expect(plan.tabs[1].url == fallback)
            #expect(plan.tabs[1].sortKey == .size)
            #expect(plan.fallbackReasons == [1: .invalidLocation])
        }
    }

    @Test func missingConnectionsFallBackInPlaceAndOverviewStaysValid() throws {
        try isolated { defaults in
            let preferences = SessionPreferences(defaults: defaults), kept = UUID(), removed = UUID()
            preferences.setRestoreTabs(true)
            let tabs = [SessionTabState(url: RemoteLocation.url(connectionID: kept, key: "folder/")),
                        SessionTabState(url: RemoteLocation.url(connectionID: removed, key: "other/")),
                        SessionTabState(url: URL(string: "myexplorer-cloud:///")!)]
            preferences.remember(tabs: tabs, activeIndex: 1)
            let plan = try #require(preferences.restorationPlan(fallback: fallback, availableConnectionIDs: [kept]))
            #expect(plan.tabs[0] == tabs[0])
            #expect(plan.tabs[1].url == fallback)
            #expect(plan.tabs[2] == tabs[2])
            #expect(plan.activeIndex == 1)
            #expect(plan.fallbackReasons == [1: .missingConnection])
        }
    }

    @Test func corruptUnknownAndOversizedSnapshotsAreDiscarded() throws {
        try isolated { defaults in
            let preferences = SessionPreferences(defaults: defaults)
            preferences.setRestoreTabs(true)
            let tab: [String: Any] = ["location": fallback.absoluteString, "sortKey": "name", "sortAscending": true, "showHidden": false]
            let values = [Data("invalid".utf8), Data(repeating: 0, count: 601 * 1024),
                          try JSONSerialization.data(withJSONObject: ["version": 2, "tabs": [tab], "activeIndex": 0]),
                          try JSONSerialization.data(withJSONObject: ["version": 1, "tabs": Array(repeating: tab, count: 33), "activeIndex": 0]),
                          try JSONSerialization.data(withJSONObject: ["version": 1, "tabs": [], "activeIndex": 0])]
            for data in values {
                defaults.set(data, forKey: "sessionSnapshot")
                #expect(preferences.restorationPlan(fallback: fallback, availableConnectionIDs: []) == nil)
                #expect(defaults.object(forKey: "sessionSnapshot") == nil)
            }
            defaults.set("true", forKey: "restoreTabs")
            #expect(!preferences.restoreTabs)
        }
    }

    @Test func injectedUnsafeURLsAndUnknownFieldsAreScrubbed() throws {
        try isolated { defaults in
            let preferences = SessionPreferences(defaults: defaults)
            preferences.setRestoreTabs(true)
            let payload: [String: Any] = ["version": 1, "activeIndex": 999, "credentials": "injected-secret",
                "tabs": [["location": "https://user:injected-secret@example.com/", "sortKey": "unknown", "sortAscending": false, "showHidden": true]]]
            defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "sessionSnapshot")
            let plan = try #require(preferences.restorationPlan(fallback: fallback, availableConnectionIDs: []))
            #expect(plan.activeIndex == 0)
            #expect(plan.tabs[0].url == fallback)
            #expect(plan.tabs[0].sortKey == .name)
            #expect(plan.fallbackReasons[0] == .invalidLocation)
            let sanitized = String(decoding: try #require(defaults.data(forKey: "sessionSnapshot")), as: UTF8.self)
            #expect(!sanitized.contains("injected-secret"))
            #expect(!sanitized.contains("credentials"))
        }
    }
}
