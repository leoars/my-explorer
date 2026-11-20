// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum FontArea: String, CaseIterable, Sendable {
    case tree, files, menus, bars
    public var defaultSize: Double { self == .menus ? 16 : 14 }
}

@MainActor
public final class DisplayPreferences {
    public enum Change { case fileNames, fonts, preview }
    private let defaults: UserDefaults
    public var onChange: ((Change) -> Void)?
    public var showFileExtensions: Bool {
        defaults.object(forKey: "showFileExtensions") == nil || defaults.bool(forKey: "showFileExtensions")
    }
    public var showPreviewPane: Bool { defaults.bool(forKey: "showPreviewPane") }
    public func setShowPreviewPane(_ value: Bool) {
        defaults.set(value, forKey: "showPreviewPane")
        onChange?(.preview)
    }
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func setShowFileExtensions(_ value: Bool) {
        defaults.set(value, forKey: "showFileExtensions")
        onChange?(.fileNames)
    }
    public func fontSize(for area: FontArea) -> Double {
        guard let value = defaults.object(forKey: "fontSize.\(area.rawValue)") as? NSNumber,
              value.doubleValue.isFinite, (10...24).contains(value.doubleValue) else { return area.defaultSize }
        return value.doubleValue
    }
    public func setFontSize(_ value: Double, for area: FontArea) {
        guard value.isFinite else { return }
        defaults.set(min(24, max(10, value)), forKey: "fontSize.\(area.rawValue)")
        onChange?(.fonts)
    }
    public func adjustAllFontSizes(by delta: Double) {
        guard delta.isFinite, delta != 0 else { return }
        var changed = false
        for area in FontArea.allCases {
            let current = fontSize(for: area)
            let next = min(24, max(10, current + delta))
            if next != current {
                defaults.set(next, forKey: "fontSize.\(area.rawValue)")
                changed = true
            }
        }
        // Rebuild once, after every area has its final value.
        if changed { onChange?(.fonts) }
    }
    public func resetFonts() {
        for area in FontArea.allCases { defaults.removeObject(forKey: "fontSize.\(area.rawValue)") }
        onChange?(.fonts)
    }
}

extension FileEntry {
    public func displayName(showExtensions: Bool) -> String {
        guard !showExtensions, !canNavigate,
              let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return name }
        return String(name[..<dot])
    }
}
