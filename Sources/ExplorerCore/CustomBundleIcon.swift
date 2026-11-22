// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The Finder "custom icon" of a bundle: an `Icon\r` file in the bundle root plus Finder
/// information on the bundle directory. macOS shows it as drawn, without the grey plate it puts
/// behind free-form application icons, but it sits outside the code signature and makes a strict
/// signature check fail, so it must be removed before the bundle is verified.
public enum CustomBundleIcon {
    static let fileName = "Icon\r"
    static let finderInfo = "com.apple.FinderInfo"

    public static func isPresent(at bundle: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundle.appendingPathComponent(fileName).path)
    }

    /// Removes the custom icon, leaving the bundle as it was signed. Missing pieces are not errors.
    public static func remove(at bundle: URL) throws {
        let icon = bundle.appendingPathComponent(fileName)
        if unlink(icon.path) != 0, errno != ENOENT {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: icon.path])
        }
        if removexattr(bundle.path, finderInfo, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: bundle.path])
        }
    }
}
