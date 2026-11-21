#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-all}"
if [[ "$mode" != all && "$mode" != git && "$mode" != shutdown && "$mode" != session && "$mode" != ocr && "$mode" != stability && "$mode" != buttons && "$mode" != eject && "$mode" != volumes && "$mode" != vault && "$mode" != dialogs && "$mode" != trash-undo && "$mode" != rename && "$mode" != deletion && "$mode" != search && "$mode" != address && "$mode" != clipboard && "$mode" != s3-drag ]]; then
  echo "Usage: $0 [all|search|address|git|shutdown|session|ocr|stability|buttons|eject|volumes|vault|clipboard|dialogs|deletion|rename|trash-undo|s3-drag]" >&2
  exit 2
fi
if [[ "$mode" == all ]]; then
  swift - <<'SWIFT'
import CoreGraphics
import Foundation
let session = CGSessionCopyCurrentDictionary() as? [String: Any]
if session?["CGSSessionScreenIsLocked"] as? Bool == true {
    fputs("Full GUI smoke requires an unlocked macOS session for keyboard/mouse focus.\n", stderr)
    exit(1)
}
SWIFT
fi
fixture_root="$(mktemp -d /tmp/my-explorer-smoke.XXXXXX)"
smoke_suite="MyExplorer.Smoke.Restart.$(uuidgen)"
trap 'rm -rf "$fixture_root"; defaults delete "$smoke_suite" >/dev/null 2>&1 || true' EXIT
mkdir -p "$fixture_root/Documents/Projects" "$fixture_root/Downloads" "$fixture_root/Pictures" "$fixture_root/Archive" "$fixture_root/LongList"
for ((index=1; index<=120; index++)); do
  printf 'Scroll fixture\n' > "$fixture_root/LongList/Item-$index.txt"
done
printf 'Sample project notes\n' > "$fixture_root/Documents/Notes.txt"
printf '# My Explorer\n' > "$fixture_root/README.md"
printf 'name,status\nPrototype,Ready\n' > "$fixture_root/Roadmap.csv"
printf 'Hidden fixture\n' > "$fixture_root/.hidden"
cp Resources/AppIcon.png "$fixture_root/Preview.png"
printf 'Plain text fixture\n' > "$fixture_root/Notes.txt"
ln -s Documents/Notes.txt "$fixture_root/Notes-link.txt"
swift - "$fixture_root/Example.pdf" <<'SWIFT'
import AppKit
var page = CGRect(x: 0, y: 0, width: 300, height: 400)
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let pdf = CGContext(destination as CFURL, mediaBox: &page, nil)!
pdf.beginPDFPage(nil)
pdf.setFillColor(CGColor(gray: 0.95, alpha: 1))
pdf.fill(page)
pdf.endPDFPage()
pdf.closePDF()
SWIFT
swift scripts/generate-media-fixtures.swift "$fixture_root/Media"
python3 scripts/generate-git-fixtures.py "$fixture_root/GitFixtures"
python3 - "$fixture_root/LargeListing" <<'PYFIXTURE'
from pathlib import Path
import sys
root = Path(sys.argv[1]); root.mkdir()
for index in range(10_000):
    (root / f"Item-{index:05d}.txt").touch()
PYFIXTURE
bash scripts/build-app.sh debug
ditto "$PWD/dist/My Explorer.app" "$fixture_root/Relocated/My Explorer.app"
"$fixture_root/Relocated/My Explorer.app/Contents/MacOS/MyExplorer" --verify-localizations
mkdir -p .build/previews
# Launch through LaunchServices, matching how the user opens the application.
run_smoke() {
  local out="$fixture_root/smoke.stdout" err="$fixture_root/smoke.stderr"
  : > "$out"
  : > "$err"
  open -n -W --stdout "$out" --stderr "$err" "$PWD/dist/My Explorer.app" --args "$@"
  python3 - "$out" "$err" <<'PYLOG'
import pathlib, sys
output = "\n".join(pathlib.Path(path).read_text() for path in sys.argv[1:])
print(output, end="")
# open -W waits for termination but does not propagate the app's exit status.
if "SMOKE FAIL:" in output or sum(line.startswith("SMOKE PASS:") for line in output.splitlines()) != 1:
    raise SystemExit("Smoke app did not finish successfully")
PYLOG
}
if [[ "$mode" == s3-drag || "$mode" == all ]]; then
  run_smoke --smoke-test --s3-drag-smoke --directory "$fixture_root"
  if [[ "$mode" == s3-drag ]]; then exit 0; fi
fi
if [[ "$mode" == search || "$mode" == all ]]; then
  run_smoke --smoke-test --file-search-smoke --directory "$fixture_root"
  if [[ "$mode" == search ]]; then exit 0; fi
fi
if [[ "$mode" == address || "$mode" == all ]]; then
  run_smoke --smoke-test --address-completion-smoke --directory "$fixture_root"
  if [[ "$mode" == address ]]; then exit 0; fi
fi
if [[ "$mode" == trash-undo || "$mode" == all ]]; then
  run_smoke --smoke-test --trash-undo-smoke --directory "$fixture_root"
  if [[ "$mode" == trash-undo ]]; then exit 0; fi
fi
if [[ "$mode" == rename || "$mode" == all ]]; then
  run_smoke --smoke-test --inline-rename-smoke --directory "$fixture_root" --light
  run_smoke --smoke-test --inline-rename-smoke --directory "$fixture_root" --dark
  if [[ "$mode" == rename ]]; then exit 0; fi
fi
if [[ "$mode" == deletion || "$mode" == all ]]; then
  run_smoke --smoke-test --deletion-smoke --directory "$fixture_root"
  if [[ "$mode" == deletion ]]; then exit 0; fi
fi
if [[ "$mode" == dialogs || "$mode" == all ]]; then
  run_smoke --smoke-test --dialogs-smoke --directory "$fixture_root" --light
  if [[ "$mode" == dialogs ]]; then exit 0; fi
fi
if [[ "$mode" == vault || "$mode" == all ]]; then
  run_smoke --smoke-test --vault-smoke --directory "$fixture_root" --light
  if [[ "$mode" == vault ]]; then exit 0; fi
fi
if [[ "$mode" == clipboard ]]; then
  run_smoke --smoke-test --clipboard-smoke --directory "$fixture_root"
  exit 0
fi
if [[ "$mode" == eject ]]; then
  token="$(uuidgen)"
  volume="/Volumes/MyExplorer-$token"
  hdiutil create -quiet -size 16m -fs HFS+ -volname "MyExplorer-$token" "$fixture_root/eject.dmg"
  hdiutil attach -nobrowse "$fixture_root/eject.dmg" >/dev/null
  trap 'if [[ -d "$volume" ]]; then hdiutil detach "$volume" >/dev/null; fi; rm -rf "$fixture_root"; defaults delete "$smoke_suite" >/dev/null 2>&1 || true' EXIT
  printf %s "$token" > "$fixture_root/eject-fixture"
  cp "$fixture_root/eject-fixture" "$volume/eject-fixture"
  run_smoke --smoke-test --eject-smoke --directory "$fixture_root"
  exit 0
fi
if [[ "$mode" == volumes ]]; then
  run_smoke --smoke-test --volumes-smoke --directory "$fixture_root" --light
  run_smoke --smoke-test --volumes-smoke --directory "$fixture_root" --dark
  exit 0
fi
if [[ "$mode" == buttons ]]; then
  run_smoke --smoke-test --buttons-smoke --directory "$fixture_root" --light --preview "$PWD/.build/previews/light.png"
  run_smoke --smoke-test --buttons-smoke --directory "$fixture_root" --dark --preview "$PWD/.build/previews/dark.png"
  exit 0
fi
if [[ "$mode" == stability ]]; then
  run_smoke --smoke-test --stability-smoke --directory "$fixture_root" --light
  run_smoke --smoke-test --stability-smoke --directory "$fixture_root" --dark
  exit 0
fi
if [[ "$mode" == ocr ]]; then
  run_smoke --smoke-test --ocr-smoke --directory "$fixture_root" --light --preview "$PWD/.build/previews/light.png"
  run_smoke --smoke-test --ocr-smoke --directory "$fixture_root" --dark --preview "$PWD/.build/previews/dark.png"
  exit 0
fi
if [[ "$mode" == git ]]; then
  run_smoke --smoke-test --git-smoke --directory "$fixture_root" --light --preview "$PWD/.build/previews/light.png"
  run_smoke --smoke-test --git-smoke --directory "$fixture_root" --dark --preview "$PWD/.build/previews/dark.png"
  exit 0
fi
if [[ "$mode" == session ]]; then
  run_smoke --smoke-test --save-tabs-smoke --smoke-suite "$smoke_suite" --directory "$fixture_root" --preview "$PWD/.build/previews/session-options.png"
  run_smoke --smoke-test --restore-tabs-smoke --smoke-suite "$smoke_suite" --session-fixture-root "$fixture_root"
  run_smoke --smoke-test --override-tabs-smoke --smoke-suite "$smoke_suite" --directory "$fixture_root/Documents"
  exit 0
fi
if [[ "$mode" == shutdown ]]; then
  run_smoke --smoke-test --quit-operation-smoke paused --directory "$fixture_root"
  run_smoke --smoke-test --quit-operation-smoke conflict --directory "$fixture_root"
  run_smoke --smoke-test --quit-operation-smoke cloud --directory "$fixture_root"
  exit 0
fi
run_smoke --smoke-test --directory "$fixture_root" --light --preview "$PWD/.build/previews/light.png"
run_smoke --smoke-test --directory "$fixture_root" --dark --preview "$PWD/.build/previews/dark.png"
run_smoke --smoke-test --close-last-tab-smoke --directory "$fixture_root"
run_smoke --smoke-test --close-main-window-smoke --smoke-suite "$smoke_suite" --directory "$fixture_root"
run_smoke --smoke-test --restore-startup-smoke --smoke-suite "$smoke_suite" --expected-directory "$fixture_root/Documents"

run_smoke --smoke-test --save-layout-smoke --smoke-suite "$smoke_suite" --directory "$fixture_root"
run_smoke --smoke-test --restore-layout-smoke --smoke-suite "$smoke_suite" --directory "$fixture_root"

run_smoke --smoke-test --save-tabs-smoke --smoke-suite "$smoke_suite" --directory "$fixture_root" --preview "$PWD/.build/previews/session-options.png"
run_smoke --smoke-test --restore-tabs-smoke --smoke-suite "$smoke_suite" --session-fixture-root "$fixture_root"
run_smoke --smoke-test --override-tabs-smoke --smoke-suite "$smoke_suite" --directory "$fixture_root/Documents"

run_smoke --smoke-test --quit-operation-smoke paused --directory "$fixture_root"
run_smoke --smoke-test --quit-operation-smoke conflict --directory "$fixture_root"
run_smoke --smoke-test --quit-operation-smoke cloud --directory "$fixture_root"
