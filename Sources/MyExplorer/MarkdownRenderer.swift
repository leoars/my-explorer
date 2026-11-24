// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

extension NSAttributedString.Key {
    /// A heading's or footnote's anchor (`getting-started`, `fn-1`, `fnref-1`), for links inside the document.
    static let markdownAnchor = NSAttributedString.Key("MyExplorerMarkdownAnchor")
    /// The local image a placeholder stands for until the image is read (an NSURL).
    static let markdownImage = NSAttributedString.Key("MyExplorerMarkdownImage")
}

/// What a link in the rendered document leads to. Only `MarkdownPreviewView` acts on it, and only
/// when it is clicked.
final class MarkdownLink: NSObject, @unchecked Sendable {
    let target: MarkdownLinkTarget
    init(_ target: MarkdownLinkTarget) { self.target = target }
}

/// What the renderer needs from the interface, taken on the main thread before it runs elsewhere.
struct MarkdownRenderStyle: Sendable {
    var baseSize: CGFloat
    var imageFormat: String
    var untitledImage: String
    var footnoteBack: String
}

/// Turns a parsed Markdown document into text the preview pane lays out. It runs off the main
/// thread. Colors are dynamic, so the result follows light and dark appearance by itself.
enum MarkdownRenderer {
    static func render(_ document: MarkdownDocument, documentURL: URL, style: MarkdownRenderStyle) -> NSAttributedString {
        var builder = Builder(style: style, documentURL: documentURL)
        builder.blocks(document.blocks, Context(spacing: style.baseSize * 0.65))
        if !document.footnotes.isEmpty { builder.footnotes(document.footnotes) }
        if builder.output.length > 0, builder.output.string.hasSuffix("\n") {
            builder.output.deleteCharacters(in: NSRange(location: builder.output.length - 1, length: 1))
        }
        return builder.output
    }

    static func source(_ text: String, style: MarkdownRenderStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: style.baseSize * 0.95, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
    }

    // MARK: - Colors

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } == true ? dark : light
        }
    }
    static var codeBackground: NSColor {
        dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.08))
    }
    static var rule: NSColor {
        dynamic(light: NSColor(white: 0, alpha: 0.15), dark: NSColor(white: 1, alpha: 0.18))
    }
    static var headerBackground: NSColor {
        dynamic(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.06))
    }
    static func color(for kind: CodeTokenKind) -> NSColor {
        switch kind {
        case .keyword: return .systemPink
        case .string: return dynamic(light: NSColor(srgbRed: 0.77, green: 0.10, blue: 0.09, alpha: 1), dark: NSColor(srgbRed: 0.99, green: 0.42, blue: 0.36, alpha: 1))
        case .comment: return .secondaryLabelColor
        case .number: return .systemPurple
        case .type: return .systemTeal
        case .tag: return .systemBlue
        case .attribute: return .systemOrange
        }
    }

    // MARK: - Building

    struct Context {
        var indent: CGFloat = 0
        var blocks: [NSTextBlock] = []
        var color: NSColor = .labelColor
        var spacing: CGFloat
    }

    private struct InlineStyle {
        var size: CGFloat
        var bold = false
        var italic = false
        var strike = false
        var color: NSColor
        var link: MarkdownLink?
        var toolTip: String?
    }

    private struct Builder {
        let style: MarkdownRenderStyle
        let documentURL: URL
        let output = NSMutableAttributedString()
        private var firstReference: Set<Int> = []
        private var base: CGFloat { style.baseSize }

        init(style: MarkdownRenderStyle, documentURL: URL) {
            self.style = style
            self.documentURL = documentURL
        }

        // MARK: Blocks

        mutating func blocks(_ blocks: [MarkdownBlock], _ context: Context) {
            for block in blocks { self.block(block, context) }
        }

        private func paragraphStyle(_ context: Context, first: CGFloat? = nil, head: CGFloat? = nil, before: CGFloat = 0,
                                    after: CGFloat, alignment: NSTextAlignment = .natural, tabs: [CGFloat] = []) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = first ?? context.indent
            paragraph.headIndent = head ?? context.indent
            paragraph.paragraphSpacingBefore = before
            paragraph.paragraphSpacing = after
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.textBlocks = context.blocks
            paragraph.tabStops = tabs.map { NSTextTab(textAlignment: .natural, location: $0) }
            paragraph.defaultTabInterval = base * 2
            return paragraph
        }

        /// Appends one paragraph and its line end, all with the same paragraph style.
        private func append(_ content: NSAttributedString, _ paragraph: NSParagraphStyle) {
            let start = output.length
            output.append(content)
            output.append(NSAttributedString(string: "\n", attributes: content.length > 0
                ? content.attributes(at: content.length - 1, effectiveRange: nil) : [.font: NSFont.systemFont(ofSize: base)]))
            output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: output.length - start))
        }

        /// Makes the last paragraph leave at least this much room after itself.
        private func ensureSpacing(_ spacing: CGFloat) {
            guard output.length > 0 else { return }
            let range = (output.string as NSString).paragraphRange(for: NSRange(location: output.length - 1, length: 0))
            guard let current = output.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  current.paragraphSpacing < spacing,
                  let copy = current.mutableCopy() as? NSMutableParagraphStyle else { return }
            copy.paragraphSpacing = spacing
            output.addAttribute(.paragraphStyle, value: copy, range: range)
        }

        /// A block (code, quote, rule, heading underline) that starts at the context's indent.
        private func textBlock(_ context: Context, after: CGFloat) -> NSTextBlock {
            let block = NSTextBlock()
            // Without a width of its own a block keeps the width of its first layout.
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            block.setWidth(after, type: .absoluteValueType, for: .margin, edge: .maxY)
            return block
        }

        private mutating func block(_ block: MarkdownBlock, _ context: Context) {
            switch block {
            case .paragraph(let content):
                append(inlines(content, InlineStyle(size: base, color: context.color)), paragraphStyle(context, after: context.spacing))
            case .heading(let level, let content, let anchor):
                let scale: [CGFloat] = [1.75, 1.45, 1.22, 1.08, 1.0, 0.92]
                let size = base * scale[min(max(level, 1), 6) - 1]
                let text = NSMutableAttributedString(attributedString: inlines(content, InlineStyle(size: size, bold: true, color: level == 6 ? .secondaryLabelColor : context.color)))
                if text.length == 0 { text.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: size)])) }
                text.addAttribute(.markdownAnchor, value: anchor, range: NSRange(location: 0, length: text.length))
                var headingContext = context
                if level <= 2 {
                    let underline = textBlock(context, after: base * 0.55)
                    underline.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    underline.setBorderColor(MarkdownRenderer.rule, for: .maxY)
                    underline.setWidth(base * 0.25, type: .absoluteValueType, for: .padding, edge: .maxY)
                    headingContext.blocks.append(underline)
                    headingContext.indent = 0
                }
                append(text, paragraphStyle(headingContext, before: output.length == 0 ? 0 : base * 0.7,
                                            after: level <= 2 ? 0 : base * 0.45))
            case .code(let language, let text):
                code(text, language: language, context)
            case .quote(let content):
                guard !content.isEmpty else { return }
                let quote = textBlock(context, after: context.spacing)
                quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                quote.setBorderColor(MarkdownRenderer.rule, for: .minX)
                quote.setWidth(base * 0.8, type: .absoluteValueType, for: .padding, edge: .minX)
                quote.setWidth(base * 0.3, type: .absoluteValueType, for: .margin, edge: .minY)
                var inner = context
                inner.indent = 0
                inner.blocks.append(quote)
                inner.color = .secondaryLabelColor
                let start = output.length
                blocks(content, inner)
                // The last paragraph's own spacing would sit inside the quote's border.
                if output.length > start { lastParagraphSpacing(0) }
            case .list(let list):
                self.list(list, context)
            case .table(let table):
                self.table(table, context)
            case .thematicBreak:
                let rule = textBlock(context, after: context.spacing)
                rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(MarkdownRenderer.rule, for: .maxY)
                rule.setWidth(base * 0.3, type: .absoluteValueType, for: .margin, edge: .minY)
                var inner = context
                inner.indent = 0
                inner.blocks.append(rule)
                append(NSAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 2)]), paragraphStyle(inner, after: 0))
            case .html(let text):
                let literal = NSAttributedString(string: text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: base * 0.88, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor])
                append(literal, paragraphStyle(context, after: context.spacing))
            }
        }

        private func lastParagraphSpacing(_ spacing: CGFloat) {
            guard output.length > 0 else { return }
            let range = (output.string as NSString).paragraphRange(for: NSRange(location: output.length - 1, length: 0))
            guard let current = output.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let copy = current.mutableCopy() as? NSMutableParagraphStyle else { return }
            copy.paragraphSpacing = spacing
            output.addAttribute(.paragraphStyle, value: copy, range: range)
        }

        private func code(_ text: String, language: String?, _ context: Context) {
            let block = textBlock(context, after: context.spacing)
            block.backgroundColor = MarkdownRenderer.codeBackground
            block.setWidth(base * 0.7, type: .absoluteValueType, for: .padding)
            // A table's own bottom margin is not laid out; this keeps a block from touching it.
            block.setWidth(base * 0.5, type: .absoluteValueType, for: .margin, edge: .minY)
            var inner = context
            inner.indent = 0
            inner.blocks.append(block)
            let font = NSFont.monospacedSystemFont(ofSize: base * 0.88, weight: .regular)
            let body = NSMutableAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            if let language, let highlighter = CodeHighlighter.language(named: language) {
                for token in CodeHighlighter.tokens(text, language: highlighter) where token.range.upperBound <= body.length {
                    body.addAttribute(.foregroundColor, value: MarkdownRenderer.color(for: token.kind),
                                      range: NSRange(location: token.range.lowerBound, length: token.range.count))
                }
            }
            // Lines of code do not wrap at word boundaries differently from the source.
            let paragraph = paragraphStyle(inner, after: 0).mutableCopy() as! NSMutableParagraphStyle
            paragraph.lineBreakMode = .byCharWrapping
            append(body, paragraph)
        }

        private mutating func list(_ list: MarkdownList, _ context: Context) {
            let nested = context.indent > 0
            let spacing = list.tight ? base * 0.2 : context.spacing
            let last = list.start + list.items.count - 1
            let numberWidth = CGFloat(String(max(last, 1)).count) * base * 0.62 + base * 0.9
            let markerWidth = list.ordered ? max(base * 1.6, numberWidth) : base * 1.4
            let bullets = ["•", "◦", "▪"]
            let level = Int((context.indent / (base * 1.4)).rounded())
            for (index, item) in list.items.enumerated() {
                let marker: String
                switch item.task {
                case .some(true): marker = "☑"
                case .some(false): marker = "☐"
                case .none: marker = list.ordered ? "\(list.start + index)." : bullets[level % bullets.count]
                }
                var inner = context
                inner.indent = context.indent + (item.task != nil ? base * 1.5 : markerWidth)
                inner.spacing = spacing
                let markerText = NSAttributedString(string: marker + "\t", attributes: [
                    .font: NSFont.systemFont(ofSize: item.task != nil ? base * 1.05 : base),
                    .foregroundColor: item.task == true ? NSColor.controlAccentColor : context.color])
                var remaining = item.blocks
                let content = NSMutableAttributedString(attributedString: markerText)
                if case .paragraph(let first)? = remaining.first {
                    content.append(inlines(first, InlineStyle(size: base, color: context.color)))
                    remaining.removeFirst()
                }
                append(content, paragraphStyle(inner, first: context.indent, head: inner.indent, after: spacing, tabs: [inner.indent]))
                blocks(remaining, inner)
            }
            if !nested || !list.tight { ensureSpacing(context.spacing) }
        }

        private mutating func table(_ table: MarkdownTable, _ context: Context) {
            let columns = max(table.header.count, 1)
            let grid = NSTextTable()
            grid.numberOfColumns = columns
            grid.layoutAlgorithm = .automaticLayoutAlgorithm
            grid.collapsesBorders = true
            grid.setContentWidth(100, type: .percentageValueType)
            grid.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            grid.setWidth(context.spacing, type: .absoluteValueType, for: .margin, edge: .maxY)
            let rows = [table.header] + table.rows
            for (rowIndex, row) in rows.enumerated() {
                for column in 0..<columns {
                    let cell = NSTextTableBlock(table: grid, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(MarkdownRenderer.rule)
                    cell.setWidth(base * 0.3, type: .absoluteValueType, for: .padding, edge: .minY)
                    cell.setWidth(base * 0.3, type: .absoluteValueType, for: .padding, edge: .maxY)
                    cell.setWidth(base * 0.5, type: .absoluteValueType, for: .padding, edge: .minX)
                    cell.setWidth(base * 0.5, type: .absoluteValueType, for: .padding, edge: .maxX)
                    if rowIndex == 0 { cell.backgroundColor = MarkdownRenderer.headerBackground }
                    var inner = context
                    inner.indent = 0
                    inner.blocks.append(cell)
                    let content = column < row.count ? row[column] : []
                    let text = NSMutableAttributedString(attributedString: inlines(content, InlineStyle(size: base * 0.95, bold: rowIndex == 0, color: context.color)))
                    if text.length == 0 { text.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: base * 0.95)])) }
                    let alignment: NSTextAlignment
                    switch column < table.alignments.count ? table.alignments[column] : .none {
                    case .left: alignment = .left
                    case .center: alignment = .center
                    case .right: alignment = .right
                    case .none: alignment = .natural
                    }
                    append(text, paragraphStyle(inner, after: 0, alignment: alignment))
                }
            }
        }

        mutating func footnotes(_ footnotes: [MarkdownFootnote]) {
            let context = Context(spacing: base * 0.4)
            block(.thematicBreak, Context(spacing: base * 0.5))
            let markerWidth = CGFloat(String(footnotes.count).count) * base * 0.55 + base * 1.0
            for footnote in footnotes {
                var inner = context
                inner.indent = markerWidth
                let small = base * 0.9
                let marker = NSMutableAttributedString(string: "\(footnote.number).\t", attributes: [
                    .font: NSFont.systemFont(ofSize: small), .foregroundColor: NSColor.secondaryLabelColor])
                marker.addAttribute(.markdownAnchor, value: "fn-\(footnote.number)", range: NSRange(location: 0, length: marker.length - 1))
                var remaining = footnote.blocks
                if case .paragraph(let first)? = remaining.first {
                    marker.append(inlines(first, InlineStyle(size: small, color: .secondaryLabelColor)))
                    remaining.removeFirst()
                }
                append(marker, paragraphStyle(inner, first: 0, head: markerWidth, after: context.spacing, tabs: [markerWidth]))
                blocks(remaining, inner)
                let back = NSAttributedString(string: " ↩︎", attributes: [
                    .font: NSFont.systemFont(ofSize: small), .foregroundColor: NSColor.linkColor,
                    .link: MarkdownLink(.anchor("fnref-\(footnote.number)")), .toolTip: style.footnoteBack])
                output.insert(back, at: max(0, output.length - 1))
            }
        }

        // MARK: Inlines

        private func font(_ style: InlineStyle, monospaced: Bool = false) -> NSFont {
            let size = monospaced ? style.size * 0.9 : style.size
            let weight: NSFont.Weight = style.bold ? .semibold : .regular
            let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
            guard style.italic else { return font }
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            return NSFont(descriptor: descriptor, size: size) ?? font
        }

        private func attributes(_ style: InlineStyle, monospaced: Bool = false) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [.font: font(style, monospaced: monospaced), .foregroundColor: style.color]
            if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = style.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
            }
            if let toolTip = style.toolTip { attributes[.toolTip] = toolTip }
            return attributes
        }

        private mutating func inlines(_ inlines: [MarkdownInline], _ style: InlineStyle) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for inline in inlines {
                switch inline {
                case .text(let text):
                    result.append(NSAttributedString(string: text, attributes: attributes(style)))
                case .code(let text):
                    var codeAttributes = attributes(style, monospaced: true)
                    codeAttributes[.backgroundColor] = MarkdownRenderer.codeBackground
                    result.append(NSAttributedString(string: text, attributes: codeAttributes))
                case .emphasis(let content):
                    var inner = style; inner.italic = true
                    result.append(self.inlines(content, inner))
                case .strong(let content):
                    var inner = style; inner.bold = true
                    result.append(self.inlines(content, inner))
                case .strikethrough(let content):
                    var inner = style; inner.strike = true
                    result.append(self.inlines(content, inner))
                case .link(let destination, let title, let content):
                    var inner = style
                    let target = MarkdownLinkTarget.classify(destination, documentURL: documentURL)
                    inner.link = target == .refused ? nil : MarkdownLink(target)
                    inner.toolTip = title.isEmpty ? destination : "\(title)\n\(destination)"
                    result.append(self.inlines(content, inner))
                case .image(let source, let title, let alt):
                    result.append(image(source: source, title: title, alt: alt, style))
                case .softBreak:
                    result.append(NSAttributedString(string: " ", attributes: attributes(style)))
                case .lineBreak:
                    result.append(NSAttributedString(string: "\u{2028}", attributes: attributes(style)))
                case .html(let text):
                    var inner = style; inner.color = .secondaryLabelColor
                    result.append(NSAttributedString(string: text, attributes: attributes(inner, monospaced: true)))
                case .footnoteReference(let label, let number):
                    guard let number else {
                        result.append(NSAttributedString(string: "[^\(label)]", attributes: attributes(style)))
                        continue
                    }
                    var inner = style
                    inner.size = style.size * 0.75
                    inner.link = MarkdownLink(.anchor("fn-\(number)"))
                    inner.toolTip = label
                    var referenceAttributes = attributes(inner)
                    referenceAttributes[.baselineOffset] = style.size * 0.35
                    if firstReference.insert(number).inserted { referenceAttributes[.markdownAnchor] = "fnref-\(number)" }
                    result.append(NSAttributedString(string: "\(number)", attributes: referenceAttributes))
                }
            }
            return result
        }

        /// An image is first its description; a local one is replaced by the picture once it has
        /// been read. A remote one is never fetched: its description links to it.
        private func image(source: String, title: String, alt: String, _ style: InlineStyle) -> NSAttributedString {
            let description = alt.isEmpty ? (title.isEmpty ? self.style.untitledImage : title) : alt
            var inner = style
            inner.color = .secondaryLabelColor
            inner.toolTip = title.isEmpty ? source : "\(title)\n\(source)"
            var extra: [NSAttributedString.Key: Any] = [:]
            switch MarkdownImageSource.resolve(source, documentURL: documentURL) {
            case .local(let url): extra[.markdownImage] = url as NSURL
            case .remote(let url): inner.link = MarkdownLink(.web(url))
            case .invalid: break
            }
            let text = "🖼\u{00A0}" + String(format: self.style.imageFormat, description)
            var all = attributes(inner)
            all.merge(extra) { $1 }
            return NSAttributedString(string: text, attributes: all)
        }
    }
}

