// SPDX-License-Identifier: Apache-2.0
import AppKit
import UniformTypeIdentifiers
import ExplorerCore

/// One drawn icon per kind of file, without macOS's document-with-a-small-app-logo wrapper.
@MainActor
enum FileTypeIcon {
    struct Appearance {
        /// The system symbol and tint of the earlier single-colour icons; kept as the fallback.
        let symbol: String
        let color: NSColor
        let icon: ExplorerIcon
    }

    static func appearance(for entry: FileEntry) -> Appearance {
        if entry.canNavigate { return Appearance(symbol: "folder.fill", color: .systemYellow, icon: .folder) }
        let ext = entry.url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if ext == "pdf" { return Appearance(symbol: "doc.richtext.fill", color: .systemRed, icon: .pdf) }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "tgz"].contains(ext) || type?.conforms(to: .archive) == true {
            return Appearance(symbol: "archivebox.fill", color: .systemBrown, icon: .archive)
        }
        if ["ppt", "pptx", "odp", "key"].contains(ext) || type?.conforms(to: .presentation) == true {
            return Appearance(symbol: "rectangle.on.rectangle.fill", color: .systemOrange, icon: .slides)
        }
        if ["xls", "xlsx", "ods", "numbers", "csv", "tsv"].contains(ext) || type?.conforms(to: .spreadsheet) == true {
            return Appearance(symbol: "tablecells.fill", color: .systemGreen, icon: .sheet)
        }
        if type?.conforms(to: .image) == true { return Appearance(symbol: "photo.fill", color: .systemBlue, icon: .image) }
        if type?.conforms(to: .movie) == true || ["mkv", "avi", "webm"].contains(ext) {
            return Appearance(symbol: "film.fill", color: .systemPurple, icon: .video)
        }
        if type?.conforms(to: .audio) == true || ["flac", "ogg", "opus"].contains(ext) {
            return Appearance(symbol: "music.note", color: .systemPink, icon: .audio)
        }
        if type?.conforms(to: .sourceCode) == true || ["json", "yaml", "yml", "toml", "xml", "sh"].contains(ext) {
            return Appearance(symbol: "chevron.left.forwardslash.chevron.right", color: .systemTeal, icon: .code)
        }
        if ["doc", "docx", "odt", "pages", "rtf"].contains(ext) {
            return Appearance(symbol: "doc.text.fill", color: .systemBlue, icon: .document)
        }
        if type?.conforms(to: .text) == true || ext == "log" {
            return Appearance(symbol: "text.alignleft", color: .secondaryLabelColor, icon: .text)
        }
        if ["dmg", "iso", "img"].contains(ext) { return Appearance(symbol: "externaldrive.fill", color: .systemGray, icon: .disk) }
        if ["pkg", "apk"].contains(ext) { return Appearance(symbol: "shippingbox.fill", color: .systemBrown, icon: .archive) }
        return Appearance(symbol: "doc.fill", color: .secondaryLabelColor, icon: .file)
    }

    /// Icon side for a row of the given height; the file list and the folder tree share it.
    static func iconSide(rowHeight: CGFloat) -> CGFloat { min(30, max(22, rowHeight - 7)) }
    static var listRowHeight: CGFloat { max(29, ExplorerStyle.preferences.fontSize(for: .files) + 14) }
    static var listIconSide: CGFloat { iconSide(rowHeight: listRowHeight) }

    static func configure(_ cell: FileNameCell, for entry: FileEntry, rowHeight: CGFloat) {
        configure(cell, for: entry, side: iconSide(rowHeight: rowHeight))
    }

    static func configure(_ cell: FileNameCell, for entry: FileEntry, side: CGFloat) {
        cell.setIconSize(side)
        cell.icon.imageScaling = .scaleProportionallyUpOrDown
        cell.icon.imageAlignment = .alignCenter
        if entry.isPackage && entry.url.isFileURL {
            cell.icon.image = NSWorkspace.shared.icon(forFile: entry.url.path)
            cell.icon.contentTintColor = nil
        } else {
            cell.icon.image = PremiumIcons.image(appearance(for: entry).icon, side: side, description: L10n.current.fileKind(entry))
            cell.icon.contentTintColor = nil
        }
        cell.icon.setAccessibilityLabel(L10n.current.fileKind(entry))
        cell.shortcutBadge.isHidden = !(entry.isSymbolicLink || entry.isAlias)
        cell.shortcutBadge.setAccessibilityLabel(L10n.text("icon.shortcut"))
    }
}
