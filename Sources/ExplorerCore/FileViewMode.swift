// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics

/// How the file list shows a folder, as in Windows: the table of details, or one of the grids.
public enum FileViewMode: String, CaseIterable, Sendable {
    case details, list, smallIcons, largeIcons, gallery
}

/// The view mode chosen for each folder. A folder nobody chose a mode for shows details; only
/// the most recently chosen folders are kept.
@MainActor
public final class FolderViewModes {
    static let key = "browserView.folderModes"
    public static let limit = 400
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Most recently chosen last.
    private var stored: [(folder: String, mode: FileViewMode)] {
        let pairs = defaults.array(forKey: Self.key) as? [[String]] ?? []
        return pairs.compactMap { pair in
            guard pair.count == 2, let mode = FileViewMode(rawValue: pair[1]) else { return nil }
            return (pair[0], mode)
        }
    }

    public func mode(for folder: String) -> FileViewMode {
        stored.last { $0.folder == folder }?.mode ?? .details
    }

    public func set(_ mode: FileViewMode, for folder: String) {
        var entries = stored.filter { $0.folder != folder }
        // Details is what an unknown folder shows: nothing to keep for it.
        if mode != .details { entries.append((folder, mode)) }
        defaults.set(entries.suffix(Self.limit).map { [$0.folder, $0.mode.rawValue] }, forKey: Self.key)
    }
}

/// Where each item of a grid of equal cells stands. Rows fill from left to right and scroll
/// vertically; columns fill from top to bottom and scroll horizontally. Nothing here depends on
/// the number of items, so a folder with tens of thousands of them costs the same as a small one.
public struct GridGeometry: Equatable, Sendable {
    public enum Flow: Sendable { case rows, columns }
    public enum Direction: Sendable { case left, right, up, down }

    public let count: Int
    public let cell: CGSize
    public let flow: Flow
    public let inset: CGFloat
    /// Items in one row (rows) or in one column (columns).
    public let perLine: Int

    public init(count: Int, cell: CGSize, flow: Flow, viewport: CGSize, inset: CGFloat = 6) {
        self.count = max(0, count)
        self.cell = CGSize(width: max(1, cell.width), height: max(1, cell.height))
        self.flow = flow
        self.inset = inset
        let room = flow == .rows ? viewport.width : viewport.height
        let side = flow == .rows ? self.cell.width : self.cell.height
        let fitting = ((room.isFinite ? room : 0) - 2 * inset) / side
        perLine = max(1, Int(fitting.rounded(.down)))
    }

    public var lines: Int { (count + perLine - 1) / perLine }

    public var contentSize: CGSize {
        switch flow {
        case .rows: return CGSize(width: 2 * inset + CGFloat(perLine) * cell.width, height: 2 * inset + CGFloat(lines) * cell.height)
        case .columns: return CGSize(width: 2 * inset + CGFloat(lines) * cell.width, height: 2 * inset + CGFloat(perLine) * cell.height)
        }
    }

    private func position(of index: Int) -> (column: Int, row: Int) {
        flow == .rows ? (index % perLine, index / perLine) : (index / perLine, index % perLine)
    }

    private func index(column: Int, row: Int) -> Int {
        flow == .rows ? row * perLine + column : column * perLine + row
    }

    private var columns: Int { flow == .rows ? perLine : lines }
    private var rows: Int { flow == .rows ? lines : perLine }

    public func frame(at index: Int) -> CGRect {
        let place = position(of: index)
        return CGRect(x: inset + CGFloat(place.column) * cell.width, y: inset + CGFloat(place.row) * cell.height,
                      width: cell.width, height: cell.height)
    }

    public func index(at point: CGPoint) -> Int? {
        let x = ((point.x - inset) / cell.width).rounded(.down), y = ((point.y - inset) / cell.height).rounded(.down)
        guard x >= 0, y >= 0, x < CGFloat(columns), y < CGFloat(rows) else { return nil }
        let found = index(column: Int(x), row: Int(y))
        return found < count ? found : nil
    }

    /// The items whose cells touch the rectangle, in ascending order.
    public func indexes(in rect: CGRect) -> [Int] {
        guard count > 0, rect.width >= 0, rect.height >= 0, !rect.isNull, !rect.isInfinite else { return [] }
        func span(_ low: CGFloat, _ high: CGFloat, side: CGFloat, limit: Int) -> ClosedRange<Int>? {
            let first = max(0, Int(((low - inset) / side).rounded(.down)))
            let last = min(limit - 1, Int(((high - inset) / side).rounded(.up)) - 1)
            return first <= last ? first...last : nil
        }
        guard let across = span(rect.minX, rect.maxX, side: cell.width, limit: columns),
              let down = span(rect.minY, rect.maxY, side: cell.height, limit: rows) else { return [] }
        var found: [Int] = []
        found.reserveCapacity(across.count * down.count)
        for row in down { for column in across {
            let item = index(column: column, row: row)
            if item < count { found.append(item) }
        } }
        return flow == .rows ? found : found.sorted()
    }

    /// The item an arrow key leads to, or nil at an edge. Arrows do not wrap to another line; one
    /// that points at the empty end of the last line lands on the last item.
    public func neighbor(of index: Int, _ direction: Direction) -> Int? {
        guard (0..<count).contains(index) else { return nil }
        let place = position(of: index)
        var column = place.column, row = place.row
        switch direction {
        case .left: column -= 1
        case .right: column += 1
        case .up: row -= 1
        case .down: row += 1
        }
        guard column >= 0, row >= 0, column < columns, row < rows else { return nil }
        let target = self.index(column: column, row: row)
        if target < count { return target }
        // Only a move onto the last, incomplete line can fall past the end.
        let alongFlow = flow == .rows ? direction == .down : direction == .right
        return alongFlow && count - 1 != index ? count - 1 : nil
    }

    /// The item one screenful before or after, staying in the same position across the flow.
    public func page(from index: Int, forward: Bool, viewport: CGSize) -> Int {
        guard (0..<count).contains(index) else { return max(0, min(count - 1, index)) }
        let room = flow == .rows ? viewport.height : viewport.width
        let side = flow == .rows ? cell.height : cell.width
        let step = max(1, Int((room / side).rounded(.down))) * perLine
        var target = index
        if forward { while target + perLine < count, target - index < step { target += perLine } }
        else { while target - perLine >= 0, index - target < step { target -= perLine } }
        return target
    }
}
