// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The App Store build has the same identifier as the direct one. On its first launch macOS moves
/// `~/Library/Preferences/<identifier>.plist` into the new container (docs/APP-STORE.md, stage 3):
/// no migration manifest keeps it in place, so the direct build would start over with nothing.
/// The direct build, which runs outside the sandbox, takes a copy back from the container when it
/// finds no preferences of its own. The container is left untouched.
public enum StorePreferencesRecovery {
    /// Keys only the App Store build writes (its folder grants), left out of the copy.
    static let storeOnlyPrefixes = ["sandbox."]

    /// Where the App Store build keeps its preferences, for a home folder and an identifier.
    public static func containerPreferences(identifier: String, home: URL) -> URL {
        home.appendingPathComponent("Library/Containers/\(identifier)/Data/Library/Preferences/\(identifier).plist")
    }

    /// Copies the preferences of `source` into `domain` when the domain holds none. Returns how
    /// many keys came back (0 when there was nothing to do or nothing readable). Never runs in
    /// the sandbox: there the container is the app's own domain.
    @discardableResult
    public static func recoverIfNeeded(domain: String, defaults: UserDefaults = .standard, source: URL) -> Int {
        guard !RealHome.isSandboxed else { return 0 }
        guard (defaults.persistentDomain(forName: domain) ?? [:]).isEmpty,
              let data = try? Data(contentsOf: source),
              let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return 0 }
        let kept = stored.filter { key, _ in !storeOnlyPrefixes.contains { key.hasPrefix($0) } }
        guard !kept.isEmpty else { return 0 }
        defaults.setPersistentDomain(kept, forName: domain)
        return kept.count
    }
}
