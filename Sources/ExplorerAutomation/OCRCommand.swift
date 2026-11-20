// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure parsing shared with CLI tests; it never opens the supplied document.
public enum OCRCommand {
    public static func request(arguments: [String], workingDirectory: URL) throws -> AutomationRequest {
        guard arguments.first == "ocr", arguments.count >= 2 else { throw AutomationError.invalidArguments }
        if arguments == ["ocr", "languages"] { return .init(method: "ocr.languages") }
        if arguments[1] == "batch" { return try batch(arguments: arguments, workingDirectory: workingDirectory) }
        if arguments.count == 3, ["status", "cancel"].contains(arguments[1]) {
            guard UUID(uuidString: arguments[2]) != nil else { throw AutomationError.invalidArguments }
            return .init(method: "ocr." + arguments[1], arguments: .object(["jobID": .string(arguments[2])]))
        }
        guard !["languages", "status", "cancel"].contains(arguments[1]) else { throw AutomationError.invalidArguments }
        let pdf = arguments[1] == "pdf"
        let sourceIndex = pdf ? 2 : 1
        guard arguments.indices.contains(sourceIndex), !arguments[sourceIndex].hasPrefix("--") else { throw AutomationError.invalidArguments }
        var languages: [String] = []
        var selectedPages: (Int, Int)?
        var output: String?
        var index = sourceIndex + 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw AutomationError.invalidArguments }
            if arguments[index] == "--language" {
                guard !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("--") else { throw AutomationError.invalidArguments }
                languages.append(arguments[index + 1])
            } else if arguments[index] == "--pages", !pdf {
                let values = arguments[index + 1].split(separator: ":", omittingEmptySubsequences: false)
                guard selectedPages == nil, values.count == 2, let first = Int(values[0]), let last = Int(values[1]),
                      first >= 1, last >= first, last <= 1_000_000, last - first < 100 else { throw AutomationError.invalidArguments }
                selectedPages = (first, last)
            } else if arguments[index] == "--output", pdf {
                guard output == nil, !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("--") else { throw AutomationError.invalidArguments }
                output = arguments[index + 1]
            } else { throw AutomationError.invalidArguments }
            index += 2
        }
        let url = try localURL(arguments[sourceIndex], relativeTo: workingDirectory)
        var values: [String: JSONValue] = ["url": .string(url.absoluteString), "languages": .array(languages.map(JSONValue.string))]
        if let selectedPages { values["pageStart"] = .number(Double(selectedPages.0)); values["pageEnd"] = .number(Double(selectedPages.1)) }
        if pdf {
            guard let output else { throw AutomationError.invalidArguments }
            values["destination"] = .string(try localURL(output, relativeTo: workingDirectory).absoluteString)
        }
        let method = pdf ? "files.ocr.pdf" : "files.ocr"
        let arguments: JSONValue = .object(values)
        guard AutomationToolCatalog.validate(method: method, arguments: arguments) else { throw AutomationError.invalidArguments }
        return .init(method: method, arguments: arguments)
    }
    private static func batch(arguments: [String], workingDirectory: URL) throws -> AutomationRequest {
        var sources: [String] = [], languages: [String] = []
        var destination: String?
        var index = 2
        while index < arguments.count {
            let value = arguments[index]
            if value == "--output-directory" || value == "--language" {
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                      !arguments[index + 1].hasPrefix("--") else { throw AutomationError.invalidArguments }
                if value == "--output-directory" {
                    guard destination == nil else { throw AutomationError.invalidArguments }
                    destination = arguments[index + 1]
                } else { languages.append(arguments[index + 1]) }
                index += 2
            } else {
                guard !value.isEmpty, !value.hasPrefix("--") else { throw AutomationError.invalidArguments }
                sources.append(value); index += 1
            }
        }
        guard let destination, (1...50).contains(sources.count) else { throw AutomationError.invalidArguments }
        let urls = try sources.map { JSONValue.string(try localURL($0, relativeTo: workingDirectory).absoluteString) }
        let values: JSONValue = .object(["urls": .array(urls),
            "destination": .string(try localURL(destination, relativeTo: workingDirectory).absoluteString),
            "languages": .array(languages.map(JSONValue.string))])
        guard AutomationToolCatalog.validate(method: "files.ocr.pdf.batch", arguments: values) else { throw AutomationError.invalidArguments }
        return .init(method: "files.ocr.pdf.batch", arguments: values)
    }
    private static func localURL(_ input: String, relativeTo directory: URL) throws -> URL {
        let value = input.hasPrefix("~") ? (input as NSString).expandingTildeInPath : input
        if value.contains("://") {
            guard let parsed = URL(string: value), parsed.isFileURL else { throw AutomationError.invalidArguments }
            return parsed
        }
        return URL(fileURLWithPath: value, isDirectory: false, relativeTo: directory).absoluteURL
    }
}
