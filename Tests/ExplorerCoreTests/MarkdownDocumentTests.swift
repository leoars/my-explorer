// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ExplorerCore

final class MarkdownDocumentTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRecognizesMarkdownFiles() {
        for name in ["README.md", "Notes.MD", "guide.markdown", "a.mdown", "b.mkd"] {
            XCTAssertTrue(MarkdownFile.isMarkdown(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["notes.txt", "README", "image.png", "md"] {
            XCTAssertFalse(MarkdownFile.isMarkdown(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    func testHeadingsAndAnchors() {
        let document = MarkdownDocument.parse("# Hello, World!\n\n## Hello, World!\n\n### Título com acento\n")
        XCTAssertEqual(document.blocks, [
            .heading(level: 1, content: [.text("Hello, World!")], anchor: "hello-world"),
            .heading(level: 2, content: [.text("Hello, World!")], anchor: "hello-world-1"),
            .heading(level: 3, content: [.text("Título com acento")], anchor: "título-com-acento")
        ])
    }

    func testInlineStyles() {
        let document = MarkdownDocument.parse("Plain **bold** *it* ~~gone~~ `code` [link](https://example.com \"T\")\\\nnext")
        guard case .paragraph(let inlines)? = document.blocks.first else { return XCTFail("No paragraph") }
        XCTAssertEqual(inlines, [
            .text("Plain "), .strong([.text("bold")]), .text(" "), .emphasis([.text("it")]), .text(" "),
            .strikethrough([.text("gone")]), .text(" "), .code("code"), .text(" "),
            .link(destination: "https://example.com", title: "T", content: [.text("link")]), .lineBreak, .text("next")
        ])
    }

    func testAutolinks() {
        guard case .paragraph(let inlines)? = MarkdownDocument.parse("See https://example.com now").blocks.first else { return XCTFail() }
        XCTAssertTrue(inlines.contains(.link(destination: "https://example.com", title: "", content: [.text("https://example.com")])))
    }

    func testNestedListsAndTaskItems() {
        let document = MarkdownDocument.parse("""
        - one
          1. inner
          2. second
        - [x] done
        - [ ] todo

        3. three
        4. four
        """)
        guard case .list(let bullets) = document.blocks[0], case .list(let numbers) = document.blocks[1] else { return XCTFail("Lists") }
        XCTAssertFalse(bullets.ordered)
        XCTAssertTrue(bullets.tight)
        XCTAssertEqual(bullets.items.map(\.task), [nil, true, false])
        guard case .list(let inner)? = bullets.items[0].blocks.last else { return XCTFail("Inner list") }
        XCTAssertTrue(inner.ordered)
        XCTAssertEqual(inner.items.count, 2)
        XCTAssertEqual(bullets.items[1].blocks, [.paragraph([.text("done")])])
        XCTAssertTrue(numbers.ordered)
        XCTAssertEqual(numbers.start, 3)
    }

    func testTableWithAlignment() {
        let document = MarkdownDocument.parse("""
        | Left | Center | Right | None |
        |:-----|:------:|------:|------|
        | a | **b** | c |
        """)
        guard case .table(let table)? = document.blocks.first else { return XCTFail("No table") }
        XCTAssertEqual(table.alignments, [.left, .center, .right, .none])
        XCTAssertEqual(table.header.map(MarkdownDocument.plainText), ["Left", "Center", "Right", "None"])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].count, 4, "Short rows are padded to the column count")
        XCTAssertEqual(table.rows[0][1], [.strong([.text("b")])])
    }

    func testCodeBlocks() {
        let document = MarkdownDocument.parse("```swift title=x\nlet a = 1\n```\n\n    indented\n\n~~~\nplain\n~~~\n")
        XCTAssertEqual(document.blocks, [
            .code(language: "swift", text: "let a = 1"),
            .code(language: nil, text: "indented"),
            .code(language: nil, text: "plain")
        ])
    }

    func testFootnotes() {
        let document = MarkdownDocument.parse("Second[^b] and first[^a] and missing[^x].\n\n[^a]: Alpha\n[^b]: Beta\n[^unused]: Never\n")
        guard case .paragraph(let inlines)? = document.blocks.first else { return XCTFail() }
        let references = inlines.compactMap { inline -> String? in
            if case .footnoteReference(let label, let number?) = inline { return "\(label)=\(number)" }
            return nil
        }
        XCTAssertEqual(references, ["b=1", "a=2"])
        XCTAssertTrue(MarkdownDocument.plainText(inlines).contains("missing[^x]."), "An undefined reference stays as text")
        XCTAssertEqual(document.footnotes.map(\.label), ["b", "a"], "Numbered in the order they are referred to")
        XCTAssertEqual(document.footnotes.map(\.number), [1, 2])
        XCTAssertEqual(document.footnotes[0].blocks, [.paragraph([.text("Beta")])])
        XCTAssertFalse(document.blocks.contains { if case .paragraph(let content) = $0 { return MarkdownDocument.plainText(content).contains("Never") }; return false })
    }

    func testRawHTMLStaysLiteral() {
        let document = MarkdownDocument.parse("<div onclick=\"x()\">block</div>\n\nText <b>bold</b> <script>alert(1)</script>\n")
        XCTAssertEqual(document.blocks.first, .html("<div onclick=\"x()\">block</div>"))
        guard case .paragraph(let inlines)? = document.blocks.last else { return XCTFail() }
        XCTAssertEqual(MarkdownDocument.plainText(inlines), "Text <b>bold</b> <script>alert(1)</script>")
        XCTAssertTrue(inlines.contains(.html("<b>")))
    }

    func testImagesQuotesAndBreaks() {
        let document = MarkdownDocument.parse("> quoted\n> > deeper\n\n---\n\n![A *cat*](cat.png \"Title\")\n")
        guard case .quote(let quote) = document.blocks[0] else { return XCTFail() }
        XCTAssertEqual(quote.first, .paragraph([.text("quoted")]))
        guard case .quote? = quote.last else { return XCTFail("Nested quote") }
        XCTAssertEqual(document.blocks[1], .thematicBreak)
        XCTAssertEqual(document.blocks[2], .paragraph([.image(source: "cat.png", title: "Title", alt: "A cat")]))
    }

    func testEmptyDocument() {
        XCTAssertEqual(MarkdownDocument.parse(""), MarkdownDocument())
        XCTAssertEqual(MarkdownDocument.parse("\n\n  \n"), MarkdownDocument())
    }

    func testDeepNestingIsFlattened() {
        let quotes = String(repeating: ">", count: 10_000) + " deep\n"
        let lists = (0..<2_000).map { String(repeating: "  ", count: $0) + "- level" }.joined(separator: "\n")
        let emphasis = String(repeating: "*a ", count: 5_000) + "b" + String(repeating: " a*", count: 5_000)
        let start = Date()
        for text in [quotes, lists, emphasis] {
            let document = MarkdownDocument.parse(text)
            XCTAssertFalse(document.blocks.isEmpty)
            XCTAssertLessThanOrEqual(depth(document.blocks), MarkdownDocument.maximumDepth + 1)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testPathologicalTwoMegabytes() {
        let row = "| a | b | c |\n"
        let text = "| x | y | z |\n|---|---|---|\n" + String(repeating: row, count: MarkdownFile.byteLimit / row.utf8.count - 4)
        let start = Date()
        guard case .table(let table)? = MarkdownDocument.parse(text).blocks.first else { return XCTFail() }
        XCTAssertGreaterThan(table.rows.count, 100_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    private func depth(_ blocks: [MarkdownBlock]) -> Int {
        blocks.map { block -> Int in
            switch block {
            case .quote(let inner): return 1 + depth(inner)
            case .list(let list): return 1 + (list.items.map { depth($0.blocks) }.max() ?? 0)
            default: return 0
            }
        }.max() ?? 0
    }

    // MARK: - Reading the file

    func testLoadReadsUTF8AndDropsByteOrderMark() throws {
        let url = folder.appendingPathComponent("bom.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("# Olá".utf8)).write(to: url)
        XCTAssertEqual(MarkdownFile.load(url), .text("# Olá"))
    }

    func testLoadRefusesOversizeFiles() throws {
        let url = folder.appendingPathComponent("big.md")
        try Data(repeating: 65, count: 101).write(to: url)
        XCTAssertEqual(MarkdownFile.load(url, limit: 100), .tooLarge)
        XCTAssertEqual(MarkdownFile.load(url, limit: 101), .text(String(repeating: "A", count: 101)))
    }

    func testLoadRefusesTextThatIsNotUTF8() throws {
        let url = folder.appendingPathComponent("latin1.md")
        try Data([0x23, 0x20, 0x4F, 0x6C, 0xE1]).write(to: url)
        XCTAssertEqual(MarkdownFile.load(url), .notUTF8)
    }

    func testLoadRefusesMissingFilesAndFolders() {
        XCTAssertEqual(MarkdownFile.load(folder.appendingPathComponent("missing.md")), .unreadable)
        XCTAssertEqual(MarkdownFile.load(folder), .unreadable)
    }

    func testLoadEmptyFile() throws {
        let url = folder.appendingPathComponent("empty.md")
        try Data().write(to: url)
        XCTAssertEqual(MarkdownFile.load(url), .text(""))
    }

    // MARK: - Links and images

    func testLinkClassification() {
        let document = URL(fileURLWithPath: "/Users/someone/Docs/README.md")
        XCTAssertEqual(MarkdownLinkTarget.classify("https://example.com/a", documentURL: document), .web(URL(string: "https://example.com/a")!))
        XCTAssertEqual(MarkdownLinkTarget.classify("HTTP://example.com", documentURL: document), .web(URL(string: "HTTP://example.com")!))
        XCTAssertEqual(MarkdownLinkTarget.classify("mailto:a@example.com", documentURL: document), .web(URL(string: "mailto:a@example.com")!))
        XCTAssertEqual(MarkdownLinkTarget.classify("#Getting%20Started", documentURL: document), .anchor("getting started"))
        XCTAssertEqual(MarkdownLinkTarget.classify("docs/Guide.md#part", documentURL: document),
                       .localFile(URL(fileURLWithPath: "/Users/someone/Docs/docs/Guide.md")))
        XCTAssertEqual(MarkdownLinkTarget.classify("../Other%20File.txt", documentURL: document),
                       .localFile(URL(fileURLWithPath: "/Users/someone/Other File.txt")))
        XCTAssertEqual(MarkdownLinkTarget.classify("file:///Applications/Calculator.app", documentURL: document),
                       .localFile(URL(fileURLWithPath: "/Applications/Calculator.app")))
        for refused in ["javascript:alert(1)", "data:text/html,x", "x-apple-helpviewer://x", "ftp://example.com",
                        "//evil.example.com", "", "   ", "vbscript:x", "myexplorer://run"] {
            XCTAssertEqual(MarkdownLinkTarget.classify(refused, documentURL: document), .refused, refused)
        }
    }

    func testImageSources() throws {
        let document = folder.appendingPathComponent("README.md")
        XCTAssertEqual(MarkdownImageSource.resolve("https://example.com/a.png", documentURL: document),
                       .remote(URL(string: "https://example.com/a.png")!))
        XCTAssertEqual(MarkdownImageSource.resolve("data:image/png;base64,AAAA", documentURL: document), .invalid)
        XCTAssertEqual(MarkdownImageSource.resolve("//cdn.example.com/a.png", documentURL: document), .invalid)
        let real = folder.appendingPathComponent("real.png")
        try Data([1]).write(to: real)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.png"), withDestinationURL: real)
        guard case .local(let resolved) = MarkdownImageSource.resolve("link.png", documentURL: document) else { return XCTFail() }
        XCTAssertEqual(resolved.path, real.resolvingSymlinksInPath().path)
    }

    // MARK: - Highlighting

    func testHighlightsSwift() throws {
        let code = "// note\nlet name: String = \"x\" + 42"
        let language = try XCTUnwrap(CodeHighlighter.language(named: "Swift"))
        let tokens = CodeHighlighter.tokens(code, language: language)
        func text(_ token: CodeToken) -> String { (code as NSString).substring(with: NSRange(location: token.range.lowerBound, length: token.range.count)) }
        XCTAssertEqual(tokens.map { "\($0.kind):\(text($0))" }, ["comment:// note", "keyword:let", "type:String", "string:\"x\"", "number:42"])
    }

    func testHighlightsPythonJSONAndMarkup() throws {
        let python = "def f():\n    \"\"\"doc\nmore\"\"\"  # c\n    return None"
        let pyTokens = CodeHighlighter.tokens(python, language: try XCTUnwrap(CodeHighlighter.language(named: "py")))
        XCTAssertEqual(pyTokens.map(\.kind), [.keyword, .string, .comment, .keyword, .keyword])

        let json = "{\"key\": [1, true, \"v\"]}"
        let jsonTokens = CodeHighlighter.tokens(json, language: try XCTUnwrap(CodeHighlighter.language(named: "json")))
        XCTAssertEqual(jsonTokens.map(\.kind), [.attribute, .number, .keyword, .string])

        let html = "<!-- c --><a href=\"x\">t</a>"
        let htmlTokens = CodeHighlighter.tokens(html, language: try XCTUnwrap(CodeHighlighter.language(named: "html")))
        XCTAssertEqual(htmlTokens.map(\.kind), [.comment, .tag, .attribute, .string, .tag, .tag, .tag])

        let sql = "SELECT name FROM users -- all"
        let sqlTokens = CodeHighlighter.tokens(sql, language: try XCTUnwrap(CodeHighlighter.language(named: "sql")))
        XCTAssertEqual(sqlTokens.map(\.kind), [.keyword, .keyword, .comment])
    }

    func testCoversCommonLanguagesAndLeavesOthersPlain() throws {
        for name in ["swift", "c", "cpp", "objc", "js", "ts", "python", "sh", "bash", "json", "yaml", "html", "xml", "css",
                     "sql", "ruby", "go", "rust", "java", "kotlin", "csharp", "php"] {
            XCTAssertNotNil(CodeHighlighter.language(named: name), name)
        }
        XCTAssertNil(CodeHighlighter.language(named: "brainfudge"))
        let language = try XCTUnwrap(CodeHighlighter.language(named: "swift"))
        XCTAssertEqual(CodeHighlighter.tokens(String(repeating: "let ", count: CodeHighlighter.maximumLength), language: language), [])
    }

    func testUnterminatedStringsAndCommentsEndAtTheBlock() throws {
        let language = try XCTUnwrap(CodeHighlighter.language(named: "c"))
        XCTAssertEqual(CodeHighlighter.tokens("/* open", language: language), [CodeToken(range: 0..<7, kind: .comment)])
        XCTAssertEqual(CodeHighlighter.tokens("\"open\\", language: language).last?.range.upperBound, 6)
    }
}
