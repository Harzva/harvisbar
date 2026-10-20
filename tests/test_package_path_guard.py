#!/usr/bin/env python3
"""Destructive-path regression tests for Harvis package scripts."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = PROJECT_ROOT / "scripts"
sys.path.insert(0, str(SCRIPT_ROOT))

from harvis_package_path_guard import PackagePathError, guard_path  # noqa: E402


class PackagePathGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="harvis-package-path-test-", dir="/private/tmp"
        )
        self.base = Path(self.temporary.name)
        self.source = self.base / "source"
        self.source.mkdir()
        self.output = self.base / "output"
        self.output.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_safe_new_app_and_dmg_under_controlled_root_are_allowed(self) -> None:
        app = guard_path(
            str(self.output / "HarvisBar.app"),
            source=self.source,
            kind="app-output",
            output_root=str(self.output),
        )
        dmg = guard_path(
            str(self.output / "HarvisBar.dmg"),
            source=self.source,
            kind="dmg-output",
            output_root=str(self.output),
        )
        self.assertEqual(app, self.output / "HarvisBar.app")
        self.assertEqual(dmg, self.output / "HarvisBar.dmg")

    def test_repeated_slash_dotdot_and_wrong_suffix_are_rejected(self) -> None:
        cases = (
            (f"{self.output}//Victim.app", "app-output"),
            (f"{self.output}/nested/../Victim.app", "app-output"),
            (str(self.output / "not-an-app"), "app-output"),
            (str(self.output / "Cargo.toml"), "dmg-output"),
        )
        for path, kind in cases:
            with self.subTest(path=path), self.assertRaises(PackagePathError):
                guard_path(
                    path,
                    source=self.source,
                    kind=kind,
                    output_root=str(self.output),
                )

    def test_repo_formal_root_and_outside_output_root_are_rejected(self) -> None:
        cases = (
            (self.source / "Victim.app", str(self.source)),
            (Path.home() / ".harvis" / "Victim.app", None),
            (self.base / "outside" / "Victim.app", str(self.output)),
        )
        for path, root in cases:
            with self.subTest(path=path), self.assertRaises(PackagePathError):
                guard_path(
                    str(path),
                    source=self.source,
                    kind="app-output",
                    output_root=root,
                )

    def test_symlink_parent_cannot_redirect_output_into_source(self) -> None:
        redirect = self.output / "redirect"
        redirect.symlink_to(self.source, target_is_directory=True)
        sentinel = self.source / "Victim.app"
        sentinel.mkdir()
        with self.assertRaisesRegex(PackagePathError, "symlink"):
            guard_path(
                str(redirect / "Victim.app"),
                source=self.source,
                kind="app-output",
                output_root=str(self.output),
            )
        self.assertTrue(sentinel.is_dir())

    def test_existing_file_directory_hardlink_and_input_symlink_fail_closed(self) -> None:
        existing_app = self.output / "Existing.app"
        existing_app.mkdir()
        with self.assertRaisesRegex(PackagePathError, "already exists"):
            guard_path(
                str(existing_app),
                source=self.source,
                kind="app-output",
                output_root=str(self.output),
            )

        original = self.output / "original.dmg"
        original.write_bytes(b"sentinel\n")
        hardlink = self.output / "hardlink.dmg"
        os.link(original, hardlink)
        with self.assertRaisesRegex(PackagePathError, "already exists"):
            guard_path(
                str(hardlink),
                source=self.source,
                kind="dmg-output",
                output_root=str(self.output),
            )
        self.assertEqual(original.read_bytes(), b"sentinel\n")

        app_link = self.output / "Linked.app"
        app_link.symlink_to(existing_app, target_is_directory=True)
        with self.assertRaisesRegex(PackagePathError, "symlink"):
            guard_path(
                str(app_link),
                source=self.source,
                kind="app-input",
                output_root=str(self.output),
            )

    def test_package_scripts_reject_app_name_path_escape_before_packaging(self) -> None:
        fake_sha = "0" * 64
        for script, variable in (
            ("harvis_bar_package_app.sh", "HARVIS_BAR_APP_NAME"),
            ("harvis_desktop_package_app.sh", "HARVIS_DESKTOP_APP_NAME"),
        ):
            environment = dict(os.environ)
            environment[variable] = "../Victim"
            result = subprocess.run(
                [
                    "bash",
                    str(SCRIPT_ROOT / script),
                    "--provenance-stage",
                    str(self.output),
                    "--provenance-sha256",
                    fake_sha,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                env=environment,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("fixed", result.stderr)

    def test_path_guard_cli_runs_under_isolated_python(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                str(SCRIPT_ROOT / "harvis_package_path_guard.py"),
                "--help",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--output-root", result.stdout)


if __name__ == "__main__":
    unittest.main()
