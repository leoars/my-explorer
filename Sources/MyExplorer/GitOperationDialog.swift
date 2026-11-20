// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

extension ExplorerWindowController {
    func prepareGitOperation(_ action: GitInteractiveAction, selection: GitSelection) {
        let generation = vaultPresentationGeneration
        Task {
            do {
                let service = GitStatusService()
                var paths = selection.paths
                // Revalidate the worktree, including paths captured by an open menu.
                guard case .changes(let snapshot, let changes) = try await service.review(.changes, root: selection.root, paths: paths)
                else { return }
                if action == .unstage, !paths.isEmpty {
                    for path in changes {
                        if let old = snapshot.entries[path]?.originalPath {
                            if !paths.contains(old) { paths.append(old) }
                            if !paths.contains(path) { paths.append(path) }
                        }
                    }
                }
                let alert = NSAlert()
                alert.messageText = L10n.text("git." + action.rawValue)
                let scope = (action == .stage || action == .unstage) && !paths.isEmpty ? paths.joined(separator: "\n") : selection.root.path
                alert.informativeText = scope + "\n\n" + L10n.text("git.in_terminal")
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
                let picker = NSPopUpButton(frame: field.frame)
                switch action {
                case .commit, .createBranch:
                    let label = L10n.text(action == .commit ? "git.message" : "git.branch_name")
                    field.placeholderString = label
                    field.setAccessibilityLabel(label)
                    alert.accessoryView = field
                case .switchBranch, .fetch, .pull, .push:
                    let branches = action == .switchBranch
                    guard branches || snapshot.branch != nil else { showGitMessage(L10n.text("git.detached")); return }
                    guard case .text(let list) = try await service.review(branches ? .branches : .remotes, root: selection.root, paths: []) else { return }
                    let choices = list.split(separator: "\n").map(String.init).filter { !branches || $0 != snapshot.branch }
                    guard !choices.isEmpty else { showGitMessage(L10n.text(branches ? "git.no_branch" : "git.no_remote")); return }
                    picker.addItems(withTitles: choices)
                    picker.setAccessibilityLabel(L10n.text(branches ? "git.branch_name" : "git.remote"))
                    alert.accessoryView = picker
                    if !branches, let branch = snapshot.branch { alert.informativeText += "\n" + branch }
                default: break
                }
                alert.addButton(withTitle: L10n.text("git.continue_terminal"))
                alert.addButton(withTitle: L10n.text("dialog.cancel"))
                guard let window, window.isVisible else { return }
                guard generation == vaultPresentationGeneration else { return }
                alert.window.representedURL = selection.root
                let response = await alert.beginSheetModal(for: window)
                guard generation == vaultPresentationGeneration, response == .alertFirstButtonReturn else { return }
                let value = alert.accessoryView === picker ? picker.titleOfSelectedItem ?? "" : field.stringValue
                if alert.accessoryView === field, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    showGitMessage(field.placeholderString ?? "Git"); return
                }
                guard let git = GitStatusService.discoverExecutable(),
                      let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
                else { showGitMessage(L10n.text("git.unavailable")); return }
                let script = try action.script(root: selection.root, paths: paths, executable: git, value: value,
                                               confirmation: L10n.text("git.confirm_terminal"), changed: L10n.text("git.target_changed"))
                try await launchGitScript(script, with: terminal)
            } catch let issue as GitInspectionIssue { showGitMessage(L10n.text("git.reason." + issue.rawValue)) }
            catch { showGitMessage(error.localizedDescription) }
        }
    }

    private func launchGitScript(_ script: String, with terminal: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer-Git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let file = directory.appendingPathComponent("Git.command")
            // Terminal reads the open file descriptor after unlinking. Do not leave
            // commit messages or repository paths in the temp directory after launch.
            let program = script.replacingOccurrences(of: "#!/bin/sh\n", with: "#!/bin/sh\n/bin/rm -f -- \"$0\"\n/bin/rmdir -- \"$(/usr/bin/dirname -- \"$0\")\"\n", options: .anchored)
            try Data(program.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init())
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
