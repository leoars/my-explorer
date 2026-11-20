// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import Security

/// Private same-user Unix socket. The signed bundled adapter plus a scoped bearer grant are required.
/// This is not a sandbox against an attacker with unrestricted access to this user's account.
public final class AutomationBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: Int32 = -1
    private let socketURL: URL
    private let handler: @Sendable (AutomationRequest) async -> AutomationResponse
    private let validatePeer: @Sendable (Int32) -> Bool
    private let slots = DispatchSemaphore(value: 8)
    public init(socketURL: URL, helperURL: URL, handler: @escaping @Sendable (AutomationRequest) async -> AutomationResponse) {
        self.socketURL = socketURL; self.handler = handler
        validatePeer = { Self.signedPeer($0, helperURL: helperURL) }
    }
    // Test-only dependency injection; not selectable through requests or environment variables.
    init(socketURL: URL, validatePeer: @escaping @Sendable (Int32) -> Bool, handler: @escaping @Sendable (AutomationRequest) async -> AutomationResponse) {
        self.socketURL = socketURL; self.validatePeer = validatePeer; self.handler = handler
    }
    public func start() throws {
        let parent = socketURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        var info = Darwin.stat()
        guard lstat(parent.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw AutomationError.forbidden }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationError.io }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketURL.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw AutomationError.invalidArguments }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: path) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // Never unlink a live listener or a non-socket supplied at this path.
        if lstat(socketURL.path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { close(fd); throw AutomationError.forbidden }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            _ = fcntl(probe, F_SETFL, O_NONBLOCK)
            let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let connectionError = errno
            close(probe)
            guard connected != 0, connectionError == ECONNREFUSED else { close(fd); throw AutomationError.busy }
            unlink(socketURL.path)
        }
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chmod(socketURL.path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); throw AutomationError.io }
        lock.withLock { listener = fd }
        DispatchQueue.global(qos: .utility).async { [self] in
            while lock.withLock({ listener == fd }) {
                let peer = accept(fd, nil, nil)
                if peer < 0 { break }
                guard slots.wait(timeout: .now()) == .success else { close(peer); continue }
                DispatchQueue.global(qos: .utility).async { [self] in
                    guard validatePeer(peer), let request = readRequest(peer) else { close(peer); slots.signal(); return }
                    Task {
                        let response = await handler(request)
                        let data = (try? JSONEncoder().encode(response)) ?? Data("{\"ok\":false,\"error\":\"io\"}".utf8)
                        if data.count <= 1_048_576 { Self.writeAll(data + Data([10]), fd: peer) }
                        close(peer); slots.signal()
                    }
                }
            }
        }
    }
    public func stop() {
        let fd = lock.withLock { let old = listener; listener = -1; return old }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); unlink(socketURL.path) }
    }
    private func readRequest(_ fd: Int32) -> AutomationRequest? {
        var timeout = timeval(tv_sec: 15, tv_usec: 0), one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(15)
        while data.count <= 1_048_576 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var wait = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                guard newline <= 1_048_576, newline == data.count - 1 else { return nil }
                return try? AutomationWire.decodeRequest(Data(data.prefix(upTo: newline)))
            }
        }
        return nil
    }
    private static func writeAll(_ data: Data, fd: Int32) {
        let deadline = Date().addingTimeInterval(15)
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                var wait = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if count <= 0 { break }; offset += count
            }
        }
    }
    private static func signedPeer(_ fd: Int32, helperURL: URL) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var pid: pid_t = 0, length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return false }
        var guest: SecCode?, staticGuest: SecStaticCode?, helper: SecStaticCode?, actualInfo: CFDictionary?, expectedInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: 0)
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, flags, &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, flags, nil) == errSecSuccess,
              SecStaticCodeCreateWithPath(helperURL as CFURL, flags, &helper) == errSecSuccess, let helper,
              SecStaticCodeCheckValidity(helper, flags, nil) == errSecSuccess,
              SecCodeCopyStaticCode(guest, flags, &staticGuest) == errSecSuccess, let staticGuest,
              SecCodeCopySigningInformation(staticGuest, SecCSFlags(rawValue: kSecCSSigningInformation), &actualInfo) == errSecSuccess,
              SecCodeCopySigningInformation(helper, SecCSFlags(rawValue: kSecCSSigningInformation), &expectedInfo) == errSecSuccess,
              let actual = (actualInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let expected = (expectedInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return false }
        return actual == expected
    }
    deinit { stop() }
}
