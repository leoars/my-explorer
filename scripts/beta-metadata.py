#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Local build provenance and private beta packaging; never contacts a remote service."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA = 1
BUILD_KEYS = {"schemaVersion", "commit", "dirty", "sourceDigestSHA256", "version", "build", "releaseChannel",
              "bundleIdentifier", "minimumSystemVersion", "architectures", "configuration", "builtAtUTC", "signing", "notarized"}


def run(arguments, cwd=ROOT, env=None):
    result = subprocess.run(arguments, cwd=str(cwd), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, env=env)
    if result.returncode:
        raise RuntimeError("{} failed (exit {})".format(pathlib.Path(arguments[0]).name, result.returncode))
    return result.stdout


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_state():
    # Never let an inherited GIT_DIR/WORK_TREE/INDEX_FILE/CONFIG_* redirect provenance.
    # Keep normal HOME/PATH configuration, then add only explicit noninteractive safeguards.
    git_environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    git_environment.update({"GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
                            "GIT_NO_LAZY_FETCH": "1", "GIT_OPTIONAL_LOCKS": "0"})
    git = ["git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
           "-c", "protocol.allow=never", "-c", "credential.helper="]
    commit = run(git + ["rev-parse", "--verify", "HEAD"], env=git_environment).decode("ascii").strip()
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        raise RuntimeError("Unable to identify the source commit")
    status = run(git + ["status", "--porcelain=v1", "-z", "--untracked-files=all"], env=git_environment)
    paths = sorted(set(run(git + ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], env=git_environment).split(b"\0")) - {b""})
    if len(paths) > 100000:
        raise RuntimeError("Source inventory exceeds the build provenance limit")
    digest = hashlib.sha256()
    digest.update(status)
    for raw in paths:
        path = ROOT / os.fsdecode(raw)
        if pathlib.PurePosixPath(os.fsdecode(raw)).is_absolute() or b".." in raw.split(b"/"):
            raise RuntimeError("Unexpected path in source inventory")
        digest.update(len(raw).to_bytes(8, "big")); digest.update(raw)
        try:
            info = path.lstat()
        except FileNotFoundError:
            digest.update(b"missing\0")
            continue
        digest.update(str(stat.S_IFMT(info.st_mode)).encode("ascii"))
        digest.update(str(info.st_mode & 0o111).encode("ascii"))
        if stat.S_ISLNK(info.st_mode):
            digest.update(os.fsencode(os.readlink(path)))
        elif stat.S_ISREG(info.st_mode):
            digest.update(bytes.fromhex(sha256(path)))
        elif stat.S_ISDIR(info.st_mode):
            digest.update(b"directory\0")
        else:
            raise RuntimeError("Unsupported source file type")
    return {"commit": commit, "dirty": bool(status), "sourceDigestSHA256": digest.hexdigest()}


def read_json(path):
    with open(path, "r", encoding="utf-8") as stream:
        return json.load(stream)


def write_json(path, value):
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, ensure_ascii=False)
        stream.write("\n")


def confirm_state(expected):
    actual = source_state()
    if actual != expected:
        raise RuntimeError("Sources changed after the build began; rebuild before packaging")
    return actual


def app_info(app):
    with open(app / "Contents/Info.plist", "rb") as stream:
        value = plistlib.load(stream)
    return {
        "version": str(value["CFBundleShortVersionString"]),
        "build": str(value["CFBundleVersion"]),
        "releaseChannel": str(value.get("MyExplorerReleaseChannel", "development")),
        "bundleIdentifier": str(value["CFBundleIdentifier"]),
        "minimumSystemVersion": str(value["LSMinimumSystemVersion"]),
    }


def architectures(app):
    values = []
    for name in ["MyExplorer", "myexplorer-cli"]:
        path = app / "Contents/MacOS" / name
        found = sorted(run(["/usr/bin/lipo", "-archs", str(path)]).decode("ascii").split())
        if not found or any(not re.fullmatch(r"[A-Za-z0-9_]+", item) for item in found):
            raise RuntimeError("Unable to verify binary architectures")
        values.append(found)
    if values[0] != values[1]:
        raise RuntimeError("App and CLI architectures differ")
    return values[0]


def parse_signature_description(text):
    fields = {}
    authorities = []
    for line in text.splitlines():
        if line.startswith("Authority="):
            authorities.append(line[len("Authority="):])
        elif "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value
    if fields.get("Signature") == "adhoc":
        kind = "ad-hoc"
    elif not authorities:
        raise RuntimeError("Unable to identify the code signature")
    elif authorities[0].startswith(("Apple Development:", "Mac Developer:")):
        kind = "apple-development"
    elif authorities[0].startswith("Developer ID Application:"):
        kind = "developer-id"
    elif authorities[0].startswith("Apple Distribution:"):
        kind = "apple-distribution"
    elif authorities[0].startswith("3rd Party Mac Developer Application:"):
        kind = "app-store"
    else:
        kind = "certificate"
    return {"kind": kind, "identifier": fields.get("Identifier"),
            "authority": authorities[0] if authorities else None, "team": fields.get("TeamIdentifier")}


def signature_description(path):
    result = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(path)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RuntimeError("Unable to inspect the code signature")
    return parse_signature_description((result.stdout + result.stderr).decode("utf-8", errors="replace"))


def verify_designated_requirement(path):
    result = subprocess.run(["/usr/bin/codesign", "--display", "--requirements", "-", str(path)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RuntimeError("Unable to inspect the designated requirement")
    lines = (result.stdout + result.stderr).decode("utf-8", errors="replace").splitlines()
    # Ad-hoc signatures expose a synthesized cdhash requirement prefixed with '# '.
    normalized = [line[2:] if line.startswith("# designated => ") else line for line in lines]
    requirements = [line[len("designated => "):] for line in normalized if line.startswith("designated => ")]
    if len(requirements) != 1 or not requirements[0]:
        raise RuntimeError("Missing or ambiguous designated requirement")
    # Check the actual embedded requirement without persisting certificate names, team IDs or paths.
    run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + requirements[0], str(path)])


def verify_signing(app):
    metadata_path = app / "Contents/Resources/BuildInfo.json"
    metadata = read_json(metadata_path) if metadata_path.is_file() else None
    identifier = app_info(app)["bundleIdentifier"]
    helper = app / "Contents/MacOS/myexplorer-cli"
    run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)])
    run(["/usr/bin/codesign", "--verify", "--strict", str(helper)])
    main = signature_description(app)
    child = signature_description(helper)
    if main["identifier"] != identifier or child["identifier"] != identifier + ".cli":
        raise RuntimeError("Code signature identifiers do not match the bundle")
    if any(main[key] != child[key] for key in ["kind", "authority", "team"]):
        raise RuntimeError("App and helper were signed with different identities")
    if metadata is not None and metadata.get("signing") != main["kind"]:
        raise RuntimeError("BuildInfo signing does not match the actual signature")
    verify_designated_requirement(app)
    verify_designated_requirement(helper)


def stage_localizations(binary_dir, target):
    source = ROOT / "Sources/ExplorerLocalization/Resources"
    generated = binary_dir / "MyExplorer_ExplorerLocalization.bundle"
    # Native SwiftPM emits a flat resource bundle; its multi-architecture/XCBuild
    # backend emits a macOS Contents bundle. Normalize both to the app's existing
    # flat resource layout and lowercase locale-directory convention.
    if (generated / "Contents/Info.plist").is_file():
        info_path = generated / "Contents/Info.plist"
        generated_resources = generated / "Contents/Resources"
    else:
        info_path = generated / "Info.plist"
        generated_resources = generated
    with open(info_path, "rb") as stream:
        resource_info = plistlib.load(stream)
    # XCBuild inserts an executable name even though this target contains only
    # resources. Do not advertise an absent executable in the normalized bundle.
    resource_info.pop("CFBundleExecutable", None)
    locales = {}
    for directory in generated_resources.iterdir():
        if directory.is_dir() and directory.name.lower().endswith(".lproj"):
            key = directory.name.casefold()
            if key in locales:
                raise RuntimeError("Ambiguous generated localization directory")
            locales[key] = directory
    target.mkdir(parents=True)
    with open(target / "Info.plist", "wb") as stream:
        plistlib.dump(resource_info, stream)
    # Copy only resources still declared by the source tree; do not inherit obsolete
    # files/locales left in either the previous app or SwiftPM's incremental resource cache.
    for resource in sorted(source.rglob("*")):
        if resource.name == ".DS_Store" or not resource.is_file():
            continue
        parts = list(resource.relative_to(source).parts)
        if parts[0].endswith(".lproj"):
            generated_locale = locales.get(parts[0].casefold())
            if generated_locale is None:
                raise RuntimeError("A declared localization is missing from the generated bundle")
            generated_resource = generated_locale.joinpath(*parts[1:])
            parts[0] = parts[0].lower()
        else:
            generated_resource = generated_resources.joinpath(*parts)
        relative = pathlib.Path(*parts)
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(generated_resource, destination)


def build_info(app, configuration, state_path):
    state = confirm_state(read_json(state_path))
    metadata = dict(state, **app_info(app), schemaVersion=SCHEMA,
                    architectures=architectures(app), configuration=configuration,
                    builtAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                    signing=signature_description(app / "Contents/MacOS/myexplorer-cli")["kind"],
                    # BuildInfo is sealed by the signature before Apple sees the app, so this records
                    # that the build is made for notarization; packaging checks the stapled ticket.
                    notarized=signature_description(app / "Contents/MacOS/myexplorer-cli")["kind"] == "developer-id")
    resources = app / "Contents/Resources"
    write_json(resources / "BuildInfo.json", metadata)
    with open(resources / "BuildInfo.plist", "wb") as stream:
        plistlib.dump(metadata, stream, sort_keys=True)


def verified_metadata(app, allow_dirty, allow_public=False):
    resources = app / "Contents/Resources"
    metadata = read_json(resources / "BuildInfo.json")
    if not isinstance(metadata, dict) or set(metadata) != BUILD_KEYS:
        raise RuntimeError("BuildInfo contains missing or unexpected metadata fields")
    with open(resources / "BuildInfo.plist", "rb") as stream:
        if plistlib.load(stream) != metadata:
            raise RuntimeError("BuildInfo plist and JSON disagree")
    if metadata.get("schemaVersion") != SCHEMA or metadata.get("configuration") != "release":
        raise RuntimeError("Private beta packages require a release build with supported BuildInfo")
    if not isinstance(metadata.get("dirty"), bool):
        raise RuntimeError("BuildInfo is missing a valid dirty flag")
    for key, value in app_info(app).items():
        if metadata.get(key) != value:
            raise RuntimeError("Info.plist does not match BuildInfo: " + key)
    if metadata.get("architectures") != architectures(app):
        raise RuntimeError("Binary architectures do not match BuildInfo")
    state = confirm_state({key: metadata.get(key) for key in ["commit", "dirty", "sourceDigestSHA256"]})
    if state["dirty"] and not allow_dirty:
        raise RuntimeError("Dirty sources/build refused. --allow-dirty is for a local rehearsal only")
    if not (metadata["releaseChannel"].startswith("private-beta") or (allow_public and metadata["releaseChannel"] == "public")):
        raise RuntimeError("The bundle is not marked as a private-beta channel")
    verify_signing(app)
    if metadata["notarized"]:
        # A build made for notarization must carry its ticket before it is packaged.
        run(["/usr/bin/xcrun", "stapler", "validate", str(app)])
    return metadata


def file_manifest(directory):
    result = []
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink():
            target = os.readlink(path)
            try:
                path.resolve().relative_to(directory.resolve())
            except ValueError:
                raise RuntimeError("Package contains an external symlink")
            result.append({"path": relative, "type": "symlink", "sha256": hashlib.sha256(os.fsencode(target)).hexdigest()})
        elif path.is_file():
            result.append({"path": relative, "type": "file", "bytes": path.stat().st_size, "sha256": sha256(path)})
    return result


def package(app, output, allow_dirty):
    metadata = verified_metadata(app, allow_dirty)
    tokens = [metadata["version"], metadata["build"], metadata["releaseChannel"]] + metadata["architectures"]
    if any(not re.fullmatch(r"[A-Za-z0-9._-]+", item) for item in tokens):
        raise RuntimeError("Version/build/channel/architecture cannot be used in an artifact filename")
    stem = "My-Explorer-{}-build{}-{}-{}-{}".format(metadata["version"], metadata["build"],
        metadata["releaseChannel"], "-".join(metadata["architectures"]), metadata["commit"][:12])
    rehearsal = bool(allow_dirty)
    if rehearsal:
        stem += "-rehearsal-" + metadata["sourceDigestSHA256"][:8]
    output.mkdir(parents=True, exist_ok=True)
    destination = output / stem
    if destination.exists():
        raise RuntimeError("Artifact already exists; use another --output directory to preserve it")
    staging = pathlib.Path(tempfile.mkdtemp(prefix=".private-beta-", dir=str(output)))
    try:
        payload = staging / stem
        payload.mkdir()
        run(["/usr/bin/ditto", str(app), str(payload / "My Explorer.app")])
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.md"]:
            shutil.copyfile(ROOT / name, payload / name)
        included_beta_notes = (ROOT / "docs/BETA.md").is_file()
        if included_beta_notes:
            (payload / "docs").mkdir()
            shutil.copyfile(ROOT / "docs/BETA.md", payload / "docs/BETA.md")
            shutil.copyfile(ROOT / "docs/S3-VALIDATION.md", payload / "docs/S3-VALIDATION.md")
            shutil.copyfile(ROOT / "docs/OCR.md", payload / "docs/OCR.md")
            (payload / "docs/aws").mkdir()
            shutil.copyfile(ROOT / "docs/aws/s3-validation-policy.json", payload / "docs/aws/s3-validation-policy.json")
            (payload / "docs/screenshots").mkdir()
            shutil.copyfile(ROOT / "docs/screenshots/session-options.png", payload / "docs/screenshots/session-options.png")
        for finder_metadata in payload.rglob(".DS_Store"):
            if finder_metadata.is_file() or finder_metadata.is_symlink():
                finder_metadata.unlink()
        # Copy/signature checks plus a final source check reject stale or concurrently edited input.
        run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(payload / "My Explorer.app")])
        files = file_manifest(payload)
        archive = staging / (stem + ".zip")
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(payload), str(archive)])
        with zipfile.ZipFile(archive) as zipped:
            if zipped.testzip() is not None:
                raise RuntimeError("ZIP verification failed")
            names = set(zipped.namelist())
            for entry in files:
                if stem + "/" + entry["path"] not in names:
                    raise RuntimeError("ZIP is missing a manifest entry")
        confirm_state({key: metadata[key] for key in ["commit", "dirty", "sourceDigestSHA256"]})
        manifest = {"schemaVersion": SCHEMA, "kind": "private-beta-rehearsal" if rehearsal else "private-beta-candidate",
                    "allowDirtyOverride": rehearsal, "published": False, "build": metadata,
                    "archive": {"file": archive.name, "bytes": archive.stat().st_size, "sha256": sha256(archive)},
                    "includesBetaNotes": included_beta_notes, "files": files}
        manifest_path = staging / (stem + ".manifest.json")
        write_json(manifest_path, manifest)
        (staging / "SHA256SUMS").write_text("{}  {}\n{}  {}\n".format(sha256(archive), archive.name,
            sha256(manifest_path), manifest_path.name), encoding="utf-8")
        shutil.rmtree(payload)
        staging.rename(destination)
        print(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("capture-state")
    capture.add_argument("--output", type=pathlib.Path, required=True)
    verify = commands.add_parser("verify-state")
    verify.add_argument("--state", type=pathlib.Path, required=True)
    localization = commands.add_parser("stage-localizations")
    localization.add_argument("--binary-dir", type=pathlib.Path, required=True)
    localization.add_argument("--target", type=pathlib.Path, required=True)
    signing = commands.add_parser("verify-signing")
    signing.add_argument("--app", type=pathlib.Path, required=True)
    info = commands.add_parser("write-build-info")
    info.add_argument("--state", type=pathlib.Path, required=True)
    info.add_argument("--app", type=pathlib.Path, required=True)
    info.add_argument("--configuration", choices=["debug", "release"], required=True)
    packaging = commands.add_parser("package")
    packaging.add_argument("--app", type=pathlib.Path, default=ROOT / "dist/My Explorer.app")
    packaging.add_argument("--output", type=pathlib.Path, default=ROOT / "dist/beta")
    packaging.add_argument("--allow-dirty", action="store_true", help="Local rehearsal only; never produce a clean beta candidate")
    args = parser.parse_args()
    try:
        if args.command == "capture-state":
            write_json(args.output, source_state())
        elif args.command == "verify-state":
            confirm_state(read_json(args.state))
        elif args.command == "stage-localizations":
            stage_localizations(args.binary_dir, args.target)
        elif args.command == "verify-signing":
            verify_signing(args.app)
        elif args.command == "write-build-info":
            build_info(args.app, args.configuration, args.state)
        elif args.command == "package":
            package(args.app.resolve(), args.output.resolve(), args.allow_dirty)
    except (OSError, RuntimeError, ValueError, KeyError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        print("Error: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
