// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics

/// Global browser preferences. Navigation locations and other display preferences are separate.
@MainActor
public final class BrowserViewPreferences {
    public static let defaultColumnOrder = ["name", "modified", "kind", "size"]
    public static let defaultColumnWidths: [String: CGFloat] = ["name": 390, "modified": 165, "kind": 150, "size": 95]
    private let defaults: UserDefaults

    enum Keys {
        static let confirmDeletion = "browser.confirmDeletion"
        static let expandTree = "browser.expandTreeToOpenFolder"
        static let autoplayMedia = "browser.autoplayMedia"
        static let columns = "browserView.columns"
        static let sortKey = "browserView.sortKey"
        static let sortAscending = "browserView.sortAscending"
        static let showHidden = "browserView.showHidden"
        static let sidebarWidth = "browserView.sidebarWidth"
        static let previewWidth = "browserView.previewWidth"
        static let windowFrame = "browserView.windowFrame"
    }

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var confirmDeletion: Bool {
        get { boolean(forKey: Keys.confirmDeletion, fallback: true) }
        set { defaults.set(newValue, forKey: Keys.confirmDeletion) }
    }

    /// Whether a video or a sound opened in the media viewer starts playing by itself.
    public var autoplayMedia: Bool {
        get { boolean(forKey: Keys.autoplayMedia, fallback: true) }
        set { defaults.set(newValue, forKey: Keys.autoplayMedia) }
    }
    /// Whether the folder tree opens its branches to show the folder open in the list. On by
    /// default; when off, the tree only highlights that folder if it is already visible.
    public var expandTreeToOpenFolder: Bool {
        get { boolean(forKey: Keys.expandTree, fallback: true) }
        set { defaults.set(newValue, forKey: Keys.expandTree) }
    }

    public var columnOrder: [String] {
        let order = (defaults.dictionary(forKey: Keys.columns)?["order"] as? [Any])?.compactMap { $0 as? String } ?? []
        return Self.normalizedOrder(order)
    }

    public var columnWidths: [String: CGFloat] {
        let stored = defaults.dictionary(forKey: Keys.columns)?["widths"] as? [String: Any] ?? [:]
        return Self.defaultColumnWidths.reduce(into: [String: CGFloat]()) { result, entry in
            result[entry.key] = Self.number(stored[entry.key]).map { Self.clamp($0, to: 75...3000) } ?? entry.value
        }
    }

    /// Order and widths are persisted as one complete value, never a partially updated layout.
    public func setColumns(order: [String], widths: [String: CGFloat]) {
        let normalizedWidths = Self.defaultColumnWidths.reduce(into: [String: Double]()) { result, entry in
            let width = widths[entry.key].flatMap { $0.isFinite ? $0 : nil } ?? entry.value
            result[entry.key] = Double(Self.clamp(width, to: 75...3000))
        }
        defaults.set(["order": Self.normalizedOrder(order), "widths": normalizedWidths], forKey: Keys.columns)
    }

    public var sortKey: EntrySortKey {
        get { defaults.string(forKey: Keys.sortKey).flatMap(EntrySortKey.init(rawValue:)) ?? .name }
        set { defaults.set(newValue.rawValue, forKey: Keys.sortKey) }
    }
    public var sortAscending: Bool {
        get { boolean(forKey: Keys.sortAscending, fallback: true) }
        set { defaults.set(newValue, forKey: Keys.sortAscending) }
    }
    public var showHidden: Bool {
        get { boolean(forKey: Keys.showHidden, fallback: false) }
        set { defaults.set(newValue, forKey: Keys.showHidden) }
    }
    public var sidebarWidth: CGFloat {
        get { dimension(forKey: Keys.sidebarWidth, range: 165...1000, fallback: 230) }
        set { setDimension(newValue, forKey: Keys.sidebarWidth, range: 165...1000) }
    }
    public var previewWidth: CGFloat {
        get { dimension(forKey: Keys.previewWidth, range: 220...1200, fallback: 300) }
        set { setDimension(newValue, forKey: Keys.previewWidth, range: 220...1200) }
    }
    public var windowFrame: CGRect? {
        guard let value = defaults.dictionary(forKey: Keys.windowFrame),
              let x = Self.number(value["x"]), let y = Self.number(value["y"]),
              let width = Self.number(value["width"]), let height = Self.number(value["height"]) else { return nil }
        let frame = CGRect(x: x, y: y, width: width, height: height)
        return Self.validFrame(frame) ? frame : nil
    }
    public func setWindowFrame(_ frame: CGRect?) {
        guard let frame else { defaults.removeObject(forKey: Keys.windowFrame); return }
        guard Self.validFrame(frame) else { return }
        defaults.set(["x": Double(frame.origin.x), "y": Double(frame.origin.y),
                      "width": Double(frame.width), "height": Double(frame.height)], forKey: Keys.windowFrame)
    }

    private static func normalizedOrder(_ input: [String]) -> [String] {
        var seen: Set<String> = []
        return (input + defaultColumnOrder).filter { defaultColumnOrder.contains($0) && seen.insert($0).inserted }
    }
    private static func number(_ value: Any?) -> CGFloat? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return CGFloat(value.doubleValue)
    }
    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }
    private func boolean(forKey key: String, fallback: Bool) -> Bool {
        guard let value = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return fallback }
        return value.boolValue
    }
    private func dimension(forKey key: String, range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        Self.number(defaults.object(forKey: key)).map { Self.clamp($0, to: range) } ?? fallback
    }
    private func setDimension(_ value: CGFloat, forKey key: String, range: ClosedRange<CGFloat>) {
        guard value.isFinite else { return }
        defaults.set(Double(Self.clamp(value, to: range)), forKey: key)
    }
    private static func validFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.size.width.isFinite && frame.size.height.isFinite
            && (820...10000).contains(frame.size.width) && (480...10000).contains(frame.size.height)
    }
}
