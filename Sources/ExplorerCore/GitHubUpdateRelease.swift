// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct GitHubUpdateRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let id: Int
        public let name: String
        public let size: Int
        public let state: String
    }
    public let draft: Bool
    public let assets: [Asset]
    /// The tag of the release, such as `v1.0.2`: where the version people know comes from, since the
    /// asset names carry only the build.
    public let tagName: String?

    enum CodingKeys: String, CodingKey { case draft, assets, tagName = "tag_name" }

    /// The version in the tag, without its `v`, when it is one: digits separated by dots.
    public var version: String? {
        guard var tag = tagName else { return nil }
        if tag.hasPrefix("v") { tag.removeFirst() }
        let parts = tag.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return tag
    }

    public static func newest(in releases: [Self], after build: Int) -> (build: Int, asset: Asset, version: String?)? {
        releases.filter { !$0.draft }.flatMap { release in release.assets.map { ($0, release.version) } }
            .compactMap { asset, version -> (Int, Asset, String?)? in
            let prefix = "MyExplorer-macOS-universal-"
            let suffix = ".dmg"
            guard asset.id > 0, (1...536_870_912).contains(asset.size), asset.state == "uploaded",
                  asset.name.hasPrefix(prefix), asset.name.hasSuffix(suffix),
                  let number = Int(asset.name.dropFirst(prefix.count).dropLast(suffix.count)),
                  asset.name == "\(prefix)\(number)\(suffix)", number > build else { return nil }
            return (number, asset, version)
        }.max { $0.0 < $1.0 }
    }
}
