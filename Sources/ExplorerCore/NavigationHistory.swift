// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct LocationSnapshot: Equatable, Sendable {
    public var url: URL
    public var selectedPaths: Set<String>
    public var scrollOffset: Double

    public init(url: URL, selectedPaths: Set<String> = [], scrollOffset: Double = 0) {
        if let location = RemoteLocation.parse(url), !location.key.isEmpty, !location.key.hasSuffix("/") {
            self.url = RemoteLocation.url(connectionID: location.connectionID, key: location.key + "/")
        } else { self.url = url.explorerNormalized }
        self.selectedPaths = selectedPaths
        self.scrollOffset = scrollOffset
    }
}

public struct NavigationHistory: Equatable, Sendable {
    public private(set) var current: LocationSnapshot
    public private(set) var back: [LocationSnapshot] = []
    public private(set) var forward: [LocationSnapshot] = []

    public init(url: URL) { current = LocationSnapshot(url: url) }

    public mutating func remember(selection: Set<String>, scrollOffset: Double) {
        current.selectedPaths = selection
        current.scrollOffset = scrollOffset
    }

    public mutating func visit(_ url: URL) {
        let destination = LocationSnapshot(url: url).url
        guard destination.explorerIdentity != current.url.explorerIdentity else { return }
        back.append(current)
        if back.count > 100 { back.removeFirst() }
        current = LocationSnapshot(url: destination)
        forward.removeAll()
    }

    public mutating func goBack() {
        guard let destination = back.popLast() else { return }
        forward.append(current)
        current = destination
    }

    public mutating func goForward() {
        guard let destination = forward.popLast() else { return }
        back.append(current)
        current = destination
    }

    public mutating func goUp() {
        let child = current.url
        let parent = child.explorerParent
        guard !child.explorerIsRoot else { return }
        visit(parent)
        current.selectedPaths = [child.explorerIdentity]
    }
}

public enum NavigationAction: Sendable {
    case visit(URL), back, forward, up, reload
}

public enum AddressParser {
    /// Relative addresses resolve against the current directory, never the process cwd.
    public static func resolve(_ text: String, relativeTo current: URL) -> URL? {
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("file:") {
            guard let url = URL(string: text), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            return url.standardizedFileURL
        }
        guard !text.contains("://") else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return current.appendingPathComponent(expanded).explorerNormalized
    }
}
