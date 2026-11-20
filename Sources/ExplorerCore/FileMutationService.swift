// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

public struct FileMutationFailure: Error, Sendable {
    public enum Reason: Sendable { case conflict, invalidName, recursive, io, cancelled }
    public let reason: Reason
    public let completed: Int
    public init(_ reason: Reason, completed: Int = 0) { self.reason = reason; self.completed = completed }
}

public struct FileMutationService: Sendable {
    public init() {}
    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        if Task.isCancelled { throw FileMutationFailure(.cancelled) }
        let worker = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { throw FileMutationFailure(.cancelled) }
            return try body()
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":" ) && !name.contains("\0")
    }
    public func newFolder(in parent: URL, name: String) async throws -> URL {
        guard Self.validName(name) else { throw FileMutationFailure(.invalidName) }
        return try await run {
            guard !LocalTransferRecovery.isProtected(parent) else { throw FileMutationFailure(.io) }
            let destination = parent.appendingPathComponent(name, isDirectory: true)
            guard !Self.exists(destination) else { throw FileMutationFailure(.conflict) }
            guard mkdir(destination.path, 0o755) == 0 else {
                throw FileMutationFailure(errno == EEXIST ? .conflict : .io)
            }
            return destination
        }
    }
    public func rename(_ source: URL, to name: String) async throws -> URL {
        guard Self.validName(name) else { throw FileMutationFailure(.invalidName) }
        return try await run {
            try Self.requireExportable(source)
            let target = source.deletingLastPathComponent().appendingPathComponent(name)
            if source.path == target.path { return source }
            try Self.moveExclusive(source, to: target)
            return target
        }
    }
    public func transfer(_ sources: [URL], to directory: URL, move: Bool) async throws -> [URL] {
        try await run {
            let manager = FileManager.default
            guard !LocalTransferRecovery.isProtected(directory) else { throw FileMutationFailure(.io) }
            let parent = directory.resolvingSymlinksInPath().standardizedFileURL.path
            var names = Set<String>()
            for source in sources {
                guard source.isFileURL, directory.isFileURL else { throw FileMutationFailure(.io) }
                try Self.requireExportable(source)
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                guard names.insert(source.lastPathComponent).inserted, !Self.exists(destination) else { throw FileMutationFailure(.conflict) }
                let canonical = source.resolvingSymlinksInPath().standardizedFileURL.path
                if parent == canonical || parent.hasPrefix(canonical + "/") { throw FileMutationFailure(.recursive) }
            }
            var completed: [URL] = []
            for source in sources {
                if Task.isCancelled { throw FileMutationFailure(.cancelled, completed: completed.count) }
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                do {
                    try Self.requireExportable(source)
                    guard !LocalTransferRecovery.isProtected(directory) else { throw FileMutationFailure(.io) }
                    if move {
                        try Self.moveExclusive(source, to: destination)
                    } else {
                        let staging = directory.appendingPathComponent(".my-explorer-copy-\(UUID().uuidString)")
                        defer { try? manager.removeItem(at: staging) }
                        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
                        let copy = staging.appendingPathComponent(source.lastPathComponent)
                        try manager.copyItem(at: source, to: copy)
                        try Task.checkCancellation()
                        try Self.requireExportable(source)
                        guard !LocalTransferRecovery.isProtected(directory) else { throw FileMutationFailure(.io) }
                        try Self.moveExclusive(copy, to: destination)
                    }
                    completed.append(destination)
                } catch {
                    throw FileMutationFailure(Task.isCancelled ? .cancelled : Self.exists(destination) ? .conflict : .io,
                                              completed: completed.count)
                }
            }
            return completed
        }
    }
    public func trash(_ sources: [URL]) async throws -> [URL] {
        try await run {
            var completed: [URL] = []
            for source in sources {
                if Task.isCancelled { throw FileMutationFailure(.cancelled, completed: completed.count) }
                do {
                    try Self.requireExportable(source)
                    try FileManager.default.trashItem(at: source, resultingItemURL: nil); completed.append(source)
                }
                catch { throw FileMutationFailure(.io, completed: completed.count) }
            }
            return completed
        }
    }
    private static func requireExportable(_ source: URL) throws {
        do { try LocalTransferRecovery.assertExportable(source) }
        catch { throw FileMutationFailure(Task.isCancelled ? .cancelled : .io) }
    }
    private static func exists(_ url: URL) -> Bool {
        // Unlike fileExists, attributes also detect dangling symlinks.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    private static func moveExclusive(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw FileMutationFailure(errno == EEXIST || errno == ENOTEMPTY ? .conflict : .io)
        }
    }
}
