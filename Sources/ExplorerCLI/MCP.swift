// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerAutomation

struct MCPSession {
    let configPath: String?
    private var phase = 0
    init(configPath: String?) { self.configPath = configPath }
    private func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
    private func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }
    mutating func handle(_ data: Data) -> JSONValue? {
        let value: JSONValue
        do { value = try AutomationWire.decode(JSONValue.self, from: data) }
        catch { return self.error(.null, -32700, "Parse error") }
        guard let object = value.objectValue, object["jsonrpc"] == .string("2.0"),
              let method = object["method"]?.stringValue, !method.isEmpty,
              Set(object.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]) else { return error(.null, -32600, "Invalid Request") }
        let id = object["id"]
        if let id {
            switch id {
            case .string: break
            case .number(let number):
                guard number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else { return error(.null, -32600, "Invalid Request") }
            default: return error(.null, -32600, "Invalid Request")
            }
        }
        let params = object["params"] ?? .object([:])
        guard let parameters = params.objectValue else { return id.map { error($0, -32602, "Invalid params") } }
        guard parameters["_meta"] == nil || parameters["_meta"]?.objectValue != nil else { return id.map { error($0, -32602, "Invalid params") } }
        // Notifications never invoke broker operations or receive a response.
        guard let id else {
            if method == "notifications/initialized", phase == 1, Set(parameters.keys).isSubset(of: ["_meta"]) { phase = 2 }
            return nil
        }
        if method == "ping" {
            guard Set(parameters.keys).isSubset(of: ["_meta"]) else { return error(id, -32602, "Invalid params") }
            return result(id, .object([:]))
        }
        if method == "initialize" {
            guard phase == 0 else { return error(id, -32600, "Already initialized") }
            guard let version = parameters["protocolVersion"]?.stringValue, !version.isEmpty,
                  parameters["capabilities"]?.objectValue != nil,
                  let client = parameters["clientInfo"]?.objectValue,
                  client["name"]?.stringValue?.isEmpty == false, client["version"]?.stringValue?.isEmpty == false,
                  Set(parameters.keys).isSubset(of: ["protocolVersion", "capabilities", "clientInfo", "_meta"]) else { return error(id, -32602, "Invalid params") }
            phase = 1
            return result(id, .object([
                "protocolVersion": .string("2025-11-25"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("myexplorer"), "version": .string("0.1.1")]),
                "instructions": .string("My Explorer must be running with automation enabled. Access is bounded by the configured grant. Prepare and inspect plans before starting mutations; enter cloud credentials only in the app.")
            ]))
        }
        guard phase == 2 else { return error(id, -32002, "Initialization is required") }
        if method == "tools/list" {
            guard Set(parameters.keys).isSubset(of: ["_meta"]) else { return error(id, -32602, "Invalid params") }
            return result(id, .object(["tools": .array(AutomationToolCatalog.tools)]))
        }
        if method == "tools/call" {
            guard Set(parameters.keys).isSubset(of: ["name", "arguments", "_meta"]),
                  let name = parameters["name"]?.stringValue, let brokerMethod = AutomationToolCatalog.method(forTool: name) else { return error(id, -32602, "Unknown tool or invalid params") }
            let arguments = parameters["arguments"] ?? .object([:])
            guard AutomationToolCatalog.validate(method: brokerMethod, arguments: arguments) else { return error(id, -32602, "Invalid tool arguments") }
            let response: AutomationResponse
            do { response = try SocketClient(configuration: .load(path: configPath)).call(method: brokerMethod, arguments: arguments) }
            catch {
                response = AutomationResponse(ok: false, error: (error as? CLIError)?.code ?? "io")
            }
            do {
                let encoded = try AutomationWire.encode(response)
                let structured = try AutomationWire.decode(JSONValue.self, from: encoded)
                let output = result(id, .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(String(decoding: encoded, as: UTF8.self))])]),
                    "structuredContent": structured, "isError": .bool(!response.ok)
                ]))
                _ = try AutomationWire.encode(output)
                return output
            } catch { return result(id, .object(["content": .array([.object(["type": .string("text"), "text": .string("Response exceeds the protocol limit.")])]), "structuredContent": .object(["ok": .bool(false), "error": .string("limitExceeded")]), "isError": .bool(true)])) }
        }
        return error(id, -32601, "Method not found")
    }
}
