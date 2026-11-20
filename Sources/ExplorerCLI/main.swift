// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import ExplorerAutomation

func emit(_ value: JSONValue) throws {
    var data = try AutomationWire.encode(value); data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}
func fail(_ error: Error, mcp: Bool = false) -> Never {
    if !mcp {
        let code: String
        if let local = error as? CLIError { code = local.code }
        else if error is AutomationWireError { code = "invalidMessage" }
        else { code = "io" }
        if var data = try? AutomationWire.encode(AutomationResponse(ok: false, error: code)) {
            data.append(10); try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }
    let message = (error as? CLIError)?.rawValue ?? "The automation request could not be completed."
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    exit(1)
}
// Reads only one bounded line at a time; never allocates an unbounded stdin buffer.
struct LineReader {
    var pending = Data()
    mutating func next() throws -> Data? {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard line.count <= AutomationWire.maximumMessageBytes else { throw CLIError.tooLarge }
                return line
            }
            guard pending.count <= AutomationWire.maximumMessageBytes else { throw CLIError.tooLarge }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw CLIError.malformed }
            if count == 0 {
                guard !pending.isEmpty else { return nil }
                defer { pending.removeAll() }; return pending
            }
            pending.append(contentsOf: bytes.prefix(count))
        }
    }
}
var args = Array(CommandLine.arguments.dropFirst()), configPath: String?
if let position = args.firstIndex(of: "--config") {
    guard position + 1 < args.count else { fail(CLIError.usage, mcp: args.contains("mcp")) }
    configPath = args[position + 1]; args.removeSubrange(position...(position + 1))
}
guard !args.isEmpty, args.first == "ocr" || !args.contains(where: { $0.hasPrefix("--") }) else { fail(CLIError.usage, mcp: args.contains("mcp")) }
if args == ["mcp"] {
    var session = MCPSession(configPath: configPath), input = LineReader()
    do {
        while let line = try input.next() { if let response = session.handle(line) { try emit(response) } }
    } catch { fail(error, mcp: true) }
} else {
    do {
        let method: String
        let suppliedArguments: JSONValue?
        if args.first == "ocr" {
            let request: AutomationRequest
            do { request = try OCRCommand.request(arguments: args, workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) }
            catch { throw CLIError.usage }
            method = request.method; suppliedArguments = request.arguments
        } else {
        suppliedArguments = nil
        if args == ["capabilities"] { method = "capabilities.get" }
        else if args.count == 2 && args[0] == "call" { method = args[1] }
        else if args.count == 2 { method = args.joined(separator: ".") }
        else { throw CLIError.usage }
        }
        guard AutomationToolCatalog.schemas[method] != nil else { throw CLIError.usage }
        var input = Data()
        if suppliedArguments == nil && isatty(STDIN_FILENO) == 0 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count < 0 { if errno == EINTR { continue }; throw CLIError.malformed }
                if count == 0 { break }
                input.append(contentsOf: bytes.prefix(count))
                guard input.count <= AutomationWire.maximumMessageBytes else { throw CLIError.tooLarge }
            }
        }
        let arguments = try suppliedArguments ?? (input.isEmpty ? JSONValue.object([:]) : AutomationWire.decode(JSONValue.self, from: input))
        guard AutomationToolCatalog.validate(method: method, arguments: arguments) else { throw CLIError.malformed }
        let result = try SocketClient(configuration: .load(path: configPath)).call(method: method, arguments: arguments)
        var encoded = try AutomationWire.encode(result); encoded.append(10)
        try FileHandle.standardOutput.write(contentsOf: encoded)
        if !result.ok { exit(1) }
    } catch { fail(error, mcp: args.first == "mcp") }
}
