# SPDX-License-Identifier: Apache-2.0
"""Disposable filesystem tests for native/universal localization staging."""
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts/beta-metadata.py"
SPEC = importlib.util.spec_from_file_location("beta_metadata_under_test", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LocalizationStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="MyExplorer.BetaMetadata.")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        original_root = MODULE.ROOT
        MODULE.ROOT = self.root
        self.addCleanup(setattr, MODULE, "ROOT", original_root)
        self.source = self.root / "Sources/ExplorerLocalization/Resources"
        for locale in ["en", "pt-BR"]:
            directory = self.source / (locale + ".lproj")
            directory.mkdir(parents=True)
            (directory / "Localizable.strings").write_text('"key" = "Source";')
        (self.source / ".DS_Store").write_bytes(b"ignored")
        self.binary_dir = self.root / "Products/Release"
        self.generated = self.binary_dir / "MyExplorer_ExplorerLocalization.bundle"
        self.target = self.root / "staged.bundle"

    def generated_bundle(self, contents):
        base = self.generated / "Contents" if contents else self.generated
        resources = base / "Resources" if contents else base
        resources.mkdir(parents=True)
        info = {"CFBundleIdentifier": "fixture.resources", "CFBundleDevelopmentRegion": "en"}
        if contents:
            info["CFBundleExecutable"] = "absent-resource-executable"
        (base / "Info.plist").write_bytes(plistlib.dumps(info))
        for locale in ["en", "pt-BR" if contents else "pt-br", "obsolete"]:
            directory = resources / (locale + ".lproj")
            directory.mkdir()
            (directory / "Localizable.strings").write_bytes(('"key" = "' + locale + '";').encode())
        (resources / ".DS_Store").write_bytes(b"ignored")
        return resources

    def verify_staged(self, generated_resources):
        MODULE.stage_localizations(self.binary_dir, self.target)
        self.assertEqual({path.name for path in self.target.iterdir()}, {"Info.plist", "en.lproj", "pt-br.lproj"})
        self.assertNotIn("CFBundleExecutable", plistlib.loads((self.target / "Info.plist").read_bytes()))
        self.assertEqual(plistlib.loads((self.target / "Info.plist").read_bytes())["CFBundleIdentifier"], "fixture.resources")
        for directory in generated_resources.iterdir():
            if directory.name.casefold() in ["en.lproj", "pt-br.lproj"]:
                self.assertEqual((directory / "Localizable.strings").read_bytes(),
                                 (self.target / directory.name.lower() / "Localizable.strings").read_bytes())

    def test_native_flat_lowercase_bundle(self):
        self.verify_staged(self.generated_bundle(contents=False))

    def test_universal_contents_case_preserving_bundle(self):
        self.verify_staged(self.generated_bundle(contents=True))

    def test_missing_declared_locale_is_an_error(self):
        resources = self.generated_bundle(contents=True)
        (resources / "pt-BR.lproj/Localizable.strings").unlink()
        (resources / "pt-BR.lproj").rmdir()
        with self.assertRaisesRegex(RuntimeError, "localization is missing"):
            MODULE.stage_localizations(self.binary_dir, self.target)


if __name__ == "__main__":
    unittest.main()
