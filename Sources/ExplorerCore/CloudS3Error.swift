// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Reads only the documented error discriminator. Server diagnostics can contain signed request data.
internal enum S3ErrorResponse {
    static func reason(for response: CloudResponse) -> CloudFailure.Reason? {
        guard [400, 401, 403].contains(response.statusCode), !response.body.isEmpty,
              response.body.count <= 65_536,
              let xml = String(data: response.body, encoding: .utf8),
              !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY"), !xml.utf8.contains(0) else { return nil }
        let delegate = S3ErrorCodeParser()
        let parser = XMLParser(data: response.body)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.root == "Error", delegate.codeCount == 1,
              let code = delegate.code else { return nil }
        switch code {
        case "ExpiredToken", "InvalidToken", "TokenRefreshRequired", "InvalidAccessKeyId", "SignatureDoesNotMatch":
            return .authenticationRequired
        case "AccessDenied": return .permissionDenied
        default: return nil
        }
    }
}

private final class S3ErrorCodeParser: NSObject, XMLParserDelegate {
    var invalid = false
    var root: String?
    var code: String?
    var codeCount = 0
    private var path: [String] = []
    private var elements = 0
    private var value = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if path == ["Error", "Code"] { invalid = true; parser.abortParsing(); return }
        if root == nil { root = elementName }
        path.append(elementName)
        elements += 1
        if path.count > 8 || elements > 128 { invalid = true; parser.abortParsing(); return }
        if path == ["Error", "Code"] { codeCount += 1; value = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard path == ["Error", "Code"] else { return }
        guard string.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              value.utf8.count + string.utf8.count <= 128 else {
            invalid = true; parser.abortParsing(); return
        }
        value += string
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if path == ["Error", "Code"] { code = value }
        if !path.isEmpty { path.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if path == ["Error", "Code"] { invalid = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        invalid = true; parser.abortParsing(); return nil
    }
}
