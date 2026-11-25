#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Writes My Explorer.xcodeproj, the Mac App Store build (docs/APP-STORE.md).

The project has one application target. It compiles Sources/MyExplorer itself, with the
APP_STORE condition, and links the library products of the local Swift package (this
folder), so the package targets are built exactly as `swift build` builds them. Run it
again after adding or removing a file in Sources/MyExplorer:

    python3 scripts/generate-store-project.py

The direct distribution does not use this project: scripts/build-app.sh stays the way
it is built and notarized.
"""
import hashlib
import os
import plistlib
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "My Explorer.xcodeproj")
PRODUCTS = ["ExplorerCore", "ExplorerClipboard", "ExplorerLocalization", "ExplorerAutomation"]
LANGUAGES = ["en", "pt-BR", "es", "fr", "de", "ja", "ko", "it"]

# Resources that SwiftPM does not produce: the localized Info.plist strings, the icon (drawn by
# scripts/generate-app-icon.swift, 1024 px at 512 pt @2x), the notices and the privacy manifest.
# The localization bundle of ExplorerLocalization is embedded by Xcode from the package.
RESOURCES_SCRIPT = """set -eu
res="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$res"
cd "$SRCROOT"
for strings in Resources/*.lproj/InfoPlist.strings; do
  locale_dir="$(basename "$(dirname "$strings")")"
  mkdir -p "$res/$locale_dir"
  cp "$strings" "$res/$locale_dir/"
done
cp Resources/AppIcon.icns LICENSE THIRD_PARTY_NOTICES.md Store/PrivacyInfo.xcprivacy "$res/"
# Xcode names the package's resource bundle after the folder that holds the package
# ("<package folder>.ExplorerLocalization.resources"); the product carries the app's own name.
# The bundle is found by its file name (Bundle.module), never by this identifier.
# Written only when it differs: the signature that follows covers it, and a build that copies
# nothing new must not change the signed bundle.
bundle_plist="$res/MyExplorer_ExplorerLocalization.bundle/Contents/Info.plist"
bundle_id="$PRODUCT_BUNDLE_IDENTIFIER.ExplorerLocalization.resources"
if [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$bundle_plist")" != "$bundle_id" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$bundle_plist"
fi
"""


def gid(name):
    return hashlib.sha1(("myexplorer-store:" + name).encode()).hexdigest()[:24].upper()


def main():
    folder = os.path.join(ROOT, "Sources", "MyExplorer")
    sources = sorted(f for f in os.listdir(folder) if f.endswith(".swift"))
    if not sources:
        sys.exit("Sources/MyExplorer has no Swift files")
    objects = {}
    refs, builds = [], []
    for name in sources:
        ref, build = gid("ref:" + name), gid("build:" + name)
        objects[ref] = {"isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift",
                        "path": "Sources/MyExplorer/" + name, "sourceTree": "SOURCE_ROOT"}
        objects[build] = {"isa": "PBXBuildFile", "fileRef": ref}
        refs.append(ref)
        builds.append(build)

    package = gid("package")
    objects[package] = {"isa": "XCLocalSwiftPackageReference", "relativePath": "."}
    product_ids, framework_builds = [], []
    for product in PRODUCTS:
        dependency, build = gid("product:" + product), gid("link:" + product)
        objects[dependency] = {"isa": "XCSwiftPackageProductDependency", "package": package, "productName": product}
        objects[build] = {"isa": "PBXBuildFile", "productRef": dependency}
        product_ids.append(dependency)
        framework_builds.append(build)

    extra = {}
    for name in ["Store/Info.plist", "Store/MyExplorer.entitlements", "Store/PrivacyInfo.xcprivacy",
                 "Store/ExportOptions.plist"]:
        ref = gid("store:" + name)
        kind = "text.plist.xml" if not name.endswith(".entitlements") else "text.plist.entitlements"
        objects[ref] = {"isa": "PBXFileReference", "lastKnownFileType": kind, "path": name, "sourceTree": "SOURCE_ROOT"}
        extra[name] = ref

    sources_phase, frameworks_phase, script = gid("sources"), gid("frameworks"), gid("script")
    objects[sources_phase] = {"isa": "PBXSourcesBuildPhase", "buildActionMask": 2147483647, "files": builds,
                              "runOnlyForDeploymentPostprocessing": 0}
    objects[frameworks_phase] = {"isa": "PBXFrameworksBuildPhase", "buildActionMask": 2147483647,
                                 "files": framework_builds, "runOnlyForDeploymentPostprocessing": 0}
    objects[script] = {"isa": "PBXShellScriptBuildPhase", "buildActionMask": 2147483647, "files": [],
                       "name": "Copy Info.plist strings, icon, notices and privacy manifest; name the resource bundle",
                       # The resource bundle as an input: the script waits for Xcode to embed it.
                       "inputPaths": ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/MyExplorer_ExplorerLocalization.bundle"],
                       "outputPaths": [], "alwaysOutOfDate": 1,
                       "runOnlyForDeploymentPostprocessing": 0, "shellPath": "/bin/bash", "shellScript": RESOURCES_SCRIPT}

    product, products_group = gid("product"), gid("products")
    sources_group, store_group, main_group = gid("group:sources"), gid("group:store"), gid("main")
    objects[product] = {"isa": "PBXFileReference", "explicitFileType": "wrapper.application",
                        "path": "My Explorer.app", "sourceTree": "BUILT_PRODUCTS_DIR"}
    objects[products_group] = {"isa": "PBXGroup", "children": [product], "name": "Products", "sourceTree": "<group>"}
    objects[sources_group] = {"isa": "PBXGroup", "children": refs, "name": "MyExplorer", "sourceTree": "<group>"}
    objects[store_group] = {"isa": "PBXGroup", "children": list(extra.values()), "name": "Store", "sourceTree": "<group>"}
    objects[main_group] = {"isa": "PBXGroup", "children": [sources_group, store_group, products_group], "sourceTree": "<group>"}

    def target_settings(configuration):
        settings = {
            "PRODUCT_NAME": "My Explorer", "EXECUTABLE_NAME": "MyExplorer", "PRODUCT_MODULE_NAME": "MyExplorer",
            "PRODUCT_BUNDLE_IDENTIFIER": "io.github.leoars.myexplorer",
            "INFOPLIST_FILE": "Store/Info.plist", "CODE_SIGN_ENTITLEMENTS": "Store/MyExplorer.entitlements",
            "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "GV4SHC87M4",
            "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "COMBINE_HIDPI_IMAGES": "YES", "SKIP_INSTALL": "NO", "INSTALL_PATH": "/Applications",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "APP_STORE" if configuration == "Release" else "DEBUG APP_STORE",
        }
        return settings

    def project_settings(configuration):
        settings = {
            "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0",
            "ARCHS": "$(ARCHS_STANDARD)", "ONLY_ACTIVE_ARCH": "YES" if configuration == "Debug" else "NO",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if configuration == "Debug" else "dwarf-with-dsym",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O",
            "SWIFT_COMPILATION_MODE": "singlefile" if configuration == "Debug" else "wholemodule",
            "GCC_OPTIMIZATION_LEVEL": "0" if configuration == "Debug" else "s",
            "ENABLE_TESTABILITY": "YES" if configuration == "Debug" else "NO",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES", "COPY_PHASE_STRIP": "NO", "ALWAYS_SEARCH_USER_PATHS": "NO",
        }
        if configuration == "Release":
            settings["ENABLE_NS_ASSERTIONS"] = "NO"
            settings["VALIDATE_PRODUCT"] = "YES"
        return settings

    target_list, project_list = gid("targetlist"), gid("projectlist")
    for name in ("Debug", "Release"):
        objects[gid("t" + name)] = {"isa": "XCBuildConfiguration", "name": name, "buildSettings": target_settings(name)}
        objects[gid("p" + name)] = {"isa": "XCBuildConfiguration", "name": name, "buildSettings": project_settings(name)}
    for key, prefix in ((target_list, "t"), (project_list, "p")):
        objects[key] = {"isa": "XCConfigurationList", "buildConfigurations": [gid(prefix + "Debug"), gid(prefix + "Release")],
                        "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Release"}

    target, project = gid("target"), gid("project")
    objects[target] = {"isa": "PBXNativeTarget", "name": "My Explorer", "productName": "My Explorer",
                       "productReference": product, "productType": "com.apple.product-type.application",
                       "buildPhases": [sources_phase, frameworks_phase, script], "buildRules": [], "dependencies": [],
                       "packageProductDependencies": product_ids, "buildConfigurationList": target_list}
    objects[project] = {"isa": "PBXProject", "attributes": {"LastSwiftUpdateCheck": "1600", "BuildIndependentTargetsInParallel": 1},
                        "buildConfigurationList": project_list, "compatibilityVersion": "Xcode 15.0",
                        "developmentRegion": "en", "hasScannedForEncodings": 0, "knownRegions": LANGUAGES + ["Base"],
                        "mainGroup": main_group, "productRefGroup": products_group, "packageReferences": [package],
                        "projectDirPath": "", "projectRoot": "", "targets": [target]}
    document = {"archiveVersion": "1", "classes": {}, "objectVersion": "60", "objects": objects, "rootObject": project}
    os.makedirs(PROJECT, exist_ok=True)
    with open(os.path.join(PROJECT, "project.pbxproj"), "wb") as stream:
        plistlib.dump(document, stream, sort_keys=False)
    print(PROJECT)


if __name__ == "__main__":
    main()
