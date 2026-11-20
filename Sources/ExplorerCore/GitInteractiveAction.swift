// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Explicit interactive actions run in Terminal so Git can use the owner's
/// credential helpers, signing agent, hooks and editor. Badge reads stay isolated.
public enum GitInteractiveAction: String, CaseIterable, Sendable {
    case stage, unstage, commit, createBranch, switchBranch, fetch, pull, push

    public func script(root: URL, paths: [String], executable: URL, value: String,
                       confirmation: String, changed: String) throws -> String {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        guard root.isFileURL, executable.isFileURL, !value.utf8.contains(0),
              paths.allSatisfy({ path in
                  !path.utf8.contains(0) && path.split(separator: "/", omittingEmptySubsequences: false)
                      .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }
              }) else { throw GitInspectionIssue.invalidOutput }
        let targets = (paths.isEmpty ? ["."] : paths).map(quote).joined(separator: " ")
        let prelude = """
        #!/bin/sh
        set -eu
        cd -P -- \(quote(root.path))
        git() { \(quote(executable.path)) --literal-pathspecs "$@"; }
        test "$(git rev-parse --show-toplevel)" = "$(pwd -P)"
        reject() { printf '%s\\n' \(quote(changed)) >&2; exit 1; }
        confirm() { printf '%s [OK] ' \(quote(confirmation)); IFS= read -r answer && test "$answer" = OK; }
        value=\(quote(value))
        """
        let body: String
        switch self {
        case .stage, .unstage:
            // Resolve existing directories again at execution, including nested worktrees.
            let validate = """
            for path in \(targets); do
                dir="$path"
                if test -L "$dir" || ! test -d "$dir"; then dir=$(dirname -- "$dir"); fi
                while ! test -d "$dir"; do dir=$(dirname -- "$dir"); done
                test "$(git -C "$dir" rev-parse --show-toplevel)" = "$(pwd -P)" || reject
            done
            """
            if self == .stage {
                body = validate + "\ngit add --dry-run -A -- " + targets + "\nconfirm\ngit add -A -- " + targets
            } else {
                body = validate + "\ngit diff --cached --no-ext-diff --no-textconv --name-status -- " + targets +
                    "\nconfirm\nif git rev-parse --verify HEAD >/dev/null 2>&1; then git restore --staged -- " + targets +
                    "; else git rm -r -f --cached --ignore-unmatch -- " + targets + "; fi"
            }
        case .commit:
            body = """
            head() { git rev-parse --verify HEAD 2>/dev/null || printf unborn; }
            branch() { git symbolic-ref -q HEAD || printf detached; }
            before=$(git write-tree)
            revision=$(head)
            ref=$(branch)
            git -c color.ui=false diff --ignore-submodules=none --cached --no-ext-diff --no-textconv --name-status --
            if git diff --cached --ignore-submodules=none --quiet --exit-code; then exit 0; else test "$?" -eq 1 || reject; fi
            confirm
            test "$before" = "$(git write-tree)" && test "$revision" = "$(head)" && test "$ref" = "$(branch)" || reject
            git commit -m "$value"
            """
        case .createBranch, .switchBranch:
            body = """
            git check-ref-format "refs/heads/$value" >/dev/null
            case "$value" in -*|HEAD) reject;; esac
            git status --short --branch
            printf '%s\\n' "$value"
            confirm
            """ + (self == .createBranch ? "\ngit switch --no-overwrite-ignore -c \"$value\"" : "\ngit show-ref --verify --quiet \"refs/heads/$value\" || reject\ngit switch --no-overwrite-ignore --no-guess -- \"$value\"")
        case .fetch, .pull, .push:
            body = """
            case "$value" in ''|-*) reject;; esac
            git remote | /usr/bin/grep -Fx -- "$value" >/dev/null || reject
            ref=$(git symbolic-ref --quiet HEAD) || reject
            case "$ref" in refs/heads/*) branch=${ref#refs/heads/};; *) reject;; esac
            printf '%s  →  %s / %s\\n' \(quote(rawValue)) "$value" "$branch"
            confirm
            test "$ref" = "$(git symbolic-ref --quiet HEAD)" || reject
            """ + "\n" + {
                switch self {
                case .fetch: return "git fetch --no-tags --no-recurse-submodules -- \"$value\" \"refs/heads/$branch\""
                case .pull: return "git pull --ff-only --no-rebase --no-recurse-submodules -- \"$value\" \"refs/heads/$branch\""
                default: return "git -c \"remote.$value.mirror=false\" push --no-force --no-follow-tags --recurse-submodules=no -- \"$value\" \"refs/heads/$branch:refs/heads/$branch\""
                }
            }()
        }
        return prelude + "\n" + body + "\n"
    }
}
