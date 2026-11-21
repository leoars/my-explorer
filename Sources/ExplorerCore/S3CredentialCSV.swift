// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum S3CredentialCSV {
    public enum Failure: Error { case invalid }
    private static let maximumSize = 256 * 1024

    public static func read(from url: URL) throws -> CloudCredentials {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Failure.invalid
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try parse(handle.read(upToCount: maximumSize + 1) ?? Data())
    }

    public static func parse(_ data: Data) throws -> CloudCredentials {
        guard data.count <= maximumSize, var input = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        if input.first == "\u{FEFF}" { input.removeFirst() }
        enum State { case plain, quoted, afterQuote }
        var state = State.plain
        var records: [[String]] = [], record: [String] = [], field = ""
        func finishRecord() throws {
            record.append(field)
            if record.count > 1 || !field.trimmingCharacters(in: .whitespaces).isEmpty { records.append(record) }
            guard records.count <= 2 else { throw Failure.invalid }
            record = []; field = ""
        }
        for char in input {
            if state == .quoted {
                if char == "\"" { state = .afterQuote } else { field.append(char) }
            } else if char == "," {
                record.append(field); field = ""; state = .plain
            } else if char.isNewline {
                try finishRecord()
                state = .plain
            } else if char == "\"" {
                if state == .afterQuote { field.append(char) }
                else if !field.isEmpty { throw Failure.invalid }
                state = .quoted
            } else {
                guard state == .plain else { throw Failure.invalid }
                field.append(char)
            }
        }
        guard state != .quoted else { throw Failure.invalid }
        try finishRecord()
        guard records.count == 2, records[0].count == records[1].count else { throw Failure.invalid }
        let names = records[0].map { $0.lowercased().filter { !$0.isWhitespace && $0 != "_" } }
        func value(_ column: String) throws -> String? {
            let indices = names.indices.filter { names[$0] == column || names[$0] == "aws" + column }
            guard indices.count <= 1 else { throw Failure.invalid }
            guard let i = indices.first else { return nil }
            let value = records[1][i].trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.invalid }
            return value.isEmpty ? nil : value
        }
        guard let id = try value("accesskeyid"), let secret = try value("secretaccesskey") else { throw Failure.invalid }
        return try CloudCredentials(accessKeyID: id, secretAccessKey: secret, sessionToken: value("sessiontoken"))
    }
}
