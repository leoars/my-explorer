// SPDX-License-Identifier: Apache-2.0
#if !APP_STORE
import ExplorerCore
import Foundation

private enum InstallerError: Error { case invalid }

enum UpdateInstaller {
    static let appID = "io.github.leoars.myexplorer"
    static let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"GV4SHC87M4\""
    static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw InstallerError.invalid }
    }
    static func verify(_ url: URL, identifier: String) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement) and identifier \"\(identifier)\"", url.path])
    }
    static func build(_ app: URL) throws -> Int {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == appID,
              let string = plist["CFBundleVersion"] as? String, let number = Int(string) else { throw InstallerError.invalid }
        return number
    }
    static func stage(image: URL, number: Int, current: URL) throws -> URL {
        try verify(image, identifier: appID + ".update")
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        } catch { _ = rmdir(mount.path); throw error }
        defer {
            if (try? run("/usr/bin/hdiutil", ["detach", mount.path])) != nil { _ = rmdir(mount.path) }
        }
        let directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        let staged = directory.appendingPathComponent("My Explorer.app")
        do {
            try run("/usr/bin/ditto", [mount.appendingPathComponent("My Explorer.app").path, staged.path])
            try verify(staged, identifier: appID)
            guard try build(staged) == number, try build(current) < number else { throw InstallerError.invalid }
            for architecture in ["arm64", "x86_64"] {
                try run("/usr/bin/lipo", [staged.appendingPathComponent("Contents/MacOS/MyExplorer").path, "-verify_arch", architecture])
            }
            guard Bundle(url: staged)?.supportsCurrentSystem() == true else { throw InstallerError.invalid }
            return staged
        } catch { try? fm.removeItem(at: directory); throw error }
    }
    static func reopenAfterExit(_ app: URL) throws {
        // LaunchServices must open the replaced bundle after this process releases its services.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open -n "$2""#,
                              "reopen", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try launcher.run()
    }

    static func install(_ staged: URL, over current: URL) throws {
        // The custom Finder icon the app gives itself is outside the signature; drop it so the
        // installed copy verifies as signed. The new version applies its own icon when it opens.
        try CustomBundleIcon.remove(at: current)
        try verify(current, identifier: appID)
        try verify(staged, identifier: appID)
        guard try build(staged) > build(current),
              renamex_np(staged.path, current.path, UInt32(RENAME_SWAP)) == 0 else { throw InstallerError.invalid }
    }
}

private extension Bundle {
    func supportsCurrentSystem() -> Bool {
        guard let minimum = object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String else { return false }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: major,
            minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0))
    }
}
#endif
