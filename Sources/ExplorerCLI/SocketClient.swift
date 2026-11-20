// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import ExplorerAutomation

enum CLIError: String, Error {
    case usage = "Usage: myexplorer [--config PATH] mcp | call METHOD | capabilities | GROUP ACTION. JSON arguments are read from stdin. OCR: ocr PATH [--language TAG]... [--pages START:END] | ocr pdf SOURCE --output NEW.pdf [--language TAG]... | ocr batch SOURCE... --output-directory DIR [--language TAG]... | ocr languages | ocr status JOB_ID | ocr cancel JOB_ID."
    case invalidConfiguration = "Invalid configuration. Set --config PATH or MYEXPLORER_CONFIG."
    case insecureToken = "The token file must be a regular file owned by this user with mode 0600."
    case unavailable = "My Explorer automation is unavailable. Open the app and enable automation."
    case timeout = "The automation connection timed out."
    case malformed = "Invalid automation message."
    case tooLarge = "The automation message exceeds 1 MiB."
    var code: String {
        switch self {
        case .usage, .malformed: "invalidArguments"
        case .invalidConfiguration: "invalidConfiguration"
        case .insecureToken: "unauthenticated"
        case .unavailable: "unavailable"
        case .timeout: "timeout"
        case .tooLarge: "limitExceeded"
        }
    }
}
struct CLIConfiguration: Decodable {
    let socketPath: String
    let clientID: String
    let tokenFile: String
    static func load(path: String?) throws -> Self {
        guard let path = path ?? ProcessInfo.processInfo.environment["MYEXPLORER_CONFIG"], path.hasPrefix("/"),
              let data = try? readConfiguration(path),
              let config = try? JSONDecoder().decode(Self.self, from: data),
              config.socketPath.hasPrefix("/"), !config.socketPath.utf8.contains(0), config.socketPath.utf8.count < 104,
              config.tokenFile.hasPrefix("/"), !config.tokenFile.utf8.contains(0),
              !config.clientID.isEmpty, config.clientID.utf8.count <= 256 else { throw CLIError.invalidConfiguration }
        return config
    }
    private static func readConfiguration(_ path: String) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CLIError.invalidConfiguration }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 16_384 else { throw CLIError.invalidConfiguration }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw CLIError.invalidConfiguration }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 16_384 else { throw CLIError.invalidConfiguration }
        }
    }
    func token() throws -> String {
        let fd = Darwin.open(tokenFile, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CLIError.insecureToken }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600, info.st_size > 0, info.st_size <= 4096 else { throw CLIError.insecureToken }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count <= 4096, let raw = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw CLIError.insecureToken }
        let token = raw.trimmingCharacters(in: .newlines)
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r"), !token.utf8.contains(0) else { throw CLIError.insecureToken }
        return token
    }
}
struct SocketClient {
    let configuration: CLIConfiguration
    func call(method: String, arguments: JSONValue) throws -> AutomationResponse {
        let request = AutomationRequest(method: method, arguments: arguments, clientID: configuration.clientID, token: try configuration.token())
        var data = try AutomationWire.encode(request); data.append(10)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.unavailable }; defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CLIError.unavailable }
        let deadline = Date().addingTimeInterval(15)
        func ready(_ events: Int16) throws {
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw CLIError.timeout }
                var item = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&item, 1, Int32(max(1, remaining * 1000)))
                if result == 0 { throw CLIError.timeout }
                if result < 0 { if errno == EINTR { continue }; throw CLIError.unavailable }
                guard item.revents & events != 0 else { throw CLIError.unavailable }
                return
            }
        }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(configuration.socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw CLIError.unavailable }
            try ready(Int16(POLLOUT))
            var status: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &length) == 0, status == 0 else { throw CLIError.unavailable }
        }
        var peerUser: uid_t = 0, peerGroup: gid_t = 0
        guard getpeereid(fd, &peerUser, &peerGroup) == 0, peerUser == getuid() else { throw CLIError.unavailable }
        var offset = 0
        while offset < data.count {
            try ready(Int16(POLLOUT))
            let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if sent < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw CLIError.unavailable }
            guard sent > 0 else { throw CLIError.unavailable }; offset += sent
        }
        var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try ready(Int16(POLLIN))
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw CLIError.unavailable }
            guard count > 0 else { throw CLIError.malformed }
            if let end = buffer.prefix(count).firstIndex(of: 10) {
                response.append(contentsOf: buffer[..<end])
                guard end == count - 1 else { throw CLIError.malformed }
                return try AutomationWire.decodeResponse(response)
            }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= AutomationWire.maximumMessageBytes else { throw CLIError.tooLarge }
        }
    }
}
