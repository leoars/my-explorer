// SPDX-License-Identifier: Apache-2.0
#if !APP_STORE
import AppKit
import ExplorerCore

struct GitSelection {
    let root: URL
    let paths: [String]

    init?(root: URL, urls: [URL]) {
        let prefix = root.standardizedFileURL.pathComponents
        var paths: [String] = []
        for url in urls {
            let components = url.standardizedFileURL.pathComponents
            guard url.isFileURL, components.starts(with: prefix) else { return nil }
            let relative = components.dropFirst(prefix.count)
            guard !relative.contains(where: { $0.lowercased() == ".git" }) else { return nil }
            if !relative.isEmpty { paths.append(relative.joined(separator: "/")) }
        }
        self.root = root
        self.paths = paths
    }
}

@MainActor
final class GitReviewController: DialogWindowController {
    private let service = GitStatusService()
    var repositoryRoot: URL { selection.root }
    private let selection: GitSelection
    private let files = NSPopUpButton()
    private let modes = NSSegmentedControl(labels: [L10n.text("git.unstaged"), L10n.text("git.staged")], trackingMode: .selectOne, target: nil, action: nil)
    private let output = NSTextView.scrollableTextView()
    private var text: NSTextView { output.documentView as! NSTextView }
    private var snapshot: GitStatusSnapshot?
    private var paths: [String] = []
    private var query: Task<Void, Never>?

    init(selection: GitSelection, history: Bool) {
        self.selection = selection
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = L10n.text(history ? "git.history" : "git.changes") + " — " + selection.root.lastPathComponent
        window.minSize = NSSize(width: 480, height: 260)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = stack
        let scope = NSTextField(labelWithString: selection.paths.isEmpty ? selection.root.path : selection.paths.joined(separator: ", "))
        scope.toolTip = selection.root.path + "\n" + selection.paths.joined(separator: "\n")
        stack.addArrangedSubview(scope)
        if !history {
            files.target = self; files.action = #selector(selectFile)
            files.setAccessibilityLabel(L10n.text("git.changes"))
            stack.addArrangedSubview(files)
            modes.target = self; modes.action = #selector(showDiff)
            stack.addArrangedSubview(modes)
            files.isEnabled = false; modes.isEnabled = false
        }
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = L10n.text("status.loading")
        stack.addArrangedSubview(output)
        for view in stack.arrangedSubviews where view !== modes {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        query = Task { [weak self, service] in
            do {
                let result = try await service.review(history ? .history : .changes, root: selection.root, paths: selection.paths)
                guard !Task.isCancelled, let self else { return }
                switch result {
                case .text(let value): self.text.string = value.isEmpty ? L10n.text("git.no_history") : value
                case .changes(let snapshot, let paths):
                    self.snapshot = snapshot
                    self.paths = paths
                    for path in paths {
                        guard let status = snapshot.entries[path] else { continue }
                        self.files.addItem(withTitle: GitDecoration.statusText(status) + "  " + path)
                    }
                    self.files.isEnabled = !paths.isEmpty
                    if paths.isEmpty { self.text.string = L10n.text("git.no_changes") }
                    else { self.selectFile() }
                }
            } catch { if !Task.isCancelled { self?.display(error) } }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func selectFile() {
        let index = files.indexOfSelectedItem
        guard paths.indices.contains(index), let state = snapshot?.entries[paths[index]] else { return }
        let working = state.unstaged || state.kind == .untracked
        modes.isEnabled = true
        modes.setEnabled(working, forSegment: 0)
        modes.setEnabled(state.staged, forSegment: 1)
        modes.selectedSegment = working ? 0 : 1
        showDiff()
    }

    @objc private func showDiff() {
        let index = files.indexOfSelectedItem
        guard paths.indices.contains(index) else { return }
        let path = paths[index], root = selection.root, staged = modes.selectedSegment == 1
        query?.cancel()
        text.string = L10n.text("status.loading")
        query = Task { [weak self, service] in
            do {
                let result = try await service.review(.diff(staged: staged), root: root, paths: [path])
                guard !Task.isCancelled, case .text(let value) = result else { return }
                self?.text.string = value.isEmpty ? L10n.text("git.no_changes") : value
            } catch { if !Task.isCancelled { self?.display(error) } }
        }
    }
    private func display(_ error: Error) {
        text.string = L10n.text("git.reason." + ((error as? GitInspectionIssue) ?? .commandFailed).rawValue)
    }
    func windowWillClose(_ notification: Notification) { query?.cancel() }
}
#endif
