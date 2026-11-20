// SPDX-License-Identifier: Apache-2.0
import AppKit
import UniformTypeIdentifiers
import ExplorerCore

/// Clear silhouettes for dense file lists, without macOS's document-with-a-small-app-logo wrapper.
@MainActor
enum FileTypeIcon {
    struct Appearance {
        let symbol: String
        let color: NSColor
    }

    static func appearance(for entry: FileEntry) -> Appearance {
        if entry.canNavigate { return Appearance(symbol: "folder.fill", color: .systemYellow) }
        let ext = entry.url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if ext == "pdf" { return Appearance(symbol: "doc.richtext.fill", color: .systemRed) }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "tgz"].contains(ext) || type?.conforms(to: .archive) == true {
            return Appearance(symbol: "archivebox.fill", color: .systemBrown)
        }
        if ["ppt", "pptx", "odp", "key"].contains(ext) || type?.conforms(to: .presentation) == true {
            return Appearance(symbol: "rectangle.on.rectangle.fill", color: .systemOrange)
        }
        if ["xls", "xlsx", "ods", "numbers", "csv", "tsv"].contains(ext) || type?.conforms(to: .spreadsheet) == true {
            return Appearance(symbol: "tablecells.fill", color: .systemGreen)
        }
        if type?.conforms(to: .image) == true { return Appearance(symbol: "photo.fill", color: .systemBlue) }
        if type?.conforms(to: .movie) == true || ["mkv", "avi", "webm"].contains(ext) {
            return Appearance(symbol: "film.fill", color: .systemPurple)
        }
        if type?.conforms(to: .audio) == true || ["flac", "ogg", "opus"].contains(ext) {
            return Appearance(symbol: "music.note", color: .systemPink)
        }
        if type?.conforms(to: .sourceCode) == true || ["json", "yaml", "yml", "toml", "xml", "sh"].contains(ext) {
            return Appearance(symbol: "chevron.left.forwardslash.chevron.right", color: .systemTeal)
        }
        if ["doc", "docx", "odt", "pages", "rtf"].contains(ext) {
            return Appearance(symbol: "doc.text.fill", color: .systemBlue)
        }
        if type?.conforms(to: .text) == true || ext == "log" {
            return Appearance(symbol: "text.alignleft", color: .secondaryLabelColor)
        }
        if ["dmg", "iso", "img"].contains(ext) { return Appearance(symbol: "externaldrive.fill", color: .systemGray) }
        if ["pkg", "apk"].contains(ext) { return Appearance(symbol: "shippingbox.fill", color: .systemBrown) }
        return Appearance(symbol: "doc.fill", color: .secondaryLabelColor)
    }

    static func configure(_ cell: FileNameCell, for entry: FileEntry, rowHeight: CGFloat) {
        let side = min(30, max(22, rowHeight - 7))
        cell.setIconSize(side)
        cell.icon.imageScaling = .scaleProportionallyUpOrDown
        cell.icon.imageAlignment = .alignCenter
        if entry.isPackage && entry.url.isFileURL {
            cell.icon.image = NSWorkspace.shared.icon(forFile: entry.url.path)
            cell.icon.contentTintColor = nil
        } else {
            let appearance = appearance(for: entry)
            cell.icon.image = ExplorerStyle.symbol(appearance.symbol, description: L10n.current.fileKind(entry))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side, weight: .regular))
                ?? ExplorerStyle.symbol("doc.fill", description: L10n.current.fileKind(entry))
            cell.icon.contentTintColor = appearance.color
        }
        cell.icon.setAccessibilityLabel(L10n.current.fileKind(entry))
        cell.shortcutBadge.isHidden = !(entry.isSymbolicLink || entry.isAlias)
        cell.shortcutBadge.setAccessibilityLabel(L10n.text("icon.shortcut"))
    }
}
