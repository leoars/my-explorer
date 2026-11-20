// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ExplorerCore

final class GitStatusServiceTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer-Git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @discardableResult private func git(_ args: [String], at url: URL) throws -> String {
        guard let executable = GitStatusService.discoverExecutable() else { throw XCTSkip("Git is not installed") }
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = url
        process.environment = ["PATH":"/usr/bin:/bin", "HOME":url.path, "GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null",
                               "GIT_AUTHOR_NAME":"Fixture", "GIT_AUTHOR_EMAIL":"fixture@example.invalid",
                               "GIT_COMMITTER_NAME":"Fixture", "GIT_COMMITTER_EMAIL":"fixture@example.invalid", "LC_ALL":"C"]
        process.standardOutput = out; process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }
    private func repository() throws -> URL {
        let url = try fixture()
        try git(["init", "-b", "main"], at: url)
        try Data("original\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"], at: url)
        try git(["commit", "-qm", "fixture"], at: url)
        return url
    }
    private func snapshot(_ result: GitInspectionResult, file: StaticString = #filePath, line: UInt = #line) throws -> GitStatusSnapshot {
        guard case .repository(let snapshot) = result else { XCTFail("Expected Git snapshot, got \(result)", file: file, line: line); throw Failure.result }
        return snapshot
    }
    private enum Failure: Error { case result }

    func testReviewSelectionIncludesDeletedAndLiteralUntrackedPaths() async throws {
        let root = try repository(), service = GitStatusService()
        let name = "sub/[?]*.txt"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("new file\n".utf8).write(to: root.appendingPathComponent(name))
        try FileManager.default.removeItem(at: root.appendingPathComponent("tracked.txt"))
        guard case .changes(_, let selected) = try await service.review(.changes, root: root, paths: ["sub"]),
              case .text(let patch) = try await service.review(.diff(staged: false), root: root, paths: [name]),
              case .changes(_, let deleted) = try await service.review(.changes, root: root, paths: ["tracked.txt"])
        else { return XCTFail("Missing selection") }
        XCTAssertEqual(selected, [name])
        XCTAssertEqual(deleted, ["tracked.txt"])
        XCTAssertTrue(patch.contains("+new file"))
        try git(["init", "nested"], at: root)
        do {
            _ = try await service.review(.changes, root: root, paths: ["nested"])
            XCTFail("Nested repository accepted")
        } catch GitInspectionIssue.unreadableRepository {}
    }

    func testReviewSeparatesIndexAndWorktree() async throws {
        let root = try repository(), service = GitStatusService()
        let file = root.appendingPathComponent("tracked.txt")
        try Data("index\n".utf8).write(to: file)
        try git(["add", "--", "tracked.txt"], at: root)
        try Data("working\n".utf8).write(to: file)
        for (staged, expected) in [(true, "+index"), (false, "+working")] {
            guard case .text(let patch) = try await service.review(.diff(staged: staged), root: root, paths: ["tracked.txt"]) else { return XCTFail() }
            XCTAssertTrue(patch.contains(expected))
        }
    }

    @discardableResult private func interactive(_ action: GitInteractiveAction, root: URL, paths: [String] = [],
                                                value: String = "", reply: String = "OK", succeeds: Bool = true, beforeConfirm: (() throws -> Void)? = nil) throws -> String {
        let script = try action.script(root: root, paths: paths, executable: XCTUnwrap(GitStatusService.discoverExecutable()),
                                       value: value, confirmation: "Confirm", changed: "Changed")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null",
                               "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        var preview = Data()
        if let beforeConfirm {
            while !String(decoding: preview, as: UTF8.self).contains("Confirm [OK]") {
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw Failure.result }
                preview.append(chunk)
            }
            try beforeConfirm()
        }
        try input.fileHandleForWriting.write(contentsOf: Data((reply + "\n").utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: preview + output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus == 0, succeeds, text)
        return text
    }

    func testStageUnstageAndReviewEntireIndexBeforeCommit() throws {
        let root = try fixture()
        try git(["init", "-b", "main"], at: root)
        let name = "it's $(touch sentinel) [x].txt"
        for file in [name, "other.txt"] { try Data("initial".utf8).write(to: root.appendingPathComponent(file)) }
        try interactive(.stage, root: root, paths: [name], reply: "cancel", succeeds: false)
        XCTAssertEqual(try git(["ls-files"], at: root), "")
        try interactive(.stage, root: root, paths: [name, "other.txt"])
        try Data("updated after staging".utf8).write(to: root.appendingPathComponent(name))
        try interactive(.unstage, root: root, paths: [name])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8), "updated after staging")
        XCTAssertEqual(try git(["ls-files"], at: root), "other.txt\n")
        try interactive(.stage, root: root, paths: [name])
        try git(["config", "user.name", "Fixture"], at: root)
        try git(["config", "user.email", "fixture@example.invalid"], at: root)
        let message = "commit ' $(touch sentinel)"
        let preview = try interactive(.commit, root: root, paths: [name], value: message)
        XCTAssertTrue(preview.contains("other.txt"))
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], at: root), message + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sentinel").path))
        try Data("more".utf8).write(to: root.appendingPathComponent(name))
        try interactive(.stage, root: root, paths: [name])
        try interactive(.unstage, root: root, paths: [name])
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], at: root), "")
    }

    func testCommitDeclinesChangedIndexAndRenameCanBeStaged() throws {
        let root = try repository()
        try git(["mv", "tracked.txt", "renamed.txt"], at: root)
        try Data("edited".utf8).write(to: root.appendingPathComponent("renamed.txt"))
        try interactive(.stage, root: root, paths: ["renamed.txt"])
        let text = try interactive(.commit, root: root, value: "stale preview", succeeds: false) {
            try Data("another".utf8).write(to: root.appendingPathComponent("other"))
            try self.git(["add", "other"], at: root)
        }
        XCTAssertTrue(text.contains("Changed"))
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], at: root), "fixture\n")
    }

    func testBranchAndSyncOperationsOnDisposableRemote() throws {
        let root = try repository(), remote = try fixture(), clone = try fixture()
        try git(["init", "--bare", "-b", "main"], at: remote)
        try git(["remote", "add", "fixture", remote.path], at: root)
        try git(["tag", "main"], at: root)
        try interactive(.push, root: root, value: "fixture")
        try git(["clone", remote.path, clone.path], at: root)
        try interactive(.createBranch, root: root, value: "topic")
        XCTAssertEqual(try git(["branch", "--show-current"], at: root), "topic\n")
        try interactive(.switchBranch, root: root, value: "main")
        try Data("remote".utf8).write(to: clone.appendingPathComponent("tracked.txt"))
        try git(["commit", "-am", "incoming"], at: clone)
        try git(["push", "origin", "main"], at: clone)
        try interactive(.fetch, root: root, value: "fixture")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], at: root), "fixture\n")
        try interactive(.pull, root: root, value: "fixture")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], at: root), "incoming\n")
        try interactive(.switchBranch, root: root, value: "--discard-changes", succeeds: false)
        try interactive(.push, root: root, value: remote.path, succeeds: false)
    }

    func testOutsideRepositoryAndUnavailableTool() async throws {
        let directory = try fixture()
        let service = GitStatusService(executableURL: nil)
        guard case .notRepository = await service.inspect(directory: directory) else { return XCTFail("Non-repository must stay silent without Git") }
        let repo = try repository()
        guard case .unavailable = await service.inspect(directory: repo) else { return XCTFail("Missing executable was not reported") }
    }
    func testCleanModifiedUntrackedAndForceRefresh() async throws {
        let repo = try repository(), service = GitStatusService(cacheTTL: 60)
        let initial = try snapshot(await service.inspect(directory: repo))
        XCTAssertEqual(initial.branch, "main")
        XCTAssertEqual(initial.status(for: repo.appendingPathComponent("tracked.txt"), isDirectory: false)?.kind, .clean)
        try Data("changed content\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try Data("new\n".utf8).write(to: repo.appendingPathComponent("日本語 space.txt"))
        let cached = try snapshot(await service.inspect(directory: repo))
        XCTAssertEqual(cached.status(for: repo.appendingPathComponent("tracked.txt"), isDirectory: false)?.kind, .clean)
        let fresh = try snapshot(await service.inspect(directory: repo, force: true))
        XCTAssertEqual(fresh.status(for: repo.appendingPathComponent("tracked.txt"), isDirectory: false)?.kind, .modified)
        XCTAssertEqual(fresh.status(for: repo.appendingPathComponent("日本語 space.txt"), isDirectory: false)?.kind, .untracked)
    }
    func testNestedDirectorySharesRepositoryAndLexicalRoot() async throws {
        let repo = try repository(), child = repo.appendingPathComponent("nested/inside")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let service = GitStatusService()
        let value = try snapshot(await service.inspect(directory: child))
        XCTAssertEqual(value.rootURL.path, repo.path)
        XCTAssertNotNil(value.status(for: repo.appendingPathComponent("tracked.txt"), isDirectory: false))
    }
    func testLinkedWorktreeAndChildRootHints() async throws {
        let repo = try repository(), parent = try fixture(), worktree = parent.appendingPathComponent("linked worktree")
        try git(["worktree", "add", "-b", "other", worktree.path], at: repo)
        let service = GitStatusService()
        let value = try snapshot(await service.inspect(directory: worktree))
        XCTAssertEqual(value.branch, "other")
        XCTAssertEqual(value.rootURL.path, worktree.path)
        let fake = parent.appendingPathComponent("fake")
        try FileManager.default.createDirectory(at: fake.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let hints = await service.repositoryRoots(in: [worktree, fake, parent])
        XCTAssertEqual(Set(hints.map(\.path)), [worktree.path])
    }
    func testFilterAndIncludeConfigurationAreNeverExecuted() async throws {
        let repo = try repository(), sentinel = repo.appendingPathComponent("filter-ran")
        try git(["config", "filter.review.clean", "touch '\(sentinel.path)'; cat"], at: repo)
        try Data("tracked.txt filter=review\n".utf8).write(to: repo.appendingPathComponent(".gitattributes"))
        try Data("CHANGED!\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        guard case .skipped(.unsafeConfiguration) = await GitStatusService().inspect(directory: repo) else { return XCTFail("Unsafe filter was not refused") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        try git(["config", "--remove-section", "filter.review"], at: repo)
        try git(["config", "include.path", "/not/read/by/myexplorer"], at: repo)
        guard case .skipped(.unsafeConfiguration) = await GitStatusService().inspect(directory: repo) else { return XCTFail("Config includes were not refused") }
    }
    func testFsmonitorOverrideAndReadOnlyIndex() async throws {
        let repo = try repository(), sentinel = repo.appendingPathComponent("fsmonitor-ran")
        try git(["config", "core.fsmonitor", "touch '\(sentinel.path)'"], at: repo)
        let index = repo.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)
        _ = try snapshot(await GitStatusService().inspect(directory: repo))
        XCTAssertEqual(try Data(contentsOf: index), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index.lock").path))
    }
    func testIgnoredTreeIsPrunedAndTrackedIgnoredFileIsStillTracked() async throws {
        let repo = try repository()
        try Data(".build/\ntracked.txt\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        let ignored = repo.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        for number in 0..<140 {
            try FileManager.default.createDirectory(at: ignored.appendingPathComponent("folder-\(number)"), withIntermediateDirectories: true)
        }
        let value = try snapshot(await GitStatusService().inspect(directory: repo))
        XCTAssertEqual(value.status(for: repo.appendingPathComponent("tracked.txt"), isDirectory: false)?.kind, .clean)
        XCTAssertEqual(value.status(for: ignored, isDirectory: true)?.kind, .ignored)
    }

    private func executable(_ body: String, in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("fake-git-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testTimeoutOutputLimitAndImmediateCancellation() async throws {
        let repo = try repository()
        let slow = try executable("exec /bin/sleep 5", in: try fixture())
        let timeout = await GitStatusService(executableURL: slow, processTimeout: 0.05).inspect(directory: repo)
        guard case .failed(.timedOut) = timeout else { return XCTFail("Expected deadline, got \(timeout)") }
        let noisy = try executable("exec /usr/bin/yes X", in: try fixture())
        let oversized = await GitStatusService(executableURL: noisy, outputLimit: 1024).inspect(directory: repo)
        guard case .skipped(.resourceLimit) = oversized else { return XCTFail("Expected bounded output, got \(oversized)") }
        let service = GitStatusService(executableURL: slow)
        let pending = Task { await service.inspect(directory: repo) }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        pending.cancel()
        guard case .failed(.cancelled) = await pending.value else { return XCTFail("Cancellation not reported") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        try await Task.sleep(for: .milliseconds(100)) // Let the terminated fixture process be reaped.
    }

    func testGitFileCannotBypassCloudStorageGate() async throws {
        let directory = try fixture(), backing = directory.appendingPathComponent("Library/CloudStorage/FakeProvider/repository")
        try FileManager.default.createDirectory(at: backing, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: backing)
        let worktree = directory.appendingPathComponent("normal-worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data(("gitdir: " + backing.appendingPathComponent(".git").path + "\n").utf8).write(to: worktree.appendingPathComponent(".git"))
        guard case .skipped(.nonLocalLocation) = await GitStatusService().inspect(directory: worktree) else {
            return XCTFail("Linked metadata bypassed cloud storage exclusion")
        }
    }

    func testUnignoredTreeHonorsDirectoryBudget() async throws {
        let repo = try repository()
        for number in 0..<140 {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent("folder-\(number)"), withIntermediateDirectories: true)
        }
        guard case .skipped(.resourceLimit) = await GitStatusService().inspect(directory: repo) else {
            return XCTFail("Directory preflight exceeded its bounded scan budget")
        }
    }

    func testFilterAttributeWithoutLocalDefinitionIsRefusedWithoutChangingFiles() async throws {
        let repo = try repository(), file = repo.appendingPathComponent("tracked.txt")
        let attributes = repo.appendingPathComponent(".gitattributes")
        let original = try Data(contentsOf: file)
        for attribute in ["filter=custom", "filter"] {
            let rules = Data(("tracked.txt " + attribute + "\n").utf8)
            try rules.write(to: attributes)
            let result = await GitStatusService().inspect(directory: repo)
            guard case .skipped(.unsafeConfiguration) = result else {
                return XCTFail("Filter attribute without local configuration was not refused: \(result)")
            }
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try Data(contentsOf: attributes), rules)
        }
        for attribute in ["-filter", "!filter"] {
            try Data(("tracked.txt " + attribute + "\n").utf8).write(to: attributes)
            let value = try snapshot(await GitStatusService().inspect(directory: repo))
            XCTAssertEqual(value.status(for: file, isDirectory: false)?.kind, .clean)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

}
