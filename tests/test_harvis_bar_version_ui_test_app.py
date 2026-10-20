#!/usr/bin/env python3
"""Contract tests for the compile-isolated Harvis version UI-test app."""

from __future__ import annotations

import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BUILDER = PROJECT_ROOT / "tests/helpers/harvis_bar_version_ui_test_app.sh"
PLIST = PROJECT_ROOT / "tests/fixtures/harvis-version-ui-test/Info.plist"
PROVIDER = (
    PROJECT_ROOT
    / "apps/HarvisBar/Sources/HarvisBar/Runtime/HarvisVersionFixtureProvider.swift"
)
TESTS = (
    PROJECT_ROOT
    / "apps/HarvisBar/Tests/HarvisBarTests/HarvisVersionFixtureProviderTests.swift"
)
MARKER = ".harvis-version-ui-owner"
APP_NAME = "HarvisBarVersionUITest.app"
TOKEN = "0123456789abcdef0123456789abcdef"  # gitleaks:allow -- deterministic test ownership marker


class HarvisVersionUITestAppContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="harvis-version-builder-test-")
        self.tmpdir = Path(self.temporary.name).resolve()
        self.environment = dict(os.environ)
        self.environment["TMPDIR"] = str(self.tmpdir)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_scratch(self, *, token: str = TOKEN) -> tuple[Path, os.stat_result]:
        result = subprocess.run(
            [
                "/usr/bin/mktemp",
                "-d",
                str(self.tmpdir / "harvis-version-ui.XXXXXXXX"),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        scratch = Path(result.stdout.strip())
        scratch.chmod(0o700)
        marker = scratch / MARKER
        descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(descriptor, (token + "\n").encode("ascii"))
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        marker.chmod(0o600)
        return scratch, os.lstat(scratch)

    def invoke(
        self,
        command: str,
        scratch: Path,
        identity: os.stat_result,
        *,
        token: str = TOKEN,
        device: int | None = None,
        inode: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(BUILDER),
                command,
                "--scratch-root",
                str(scratch),
                "--owner-token",
                token,
                "--root-device",
                str(identity.st_dev if device is None else device),
                "--root-inode",
                str(identity.st_ino if inode is None else inode),
            ],
            cwd=PROJECT_ROOT,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def assert_rejected(
        self,
        scratch: Path,
        identity: os.stat_result,
        **overrides: object,
    ) -> None:
        result = self.invoke("validate", scratch, identity, **overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_validate_accepts_only_fresh_identity_bound_scratch(self) -> None:
        scratch, identity = self.make_scratch()
        result = self.invoke("validate", scratch, identity)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, f"validated: {scratch}\n")
        self.assertEqual(stat.S_IMODE(os.lstat(scratch).st_mode), 0o700)
        self.assertEqual((scratch / MARKER).read_text(encoding="ascii"), TOKEN + "\n")

    def test_validate_rejects_token_identity_mode_and_roster_drift(self) -> None:
        for mutation in ("token", "device", "inode", "root-mode", "marker-mode", "marker-value", "target", "extra"):
            with self.subTest(mutation=mutation):
                scratch, identity = self.make_scratch()
                overrides: dict[str, object] = {}
                if mutation == "token":
                    overrides["token"] = "f" * 32
                elif mutation == "device":
                    overrides["device"] = identity.st_dev + 1
                elif mutation == "inode":
                    overrides["inode"] = identity.st_ino + 1
                elif mutation == "root-mode":
                    scratch.chmod(0o755)
                elif mutation == "marker-mode":
                    (scratch / MARKER).chmod(0o644)
                elif mutation == "marker-value":
                    (scratch / MARKER).write_text("f" * 32 + "\n", encoding="ascii")
                    (scratch / MARKER).chmod(0o600)
                elif mutation == "target":
                    (scratch / APP_NAME).mkdir()
                elif mutation == "extra":
                    (scratch / "caller-owned.txt").write_text("canary\n", encoding="ascii")
                self.assert_rejected(scratch, identity, **overrides)

    def test_validate_rejects_missing_symlink_and_hardlinked_marker(self) -> None:
        for mutation in ("missing", "symlink", "hardlink"):
            with self.subTest(mutation=mutation):
                scratch, identity = self.make_scratch()
                marker = scratch / MARKER
                marker.unlink()
                if mutation == "symlink":
                    victim = self.tmpdir / f"marker-victim-{identity.st_ino}"
                    victim.write_text(TOKEN + "\n", encoding="ascii")
                    marker.symlink_to(victim)
                elif mutation == "hardlink":
                    victim = self.tmpdir / f"marker-victim-{identity.st_ino}"
                    victim.write_text(TOKEN + "\n", encoding="ascii")
                    victim.chmod(0o600)
                    os.link(victim, marker)
                self.assert_rejected(scratch, identity)

    def test_validate_rejects_nested_alias_symlink_and_broad_paths(self) -> None:
        scratch, identity = self.make_scratch()
        alias = scratch.parent / "alias-parent" / ".." / scratch.name
        self.assert_rejected(alias, identity)

        nested_parent = self.tmpdir / "nested"
        nested_parent.mkdir(mode=0o700)
        nested = nested_parent / "harvis-version-ui.ABCDEFGH"
        nested.mkdir(mode=0o700)
        (nested / MARKER).write_text(TOKEN + "\n", encoding="ascii")
        (nested / MARKER).chmod(0o600)
        self.assert_rejected(nested, os.lstat(nested))

        actual, actual_identity = self.make_scratch()
        linked = self.tmpdir / "harvis-version-ui.SYMLINK0"
        linked.symlink_to(actual, target_is_directory=True)
        self.assert_rejected(linked, actual_identity)

        for broad in (Path("/"), Path.home(), PROJECT_ROOT, self.tmpdir):
            with self.subTest(broad=str(broad)):
                broad_identity = os.lstat(broad)
                self.assert_rejected(broad, broad_identity)

    def test_cleanup_revalidates_marker_and_removes_only_closed_roster(self) -> None:
        scratch, identity = self.make_scratch()
        sibling = self.tmpdir / "caller-canary"
        sibling.write_text("preserve\n", encoding="ascii")
        build = scratch / ".swift-build"
        build.mkdir(mode=0o700)
        (build / "artifact").write_text("synthetic\n", encoding="ascii")
        nested = build / "nested"
        nested.mkdir()
        (nested / "link").symlink_to(sibling)
        app = scratch / APP_NAME / "Contents/MacOS"
        app.mkdir(parents=True)
        (app / "HarvisBar").write_bytes(b"synthetic")

        result = self.invoke("cleanup", scratch, identity)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(scratch.exists())
        self.assertEqual(sibling.read_text(encoding="ascii"), "preserve\n")

    def test_cleanup_refuses_mismatch_and_preserves_evidence(self) -> None:
        for mutation in ("token", "identity", "unexpected-entry"):
            with self.subTest(mutation=mutation):
                scratch, identity = self.make_scratch()
                kwargs: dict[str, object] = {}
                if mutation == "token":
                    kwargs["token"] = "e" * 32
                elif mutation == "identity":
                    kwargs["inode"] = identity.st_ino + 1
                else:
                    (scratch / "caller-owned.txt").write_text("evidence\n", encoding="ascii")
                result = self.invoke("cleanup", scratch, identity, **kwargs)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(scratch.is_dir())
                self.assertTrue((scratch / MARKER).is_file())

    def test_fixed_bundle_identity_is_test_only_and_minimal(self) -> None:
        with PLIST.open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["CFBundleIdentifier"], "local.harzva.harvisbar.version-ui-test")
        self.assertEqual(info["CFBundleExecutable"], "HarvisBar")
        self.assertEqual(info["CFBundleName"], "HarvisBarVersionUITest")
        self.assertEqual(info["CFBundleShortVersionString"], "0.36.0")
        self.assertEqual(info["LSMinimumSystemVersion"], "13.0")
        self.assertTrue(info["LSUIElement"])
        self.assertNotIn("HarvisPlugin", PLIST.read_text(encoding="utf-8"))

        for allowlist in (
            PROJECT_ROOT / "packaging/app-runtime-allowlist-v1.txt",
            PROJECT_ROOT / "packaging/plugin-stage-allowlist-v1.txt",
        ):
            content = allowlist.read_text(encoding="utf-8")
            self.assertNotIn("tests/fixtures/harvis-version-ui-test", content)
            self.assertNotIn("tests/helpers/harvis_bar_version_ui_test_app.sh", content)

    def test_builder_uses_fixed_compile_flag_target_and_no_broad_delete(self) -> None:
        content = BUILDER.read_text(encoding="utf-8")
        self.assertIn("-Xswiftc HARVIS_VERSION_UI_TESTING", content.replace("\\\n", " "))
        self.assertIn('readonly APP_NAME="HarvisBarVersionUITest.app"', content)
        self.assertIn('readonly BUNDLE_ID="local.harzva.harvisbar.version-ui-test"', content)
        self.assertIn('getattr(os, "O_NOFOLLOW", 0)', content)
        self.assertIn("st_dev", content)
        self.assertIn("st_ino", content)
        self.assertNotIn("rm -rf", content)
        self.assertNotRegex(content, r"\beval\b")

    def test_fixture_provider_and_tests_are_compile_isolated(self) -> None:
        provider = PROVIDER.read_text(encoding="utf-8")
        tests = TESTS.read_text(encoding="utf-8")
        self.assertTrue(provider.startswith("#if HARVIS_VERSION_UI_TESTING\n"))
        self.assertTrue(provider.rstrip().endswith("#endif"))
        self.assertTrue(tests.startswith("#if HARVIS_VERSION_UI_TESTING\n"))
        self.assertTrue(tests.rstrip().endswith("#endif"))
        self.assertEqual(provider.count("#if HARVIS_VERSION_UI_TESTING"), 1)
        self.assertEqual(tests.count("#if HARVIS_VERSION_UI_TESTING"), 1)
        self.assertIn('defaultsSuiteName = "local.harzva.harvisbar.version-ui-test.fixtures"', provider)
        required_ids = {
            "baseline-unbound",
            "ready-exact",
            "source-offline",
            "helper-mismatch",
            "latest-wins",
        }
        declared_ids = set(re.findall(r'case \w+ = "([a-z0-9-]+)"', provider))
        self.assertTrue(required_ids <= declared_ids)
        self.assertIn('arguments.count == 2', provider)

        production_files = (
            PROJECT_ROOT / "scripts/harvis_bar_build.sh",
            PROJECT_ROOT / "scripts/harvis_bar_package_app.sh",
            PROJECT_ROOT / "scripts/harvis_desktop_package_app.sh",
        )
        for production_file in production_files:
            content = production_file.read_text(encoding="utf-8")
            self.assertNotIn("HARVIS_VERSION_UI_TESTING", content)
            self.assertNotIn("local.harzva.harvisbar.version-ui-test", content)
            self.assertNotIn("--harvis-version-fixture", content)


if __name__ == "__main__":
    unittest.main()
