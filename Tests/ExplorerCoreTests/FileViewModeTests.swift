// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import Testing
@testable import ExplorerCore

struct FileViewModeTests {
    @Test @MainActor func folderWithoutChoiceShowsDetailsAndChoicesSurviveNewInstances() throws {
        let suite = "MyExplorer.FolderViewModes.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let modes = FolderViewModes(defaults: defaults)
        #expect(modes.mode(for: "/a") == .details)
        modes.set(.gallery, for: "/a")
        modes.set(.list, for: "/b")
        modes.set(.largeIcons, for: "/a")
        let restored = FolderViewModes(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(restored.mode(for: "/a") == .largeIcons && restored.mode(for: "/b") == .list)
        #expect(restored.mode(for: "/c") == .details)
        restored.set(.details, for: "/a")
        #expect(restored.mode(for: "/a") == .details)
        #expect((defaults.array(forKey: FolderViewModes.key) as? [[String]]) == [["/b", "list"]])
    }

    @Test @MainActor func onlyTheMostRecentFoldersAreKeptAndDamagedValuesAreIgnored() throws {
        let suite = "MyExplorer.FolderViewModes.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let modes = FolderViewModes(defaults: defaults)
        for index in 0..<(FolderViewModes.limit + 5) { modes.set(.list, for: "/\(index)") }
        modes.set(.gallery, for: "/7") // chosen again: becomes the most recent
        #expect(modes.mode(for: "/0") == .details && modes.mode(for: "/5") == .list && modes.mode(for: "/7") == .gallery)
        #expect((defaults.array(forKey: FolderViewModes.key) as? [[String]])?.count == FolderViewModes.limit)
        defaults.set([["/x", "nonsense"], ["/y"], ["/z", "gallery"]], forKey: FolderViewModes.key)
        #expect(modes.mode(for: "/x") == .details && modes.mode(for: "/y") == .details && modes.mode(for: "/z") == .gallery)
        defaults.set("not a list", forKey: FolderViewModes.key)
        #expect(modes.mode(for: "/z") == .details)
    }

    @Test func rowsFillFromLeftToRightAndScrollDown() {
        let grid = GridGeometry(count: 10, cell: CGSize(width: 100, height: 50), flow: .rows, viewport: CGSize(width: 330, height: 120), inset: 10)
        #expect(grid.perLine == 3 && grid.lines == 4)
        #expect(grid.contentSize == CGSize(width: 320, height: 220))
        #expect(grid.frame(at: 0) == CGRect(x: 10, y: 10, width: 100, height: 50))
        #expect(grid.frame(at: 4) == CGRect(x: 110, y: 60, width: 100, height: 50))
        #expect(grid.index(at: CGPoint(x: 115, y: 65)) == 4)
        #expect(grid.index(at: CGPoint(x: 5, y: 65)) == nil)      // in the margin
        #expect(grid.index(at: CGPoint(x: 150, y: 180)) == nil)   // empty end of the last row
        #expect(grid.index(at: CGPoint(x: 315, y: 20)) == nil)    // right of the last column
        #expect(grid.indexes(in: CGRect(x: 0, y: 0, width: 330, height: 120)) == Array(0..<9))
        #expect(grid.indexes(in: CGRect(x: 120, y: 70, width: 10, height: 10)) == [4])
        #expect(grid.indexes(in: CGRect(x: 0, y: 150, width: 400, height: 500)) == [6, 7, 8, 9])
        #expect(grid.indexes(in: CGRect(x: 0, y: 5000, width: 400, height: 50)).isEmpty)
    }

    @Test func columnsFillFromTopToBottomAndScrollSideways() {
        let grid = GridGeometry(count: 7, cell: CGSize(width: 100, height: 20), flow: .columns, viewport: CGSize(width: 250, height: 72), inset: 6)
        #expect(grid.perLine == 3 && grid.lines == 3)
        #expect(grid.contentSize == CGSize(width: 312, height: 72))
        #expect(grid.frame(at: 4) == CGRect(x: 106, y: 26, width: 100, height: 20))
        #expect(grid.index(at: CGPoint(x: 210, y: 10)) == 6)
        #expect(grid.index(at: CGPoint(x: 210, y: 30)) == nil)
        #expect(grid.indexes(in: CGRect(x: 110, y: 0, width: 300, height: 72)) == [3, 4, 5, 6])
        #expect(grid.neighbor(of: 4, .up) == 3 && grid.neighbor(of: 4, .down) == 5)
        #expect(grid.neighbor(of: 4, .left) == 1 && grid.neighbor(of: 3, .right) == 6)
        #expect(grid.neighbor(of: 4, .right) == 6)                 // past the end: the last item
        #expect(grid.neighbor(of: 5, .down) == nil && grid.neighbor(of: 0, .left) == nil && grid.neighbor(of: 6, .right) == nil)
    }

    @Test func arrowsStopAtTheEdgesAndLandOnTheLastItemOfAnIncompleteLine() {
        let grid = GridGeometry(count: 10, cell: CGSize(width: 100, height: 50), flow: .rows, viewport: CGSize(width: 330, height: 120), inset: 10)
        #expect(grid.neighbor(of: 4, .left) == 3 && grid.neighbor(of: 4, .right) == 5)
        #expect(grid.neighbor(of: 4, .up) == 1 && grid.neighbor(of: 4, .down) == 7)
        #expect(grid.neighbor(of: 3, .left) == nil && grid.neighbor(of: 5, .right) == nil)
        #expect(grid.neighbor(of: 1, .up) == nil && grid.neighbor(of: 9, .down) == nil && grid.neighbor(of: 9, .right) == nil)
        #expect(grid.neighbor(of: 8, .down) == 9 && grid.neighbor(of: 6, .down) == 9)
        #expect(grid.neighbor(of: 12, .left) == nil && grid.neighbor(of: -1, .right) == nil)
    }

    @Test func stripHasOneItemPerColumnWhateverTheHeight() {
        let grid = GridGeometry(count: 5, cell: CGSize(width: 90, height: 100), flow: .columns, viewport: CGSize(width: 400, height: 40))
        #expect(grid.perLine == 1 && grid.lines == 5)
        #expect(grid.neighbor(of: 2, .right) == 3 && grid.neighbor(of: 2, .left) == 1)
        #expect(grid.neighbor(of: 2, .up) == nil && grid.neighbor(of: 2, .down) == nil)
        let empty = GridGeometry(count: 0, cell: CGSize(width: 90, height: 100), flow: .rows, viewport: .zero)
        #expect(empty.perLine == 1 && empty.lines == 0 && empty.indexes(in: CGRect(x: 0, y: 0, width: 500, height: 500)).isEmpty)
        #expect(empty.index(at: CGPoint(x: 20, y: 20)) == nil)
    }

    @Test func pagingKeepsTheColumnAndStaysInsideTheList() {
        let grid = GridGeometry(count: 31, cell: CGSize(width: 100, height: 50), flow: .rows, viewport: CGSize(width: 330, height: 120), inset: 10)
        let screen = CGSize(width: 330, height: 120) // two rows fit
        #expect(grid.page(from: 4, forward: true, viewport: screen) == 10)
        #expect(grid.page(from: 10, forward: false, viewport: screen) == 4)
        #expect(grid.page(from: 1, forward: false, viewport: screen) == 1)
        #expect(grid.page(from: 26, forward: true, viewport: screen) == 29)
        #expect(grid.page(from: 30, forward: true, viewport: screen) == 30)
        let list = GridGeometry(count: 20, cell: CGSize(width: 100, height: 20), flow: .columns, viewport: CGSize(width: 250, height: 72), inset: 6)
        #expect(list.page(from: 1, forward: true, viewport: CGSize(width: 250, height: 72)) == 7) // two columns of three
        #expect(list.page(from: 19, forward: false, viewport: CGSize(width: 250, height: 72)) == 13)
    }

    @Test func rectanglesOnCellBoundariesAndNarrowViewports() {
        let grid = GridGeometry(count: 10, cell: CGSize(width: 100, height: 50), flow: .rows, viewport: CGSize(width: 330, height: 120), inset: 10)
        #expect(grid.indexes(in: CGRect(x: 110, y: 60, width: 100, height: 50)) == [4])       // exactly one cell
        #expect(grid.indexes(in: CGRect(x: -500, y: -500, width: 520, height: 520)) == [0])   // starts outside the grid
        #expect(grid.indexes(in: CGRect(x: -500, y: -500, width: 100, height: 100)).isEmpty)
        let narrow = GridGeometry(count: 3, cell: CGSize(width: 100, height: 50), flow: .rows, viewport: CGSize(width: 40, height: 400), inset: 10)
        #expect(narrow.perLine == 1 && narrow.lines == 3 && narrow.frame(at: 2) == CGRect(x: 10, y: 110, width: 100, height: 50))
        #expect(narrow.neighbor(of: 1, .down) == 2 && narrow.neighbor(of: 1, .right) == nil)
    }
}
