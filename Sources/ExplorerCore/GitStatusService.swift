// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

public enum GitInspectionIssue: String, Error, Sendable {
    case nonLocalLocation, offlineFiles, unsafeConfiguration, resourceLimit, timedOut
    case cancelled, commandFailed, invalidOutput, unreadableRepository
}

public enum GitInspectionResult: Sendable {
    case repository(GitStatusSnapshot)
    case notRepository
    case unavailable
    case failed(GitInspectionIssue)
    case skipped(GitInspectionIssue)
}

/// Read-only Git inspection. Never launches Apple's developer-tools installation shim.
public actor GitStatusService {
    private struct Cached: Sendable { let date: Date; let result: GitInspectionResult }
    private var cache: [String: Cached] = [:]
    private var generations: [String: UInt64] = [:]
    private var nextGeneration: UInt64 = 0
    private let executable: URL?
    private let cacheTTL: TimeInterval
    private let processTimeout: TimeInterval
    private let outputLimit: Int

    public init(executableURL: URL? = GitStatusService.discoverExecutable(), cacheTTL: TimeInterval = 2,
                processTimeout: TimeInterval = 3, outputLimit: Int = 4 * 1024 * 1024) {
        executable = executableURL
        self.cacheTTL = max(0, cacheTTL)
        self.processTimeout = max(0.05, min(15, processTimeout))
        self.outputLimit = max(1024, min(16 * 1024 * 1024, outputLimit))
    }

    public nonisolated static func discoverExecutable() -> URL? {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public func inspect(directory: URL, force: Bool = false) async -> GitInspectionResult {
        let discovery = await GitWorker.perform(cancelled: GitDiscovery.failed(.cancelled), rejected: .failed(.resourceLimit), timedOut: .failed(.timedOut)) { control in
            do { return try GitRepositoryLocation.discover(directory, control: control).map(GitDiscovery.found) ?? .absent }
            catch let issue as GitInspectionIssue { return .failed(issue) }
            catch { return .failed(.unreadableRepository) }
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        let location: GitRepositoryLocation
        switch discovery {
        case .found(let found): location = found
        case .absent: return .notRepository
        case .failed(let issue): return Self.failure(issue)
        }
        guard let executable else { return .unavailable }
        let key = location.gitDirectory.path + "\n" + location.root.path
        if !force, let saved = cache[key], Date().timeIntervalSince(saved.date) < cacheTTL { return saved.result }
        nextGeneration &+= 1
        let generation = nextGeneration
        generations[key] = generation
        let timeout = processTimeout, limit = outputLimit
        let result = await GitWorker.perform(cancelled: GitInspectionResult.failed(.cancelled), rejected: .failed(.resourceLimit), timedOut: .failed(.timedOut)) { control in
            do {
                let runner = GitRunner(executable: executable, timeout: timeout, outputLimit: limit, control: control)
                return .repository(try location.snapshot(using: runner, control: control))
            } catch let issue as GitInspectionIssue { return Self.failure(issue) }
            catch { return .failed(.invalidOutput) }
        }
        let isLatest = generations[key] == generation
        if isLatest { generations.removeValue(forKey: key) }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        if isLatest { cache[key] = Cached(date: Date(), result: result) }
        if cache.count > 16, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key { cache.removeValue(forKey: oldest) }
        return result
    }

    public enum Review: Sendable {
        case changes, diff(staged: Bool), history, branches, remotes
    }

    public enum ReviewOutput: Sendable {
        case changes(GitStatusSnapshot, [String])
        case text(String)
    }

    /// A click captures its worktree and literal relative paths. Re-resolve them
    /// before every query so a stale row cannot redirect Git into a nested repo.
    public func review(_ request: Review, root: URL, paths: [String]) async throws -> ReviewOutput {
        guard let executable else { throw GitInspectionIssue.commandFailed }
        let timeout = processTimeout, limit = outputLimit
        let result: Result<ReviewOutput, GitInspectionIssue> = await GitWorker.perform(
            cancelled: .failure(.cancelled), rejected: .failure(.resourceLimit), timedOut: .failure(.timedOut)
        ) { control in
            do {
                guard let repo = try GitRepositoryLocation.discover(root, exact: true, control: control) else {
                    throw GitInspectionIssue.unreadableRepository
                }
                for path in paths {
                    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                    guard !parts.isEmpty, !path.utf8.contains(0),
                          parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" })
                    else { throw GitInspectionIssue.invalidOutput }
                    var dir = root
                    for part in parts {
                        dir.appendPathComponent(String(part))
                        guard let info = try GitRepositoryLocation.metadata(dir) else { break }
                        if info.st_mode & S_IFMT != S_IFDIR {
                            guard dir.path == root.appendingPathComponent(path).path else { throw GitInspectionIssue.unreadableRepository }
                            break
                        }
                        if try GitRepositoryLocation.metadata(dir.appendingPathComponent(".git")) != nil {
                            throw GitInspectionIssue.unreadableRepository
                        }
                    }
                }
                let runner = GitRunner(executable: executable, timeout: timeout, outputLimit: limit, control: control)
                let snapshot = try repo.snapshot(using: runner, control: control, expandUntracked: true)
                let args = ["--literal-pathspecs", "--git-dir=" + repo.gitDirectory.path, "--work-tree=" + root.path]
                let commands: [String]
                switch request {
                case .changes:
                    let selected = Set(paths)
                    func matches(_ value: String) -> Bool {
                        if selected.isEmpty { return true }
                        var candidate = value[...]
                        while !candidate.isEmpty {
                            if selected.contains(String(candidate)) { return true }
                            guard let slash = candidate.lastIndex(of: "/") else { break }
                            candidate = candidate[..<slash]
                        }
                        return false
                    }
                    let keys = snapshot.entries.compactMap { path, status -> String? in
                        guard status.kind != .ignored && status.kind != .clean,
                              matches(path) || status.originalPath.map(matches) == true else { return nil }
                        return path
                    }.sorted()
                    return .success(.changes(snapshot, keys))
                case .branches:
                    commands = ["for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads"]
                case .remotes:
                    commands = ["remote"]
                case .history:
                    if snapshot.isUnborn { return .success(.text("")) }
                    commands = ["log", "-100", "--no-color", "--no-show-signature", "--format=%h  %as  %an  %s", "--"] + paths
                case .diff(let staged):
                    var selected = paths
                    if paths.count == 1, let status = snapshot.entries[paths[0]] {
                        if status.kind == .untracked && !staged {
                            let url = root.appendingPathComponent(paths[0])
                            guard let info = try GitRepositoryLocation.metadata(url),
                                  [S_IFREG, S_IFLNK].contains(info.st_mode & S_IFMT) else {
                                throw GitInspectionIssue.unreadableRepository
                            }
                            let data = try runner.run(args + ["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--", "/dev/null", "./" + paths[0]], directory: root, allowedExitCodes: [0, 1])
                            return .success(.text(String(decoding: data, as: UTF8.self)))
                        }
                        if let original = status.originalPath { selected.append(original) }
                    }
                    commands = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all"] +
                        (staged ? ["--cached"] : []) + ["--"] + selected
                }
                let data = try runner.run(args + commands, directory: root)
                return .success(.text(String(decoding: data, as: UTF8.self)))
            } catch let issue as GitInspectionIssue { return .failure(issue) }
            catch { return .failure(.invalidOutput) }
        }
        return try result.get()
    }

    /// Checks only the supplied children for a Git/worktree marker plus HEAD/config/objects
    /// structure. This is not a recursive search or a claim that `git fsck` would succeed.
    public func repositoryRoots(in childDirectories: [URL]) async -> Set<URL> {
        await GitWorker.perform(cancelled: Set<URL>(), rejected: Set<URL>()) { control in
            var roots: Set<URL> = []
            for child in childDirectories.prefix(512) {
                do {
                    try control.check()
                    if let found = try GitRepositoryLocation.discover(child, exact: true, control: control) { roots.insert(found.root) }
                } catch { continue }
            }
            return roots
        }
    }

    private nonisolated static func failure(_ issue: GitInspectionIssue) -> GitInspectionResult {
        switch issue {
        case .nonLocalLocation, .offlineFiles, .unsafeConfiguration, .resourceLimit: .skipped(issue)
        default: .failed(issue)
        }
    }
}

private enum GitDiscovery: Sendable { case found(GitRepositoryLocation), absent, failed(GitInspectionIssue) }

private struct GitRepositoryLocation: Sendable {
    let root: URL
    let gitDirectory: URL
    let commonDirectory: URL

    static func discover(_ directory: URL, exact: Bool = false, control: GitRunControl) throws -> Self? {
        guard directory.isFileURL, directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.query == nil, directory.fragment == nil else { throw GitInspectionIssue.nonLocalLocation }
        try validateStorage(directory, control: control)
        var current = directory.standardizedFileURL
        guard (try metadata(current)?.st_mode ?? 0) & S_IFMT == S_IFDIR else { throw GitInspectionIssue.unreadableRepository }
        for _ in 0..<128 {
            try control.check()
            let marker = current.appendingPathComponent(".git")
            if let info = try metadata(marker) {
                let gitDirectory: URL
                if info.st_mode & S_IFMT == S_IFDIR { gitDirectory = marker }
                else if info.st_mode & S_IFMT == S_IFREG {
                    let value = try smallText(marker)
                    guard value.hasPrefix("gitdir: ") else { return nil }
                    gitDirectory = resolve(String(value.dropFirst(8)), relativeTo: current)
                } else { return nil }
                try validateStorage(gitDirectory, control: control)
                let commonFile = gitDirectory.appendingPathComponent("commondir")
                let common = try metadata(commonFile) == nil ? gitDirectory : resolve(try smallText(commonFile), relativeTo: gitDirectory)
                try validateStorage(common, control: control)
                guard (try metadata(gitDirectory.appendingPathComponent("HEAD"))?.st_mode ?? 0) & S_IFMT == S_IFREG,
                      (try metadata(common.appendingPathComponent("config"))?.st_mode ?? 0) & S_IFMT == S_IFREG,
                      (try metadata(common.appendingPathComponent("objects"))?.st_mode ?? 0) & S_IFMT == S_IFDIR else { return nil }
                guard !LocalTransferRecovery.isProtected(current), !LocalTransferRecovery.isProtected(gitDirectory),
                      !LocalTransferRecovery.isProtected(common) else { throw GitInspectionIssue.unreadableRepository }
                return Self(root: current, gitDirectory: gitDirectory, commonDirectory: common)
            }
            if exact || current.path == "/" { return nil }
            current.deleteLastPathComponent()
        }
        throw GitInspectionIssue.resourceLimit
    }

    private static func validateStorage(_ directory: URL, control: GitRunControl) throws {
        let resolved = directory.resolvingSymlinksInPath()
        let canonical = resolved.path.lowercased()
        guard !canonical.contains("/library/cloudstorage/"), !canonical.contains("/library/mobile documents/"),
              (try? resolved.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey]).volumeIsLocal) == true,
              (try? resolved.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) != true else {
            throw GitInspectionIssue.nonLocalLocation
        }
        for path in [directory.standardizedFileURL, resolved] {
            var ancestor = path
            for _ in 0..<128 {
                try control.check()
                _ = try metadata(ancestor)
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
        }
    }

    private static func resolve(_ value: String, relativeTo base: URL) -> URL {
        value.hasPrefix("/") ? URL(fileURLWithPath: value).standardizedFileURL : base.appendingPathComponent(value).standardizedFileURL
    }

    static func metadata(_ url: URL) throws -> stat? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw GitInspectionIssue.unreadableRepository
        }
        if value.st_flags & UInt32(SF_DATALESS) != 0 { throw GitInspectionIssue.offlineFiles }
        return value
    }

    private static func smallText(_ url: URL) throws -> String {
        guard let info = try metadata(url), info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 4096 else {
            throw GitInspectionIssue.unreadableRepository
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw GitInspectionIssue.unreadableRepository }
        defer { Darwin.close(descriptor) }
        var data = [UInt8](repeating: 0, count: 4097)
        let count = Darwin.read(descriptor, &data, data.count)
        guard count > 0, count <= 4096, let string = String(bytes: data.prefix(count), encoding: .utf8) else { throw GitInspectionIssue.invalidOutput }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func snapshot(using runner: GitRunner, control: GitRunControl, expandUntracked: Bool = false) throws -> GitStatusSnapshot {
        try checkGitMetadata(control: control)
        for config in [commonDirectory.appendingPathComponent("config"), gitDirectory.appendingPathComponent("config.worktree")] {
            guard let metadata = try Self.metadata(config) else { continue }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 1024 * 1024 else { throw GitInspectionIssue.unsafeConfiguration }
            // Running outside the repository prevents its config from being loaded during
            // command setup. --no-includes checks declarations without following them.
            let configData = try runner.run(["config", "--file", config.path, "--no-includes", "--null", "--list"], directory: URL(fileURLWithPath: "/"))
            for record in configData.split(separator: 0) {
                guard let key = String(bytes: record.prefix(while: { $0 != 10 }), encoding: .utf8)?.lowercased() else { throw GitInspectionIssue.invalidOutput }
                if key.hasPrefix("filter.") || key.hasPrefix("include.") || key.hasPrefix("includeif.")
                    || key == "extensions.partialclone" || key.hasSuffix(".promisor") || key == "core.worktree" {
                    throw GitInspectionIssue.unsafeConfiguration
                }
            }
        }
        let args = ["--git-dir=\(gitDirectory.path)", "--work-tree=\(root.path)"]
        let inventory = try runner.run(args + ["ls-files", "-z"], directory: root)
        let tracked = try GitStatusParser.trackedPaths(from: inventory)
        guard tracked.count <= 20_000 else { throw GitInspectionIssue.resourceLimit }
        var checkedDirectories: Set<String> = []
        for path in tracked {
            try control.check()
            _ = try Self.metadata(root.appendingPathComponent(path))
            var directory = root.appendingPathComponent(path).deletingLastPathComponent()
            while directory.pathComponents.count >= root.pathComponents.count {
                if checkedDirectories.insert(directory.path).inserted {
                    guard let info = try Self.metadata(directory), info.st_mode & S_IFMT == S_IFDIR else {
                        if directory == root { throw GitInspectionIssue.unreadableRepository }
                        break // An intentionally deleted tracked directory need not exist.
                    }
                    try checkRuleFiles(in: directory)
                }
                if directory == root { break }
                directory.deleteLastPathComponent()
            }
        }
        let ignored = try preflightWorktree(using: runner, arguments: args, tracked: tracked, control: control)
        try checkTrackedFilters(tracked, using: runner, arguments: args)
        var status = try runner.run(args + ["status", "--porcelain=v2", "--branch", "-z", expandUntracked ? "--untracked-files=all" : "--untracked-files=normal", "--ignore-submodules=all"], directory: root)
        for path in ignored.sorted() { status.append(contentsOf: ("! " + path).utf8); status.append(0) }
        return try GitStatusParser.parse(status, rootURL: root, trackedPaths: tracked)
    }

    private func checkTrackedFilters(_ tracked: Set<String>, using runner: GitRunner, arguments: [String]) throws {
        guard !tracked.isEmpty else { return }
        // A repository can assign filter=lfs/custom while the executable definition lives
        // in global config (deliberately disabled here). Do not report an inaccurate raw
        // comparison as Modified. check-attr resolves attributes without executing filters.
        let input = Data((tracked.sorted().joined(separator: "\0") + "\0").utf8)
        let output = try runner.run(arguments + ["check-attr", "-z", "--stdin", "filter"], directory: root, input: input)
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true else { throw GitInspectionIssue.invalidOutput }
        fields.removeLast()
        guard fields.count == tracked.count * 3 else { throw GitInspectionIssue.invalidOutput }
        var seen: Set<String> = []
        for offset in stride(from: 0, to: fields.count, by: 3) {
            guard let path = String(bytes: fields[offset], encoding: .utf8), tracked.contains(path),
                  seen.insert(path).inserted,
                  String(bytes: fields[offset + 1], encoding: .utf8) == "filter",
                  let value = String(bytes: fields[offset + 2], encoding: .utf8) else {
                throw GitInspectionIssue.invalidOutput
            }
            guard value == "unspecified" || value == "unset" else { throw GitInspectionIssue.unsafeConfiguration }
        }
    }

    private func checkGitMetadata(control: GitRunControl) throws {
        var pending = [commonDirectory]
        if commonDirectory != gitDirectory { pending.append(gitDirectory) }
        var count = 0
        while let directory = pending.popLast() {
            try control.check()
            for child in try children(directory, remaining: 20_000 - count) {
                count += 1
                guard count <= 20_000 else { throw GitInspectionIssue.resourceLimit }
                guard let info = try Self.metadata(child) else { continue }
                let type = info.st_mode & S_IFMT
                guard type == S_IFREG || type == S_IFDIR else { throw GitInspectionIssue.unsafeConfiguration }
                if child.path.hasSuffix("/objects/info/alternates"), info.st_size > 0 { throw GitInspectionIssue.unsafeConfiguration }
                if type == S_IFDIR {
                    guard child.pathComponents.count - min(commonDirectory.pathComponents.count, gitDirectory.pathComponents.count) < 64 else { throw GitInspectionIssue.resourceLimit }
                    pending.append(child)
                }
            }
        }
    }

    private func checkRuleFiles(in directory: URL) throws {
        for name in [".gitignore", ".gitattributes"] {
            if let info = try Self.metadata(directory.appendingPathComponent(name)), info.st_mode & S_IFMT != S_IFREG {
                throw GitInspectionIssue.unsafeConfiguration
            }
        }
    }

    /// Visit only directories Git may inspect, pruning ignored children before touching
    /// their contents. Each check-ignore batch reads rules of parents already preflighted.
    private func preflightWorktree(using runner: GitRunner, arguments: [String], tracked: Set<String>, control: GitRunControl) throws -> Set<String> {
        var pending = [root], ignored: Set<String> = [], directories = 0, entries = 0, calls = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !pending.isEmpty {
            try control.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitInspectionIssue.resourceLimit }
            var candidates: [URL] = []
            for directory in pending {
                directories += 1
                guard directories <= 128 else { throw GitInspectionIssue.resourceLimit }
                _ = try Self.metadata(directory)
                try checkRuleFiles(in: directory)
                let found = try children(directory, remaining: 20_000 - entries).filter { $0.lastPathComponent != ".git" }
                entries += found.count
                guard entries <= 20_000 else { throw GitInspectionIssue.resourceLimit }
                candidates += found
            }
            pending = []
            guard !candidates.isEmpty else { continue }
            calls += 1
            guard calls <= 16 else { throw GitInspectionIssue.resourceLimit }
            let relative = candidates.map { String($0.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1)) }
            let input = Data((relative.joined(separator: "\0") + "\0").utf8)
            let excludedData = try runner.run(arguments + ["check-ignore", "--no-index", "-z", "--stdin"], directory: root, allowedExitCodes: [0, 1], input: input)
            guard let excludedText = String(data: excludedData, encoding: .utf8) else { throw GitInspectionIssue.invalidOutput }
            let excluded = Set(excludedText.split(separator: "\0").map(String.init))
            for (child, path) in zip(candidates, relative) {
                try control.check()
                if excluded.contains(path) {
                    // A trailing slash distinguishes an ignored directory in porcelain.
                    var info = stat()
                    let isDirectory = lstat(child.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
                    if !tracked.contains(path) { ignored.insert(path + (isDirectory ? "/" : "")) }
                    continue
                }
                guard let info = try Self.metadata(child) else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    if try Self.discover(child, exact: true, control: control) == nil { pending.append(child) }
                }
            }
        }
        return ignored
    }

    private func children(_ directory: URL, remaining: Int) throws -> [URL] {
        guard remaining >= 0, let handle = opendir(directory.path) else { throw GitInspectionIssue.unreadableRepository }
        defer { closedir(handle) }
        var urls: [URL] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw GitInspectionIssue.invalidOutput }
            if name == "." || name == ".." { continue }
            guard urls.count < remaining else { throw GitInspectionIssue.resourceLimit }
            urls.append(directory.appendingPathComponent(name))
        }
        return urls
    }

}

/// A bounded blocking pool, rather than cooperative Swift executor threads. Cancellation
/// resumes the awaiting UI immediately even if a filesystem metadata call cannot be interrupted.
private enum GitWorker {
    static let queue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility
        return queue
    }()
    static let admission = GitAdmission()
    static func perform<Value: Sendable>(cancelled: Value, rejected: Value, timedOut: Value? = nil,
                                         operation: @escaping @Sendable (GitRunControl) -> Value) async -> Value {
        guard admission.enter() else { return rejected }
        let job = GitWork<Value>(cancelled: cancelled)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak job] in
            guard let job else { return }
            job.finish(timedOut ?? rejected)
            job.control.cancel()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                job.bind(continuation)
                queue.addOperation {
                    defer { admission.leave() }
                    if !job.control.isCancelled { job.finish(operation(job.control)) }
                    else { job.finish(cancelled) }
                }
            }
        } onCancel: { job.cancel() }
    }
}

private final class GitAdmission: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func enter() -> Bool { lock.withLock { guard count < 32 else { return false }; count += 1; return true } }
    func leave() { lock.withLock { count -= 1 } }
}
private final class GitWork<Value: Sendable>: @unchecked Sendable {
    let control = GitRunControl()
    private let lock = NSLock()
    private let cancelled: Value
    private var result: Value?
    private var finished = false
    private var continuation: CheckedContinuation<Value, Never>?
    init(cancelled: Value) { self.cancelled = cancelled }
    func bind(_ continuation: CheckedContinuation<Value, Never>) {
        let previous = lock.withLock { () -> Value? in
            if finished { return result }
            self.continuation = continuation; return nil
        }
        if let previous { continuation.resume(returning: previous) }
    }
    func finish(_ value: Value) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            guard !finished else { return nil }
            finished = true; result = value
            let continuation = self.continuation; self.continuation = nil; return continuation
        }
        continuation?.resume(returning: value)
    }
    func cancel() { control.cancel(); finish(cancelled) }
}
private final class GitRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private let deadline = ProcessInfo.processInfo.systemUptime + 15
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() {
        let active = lock.withLock { cancelled = true; return process }
        if let active, active.isRunning { active.terminate() }
    }
    func register(_ process: Process?) { lock.withLock { self.process = process } }
    func check() throws {
        if isCancelled { throw GitInspectionIssue.cancelled }
        if ProcessInfo.processInfo.systemUptime > deadline { throw GitInspectionIssue.timedOut }
    }
}

private struct GitRunner {
    let executable: URL
    let timeout: TimeInterval
    let outputLimit: Int
    let control: GitRunControl
    static let arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                            "-c", "core.untrackedCache=false", "-c", "core.excludesFile=/dev/null", "-c", "core.attributesFile=/dev/null",
                            "-c", "protocol.allow=never", "-c", "maintenance.auto=false", "-c", "gc.auto=0"]
    func run(_ arguments: [String], directory: URL, allowedExitCodes: Set<Int32> = [0], input: Data? = nil) throws -> Data {
        try control.check()
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        let stdin = input == nil ? nil : Pipe()
        process.executableURL = executable
        process.arguments = Self.arguments + arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "XDG_CONFIG_HOME": "/var/empty",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_ASKPASS": "/usr/bin/false",
            "LC_ALL": "C", "LANG": "C", "GIT_PAGER": "cat"]
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { throw GitInspectionIssue.commandFailed }
        control.register(process)
        if let input, let stdin {
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        defer { control.register(nil); try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) }
        var output = Data(), total = 0, closed: Set<Int32> = []
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            while closed.count < descriptors.count || process.isRunning {
                try control.check()
                if ProcessInfo.processInfo.systemUptime > deadline { throw GitInspectionIssue.timedOut }
                for (index, descriptor) in descriptors.enumerated() where !closed.contains(descriptor) {
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    while true {
                        let count = Darwin.read(descriptor, &buffer, buffer.count)
                        if count == 0 { closed.insert(descriptor); break }
                        if count < 0 { if errno == EAGAIN || errno == EINTR { break }; throw GitInspectionIssue.commandFailed }
                        total += count
                        guard total <= outputLimit else { throw GitInspectionIssue.resourceLimit }
                        if index == 0 { output.append(contentsOf: buffer.prefix(count)) }
                    }
                }
                if closed.count < descriptors.count || process.isRunning {
                    var fds = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                    _ = poll(&fds, nfds_t(fds.count), 25)
                }
            }
        } catch {
            if process.isRunning { process.terminate() }
            let stopDeadline = Date().addingTimeInterval(0.1)
            while process.isRunning && Date() < stopDeadline { usleep(1000) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            // Hold this pool slot until the child really exits. If kernel I/O is stuck,
            // the independent job deadline/cancellation still resumes the UI, while
            // no third process can bypass the global two-process bound.
            while process.isRunning { usleep(10_000) }
            throw error
        }
        guard allowedExitCodes.contains(process.terminationStatus) else { throw GitInspectionIssue.commandFailed }
        return output
    }
}
