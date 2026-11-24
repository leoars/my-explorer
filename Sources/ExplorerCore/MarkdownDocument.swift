// SPDX-License-Identifier: Apache-2.0
import Foundation
import CMarkGFM
import UniformTypeIdentifiers

/// Which files the preview pane reads as Markdown, and how much of one it reads.
public enum MarkdownFile {
    public static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"]
    /// Above this size a Markdown file is left to Quick Look, as before.
    public static let byteLimit = 2 * 1024 * 1024

    public static func isMarkdown(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if extensions.contains(pathExtension) { return true }
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension),
              let markdown = UTType("net.daringfireball.markdown") else { return false }
        return type.conforms(to: markdown)
    }

    public enum Loaded: Equatable, Sendable {
        case text(String), tooLarge, unreadable, notUTF8
    }

    /// Reads a regular file of at most `limit` bytes as UTF-8 (a byte order mark is dropped). The
    /// size is checked before reading and the read itself stops one byte past the limit, so a file
    /// that grows in the meantime is still refused.
    public static func load(_ url: URL, limit: Int = byteLimit) -> Loaded {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .unreadable }
        guard info.st_size <= limit else { return .tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= limit {
            if Task.isCancelled { return .unreadable }
            let wanted = min(buffer.count, limit + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EINTR { continue }
                return .unreadable
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard data.count <= limit else { return .tooLarge }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        guard let text = String(data: data, encoding: .utf8) else { return .notUTF8 }
        return .text(text)
    }
}

public enum MarkdownAlignment: Equatable, Sendable { case none, left, center, right }

public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link(destination: String, title: String, content: [MarkdownInline])
    case image(source: String, title: String, alt: String)
    case softBreak
    case lineBreak
    /// Raw HTML is kept as the text it is written with; it is never interpreted.
    case html(String)
    /// `number` is the footnote's position in the document, or nil when nothing defines it.
    case footnoteReference(label: String, number: Int?)
}

public struct MarkdownListItem: Equatable, Sendable {
    /// nil for an ordinary item; true or false for a task list item, checked or not.
    public var task: Bool?
    public var blocks: [MarkdownBlock]
}

public struct MarkdownList: Equatable, Sendable {
    public var ordered: Bool
    public var start: Int
    public var tight: Bool
    public var items: [MarkdownListItem]
}

public struct MarkdownTable: Equatable, Sendable {
    public var alignments: [MarkdownAlignment]
    public var header: [[MarkdownInline]]
    public var rows: [[[MarkdownInline]]]
}

public indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, content: [MarkdownInline], anchor: String)
    case paragraph([MarkdownInline])
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case thematicBreak
    /// A raw HTML block, shown as the text it is written with.
    case html(String)
}

public struct MarkdownFootnote: Equatable, Sendable {
    public var label: String
    public var number: Int
    public var blocks: [MarkdownBlock]
}

/// A Markdown file read into blocks, with GitHub's extensions (tables, strikethrough, autolinks,
/// task lists) and footnotes. The parser is the vendored cmark-gfm; nothing here produces HTML.
public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlock]
    /// In the order they are first referred to, which is their number.
    public var footnotes: [MarkdownFootnote]

    /// Deeper nesting (of quotes, lists or emphasis) is shown flattened into plain text, so a
    /// hostile file cannot exhaust the stack.
    public static let maximumDepth = 32

    public init(blocks: [MarkdownBlock] = [], footnotes: [MarkdownFootnote] = []) {
        self.blocks = blocks
        self.footnotes = footnotes
    }

    public static func parse(_ text: String) -> MarkdownDocument {
        CMarkRegistration.ensure()
        guard let parser = cmark_parser_new(CMARK_OPT_FOOTNOTES) else { return MarkdownDocument() }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        var bytes = Array(text.utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                cmark_parser_feed(parser, $0, buffer.count)
            }
        }
        bytes = []
        guard let root = cmark_parser_finish(parser) else { return MarkdownDocument() }
        defer { cmark_node_free(root) }
        var builder = MarkdownTreeBuilder()
        return builder.document(root)
    }

    /// GitHub's anchor for a heading: lowercased, spaces become hyphens, and punctuation other
    /// than hyphens and underscores is dropped.
    public static func slug(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " { result.append("-") }
            else if scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
                        || CharacterSet.nonBaseCharacters.contains(scalar) { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    /// The text a person reads in these inlines, without any markup.
    public static func plainText(_ inlines: [MarkdownInline]) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case .text(let text), .code(let text), .html(let text): result += text
            case .emphasis(let content), .strong(let content), .strikethrough(let content): result += plainText(content)
            case .link(_, _, let content): result += plainText(content)
            case .image(_, _, let alt): result += alt
            case .softBreak, .lineBreak: result += " "
            case .footnoteReference(let label, _): result += label
            }
        }
        return result
    }
}

private enum CMarkRegistration {
    /// A static initialiser runs once, however many threads get here first.
    private static let registered: Bool = {
        cmark_gfm_core_extensions_ensure_registered()
        return true
    }()
    static func ensure() { _ = registered }
}

/// Walks the cmark tree once, inside one call, so no C pointer outlives the parse.
private struct MarkdownTreeBuilder {
    private var anchors: [String: Int] = [:]
    private var footnoteLabels: [String] = []

    mutating func document(_ root: OpaquePointer) -> MarkdownDocument {
        // cmark-gfm moves the definitions that are referred to to the end, in reference order,
        // and drops the others.
        var definitions: [OpaquePointer] = []
        var node = cmark_node_first_child(root)
        while let current = node {
            if cmark_node_get_type(current) == CMARK_NODE_FOOTNOTE_DEFINITION {
                definitions.append(current)
                footnoteLabels.append(Self.literal(current))
            }
            node = cmark_node_next(current)
        }
        let blocks = children(of: root, depth: 0)
        let footnotes = definitions.enumerated().map { index, definition in
            MarkdownFootnote(label: Self.literal(definition), number: index + 1, blocks: children(of: definition, depth: 1))
        }
        return MarkdownDocument(blocks: blocks, footnotes: footnotes)
    }

    private static func literal(_ node: OpaquePointer) -> String {
        cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }

    private static func typeString(_ node: OpaquePointer) -> String {
        cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    private mutating func children(of parent: OpaquePointer, depth: Int) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var node = cmark_node_first_child(parent)
        while let current = node {
            if let block = block(current, depth: depth) { result.append(block) }
            node = cmark_node_next(current)
        }
        return result
    }

    private mutating func block(_ node: OpaquePointer, depth: Int) -> MarkdownBlock? {
        let type = cmark_node_get_type(node)
        if depth >= MarkdownDocument.maximumDepth {
            guard type != CMARK_NODE_FOOTNOTE_DEFINITION else { return nil }
            return .paragraph([.text(Self.flattenedText(node))])
        }
        switch type {
        case CMARK_NODE_PARAGRAPH:
            return .paragraph(inlines(of: node, depth: depth))
        case CMARK_NODE_HEADING:
            let content = inlines(of: node, depth: depth)
            let base = MarkdownDocument.slug(MarkdownDocument.plainText(content))
            let seen = anchors[base, default: 0]
            anchors[base] = seen + 1
            return .heading(level: Int(cmark_node_get_heading_level(node)), content: content,
                            anchor: seen == 0 ? base : "\(base)-\(seen)")
        case CMARK_NODE_CODE_BLOCK:
            let info = Self.string(cmark_node_get_fence_info(node)).trimmingCharacters(in: .whitespaces)
            let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first.map(String.init)
            var text = Self.literal(node)
            if text.hasSuffix("\n") { text.removeLast() }
            return .code(language: language?.isEmpty == false ? language : nil, text: text)
        case CMARK_NODE_BLOCK_QUOTE:
            return .quote(children(of: node, depth: depth + 1))
        case CMARK_NODE_LIST:
            var items: [MarkdownListItem] = []
            var item = cmark_node_first_child(node)
            while let current = item {
                let task: Bool? = Self.typeString(current) == "tasklist"
                    ? cmark_gfm_extensions_get_tasklist_item_checked(current) : nil
                items.append(MarkdownListItem(task: task, blocks: children(of: current, depth: depth + 1)))
                item = cmark_node_next(current)
            }
            return .list(MarkdownList(ordered: cmark_node_get_list_type(node) == CMARK_ORDERED_LIST,
                                      start: Int(cmark_node_get_list_start(node)),
                                      tight: cmark_node_get_list_tight(node) != 0, items: items))
        case CMARK_NODE_THEMATIC_BREAK:
            return .thematicBreak
        case CMARK_NODE_HTML_BLOCK:
            var text = Self.literal(node)
            while text.hasSuffix("\n") { text.removeLast() }
            return .html(text)
        case CMARK_NODE_FOOTNOTE_DEFINITION:
            return nil
        default:
            if Self.typeString(node) == "table" { return table(node, depth: depth) }
            let content = children(of: node, depth: depth + 1)
            return content.isEmpty ? nil : .quote(content)
        }
    }

    private mutating func table(_ node: OpaquePointer, depth: Int) -> MarkdownBlock {
        let columns = Int(cmark_gfm_extensions_get_table_columns(node))
        var alignments: [MarkdownAlignment] = []
        if let raw = cmark_gfm_extensions_get_table_alignments(node) {
            for index in 0..<columns {
                switch UInt8(raw[index]) {
                case UInt8(ascii: "l"): alignments.append(.left)
                case UInt8(ascii: "c"): alignments.append(.center)
                case UInt8(ascii: "r"): alignments.append(.right)
                default: alignments.append(.none)
                }
            }
        } else {
            alignments = Array(repeating: .none, count: columns)
        }
        var header: [[MarkdownInline]] = []
        var rows: [[[MarkdownInline]]] = []
        var row = cmark_node_first_child(node)
        while let currentRow = row {
            var cells: [[MarkdownInline]] = []
            var cell = cmark_node_first_child(currentRow)
            while let currentCell = cell {
                cells.append(inlines(of: currentCell, depth: depth))
                cell = cmark_node_next(currentCell)
            }
            while cells.count < columns { cells.append([]) }
            if cells.count > columns { cells.removeLast(cells.count - columns) }
            if Self.typeString(currentRow) == "table_header" { header = cells } else { rows.append(cells) }
            row = cmark_node_next(currentRow)
        }
        if header.isEmpty { header = Array(repeating: [], count: columns) }
        return .table(MarkdownTable(alignments: alignments, header: header, rows: rows))
    }

    private mutating func inlines(of parent: OpaquePointer, depth: Int) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var node = cmark_node_first_child(parent)
        while let current = node {
            if let inline = inline(current, depth: depth) {
                // Adjacent text runs (cmark splits text at every bracket) read as one.
                if case .text(let next) = inline, case .text(let previous)? = result.last {
                    result[result.count - 1] = .text(previous + next)
                } else {
                    result.append(inline)
                }
            }
            node = cmark_node_next(current)
        }
        return result
    }

    private mutating func inline(_ node: OpaquePointer, depth: Int) -> MarkdownInline? {
        let type = cmark_node_get_type(node)
        if depth >= MarkdownDocument.maximumDepth { return .text(Self.flattenedText(node)) }
        switch type {
        case CMARK_NODE_TEXT: return .text(Self.literal(node))
        case CMARK_NODE_CODE: return .code(Self.literal(node))
        case CMARK_NODE_SOFTBREAK: return .softBreak
        case CMARK_NODE_LINEBREAK: return .lineBreak
        case CMARK_NODE_HTML_INLINE: return .html(Self.literal(node))
        case CMARK_NODE_EMPH: return .emphasis(inlines(of: node, depth: depth + 1))
        case CMARK_NODE_STRONG: return .strong(inlines(of: node, depth: depth + 1))
        case CMARK_NODE_LINK:
            return .link(destination: Self.string(cmark_node_get_url(node)), title: Self.string(cmark_node_get_title(node)),
                         content: inlines(of: node, depth: depth + 1))
        case CMARK_NODE_IMAGE:
            return .image(source: Self.string(cmark_node_get_url(node)), title: Self.string(cmark_node_get_title(node)),
                          alt: MarkdownDocument.plainText(inlines(of: node, depth: depth + 1)))
        case CMARK_NODE_FOOTNOTE_REFERENCE:
            // cmark-gfm replaces a resolved reference's label with its number, and turns one
            // that nothing defines back into its text.
            let literal = Self.literal(node)
            guard let number = Int(literal), footnoteLabels.indices.contains(number - 1) else {
                return .footnoteReference(label: literal, number: nil)
            }
            return .footnoteReference(label: footnoteLabels[number - 1], number: number)
        default:
            if Self.typeString(node) == "strikethrough" { return .strikethrough(inlines(of: node, depth: depth + 1)) }
            let content = inlines(of: node, depth: depth + 1)
            return content.isEmpty ? nil : .text(MarkdownDocument.plainText(content))
        }
    }

    /// The literal text under a node, gathered with cmark's iterator instead of recursion.
    private static func flattenedText(_ node: OpaquePointer) -> String {
        guard let iterator = cmark_iter_new(node) else { return "" }
        defer { cmark_iter_free(iterator) }
        var result = ""
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            guard event == CMARK_EVENT_ENTER, let current = cmark_iter_get_node(iterator) else { continue }
            switch cmark_node_get_type(current) {
            case CMARK_NODE_TEXT, CMARK_NODE_CODE, CMARK_NODE_HTML_INLINE: result += literal(current)
            case CMARK_NODE_CODE_BLOCK, CMARK_NODE_HTML_BLOCK: result += literal(current)
            case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK: result += " "
            default: break
            }
        }
        return result
    }
}

/// Where a link in a Markdown file leads, decided before anything is opened.
public enum MarkdownLinkTarget: Equatable, Sendable {
    /// http, https or mailto: opened in the default app, and only when clicked.
    case web(URL)
    /// A heading or footnote of the same document.
    case anchor(String)
    /// A file or folder on this Mac, relative to the document or as a file URL: shown in My
    /// Explorer, never opened or run.
    case localFile(URL)
    /// Any other scheme (javascript, data, custom app schemes, a protocol-relative address).
    case refused

    public static func classify(_ destination: String, documentURL: URL) -> MarkdownLinkTarget {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return .refused }
        if trimmed.hasPrefix("#") {
            let fragment = String(trimmed.dropFirst())
            return .anchor((fragment.removingPercentEncoding ?? fragment).lowercased())
        }
        if let scheme = Self.scheme(of: trimmed) {
            switch scheme {
            case "http", "https", "mailto":
                guard let url = URL(string: trimmed) else { return .refused }
                return .web(url)
            case "file":
                guard let url = URL(string: trimmed), url.isFileURL, !url.path.isEmpty else { return .refused }
                return .localFile(url.standardizedFileURL)
            default:
                return .refused
            }
        }
        guard let url = localURL(trimmed, documentURL: documentURL) else { return .refused }
        return .localFile(url)
    }

    /// A relative path (with any query or fragment dropped) resolved against the document's folder.
    static func localURL(_ path: String, documentURL: URL) -> URL? {
        var path = path
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<cut]) }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty else { return nil }
        let folder = documentURL.deletingLastPathComponent()
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        return url.standardizedFileURL
    }

    static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[..<colon]
        guard let first = candidate.first, first.isASCII, first.isLetter,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") })
        else { return nil }
        return candidate.lowercased()
    }
}

/// Where an image in a Markdown file comes from. Only a file on this Mac is ever read.
public enum MarkdownImageSource: Equatable, Sendable {
    case local(URL)
    /// Shown as its description; nothing is downloaded.
    case remote(URL)
    case invalid

    public static func resolve(_ source: String, documentURL: URL) -> MarkdownImageSource {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return .invalid }
        if let scheme = MarkdownLinkTarget.scheme(of: trimmed) {
            switch scheme {
            case "http", "https": return URL(string: trimmed).map { .remote($0) } ?? .invalid
            case "file":
                guard let url = URL(string: trimmed), url.isFileURL else { return .invalid }
                return .local(url.standardizedFileURL.resolvingSymlinksInPath())
            default: return .invalid
            }
        }
        guard let url = MarkdownLinkTarget.localURL(trimmed, documentURL: documentURL) else { return .invalid }
        return .local(url.resolvingSymlinksInPath())
    }
}
