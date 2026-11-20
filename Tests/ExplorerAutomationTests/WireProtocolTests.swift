// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerAutomation

final class WireProtocolTests: XCTestCase {
    func testJSONRoundTripPreservesTypesAndUnicode() throws {
        let value: JSONValue = .object(["null": .null, "bool": .bool(true), "number": .number(42.5), "array": .array([.string("日本語 / ç 😀")])])
        XCTAssertEqual(try AutomationWire.decode(JSONValue.self, from: AutomationWire.encode(value)), value)
    }
    func testRequestAndResponseContract() throws {
        let request = AutomationRequest(method: "locations.list", arguments: .object(["url": .string("file:///tmp")]), clientID: "test", token: "opaque")
        XCTAssertEqual(try AutomationWire.decodeRequest(AutomationWire.encode(request)), request)
        XCTAssertEqual(try AutomationWire.decodeResponse(AutomationWire.encode(AutomationResponse(ok: true, result: .array([])))).ok, true)
        XCTAssertThrowsError(try AutomationWire.decodeRequest(Data(#"{"method":"x","arguments":[]}"#.utf8)))
        XCTAssertThrowsError(try AutomationWire.decodeResponse(Data(#"{"ok":false}"#.utf8)))
        XCTAssertThrowsError(try AutomationWire.decodeResponse(Data(#"{"ok":true,"error":"conflict"}"#.utf8)))
    }
    func testMessageSizeAndDepthAreBounded() throws {
        XCTAssertThrowsError(try AutomationWire.decode(JSONValue.self, from: Data(repeating: 32, count: AutomationWire.maximumMessageBytes + 1)))
        XCTAssertThrowsError(try AutomationWire.encode(JSONValue.string(String(repeating: "x", count: AutomationWire.maximumMessageBytes))))
        let nested = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        XCTAssertThrowsError(try AutomationWire.decode(JSONValue.self, from: Data(nested.utf8)))
        let braces = JSONValue.string(String(repeating: "[\\\"", count: 100))
        XCTAssertEqual(try AutomationWire.decode(JSONValue.self, from: AutomationWire.encode(braces)), braces)
    }
    func testAllToolSchemasAreObjectsAndNoGrantToolExists() {
        XCTAssertEqual(AutomationToolCatalog.tools.count, 24)
        for tool in AutomationToolCatalog.tools {
            let name = tool["name"]!.stringValue!
            XCTAssertNotNil(AutomationToolCatalog.method(forTool: name))
            XCTAssertEqual(tool["inputSchema"]?["type"], .string("object"))
            XCTAssertEqual(tool["outputSchema"]?["type"], .string("object"))
            XCTAssertFalse(name.contains("grant"))
        }
    }
    func testArgumentSchemasRejectWrongTypesUnknownFieldsAndUnsafeBounds() {
        XCTAssertTrue(AutomationToolCatalog.validate(method: "locations.list", arguments: .object(["url": .string("file:///tmp"), "limit": .number(200)])))
        XCTAssertFalse(AutomationToolCatalog.validate(method: "locations.list", arguments: .object(["url": .string("file:///tmp"), "limit": .number(201)])))
        XCTAssertFalse(AutomationToolCatalog.validate(method: "locations.list", arguments: .object(["url": .string("file:///tmp"), "limit": .bool(true)])))
        XCTAssertFalse(AutomationToolCatalog.validate(method: "connections.prepare", arguments: .object(["name": .string("test"), "provider": .string("s3"), "bucket": .string("bucket"), "secret": .string("never") ])))
        XCTAssertFalse(AutomationToolCatalog.validate(method: "deletions.start", arguments: .object(["planID": .string("invalid"), "idempotencyKey": .string("test")])))
        XCTAssertFalse(AutomationToolCatalog.validate(method: "transfers.plan", arguments: .object(["sources": .array([]), "destination": .string("file:///tmp")])))
        XCTAssertTrue(AutomationToolCatalog.validate(method: "preferences.update", arguments: .object(["fonts": .object(["files": .number(24)])])))
        XCTAssertFalse(AutomationToolCatalog.validate(method: "preferences.update", arguments: .object(["fonts": .object(["files": .number(25)])])))
    }
}
