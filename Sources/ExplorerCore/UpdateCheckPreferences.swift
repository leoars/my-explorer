// SPDX-License-Identifier: Apache-2.0
import Foundation

@MainActor
public struct UpdateCheckPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var enabled: Bool {
        get { defaults.object(forKey: "updates.automatic") == nil || defaults.bool(forKey: "updates.automatic") }
        nonmutating set { defaults.set(newValue, forKey: "updates.automatic") }
    }

    public func isDeferred(at now: Date) -> Bool {
        guard let until = defaults.object(forKey: "updates.resumeAfter") as? Date else { return false }
        return now < until
    }

    public func remindLater(from now: Date) {
        defaults.set(now.addingTimeInterval(7 * 24 * 60 * 60), forKey: "updates.resumeAfter")
    }

    public var skippedBuild: Int { defaults.integer(forKey: "updates.skippedBuild") }

    public func skip(build: Int) {
        defaults.set(max(build, skippedBuild), forKey: "updates.skippedBuild")
    }
}
