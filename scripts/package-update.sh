#!/bin/bash
# Prepare the signed GitHub Release asset locally.
set -euo pipefail
cd "$(dirname "$0")/.."
rehearsal=false
if [[ "${1:-}" == "--allow-dirty" ]]; then rehearsal=true; shift; fi
app="${1:-dist/My Explorer.app}"
output="${2:-dist/updates}"
if [[ "$rehearsal" == true ]]; then output="$output/rehearsal"; fi
python3 - "$app" "$rehearsal" <<'PYMETA'
import pathlib, runpy, sys
metadata = runpy.run_path("scripts/beta-metadata.py")
metadata["verified_metadata"](pathlib.Path(sys.argv[1]), sys.argv[2] == "true")
PYMETA
identity="${MY_EXPLORER_SIGNING_IDENTITY:?Set the Apple signing identity used for the release}"
requirement='anchor apple generic and certificate leaf[subject.OU] = "GV4SHC87M4"'
codesign --verify --deep --strict "-R=$requirement and identifier \"io.github.leoars.myexplorer\"" "$app"
for arch in arm64 x86_64; do lipo "$app/Contents/MacOS/MyExplorer" -verify_arch "$arch"; done
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[[ "$build" =~ ^[1-9][0-9]*$ ]]
mkdir -p "$output"
work=$(mktemp -d "$output/.update.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/payload"
ditto "$app" "$work/payload/My Explorer.app"
name="MyExplorer-macOS-universal-$build.dmg"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "My Explorer Update" -srcfolder "$work/payload" "$work/$name"
codesign --force --sign "$identity" --identifier io.github.leoars.myexplorer.update "$work/$name"
codesign --verify --strict "-R=$requirement and identifier \"io.github.leoars.myexplorer.update\"" "$work/$name"
# Publish the complete file locally, refusing to overwrite an existing build.
ln "$work/$name" "$output/$name"
echo "$output/$name"
