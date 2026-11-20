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

    public static func newest(in releases: [Self], after build: Int) -> (build: Int, asset: Asset)? {
        releases.filter { !$0.draft }.flatMap(\.assets).compactMap { asset -> (Int, Asset)? in
            let prefix = "MyExplorer-macOS-universal-"
            let suffix = ".dmg"
            guard asset.id > 0, (1...536_870_912).contains(asset.size), asset.state == "uploaded",
                  asset.name.hasPrefix(prefix), asset.name.hasSuffix(suffix),
                  let number = Int(asset.name.dropFirst(prefix.count).dropLast(suffix.count)),
                  asset.name == "\(prefix)\(number)\(suffix)", number > build else { return nil }
            return (number, asset)
        }.max { $0.0 < $1.0 }
    }
}
