// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerCore

struct UpdateCheckPreferencesTests {
    @Test @MainActor func decisionsSurviveRelaunch() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UpdateCheckPreferences(defaults: defaults)
        let now = Date()
        #expect(first.enabled)
        first.skip(build: 23)
        first.remindLater(from: now)
        first.enabled = false
        let next = UpdateCheckPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(!next.enabled)
        next.enabled = true
        #expect(next.isDeferred(at: now.addingTimeInterval(604799)))
        #expect(!next.isDeferred(at: now.addingTimeInterval(604800)))
        next.skip(build: 22)
        #expect(next.skippedBuild == 23)
    }
}
