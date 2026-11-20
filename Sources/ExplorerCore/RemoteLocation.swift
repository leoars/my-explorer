// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum RemoteLocation {
    public static let scheme = "myexplorer-cloud"
    public static func url(connectionID: UUID, key: String = "") -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = connectionID.uuidString.lowercased()
        components.path = "/" + key
        return components.url!
    }
    public static func parse(_ url: URL) -> (connectionID: UUID, key: String)? {
        guard url.scheme == scheme, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil, let host = url.host, let id = UUID(uuidString: host) else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        return (id, String(path.dropFirst()))
    }
}

extension URL {
    public var explorerIdentity: String { isFileURL ? standardizedFileURL.path : absoluteString }
    public var explorerNormalized: URL { isFileURL ? standardizedFileURL : self }
    public var explorerParent: URL {
        guard let location = RemoteLocation.parse(self) else { return deletingLastPathComponent() }
        let components = location.key.split(separator: "/", omittingEmptySubsequences: false)
        let nameParts = location.key.hasSuffix("/") ? Array(components.dropLast()) : components
        let parent = nameParts.dropLast().joined(separator: "/")
        return RemoteLocation.url(connectionID: location.connectionID, key: parent.isEmpty ? "" : parent + "/")
    }
    public var explorerIsRoot: Bool {
        if let location = RemoteLocation.parse(self) { return location.key.isEmpty }
        return path == "/" || path.isEmpty
    }
}
