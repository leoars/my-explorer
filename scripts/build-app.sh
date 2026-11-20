#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
# Optional local signing identity; never downgrade a requested certificate to ad-hoc.
signing_identity="${MY_EXPLORER_SIGNING_IDENTITY--}"
if [[ -z "$signing_identity" || "$signing_identity" == *$'\n'* || "$signing_identity" == *$'\r'* ]]; then
  echo "MY_EXPLORER_SIGNING_IDENTITY must be a nonempty, single-line identity or '-'." >&2
  exit 2
fi
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
if [[ ! "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  echo "Info.plist contains an invalid bundle identifier." >&2
  exit 2
fi
if [[ "$configuration" != debug && "$configuration" != release ]] || [[ $# -gt 1 ]]; then
  echo "Usage: $0 [debug|release]" >&2
  exit 2
fi
# Unset means SwiftPM's native architecture. A universal build is explicit, e.g.
# MY_EXPLORER_ARCHITECTURES='arm64 x86_64' bash scripts/build-app.sh release
# Parse only whitelisted tokens into an argument array; never evaluate shell text.
build_arguments=(-c "$configuration")
requested_architectures=()
if [[ "${MY_EXPLORER_ARCHITECTURES+x}" == x ]]; then
  architecture_spec="$MY_EXPLORER_ARCHITECTURES"
  if [[ -z "$architecture_spec" || "$architecture_spec" == *$'\n'* || "$architecture_spec" == *$'\r'* ]]; then
    echo "MY_EXPLORER_ARCHITECTURES must contain arm64, x86_64, or both separated by spaces." >&2
    exit 2
  fi
  IFS=' ' read -r -a requested_architectures <<< "$architecture_spec"
  if [[ "${#requested_architectures[@]}" -lt 1 || "${#requested_architectures[@]}" -gt 2 ]]; then
    echo "MY_EXPLORER_ARCHITECTURES must contain one or two supported architectures." >&2
    exit 2
  fi
  for architecture in "${requested_architectures[@]}"; do
    case "$architecture" in
      arm64|x86_64) build_arguments+=(--arch "$architecture") ;;
      *) echo "Unsupported architecture; only arm64 and x86_64 are allowed." >&2; exit 2 ;;
    esac
  done
  if [[ "${#requested_architectures[@]}" -eq 2 && "${requested_architectures[0]}" == "${requested_architectures[1]}" ]]; then
    echo "MY_EXPLORER_ARCHITECTURES must not repeat an architecture." >&2
    exit 2
  fi
fi
mkdir -p "$PWD/dist"
lock_path="$PWD/dist/.artifact-build.lock"
if ! mkdir "$lock_path" 2>/dev/null; then
  echo "Another build/package operation owns dist/.artifact-build.lock. Check it before retrying." >&2
  exit 1
fi
stage_root=""
app_path="$PWD/dist/My Explorer.app"
committed=0
installing=0
cleanup() {
  result=$?
  trap - EXIT
  if [[ "$committed" == 0 && -n "$stage_root" ]]; then
    if [[ -e "$stage_root/previous.app" || -L "$stage_root/previous.app" ]]; then
      rm -rf "$app_path"
      if ! mv "$stage_root/previous.app" "$app_path"; then
        echo "Rollback failed; the previous app remains at $stage_root/previous.app" >&2
        rmdir "$lock_path" 2>/dev/null || true
        exit 1
      fi
    elif [[ "$installing" == 1 ]]; then
      rm -rf "$app_path"
    fi
  fi
  if [[ -n "$stage_root" ]]; then rm -rf "$stage_root"; fi
  rmdir "$lock_path" 2>/dev/null || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage_root="$(mktemp -d "$PWD/dist/.my-explorer-build.XXXXXX")"
staged_app="$stage_root/My Explorer.app"
# A source archive builds without Git history. Include provenance in a release checkout.
metadata_state="$stage_root/source-state.json"
if [[ "$(git rev-parse --show-toplevel 2>/dev/null || true)" == "$PWD" ]] && git rev-parse --verify HEAD >/dev/null 2>&1; then
  python3 scripts/beta-metadata.py capture-state --output "$metadata_state"
fi
swift build "${build_arguments[@]}"
binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_dir/MyExplorerApp" "$staged_app/Contents/MacOS/MyExplorer"
cp "$binary_dir/myexplorer" "$staged_app/Contents/MacOS/myexplorer-cli"
if [[ "${#requested_architectures[@]}" -gt 0 ]]; then
  for architecture in "${requested_architectures[@]}"; do
    /usr/bin/lipo "$staged_app/Contents/MacOS/MyExplorer" -verify_arch "$architecture"
    /usr/bin/lipo "$staged_app/Contents/MacOS/myexplorer-cli" -verify_arch "$architecture"
  done
fi
codesign --force --sign "$signing_identity" --identifier "$bundle_identifier.cli" --timestamp=none "$staged_app/Contents/MacOS/myexplorer-cli"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
cp LICENSE "$staged_app/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$staged_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Resources/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
python3 scripts/beta-metadata.py stage-localizations --binary-dir "$binary_dir" --target "$staged_app/Contents/Resources/MyExplorer_ExplorerLocalization.bundle"
if [[ -f "$metadata_state" ]]; then
  python3 scripts/beta-metadata.py write-build-info --state "$stage_root/source-state.json" --app "$staged_app" --configuration "$configuration"
fi
# Local signing does not notarize or publish the app. No entitlements or Keychain ACLs are changed.
codesign --force --sign "$signing_identity" --identifier "$bundle_identifier" --timestamp=none "$staged_app"
codesign --verify --strict --deep "$staged_app"
python3 scripts/beta-metadata.py verify-signing --app "$staged_app"
"$staged_app/Contents/MacOS/MyExplorer" --verify-localizations
if [[ -f "$metadata_state" ]]; then
  python3 scripts/beta-metadata.py verify-state --state "$stage_root/source-state.json"
fi
# Keep the previous bundle intact until the complete replacement passes verification.
if [[ -e "$app_path" || -L "$app_path" ]]; then mv "$app_path" "$stage_root/previous.app"; fi
installing=1
mv "$staged_app" "$app_path"
codesign --verify --strict --deep "$app_path"
python3 scripts/beta-metadata.py verify-signing --app "$app_path"
committed=1
echo "$app_path"
