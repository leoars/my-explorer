// SPDX-License-Identifier: Apache-2.0
// Gives an installed copy of the app a custom Finder icon so macOS shows the artwork edge to
// edge instead of inside its grey plate. The custom icon lives outside the code signature, so
// apply it only to the installed bundle, never to dist/ before signing or packaging.
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
