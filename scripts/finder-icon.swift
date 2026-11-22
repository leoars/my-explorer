// SPDX-License-Identifier: Apache-2.0
// Applies or clears the custom Finder icon that shows the artwork edge to edge instead of
// inside the grey plate macOS puts behind free-form icons. From build 30 the app gives an
// installed copy this icon by itself when it opens, and its updater removes it before
// verifying the signature, so this script is only for manual checks. The icon lives outside
// the code signature: never apply it to dist/ before signing or packaging, and clear it from a
// build 28 or 29 copy before an in-app update, because those builds refuse to update with it.
//   swift scripts/finder-icon.swift apply "/Applications/My Explorer.app"
//   swift scripts/finder-icon.swift clear "/Applications/My Explorer.app"
import AppKit

guard CommandLine.arguments.count == 3, ["apply", "clear"].contains(CommandLine.arguments[1]) else {
    fputs("Usage: finder-icon.swift apply|clear <app bundle>\n", stderr)
    exit(2)
}
let bundle = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
if CommandLine.arguments[1] == "clear" {
    if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Icon\r").path) {
        guard NSWorkspace.shared.setIcon(nil, forFile: bundle.path) else { exit(1) }
    }
} else {
    let url = bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")
    guard let icon = NSImage(contentsOf: url), NSWorkspace.shared.setIcon(icon, forFile: bundle.path) else { exit(1) }
}
