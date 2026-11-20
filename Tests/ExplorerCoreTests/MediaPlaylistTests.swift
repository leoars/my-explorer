// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class MediaPlaylistTests: XCTestCase {
    private func entry(_ name: String, directory: Bool = false, package: Bool = false,
                       url: URL? = nil, symbolicLink: Bool = false) -> FileEntry {
        FileEntry(url: url ?? URL(fileURLWithPath: "/fixture/\(name)"), name: name,
                  isDirectory: directory, isPackage: package, isSymbolicLink: symbolicLink)
    }

    func testRecognizesImagesVideosAndAudioCaseInsensitivelyWithUnicodeNames() {
        for name in ["写真.JPG", "ação.PNG", "café.heic", "Bild.tiff", "animation.gif"] {
            XCTAssertEqual(MediaKind.detect(entry(name)), .image, name)
        }
        for name in ["vídeo.MP4", "映画.MOV", "video.m4v"] {
            XCTAssertEqual(MediaKind.detect(entry(name)), .video, name)
        }
        for name in ["música.MP3", "오디오.wav", "audio.aiff", "audio.m4a"] {
            XCTAssertEqual(MediaKind.detect(entry(name)), .audio, name)
        }
    }

    func testRejectsMissingUnknownAndNonMediaExtensions() {
        for name in ["no extension", "picture.myexplorerunknown", "report.pdf", "text.txt", ".jpg"] {
            XCTAssertNil(MediaKind.detect(entry(name)), name)
        }
    }

    func testRejectsDirectoriesPackagesAndRemoteURLs() throws {
        XCTAssertNil(MediaKind.detect(entry("folder.jpg", directory: true)))
        XCTAssertNil(MediaKind.detect(entry("package.mp4", directory: true, package: true)))
        XCTAssertNil(MediaKind.detect(entry("package.jpg", package: true)))
        XCTAssertNil(MediaKind.detect(entry("folder-link.png", directory: true, symbolicLink: true)))
        for value in ["https://example.com/photo.jpg", "s3://bucket/photo.jpg", "file://other-host/fixture/photo.jpg"] {
            XCTAssertNil(MediaKind.detect(entry("photo.jpg", url: try XCTUnwrap(URL(string: value)))))
        }
        XCTAssertEqual(MediaKind.detect(entry("link.jpg", symbolicLink: true)), .image)
    }

    func testFiltersPreservesOrderAndDeduplicatesIdentityWithoutReplacingOriginalURL() throws {
        let video = entry("z.mov"), image = entry("Árvore.jpg"), audio = entry("a.mp3")
        let alias = entry("duplicate metadata", url: URL(fileURLWithPath: "/fixture/other/../Árvore.jpg"))
        let playlist = try XCTUnwrap(MediaPlaylist(entries: [video, entry("report.txt"), image, alias, audio], selectedURL: alias.url))
        XCTAssertEqual(playlist.entries, [video, image, audio])
        XCTAssertEqual(playlist.current, image)
        XCTAssertEqual(playlist.current.url, image.url)
        XCTAssertEqual(playlist.index, 1)
        XCTAssertEqual(playlist.count, 3)
    }

    func testSelectedItemMustBelongToFilteredLocalMediaList() throws {
        let image = entry("one.jpg"), text = entry("two.txt"), folder = entry("folder.jpg", directory: true)
        XCTAssertNil(MediaPlaylist(entries: [], selectedURL: image.url))
        XCTAssertNil(MediaPlaylist(entries: [image], selectedURL: entry("missing.jpg").url))
        XCTAssertNil(MediaPlaylist(entries: [image, text], selectedURL: text.url))
        XCTAssertNil(MediaPlaylist(entries: [image, folder], selectedURL: folder.url))
        let remoteSelection = try XCTUnwrap(URL(string: "file://other-host/fixture/one.jpg"))
        XCTAssertNil(MediaPlaylist(entries: [image], selectedURL: remoteSelection))
    }

    func testFinderAliasesAreExcludedWhileSymbolicLinksRemainPlayable() throws {
        let image = entry("original.jpg"), symbolic = entry("symbolic.jpg", symbolicLink: true)
        let alias = FileEntry(url: URL(fileURLWithPath: "/fixture/alias.jpg"), name: "alias.jpg",
                              isDirectory: false, isAlias: true)
        XCTAssertNil(MediaKind.detect(alias))
        XCTAssertEqual(MediaKind.detect(symbolic), .image)
        let entries = [image, alias, symbolic]
        XCTAssertNil(MediaPlaylist(entries: entries, selectedURL: alias.url))
        let playlist = try XCTUnwrap(MediaPlaylist(entries: entries, selectedURL: image.url))
        XCTAssertEqual(playlist.entries, [image, symbolic])
    }

    func testNavigationMovesInBothDirectionsWithoutWrapping() throws {
        let first = entry("one.jpg"), second = entry("two.mov"), third = entry("three.mp3")
        var playlist = try XCTUnwrap(MediaPlaylist(entries: [first, second, third], selectedURL: second.url))
        XCTAssertTrue(playlist.canPrevious)
        XCTAssertTrue(playlist.canNext)
        XCTAssertEqual(playlist.next(), third)
        XCTAssertFalse(playlist.canNext)
        XCTAssertNil(playlist.next())
        XCTAssertEqual(playlist.index, 2)
        XCTAssertEqual(playlist.previous(), second)
        XCTAssertEqual(playlist.previous(), first)
        XCTAssertFalse(playlist.canPrevious)
        XCTAssertNil(playlist.previous())
        XCTAssertEqual(playlist.current, first)
        XCTAssertEqual(playlist.index, 0)
    }

    func testSingleItemHasNoPreviousOrNext() throws {
        let image = entry("one.jpg")
        var playlist = try XCTUnwrap(MediaPlaylist(entries: [image], selectedURL: image.url))
        XCTAssertEqual(playlist.count, 1)
        XCTAssertFalse(playlist.canPrevious)
        XCTAssertFalse(playlist.canNext)
        XCTAssertNil(playlist.previous())
        XCTAssertNil(playlist.next())
        XCTAssertEqual(playlist.current, image)
    }

    func testKeyboardNavigationMapsOnlyRequestedKeys() {
        XCTAssertEqual(MediaNavigationDirection.direction(keyCode: 123), .previous)
        XCTAssertEqual(MediaNavigationDirection.direction(keyCode: 116), .previous)
        XCTAssertEqual(MediaNavigationDirection.direction(keyCode: 124), .next)
        XCTAssertEqual(MediaNavigationDirection.direction(keyCode: 121), .next)
        for code: UInt16 in [0, 36, 49, 53, 115, 119, 125, 126] {
            XCTAssertNil(MediaNavigationDirection.direction(keyCode: code))
        }
    }
}
