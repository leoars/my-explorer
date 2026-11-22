#!/bin/bash
# Has Apple notarize a Developer ID build of the app and staples the ticket to it.
# Usage: scripts/notarize-app.sh [dist/My Explorer.app]
# Needs a notarytool profile (default my-suite-notary; override with MY_EXPLORER_NOTARY_PROFILE).
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-dist/My Explorer.app}"
profile="${MY_EXPLORER_NOTARY_PROFILE:-my-suite-notary}"
requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "GV4SHC87M4"'
# Only a Developer ID signature with hardened runtime can be notarized.
codesign --verify --deep --strict "-R=$requirement" "$app"
description=$(codesign --display --verbose=2 "$app" 2>&1)
[[ "$description" == *"(runtime)"* ]] || { echo "The app is not signed with the hardened runtime." >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -c -k --keepParent "$app" "$work/app.zip"
xcrun notarytool submit "$work/app.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose "$app"
