#!/usr/bin/env python3
"""Adversarial tests for the provenance-anchored macOS app bundle contract."""

from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = PROJECT_ROOT / "scripts"
sys.path.insert(0, str(SCRIPT_ROOT))

import harvis_app_bundle_contract as bundle  # noqa: E402
import harvis_release_provenance as provenance  # noqa: E402


class SyntheticRepo:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Harvis Test"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "harvis-test@example.invalid"],
            cwd=root,
            check=True,
        )

    def write(self, relative: str, data: str | bytes, mode: int = 0o644) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(data, bytes):
            path.write_bytes(data)
        else:
            path.write_text(data, encoding="utf-8")
        path.chmod(mode)
        return path

    def commit(self, message: str) -> None:
        environment = dict(os.environ)
        environment.update(
            {
                "GIT_AUTHOR_DATE": "1700000000 +0000",
                "GIT_COMMITTER_DATE": "1700000000 +0000",
            }
        )
        subprocess.run(["git", "add", "--all"], cwd=self.root, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", message],
            cwd=self.root,
            check=True,
            env=environment,
        )


def safe_toolchain() -> dict[str, object]:
    value: dict[str, object] = {
        "commands": {
            "cargo": {"available": False},
            "rustc": {"available": False},
            "swift": {"available": False},
            "xcodebuild": {"available": False},
        },
        "platform": {"architecture": "arm64", "release": "test", "system": "Darwin"},
        "python": {"implementation": "CPython", "version": "3.test"},
    }
    value["aggregateSha256"] = provenance._sha256_bytes(
        provenance._canonical_json(value)
    )
    return value


class AppBundleVerifyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="harvis-app-bundle-test-")
        self.base = Path(self.temporary.name)
        self.repo = SyntheticRepo(self.base / "repo")
        self._write_source_contract()
        self.repo.commit("fixture source")

        artifacts_root = self.base / "artifacts"
        artifacts_root.mkdir()
        self.runtime = artifacts_root / "harvis"
        self.main = artifacts_root / "HarvisBar"
        self.extension = artifacts_root / bundle.EXTENSION_NAME
        for path, content in (
            (self.runtime, b"synthetic-runtime\n"),
            (self.main, b"synthetic-main\n"),
            (self.extension, b"synthetic-extension\n"),
        ):
            path.write_bytes(content)
            path.chmod(0o755)

        self.stage = self.base / "stage"
        self.manifest = provenance.create_stage(
            self.repo.root,
            self.stage,
            allowlist=self.repo.root / "packaging/plugin-stage-allowlist-v1.txt",
            artifacts=[
                provenance.ArtifactSpec(
                    "harvis-runtime", self.runtime, "bin/harvis"
                ),
                provenance.ArtifactSpec(
                    "harvis-system-extension",
                    self.extension,
                    f"artifacts/{bundle.EXTENSION_NAME}",
                ),
                provenance.ArtifactSpec(
                    "harvisbar-main", self.main, "artifacts/HarvisBar"
                ),
            ],
            source_date_epoch=1_700_000_000,
            toolchain_override=safe_toolchain(),
        )
        self.provenance_sha = hashlib.sha256(
            (self.stage / provenance.PROVENANCE_FILE).read_bytes()
        ).hexdigest()
        self.contract = bundle.load_provenance_contract(
            self.stage, self.repo.root, self.provenance_sha
        )
        self.app = self._build_unsigned_app()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_source_contract(self) -> None:
        self.repo.write(
            ".codex-plugin/plugin.json",
            json.dumps({"name": "harvis", "version": "0.33.0"}) + "\n",
        )
        self.repo.write(".mcp.json", "{}\n")
        self.repo.write(
            "Cargo.toml",
            '[workspace]\nmembers = []\n\n[workspace.package]\nversion = "0.33.0"\n',
        )
        self.repo.write("Cargo.lock", "# synthetic lock\n")
        self.repo.write("apps/HarvisBar/Package.swift", "// synthetic package\n")
        self.repo.write(
            "apps/HarvisBar/Resources/FULL_DISK_ACCESS.md", "Synthetic guide.\n"
        )
        self.repo.write(
            "apps/HarvisBar/Resources/HarvisBar.entitlements",
            plistlib.dumps({}),
        )
        self.repo.write(
            f"apps/HarvisBar/SystemExtensions/{bundle.EXTENSION_NAME}/Info.plist",
            plistlib.dumps(
                {
                    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                    "CFBundleIdentifier": bundle.EXTENSION_ID,
                    "CFBundlePackageType": "SYSX",
                    "NetworkExtension": {
                        "NEMachServiceName": "$(TeamIdentifierPrefix)" + bundle.EXTENSION_ID,
                        "NEProviderClasses": {
                            "com.apple.networkextension.app-proxy": "Placeholder.Provider"
                        },
                    },
                }
            ),
        )
        self.repo.write(
            f"apps/HarvisBar/SystemExtensions/{bundle.EXTENSION_NAME}/{bundle.EXTENSION_NAME}.entitlements",
            plistlib.dumps({}),
        )
        self.repo.write("scripts/runtime-tool", "#!/bin/sh\nexit 0\n", mode=0o755)
        self.repo.write("studio/assets/harvis-app-icon.png", b"synthetic-png\n")
        self.repo.write(
            "schemas/release-provenance-v2.schema.json", '{"type":"object"}\n'
        )
        self.repo.write(
            "packaging/app-runtime-allowlist-v1.txt",
            """.codex-plugin/plugin.json
packaging/app-runtime-allowlist-v1.txt
scripts/
""",
        )
        self.repo.write(
            "packaging/plugin-stage-allowlist-v1.txt",
            """.codex-plugin/plugin.json
.mcp.json
Cargo.toml
Cargo.lock
apps/HarvisBar/Package.swift
apps/HarvisBar/Resources/
apps/HarvisBar/SystemExtensions/
packaging/
schemas/
scripts/
studio/
""",
        )

    def _build_unsigned_app(self) -> Path:
        app = self.base / "HarvisBar.app"
        contents = app / "Contents"
        resources = contents / "Resources"
        macos = contents / "MacOS"
        extension_contents = (
            contents
            / "Library"
            / "SystemExtensions"
            / bundle.EXTENSION_BUNDLE_NAME
            / "Contents"
        )
        macos.mkdir(parents=True)
        resources.mkdir(parents=True)
        (extension_contents / "MacOS").mkdir(parents=True)
        shutil.copyfile(
            self.stage / bundle.EXPECTED_ARTIFACT_PATHS["harvisbar-main"],
            macos / "HarvisBar",
        )
        (macos / "HarvisBar").chmod(0o755)
        shutil.copyfile(
            self.stage
            / bundle.EXPECTED_ARTIFACT_PATHS["harvis-system-extension"],
            extension_contents / "MacOS" / bundle.EXTENSION_NAME,
        )
        (extension_contents / "MacOS" / bundle.EXTENSION_NAME).chmod(0o755)
        (resources / bundle.MARKER_FILE).write_text(
            bundle.PLUGIN_ROOT_MARKER + "\n", encoding="utf-8"
        )
        (resources / "HarvisBar.icns").write_bytes(b"synthetic-icon\n")
        bundle.materialize_runtime_payload(
            self.contract, resources / bundle.PLUGIN_ROOT_MARKER
        )
        app_info = {
            "CFBundleExecutable": "HarvisBar",
            "CFBundleIdentifier": "local.harzva.harvisbar",
            "CFBundleName": "HarvisBar",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.33.0",
            "CFBundleVersion": "0.33.0",
        }
        app_info.update(bundle.REQUIRED_MACOS_USAGE_DESCRIPTIONS)
        (contents / "Info.plist").write_bytes(
            plistlib.dumps(app_info, sort_keys=True)
        )
        (extension_contents / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": bundle.EXTENSION_NAME,
                    "CFBundleIdentifier": bundle.EXTENSION_ID,
                    "CFBundlePackageType": "SYSX",
                    "CFBundleShortVersionString": "0.33.0",
                    "CFBundleVersion": "0.33.0",
                },
                sort_keys=True,
            )
        )
        receipt = bundle.build_receipt(
            self.contract,
            contents,
            variant="bar",
            expected_bundle_id="local.harzva.harvisbar",
            expected_version="0.33.0",
            expected_executable="HarvisBar",
        )
        bundle.write_receipt(resources / bundle.RECEIPT_FILE, receipt)
        return app

    def verify(self) -> dict[str, object]:
        return bundle.verify_bundle(
            self.app,
            self.contract,
            variant="bar",
            expected_bundle_id="local.harzva.harvisbar",
            expected_version="0.33.0",
            expected_executable="HarvisBar",
            codesign_policy="skip",
        )

    def test_valid_unsigned_fixture_verifies_with_explicit_skip_policy(self) -> None:
        receipt = self.verify()
        self.assertEqual(receipt["provenance"]["sha256"], self.provenance_sha)
        staged_plugin = json.loads(
            (
                self.app
                / "Contents/Resources/HarvisPlugin/.codex-plugin/plugin.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(
            staged_plugin["version"], self.manifest["cache"]["effectiveVersion"]
        )

    def test_swift_receipt_golden_is_builder_derived_and_byte_exact(self) -> None:
        generated = (
            self.app / "Contents/Resources" / bundle.RECEIPT_FILE
        ).read_bytes()
        golden = (
            PROJECT_ROOT
            / "apps/HarvisBar/Tests/HarvisBarTests/Fixtures"
            / "harvis-bundle-receipt-v1.json"
        ).read_bytes()
        self.assertEqual(generated, golden)

    def test_verifier_cli_imports_its_contract_under_python_isolated_mode(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                str(SCRIPT_ROOT / "harvis_app_bundle_verify.py"),
                "--help",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--provenance-sha256", result.stdout)

    def test_package_help_does_not_require_workspace_cargo_toml(self) -> None:
        """The reduced in-app runtime snapshot intentionally omits Cargo.toml."""
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ)
            environment["HARVIS_PLUGIN_ROOT"] = directory
            for name in (
                "harvis_bar_package_app.sh",
                "harvis_desktop_package_app.sh",
                "harvis_bar_package_dmg.sh",
            ):
                with self.subTest(script=name):
                    result = subprocess.run(
                        ["bash", str(SCRIPT_ROOT / name), "--help"],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        check=False,
                        env=environment,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("--provenance-stage", result.stdout)

    def test_receipt_external_anchor_and_payload_digest_are_not_self_asserted(self) -> None:
        receipt_path = self.app / "Contents/Resources" / bundle.RECEIPT_FILE
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["provenance"]["sha256"] = "0" * 64
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        with self.assertRaisesRegex(bundle.AppBundleContractError, "receipt"):
            self.verify()

    def test_marker_rejects_absolute_and_traversal_values(self) -> None:
        marker = self.app / "Contents/Resources" / bundle.MARKER_FILE
        for value in ("../outside\n", "/private/outside\n", "HarvisPlugin/../outside\n"):
            with self.subTest(value=value):
                marker.write_text(value, encoding="utf-8")
                with self.assertRaisesRegex(bundle.AppBundleContractError, "marker"):
                    self.verify()
                marker.write_text("HarvisPlugin\n", encoding="utf-8")

    def test_payload_and_runtime_tampering_are_detected(self) -> None:
        runtime = self.app / "Contents/Resources/HarvisPlugin/bin/harvis"
        runtime.write_bytes(b"tampered runtime\n")
        runtime.chmod(0o755)
        with self.assertRaisesRegex(
            bundle.AppBundleContractError, "payload|runtime executable"
        ):
            self.verify()

    def test_wrong_version_and_extension_bundle_name_are_detected(self) -> None:
        app_plist = self.app / "Contents/Info.plist"
        info = plistlib.loads(app_plist.read_bytes())
        info["CFBundleShortVersionString"] = "9.9.9"
        app_plist.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(bundle.AppBundleContractError, "version|CFBundle"):
            self.verify()

        info["CFBundleShortVersionString"] = "0.33.0"
        app_plist.write_bytes(plistlib.dumps(info))
        extension = self.app / "Contents/Library/SystemExtensions" / bundle.EXTENSION_BUNDLE_NAME
        extension.rename(extension.with_name("Wrong.systemextension"))
        with self.assertRaisesRegex(bundle.AppBundleContractError, "extension"):
            self.verify()

    def test_missing_macos_usage_description_is_rejected(self) -> None:
        app_plist = self.app / "Contents/Info.plist"
        original = plistlib.loads(app_plist.read_bytes())
        for key in bundle.REQUIRED_MACOS_USAGE_DESCRIPTIONS:
            with self.subTest(key=key):
                modified = dict(original)
                modified.pop(key)
                app_plist.write_bytes(plistlib.dumps(modified))
                with self.assertRaisesRegex(
                    bundle.AppBundleContractError,
                    key,
                ):
                    self.verify()
        app_plist.write_bytes(plistlib.dumps(original))

    def test_caller_cannot_self_assert_a_different_bundle_identity_or_executable(self) -> None:
        contents = self.app / "Contents"
        with self.assertRaisesRegex(bundle.AppBundleContractError, "identifier"):
            bundle.build_receipt(
                self.contract,
                contents,
                variant="bar",
                expected_bundle_id="attacker.example.self-consistent",
                expected_version="0.33.0",
                expected_executable="HarvisBar",
                require_unsigned_artifact_copies=False,
            )
        with self.assertRaisesRegex(bundle.AppBundleContractError, "executable"):
            bundle.build_receipt(
                self.contract,
                contents,
                variant="bar",
                expected_bundle_id="local.harzva.harvisbar",
                expected_version="0.33.0",
                expected_executable="OtherExecutable",
                require_unsigned_artifact_copies=False,
            )

    def test_fixed_artifact_roles_paths_modes_and_cardinality_are_strict(self) -> None:
        cases: list[dict[str, object]] = []
        extra = copy.deepcopy(self.manifest)
        extra["artifacts"].append(
            {
                "role": "rogue",
                "relativePath": "artifacts/rogue",
                "mode": "0755",
                "sizeBytes": 1,
                "sha256": "0" * 64,
            }
        )
        cases.append(extra)
        wrong_path = copy.deepcopy(self.manifest)
        wrong_path["artifacts"][0]["relativePath"] = "bin/other"
        cases.append(wrong_path)
        wrong_mode = copy.deepcopy(self.manifest)
        wrong_mode["artifacts"][0]["mode"] = "0644"
        cases.append(wrong_mode)
        for manifest in cases:
            with self.subTest(artifacts=manifest["artifacts"]), self.assertRaises(
                bundle.AppBundleContractError
            ):
                bundle.validate_fixed_artifacts(manifest, self.stage)

    def test_stage_artifact_tamper_and_source_head_mismatch_fail_external_verify(self) -> None:
        staged_runtime = self.stage / "bin/harvis"
        staged_runtime.write_bytes(b"tampered stage\n")
        staged_runtime.chmod(0o755)
        with self.assertRaisesRegex(bundle.AppBundleContractError, "verification failed"):
            bundle.load_provenance_contract(
                self.stage, self.repo.root, self.provenance_sha
            )

        shutil.copyfile(self.runtime, staged_runtime)
        provenance._normalize_stage_mtime(
            self.stage, int(self.manifest["sourceDateEpoch"])
        )
        self.repo.write("scripts/new-commit", "new\n")
        self.repo.commit("move head")
        with self.assertRaisesRegex(bundle.AppBundleContractError, "verification failed"):
            bundle.load_provenance_contract(
                self.stage, self.repo.root, self.provenance_sha
            )

    def test_codesign_verification_is_parameterized_and_fail_closed(self) -> None:
        calls: list[list[str]] = []

        def success(argv: list[str], **_: object) -> subprocess.CompletedProcess[bytes]:
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, b"", b"")

        bundle.verify_codesign_targets(
            self.app,
            self.app
            / "Contents/Library/SystemExtensions"
            / bundle.EXTENSION_BUNDLE_NAME,
            self.app / "Contents/Resources/HarvisPlugin/bin/harvis",
            codesign="/usr/bin/codesign",
            runner=success,
        )
        self.assertEqual(len(calls), 3)

        def failure(argv: list[str], **_: object) -> subprocess.CompletedProcess[bytes]:
            return subprocess.CompletedProcess(argv, 1, b"", b"invalid")

        with self.assertRaisesRegex(bundle.AppBundleContractError, "signature"):
            bundle.verify_codesign_targets(
                self.app,
                self.app
                / "Contents/Library/SystemExtensions"
                / bundle.EXTENSION_BUNDLE_NAME,
                self.app / "Contents/Resources/HarvisPlugin/bin/harvis",
                codesign="/usr/bin/codesign",
                runner=failure,
            )

    def test_codesign_derivative_normalizes_only_linkedit_vmsize(self) -> None:
        def macho(vmsize: int, payload: bytes = b"payload") -> bytes:
            fileoff = 0x4000
            header = struct.pack(
                "<IIIIIIII",
                0xFEEDFACF,
                0x0100000C,
                0,
                2,
                1,
                72,
                0,
                0,
            )
            segment = struct.pack(
                "<II16sQQQQiiII",
                0x19,
                72,
                b"__LINKEDIT" + b"\0" * 6,
                0x100004000,
                vmsize,
                fileoff,
                len(payload),
                1,
                1,
                0,
                0,
            )
            padding = b"\0" * (fileoff - len(header) - len(segment))
            return header + segment + padding + payload

        linker_signed = macho(0x24000)
        app_signed = macho(0x38000)
        self.assertEqual(
            bundle._normalize_codesign_mutable_macho_fields(
                linker_signed,
                expected_vmsize_offset=64,
                expected_stale_vmsize=0x24000,
            ),
            bundle._normalize_codesign_mutable_macho_fields(
                app_signed,
                expected_vmsize_offset=64,
                expected_stale_vmsize=0x38000,
            ),
        )
        normalized = bundle._normalize_codesign_mutable_macho_fields(
            linker_signed,
            expected_vmsize_offset=64,
            expected_stale_vmsize=0x24000,
        )
        self.assertEqual(struct.unpack_from("<Q", normalized, 64)[0], 0x4000)
        with self.assertRaisesRegex(bundle.AppBundleContractError, "unexpected"):
            bundle._normalize_codesign_mutable_macho_fields(
                linker_signed,
                expected_vmsize_offset=64,
                expected_stale_vmsize=0x38000,
            )
        tampered = bytearray(app_signed)
        tampered[-1] ^= 1
        self.assertNotEqual(
            bundle._normalize_codesign_mutable_macho_fields(
                linker_signed,
                expected_vmsize_offset=64,
                expected_stale_vmsize=0x24000,
            ),
            bundle._normalize_codesign_mutable_macho_fields(
                bytes(tampered),
                expected_vmsize_offset=64,
                expected_stale_vmsize=0x38000,
            ),
        )

    def test_codesign_derivative_macho_parser_fails_closed(self) -> None:
        cases = [
            b"not-a-macho",
            struct.pack("<IIIIIIII", 0xFEEDFACF, 0, 0, 2, 1, 72, 0, 0),
        ]
        for raw in cases:
            with self.subTest(raw=raw), self.assertRaises(
                bundle.AppBundleContractError
            ):
                bundle._normalize_codesign_mutable_macho_fields(
                    raw,
                    expected_vmsize_offset=64,
                    expected_stale_vmsize=0x4000,
                )

    def test_signed_macho_layout_requires_canonical_linkedit_and_signature_tail(self) -> None:
        def signed_macho(vmsize: int, signature_size: int = 16) -> bytes:
            fileoff = 0x4000
            body = b"body"
            signature = b"s" * signature_size
            filesize = len(body) + len(signature)
            header = struct.pack(
                "<IIIIIIII",
                0xFEEDFACF,
                0x0100000C,
                0,
                2,
                2,
                88,
                0,
                0,
            )
            segment = struct.pack(
                "<II16sQQQQiiII",
                0x19,
                72,
                b"__LINKEDIT" + b"\0" * 6,
                0x100004000,
                vmsize,
                fileoff,
                filesize,
                1,
                1,
                0,
                0,
            )
            code_signature = struct.pack(
                "<IIII", 0x1D, 16, fileoff + len(body), signature_size
            )
            padding = b"\0" * (
                fileoff - len(header) - len(segment) - len(code_signature)
            )
            return header + segment + code_signature + padding + body + signature

        valid = signed_macho(0x4000)
        _, canonical = bundle._macho_signature_layout(
            valid, require_code_signature=True
        )
        self.assertEqual(canonical, 0x4000)
        with self.assertRaisesRegex(bundle.AppBundleContractError, "vmsize"):
            bundle._macho_signature_layout(
                signed_macho(0x8000), require_code_signature=True
            )
        with self.assertRaisesRegex(bundle.AppBundleContractError, "signature range"):
            bundle._macho_signature_layout(
                signed_macho(0x4000, signature_size=0),
                require_code_signature=True,
            )

    def test_package_scripts_verify_temporary_bundle_before_publication(self) -> None:
        for name in ("harvis_bar_package_app.sh", "harvis_desktop_package_app.sh"):
            with self.subTest(script=name):
                text = (SCRIPT_ROOT / name).read_text(encoding="utf-8")
                verify = text.index('"$PLUGIN_ROOT/scripts/harvis_app_bundle_verify.py"')
                publish = text.index('mv -n "$BUILD_APP" "$APP_PATH"')
                self.assertLess(verify, publish)
                self.assertIn('--app "$BUILD_APP"', text[verify:publish])
                install_verify = text.index('--app "$INSTALL_TMP/$APP_NAME.app"')
                install_publish = text.index(
                    'mv -n "$INSTALL_TMP/$APP_NAME.app" "$TARGET_APP"'
                )
                self.assertLess(install_verify, install_publish)

    def test_signed_entitlements_are_anchored_to_provenance(self) -> None:
        calls: list[list[str]] = []

        def expected(argv: list[str], **_: object) -> subprocess.CompletedProcess[bytes]:
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, plistlib.dumps({}), b"")

        extension = (
            self.app
            / "Contents/Library/SystemExtensions"
            / bundle.EXTENSION_BUNDLE_NAME
        )
        bundle.verify_signed_entitlements(
            self.app,
            extension,
            self.contract,
            codesign="/usr/bin/codesign",
            runner=expected,
        )
        self.assertEqual(len(calls), 2)

        def elevated(argv: list[str], **_: object) -> subprocess.CompletedProcess[bytes]:
            value = {"com.example.untrusted": True}
            return subprocess.CompletedProcess(argv, 0, plistlib.dumps(value), b"")

        with self.assertRaisesRegex(bundle.AppBundleContractError, "provenance"):
            bundle.verify_signed_entitlements(
                self.app,
                extension,
                self.contract,
                codesign="/usr/bin/codesign",
                runner=elevated,
            )


if __name__ == "__main__":
    unittest.main()
