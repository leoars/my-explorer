// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
enum GitDecoration {
    static func statusText(_ status: GitFileStatus) -> String {
        var text = L10n.text("git.status.\(status.kind.rawValue)")
        if status.staged { text += " · " + L10n.text("git.staged") }
        if status.unstaged { text += " · " + L10n.text("git.unstaged") }
        return text
    }

    static func apply(to cell: FileNameCell, url: URL, directory: Bool,
                      snapshot: GitStatusSnapshot?, roots: Set<String>, baseTooltip: String) {
        let status = snapshot?.status(for: url, isDirectory: directory)
        let isRoot = roots.contains(url.standardizedFileURL.path)
        cell.gitBadge.isHidden = status == nil && !isRoot
        cell.label.textColor = status?.kind == .ignored ? .secondaryLabelColor : .labelColor
        guard status != nil || isRoot else { cell.gitBadge.image = nil; cell.toolTip = baseTooltip; return }
        let symbol: String
        let color: NSColor
        switch status?.kind {
        case .clean: symbol = "checkmark.circle.fill"; color = .systemGreen
        case .modified: symbol = "pencil.circle.fill"; color = .systemOrange
        case .added: symbol = "plus.circle.fill"; color = .systemGreen
        case .deleted: symbol = "minus.circle.fill"; color = .systemRed
        case .renamed: symbol = "arrow.right.circle.fill"; color = .systemOrange
        case .untracked: symbol = "questionmark.circle.fill"; color = .systemBlue
        case .ignored: symbol = "minus.circle"; color = .secondaryLabelColor
        case .conflicted: symbol = "exclamationmark.triangle.fill"; color = .systemRed
        case nil: symbol = "arrow.triangle.branch"; color = .systemOrange
        }
        var details = isRoot ? L10n.text("git.repository") : "Git"
        if let status { details += " · " + statusText(status) }
        cell.gitBadge.image = NSImage(systemSymbolName: isRoot ? "arrow.triangle.branch" : symbol, accessibilityDescription: details)
        cell.gitBadge.contentTintColor = color
        cell.gitBadge.toolTip = details
        cell.gitBadge.setAccessibilityLabel(details)
        cell.toolTip = baseTooltip + "\n" + details
    }

    static func summary(_ result: GitInspectionResult?) -> String {
        switch result {
        case .repository(let snapshot):
            let branch = snapshot.isDetached ? L10n.text("git.detached") + " " + String((snapshot.headOID ?? "").prefix(7))
                : snapshot.branch ?? L10n.text("git.unknown_branch")
            let state = snapshot.isUnborn ? L10n.text("git.unborn")
                : snapshot.status(for: snapshot.rootURL, isDirectory: true).map(statusText) ?? L10n.text("git.status.clean")
            return "Git · \(branch) · \(state)"
        case .failed(let issue), .skipped(let issue): return L10n.text("git.unavailable") + " · " + L10n.text("git.reason.\(issue.rawValue)")
        case .unavailable: return L10n.text("git.not_installed")
        case .notRepository, nil: return ""
        }
    }
}
