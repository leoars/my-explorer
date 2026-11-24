// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum CodeTokenKind: Equatable, Sendable {
    case keyword, string, comment, number, type, tag, attribute
}

/// A highlighted stretch of a code block, in UTF-16 offsets (as NSString and NSRange count).
public struct CodeToken: Equatable, Sendable {
    public var range: Range<Int>
    public var kind: CodeTokenKind
}

/// A small lexical highlighter for the fenced code blocks of a Markdown preview: keywords,
/// strings, comments, numbers and type names, or tags and attributes for markup. It never runs
/// code and does not try to be a parser; an unknown language is left plain.
public enum CodeHighlighter {
    /// Longer blocks are shown plain.
    public static let maximumLength = 128 * 1024

    public struct Language: Sendable {
        public let name: String
        let style: Style
        let keywords: Set<String>
        let types: Set<String>
        let lineComments: [String]
        let blockComments: [(String, String)]
        let quotes: [Character]
        let tripleQuotes: Bool
        let caseInsensitive: Bool
        let capitalizedTypes: Bool
        let identifierExtras: Set<Character>
        let keysBeforeColon: Bool

        enum Style: Sendable { case code, markup, css }
    }

    public static func language(named info: String) -> Language? {
        let name = info.lowercased()
        return languages.first { $0.aliases.contains(name) }?.language
    }

    public static func tokens(_ code: String, language: Language) -> [CodeToken] {
        let units = Array(code.utf16)
        guard units.count <= maximumLength else { return [] }
        switch language.style {
        case .markup: return markupTokens(units)
        case .code, .css: return codeTokens(units, language)
        }
    }

    // MARK: - Languages

    private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    private static let languages: [(aliases: Set<String>, language: Language)] = {
        func code(_ name: String, keywords: String, types: String = "", line: [String] = ["//"],
                  block: [(String, String)] = [("/*", "*/")], quotes: [Character] = ["\"", "'"],
                  triple: Bool = false, caseInsensitive: Bool = false, capitalizedTypes: Bool = false,
                  extras: Set<Character> = ["_"], keysBeforeColon: Bool = false, style: Language.Style = .code) -> Language {
            Language(name: name, style: style, keywords: CodeHighlighter.words(keywords), types: CodeHighlighter.words(types),
                     lineComments: line, blockComments: block, quotes: quotes, tripleQuotes: triple,
                     caseInsensitive: caseInsensitive, capitalizedTypes: capitalizedTypes,
                     identifierExtras: extras, keysBeforeColon: keysBeforeColon)
        }
        let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL nullptr"
        let cppKeywords = cKeywords + " class namespace template typename public private protected virtual override final new delete this operator using try catch throw noexcept constexpr auto decltype friend mutable explicit static_cast dynamic_cast reinterpret_cast const_cast"
        let objcKeywords = cKeywords + " @interface @implementation @end @property @protocol @selector @class @synthesize @autoreleasepool @try @catch @finally @import self super nil YES NO id instancetype nonatomic strong weak copy readonly readwrite assign"
        let jsKeywords = "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield true false null undefined"
        let tsKeywords = jsKeywords + " abstract any as asserts bigint boolean declare enum implements infer interface is keyof module namespace never number object private protected public readonly string symbol type unique unknown"
        return [
            (["swift"], code("Swift", keywords: "actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate for func guard if import in indirect init inout internal is lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while @MainActor @escaping @Sendable @objc @available @discardableResult @State @Published",
                                 types: "Int Double Float String Bool Character Array Dictionary Set Optional Result Void Never Any URL Data Date UInt Int64 UInt8", triple: true, capitalizedTypes: true, extras: ["_", "@", "#"])),
            (["c", "h"], code("C", keywords: cKeywords, types: "size_t ssize_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t FILE", extras: ["_", "#"])),
            (["cpp", "c++", "cc", "cxx", "hpp"], code("C++", keywords: cppKeywords, types: "std string vector map set unique_ptr shared_ptr size_t", extras: ["_", "#"])),
            (["objc", "objective-c", "objectivec", "m", "mm"], code("Objective-C", keywords: objcKeywords, capitalizedTypes: true, extras: ["_", "#", "@"])),
            (["csharp", "cs", "c#"], code("C#", keywords: "abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly record ref return sbyte sealed short sizeof static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using var virtual void volatile while", capitalizedTypes: true, extras: ["_", "@"])),
            (["java"], code("Java", keywords: "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new null package private protected public record return short static strictfp super switch synchronized this throw throws transient true false try var void volatile while", capitalizedTypes: true, extras: ["_", "@"])),
            (["kotlin", "kt", "kts"], code("Kotlin", keywords: "as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor data enum finally get import init inner internal open override private protected public sealed set suspend companion lateinit", triple: true, capitalizedTypes: true, extras: ["_", "@"])),
            (["javascript", "js", "jsx", "mjs", "cjs"], code("JavaScript", keywords: jsKeywords, quotes: ["\"", "'", "`"], capitalizedTypes: true, extras: ["_", "$"])),
            (["typescript", "ts", "tsx"], code("TypeScript", keywords: tsKeywords, quotes: ["\"", "'", "`"], capitalizedTypes: true, extras: ["_", "$"])),
            (["python", "py", "python3"], code("Python", keywords: "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield match case self print len range", types: "int float str bool list dict set tuple bytes object", line: ["#"], block: [], triple: true, capitalizedTypes: true, extras: ["_", "@"])),
            (["ruby", "rb"], code("Ruby", keywords: "alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require attr_accessor attr_reader puts", line: ["#"], block: [("=begin", "=end")], capitalizedTypes: true, extras: ["_", "@", "$", "?", "!"])),
            (["go", "golang"], code("Go", keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota", types: "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any", quotes: ["\"", "'", "`"])),
            (["rust", "rs"], code("Rust", keywords: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while macro_rules", types: "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box", quotes: ["\""], capitalizedTypes: true)),
            (["php"], code("PHP", keywords: "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include instanceof insteadof interface isset list match namespace new or print private protected public readonly require return static switch throw trait try unset use var while xor yield true false null", line: ["//", "#"], capitalizedTypes: true, extras: ["_", "$"])),
            (["shell", "sh", "bash", "zsh", "console", "shellscript", "fish"], code("Shell", keywords: "if then else elif fi case esac for while until do done in function select return exit break continue local export readonly declare set unset shift source alias echo printf cd test true false sudo", line: ["#"], block: [], quotes: ["\"", "'", "`"], extras: ["_", "-", "$"])),
            (["powershell", "ps1", "pwsh"], code("PowerShell", keywords: "begin break catch class continue data define do dynamicparam else elseif end exit filter finally for foreach from function if in param process return switch throw trap try until using var while", line: ["#"], block: [("<#", "#>")], caseInsensitive: true, extras: ["_", "-", "$"])),
            (["sql", "mysql", "postgresql", "postgres", "sqlite"], code("SQL", keywords: "select from where and or not insert into values update set delete create table drop alter add column index view primary key foreign references join inner left right outer full on as group by order having limit offset union all distinct case when then else end null is in like between exists default unique check constraint begin commit rollback transaction with returning asc desc count sum avg min max", types: "int integer bigint smallint varchar char text boolean date timestamp numeric decimal real float blob", line: ["--"], quotes: ["'", "\""], caseInsensitive: true)),
            (["json", "jsonc", "json5"], code("JSON", keywords: "true false null", quotes: ["\""], keysBeforeColon: true)),
            (["yaml", "yml"], code("YAML", keywords: "true false null yes no on off", line: ["#"], block: [], keysBeforeColon: true)),
            (["toml", "ini", "cfg", "conf"], code("TOML", keywords: "true false", line: ["#", ";"], block: [], triple: true, keysBeforeColon: false)),
            (["css", "scss", "sass", "less"], code("CSS", keywords: "@media @import @font-face @keyframes @supports @charset @layer @container !important", block: [("/*", "*/")], extras: ["_", "-", "@", "!"], keysBeforeColon: true, style: .css)),
            (["html", "htm", "xml", "xhtml", "svg", "plist", "vue"], Language(name: "Markup", style: .markup, keywords: [], types: [], lineComments: [], blockComments: [], quotes: ["\"", "'"], tripleQuotes: false, caseInsensitive: false, capitalizedTypes: false, identifierExtras: [], keysBeforeColon: false)),
            (["dockerfile", "docker"], code("Dockerfile", keywords: "FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS", line: ["#"], block: [], caseInsensitive: true)),
            (["makefile", "make"], code("Makefile", keywords: "ifeq ifneq ifdef ifndef else endif include define endef export override", line: ["#"], block: [], extras: ["_", "-", "$"])),
            (["lua"], code("Lua", keywords: "and break do else elseif end false for function goto if in local nil not or repeat return then true until while", line: ["--"], block: [("--[[", "]]")])),
            (["dart"], code("Dart", keywords: "abstract as assert async await break case catch class const continue default do dynamic else enum export extends extension external factory false final finally for get if implements import in is late library mixin new null on operator part required rethrow return set static super switch this throw true try typedef var void while with yield", triple: true, capitalizedTypes: true, extras: ["_", "$", "@"])),
            (["scala"], code("Scala", keywords: "abstract case catch class def do else extends false final finally for forSome if implicit import lazy match new null object override package private protected return sealed super this throw trait try true type val var while with yield given using enum then", triple: true, capitalizedTypes: true)),
            (["r"], code("R", keywords: "if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA library return", line: ["#"], block: [])),
            (["perl", "pl"], code("Perl", keywords: "my our local sub if elsif else unless while until for foreach do last next redo return use require package print undef", line: ["#"], block: [], extras: ["_", "$", "@", "%"]))
        ]
    }()

    // MARK: - Scanning

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    private static func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit >= 0xC0
    }

    private static func matches(_ units: [UInt16], _ index: Int, _ text: String) -> Bool {
        let pattern = Array(text.utf16)
        guard index + pattern.count <= units.count else { return false }
        for offset in 0..<pattern.count where units[index + offset] != pattern[offset] { return false }
        return true
    }

    private static func find(_ units: [UInt16], _ text: String, from start: Int) -> Int? {
        var index = start
        while index < units.count {
            if matches(units, index, text) { return index }
            index += 1
        }
        return nil
    }

    private static func endOfLine(_ units: [UInt16], from start: Int) -> Int {
        var index = start
        while index < units.count, units[index] != 10 { index += 1 }
        return index
    }

    private static func nextNonSpace(_ units: [UInt16], from start: Int) -> UInt16? {
        var index = start
        while index < units.count, units[index] == 32 || units[index] == 9 { index += 1 }
        return index < units.count ? units[index] : nil
    }

    private static func codeTokens(_ units: [UInt16], _ language: Language) -> [CodeToken] {
        var tokens: [CodeToken] = []
        let extras = Set(language.identifierExtras.compactMap { $0.utf16.first })
        let quotes = language.quotes.compactMap { $0.utf16.first }
        let keywords = language.caseInsensitive ? Set(language.keywords.map { $0.lowercased() }) : language.keywords
        let types = language.caseInsensitive ? Set(language.types.map { $0.lowercased() }) : language.types
        var braceDepth = 0
        var index = 0
        scanning: while index < units.count {
            let unit = units[index]
            for (open, close) in language.blockComments where matches(units, index, open) {
                let end = find(units, close, from: index + open.utf16.count).map { $0 + close.utf16.count } ?? units.count
                tokens.append(CodeToken(range: index..<end, kind: .comment))
                index = end
                continue scanning
            }
            for prefix in language.lineComments where matches(units, index, prefix) {
                // A `#` inside a shell word (a URL fragment, `$#`) is not a comment.
                if prefix == "#", language.style == .code, index > 0, units[index - 1] != 32, units[index - 1] != 9,
                   units[index - 1] != 10, language.name == "Shell" { break }
                let end = endOfLine(units, from: index)
                tokens.append(CodeToken(range: index..<end, kind: .comment))
                index = end
                continue scanning
            }
            if quotes.contains(unit) {
                let start = index
                var end: Int
                if language.tripleQuotes, index + 2 < units.count, units[index + 1] == unit, units[index + 2] == unit {
                    let delimiter = String(repeating: String(utf16CodeUnits: [unit], count: 1), count: 3)
                    end = find(units, delimiter, from: index + 3).map { $0 + 3 } ?? units.count
                } else {
                    end = index + 1
                    while end < units.count {
                        if units[end] == 92 { end += 2; continue }
                        if units[end] == unit { end += 1; break }
                        // Only backtick strings and shell quotes run across lines.
                        if units[end] == 10, unit != 96, language.name != "Shell" { break }
                        end += 1
                    }
                    end = min(end, units.count)
                }
                let kind: CodeTokenKind = language.keysBeforeColon && nextNonSpace(units, from: end) == 58 ? .attribute : .string
                tokens.append(CodeToken(range: start..<end, kind: kind))
                index = end
                continue
            }
            if language.style == .css {
                if unit == 123 { braceDepth += 1 } else if unit == 125 { braceDepth = max(0, braceDepth - 1) }
                if unit == 35, index + 1 < units.count, isLetter(units[index + 1]) || isDigit(units[index + 1]), braceDepth > 0 {
                    var end = index + 1
                    while end < units.count, isLetter(units[end]) || isDigit(units[end]) { end += 1 }
                    tokens.append(CodeToken(range: index..<end, kind: .number))
                    index = end
                    continue
                }
            }
            let previousIsWord = index > 0 && (isLetter(units[index - 1]) || isDigit(units[index - 1]) || extras.contains(units[index - 1]))
            if isDigit(unit), !previousIsWord {
                var end = index + 1
                while end < units.count, isLetter(units[end]) || isDigit(units[end]) || units[end] == 46 || units[end] == 95 || units[end] == 37 {
                    if units[end] == 46, end + 1 < units.count, !isDigit(units[end + 1]) { break }
                    end += 1
                }
                tokens.append(CodeToken(range: index..<end, kind: .number))
                index = end
                continue
            }
            if isLetter(unit) || extras.contains(unit), !previousIsWord {
                var end = index + 1
                while end < units.count, isLetter(units[end]) || isDigit(units[end]) || extras.contains(units[end]) { end += 1 }
                let word = String(utf16CodeUnits: Array(units[index..<end]), count: end - index)
                let key = language.caseInsensitive ? word.lowercased() : word
                if keywords.contains(key) {
                    tokens.append(CodeToken(range: index..<end, kind: .keyword))
                } else if language.keysBeforeColon, language.style != .css || braceDepth > 0,
                          nextNonSpace(units, from: end) == 58 {
                    tokens.append(CodeToken(range: index..<end, kind: .attribute))
                } else if types.contains(key) || (language.capitalizedTypes && unit >= 65 && unit <= 90 && end - index > 1) {
                    tokens.append(CodeToken(range: index..<end, kind: .type))
                }
                index = end
                continue
            }
            index += 1
        }
        return tokens
    }

    private static func markupTokens(_ units: [UInt16]) -> [CodeToken] {
        var tokens: [CodeToken] = []
        var index = 0
        while index < units.count {
            if matches(units, index, "<!--") {
                let end = find(units, "-->", from: index + 4).map { $0 + 3 } ?? units.count
                tokens.append(CodeToken(range: index..<end, kind: .comment))
                index = end
                continue
            }
            guard units[index] == 60 else { index += 1; continue }
            // The tag name, after `<`, `</` or `<?`.
            var cursor = index + 1
            if cursor < units.count, units[cursor] == 47 || units[cursor] == 63 || units[cursor] == 33 { cursor += 1 }
            let nameStart = cursor
            while cursor < units.count, isLetter(units[cursor]) || isDigit(units[cursor]) || units[cursor] == 45 || units[cursor] == 58 || units[cursor] == 95 { cursor += 1 }
            guard cursor > nameStart else { index += 1; continue }
            tokens.append(CodeToken(range: index..<cursor, kind: .tag))
            // Attributes and their values, up to `>`.
            while cursor < units.count, units[cursor] != 62 {
                let unit = units[cursor]
                if unit == 34 || unit == 39 {
                    var end = cursor + 1
                    while end < units.count, units[end] != unit { end += 1 }
                    end = min(end + 1, units.count)
                    tokens.append(CodeToken(range: cursor..<end, kind: .string))
                    cursor = end
                } else if isLetter(unit) {
                    var end = cursor + 1
                    while end < units.count, isLetter(units[end]) || isDigit(units[end]) || units[end] == 45 || units[end] == 58 || units[end] == 95 { end += 1 }
                    tokens.append(CodeToken(range: cursor..<end, kind: .attribute))
                    cursor = end
                } else {
                    cursor += 1
                }
            }
            if cursor < units.count {
                tokens.append(CodeToken(range: cursor..<(cursor + 1), kind: .tag))
                cursor += 1
            }
            index = cursor
        }
        return tokens
    }
}
