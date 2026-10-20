from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = PROJECT_ROOT / "scripts" / "harvis_release_provenance.py"
SPEC = importlib.util.spec_from_file_location("harvis_release_provenance", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
provenance = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = provenance
SPEC.loader.exec_module(provenance)


def run(*argv: str, cwd: Path) -> str:
    result = subprocess.run(
        list(argv),
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"command failed: {argv}: {result.stderr}")
    return result.stdout.strip()


class FixtureRepository:
    def __init__(self, root: Path) -> None:
        self.root = root
        root.mkdir()
        run("git", "init", "-q", "-b", "main", cwd=root)
        run("git", "config", "user.name", "Harvis Test", cwd=root)
        run("git", "config", "user.email", "harvis-test@example.invalid", cwd=root)
        self.write(
            ".gitignore",
            ".env\n.harvis/\ntarget/\n.build/\n",
        )
        self.write(
            ".codex-plugin/plugin.json",
            json.dumps({"name": "harvis", "version": "1.2.3+codex.test"}) + "\n",
        )
        self.write(".mcp.json", "{}\n")
        self.write(
            "Cargo.toml",
            '[workspace]\nmembers = []\n\n[workspace.package]\nversion = "0.33.0"\n',
        )
        self.write("Cargo.lock", "version = 4\n")
        self.write(
            "apps/HarvisBar/Package.swift",
            "// swift-tools-version: 6.0\nimport PackageDescription\n",
        )
        self.write("schemas/alpha.schema.json", '{"type":"object"}\n')
        self.write("schemas/beta.schema.json", '{"type":"array"}\n')
        self.write("schemas/release-provenance-v2.schema.json", '{"type":"object"}\n')
        self.write("scripts/harvis", "#!/bin/sh\nexit 0\n", executable=True)
        self.write(
            "packaging/plugin-stage-allowlist-v1.txt",
            "\n".join(
                [
                    ".codex-plugin/plugin.json",
                    ".mcp.json",
                    "Cargo.toml",
                    "Cargo.lock",
                    "apps/HarvisBar/Package.swift",
                    "schemas/",
                    "scripts/",
                    "",
                ]
            ),
        )
        self.commit("fixture")
        self.write(".env", "SHOULD_NOT_STAGE=1\n")
        self.write(".harvis/state.json", "{}\n")

    @property
    def allowlist(self) -> Path:
        return self.root / "packaging" / "plugin-stage-allowlist-v1.txt"

    def write(self, relative: str, content: str, *, executable: bool = False) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        if executable:
            path.chmod(0o755)
        return path

    def commit(self, message: str) -> None:
        run("git", "add", "-A", cwd=self.root)
        run("git", "commit", "-q", "-m", message, cwd=self.root)


class ReleaseProvenanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="harvis-provenance-test-")
        self.base = Path(self.temporary.name)
        self.repo = FixtureRepository(self.base / "repo")
        self.toolchain = {
            "commands": {
                "cargo": {"available": True, "version": "cargo 1.90.0"},
                "rustc": {"available": True, "version": "rustc 1.90.0\nhost: arm64-apple-darwin"},
                "swift": {"available": True, "version": "Swift version 6.0"},
                "xcodebuild": {"available": True, "version": "Xcode 16.0\nBuild version 16A1"},
            },
            "platform": {
                "architecture": "arm64",
                "release": "24.0.0",
                "system": "Darwin",
            },
            "python": {"implementation": "CPython", "version": "3.12.0"},
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def stage(self, name: str, **kwargs: object) -> tuple[Path, dict[str, object]]:
        output = self.base / name
        manifest = provenance.create_stage(
            self.repo.root,
            output,
            allowlist=self.repo.allowlist,
            source_date_epoch=1_700_000_000,
            toolchain_override=self.toolchain,
            **kwargs,
        )
        return output, manifest

    @staticmethod
    def provenance_sha256(stage: Path) -> str:
        return hashlib.sha256((stage / provenance.PROVENANCE_FILE).read_bytes()).hexdigest()

    @staticmethod
    def rewrite_manifest(stage: Path, manifest: dict[str, object]) -> None:
        (stage / provenance.PROVENANCE_FILE).write_text(
            json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        provenance._normalize_stage_mtime(stage, int(manifest["sourceDateEpoch"]))

    def test_committed_head_stage_is_deterministic_and_public_safe(self) -> None:
        first, first_manifest = self.stage("first")
        second, second_manifest = self.stage("second")

        self.assertEqual(first_manifest, second_manifest)
        self.assertEqual(
            (first / provenance.PROVENANCE_FILE).read_bytes(),
            (second / provenance.PROVENANCE_FILE).read_bytes(),
        )
        rendered = json.dumps(first_manifest, sort_keys=True)
        self.assertNotIn(str(self.base), rendered)
        self.assertNotIn("/Users/", rendered)
        self.assertNotIn("/Volumes/", rendered)
        self.assertFalse((first / ".env").exists())
        self.assertFalse((first / ".harvis").exists())
        self.assertEqual(first_manifest["generatedAt"], "2023-11-14T22:13:20Z")
        self.assertTrue(first_manifest["safety"]["allowlistOnly"])
        self.assertFalse(first_manifest["safety"]["installPerformed"])

        effective = first_manifest["cache"]["effectiveVersion"]
        self.assertRegex(effective, r"^1\.2\.3\+codex\.p2-[0-9a-f]{64}$")
        self.assertEqual(effective.count("+codex."), 1)
        self.assertNotIn("+codex.test", effective)
        staged_plugin = json.loads(
            (first / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertEqual(staged_plugin["version"], effective)
        self.assertEqual(
            first_manifest["cache"]["cacheKey"],
            f"personal/harvis/{effective}",
        )
        self.assertEqual(first_manifest["inputs"]["schemaSet"]["count"], 3)
        self.assertEqual(
            provenance.verify_stage(
                first,
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(first),
            ),
            first_manifest,
        )

    def test_source_date_epoch_environment_is_honored(self) -> None:
        with mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "42"}):
            self.assertEqual(provenance._source_date_epoch(self.repo.root), 42)
        self.assertEqual(provenance._timestamp(42), "1970-01-01T00:00:42Z")

    def test_dirty_source_fails_without_creating_output(self) -> None:
        self.repo.write("Cargo.lock", "version = 4\n# dirty\n")
        output = self.base / "dirty-output"
        with self.assertRaisesRegex(provenance.ProvenanceError, "not clean"):
            provenance.create_stage(
                self.repo.root,
                output,
                allowlist=self.repo.allowlist,
                source_date_epoch=1,
                toolchain_override=self.toolchain,
            )
        self.assertFalse(output.exists())

    def test_allowlist_path_traversal_is_rejected(self) -> None:
        self.repo.write(
            "packaging/plugin-stage-allowlist-v1.txt",
            self.repo.allowlist.read_text(encoding="utf-8") + "../outside\n",
        )
        self.repo.commit("unsafe allowlist")
        with self.assertRaisesRegex(provenance.ProvenanceError, "invalid allowlist"):
            provenance.create_stage(
                self.repo.root,
                self.base / "unsafe",
                allowlist=self.repo.allowlist,
                source_date_epoch=1,
                toolchain_override=self.toolchain,
            )

    def test_selected_symlink_is_rejected(self) -> None:
        link = self.repo.root / "scripts" / "linked-runner"
        link.symlink_to("harvis")
        self.repo.commit("symlink")
        with self.assertRaisesRegex(provenance.ProvenanceError, "symlink"):
            provenance.create_stage(
                self.repo.root,
                self.base / "symlink",
                allowlist=self.repo.allowlist,
                source_date_epoch=1,
                toolchain_override=self.toolchain,
            )

    def test_submodule_and_case_collisions_are_rejected(self) -> None:
        with self.assertRaisesRegex(provenance.ProvenanceError, "submodule"):
            provenance._validate_selected_entries(
                [
                    provenance.GitEntry(
                        mode="160000",
                        kind="commit",
                        object_id="a" * 40,
                        path="vendor/submodule",
                    )
                ]
            )
        with self.assertRaisesRegex(provenance.ProvenanceError, "collision"):
            provenance._validate_selected_entries(
                [
                    provenance.GitEntry("100644", "blob", "a" * 40, "schemas/A.json"),
                    provenance.GitEntry("100644", "blob", "b" * 40, "schemas/a.json"),
                ]
            )

    def test_artifact_hash_and_verify_detect_tampering(self) -> None:
        artifact = self.base / "harvis-binary"
        artifact.write_bytes(b"synthetic-harvis-binary\n")
        artifact.chmod(0o755)
        stage, manifest = self.stage(
            "artifact-stage",
            artifacts=[
                provenance.ArtifactSpec(
                    role="rust-cli",
                    source=artifact,
                    destination="bin/harvis",
                )
            ],
        )
        expected = hashlib.sha256(artifact.read_bytes()).hexdigest()
        self.assertEqual(manifest["artifacts"][0]["sha256"], expected)
        self.assertEqual(manifest["artifacts"][0]["relativePath"], "bin/harvis")
        self.assertEqual((stage / "bin" / "harvis").stat().st_mode & 0o777, 0o755)

        (stage / "bin" / "harvis").write_bytes(b"tampered\n")
        provenance._normalize_stage_mtime(stage, int(manifest["sourceDateEpoch"]))
        with self.assertRaisesRegex(provenance.ProvenanceError, "payload hash mismatch"):
            provenance.verify_stage(
                stage,
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(stage),
            )

    def test_previous_release_is_hash_linked_without_path(self) -> None:
        first, first_manifest = self.stage("previous")
        self.repo.write("schemas/alpha.schema.json", '{"type":"string"}\n')
        self.repo.commit("next release")
        second, second_manifest = self.stage(
            "current",
            previous_provenance=first / provenance.PROVENANCE_FILE,
        )
        previous = second_manifest["previousRelease"]
        self.assertIsNotNone(previous)
        assert previous is not None
        self.assertEqual(previous["cacheKey"], first_manifest["cache"]["cacheKey"])
        self.assertEqual(
            previous["provenanceSha256"],
            hashlib.sha256((first / provenance.PROVENANCE_FILE).read_bytes()).hexdigest(),
        )
        self.assertNotIn(str(first), json.dumps(previous, sort_keys=True))
        self.assertEqual(
            provenance.verify_stage(
                second,
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(second),
            ),
            second_manifest,
        )

    def test_verify_cli_reports_only_safe_identity(self) -> None:
        stage, manifest = self.stage("cli-stage")
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "verify",
                "--stage",
                str(stage),
                "--source",
                str(self.repo.root),
                "--provenance-sha256",
                self.provenance_sha256(stage),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["cacheKey"], manifest["cache"]["cacheKey"])
        self.assertNotIn(str(self.base), result.stdout)

    def test_same_head_different_artifacts_produce_different_cache_keys(self) -> None:
        first_artifact = self.base / "first-binary"
        second_artifact = self.base / "second-binary"
        first_artifact.write_bytes(b"artifact-one\n")
        second_artifact.write_bytes(b"artifact-two\n")
        first_artifact.chmod(0o755)
        second_artifact.chmod(0o755)
        first, first_manifest = self.stage(
            "artifact-one-stage",
            artifacts=[provenance.ArtifactSpec("rust-cli", first_artifact, "bin/harvis")],
        )
        second, second_manifest = self.stage(
            "artifact-two-stage",
            artifacts=[provenance.ArtifactSpec("rust-cli", second_artifact, "bin/harvis")],
        )
        self.assertEqual(first_manifest["source"]["commit"], second_manifest["source"]["commit"])
        self.assertNotEqual(first_manifest["cache"]["cacheKey"], second_manifest["cache"]["cacheKey"])
        self.assertNotEqual(
            first_manifest["stage"]["cachePayloadSha256"],
            second_manifest["stage"]["cachePayloadSha256"],
        )
        with self.assertRaisesRegex(provenance.ProvenanceError, "trust anchor"):
            provenance.verify_stage(first, source=self.repo.root)
        self.assertEqual(
            provenance.verify_stage(
                first,
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(first),
            ),
            first_manifest,
        )

    def test_stage_mtimes_and_deterministic_tar_bytes_are_reproducible(self) -> None:
        first, _ = self.stage("tar-first")
        second, _ = self.stage("tar-second")
        expected_ns = 1_700_000_000 * 1_000_000_000
        for stage in (first, second):
            for path in [stage, *stage.rglob("*")]:
                self.assertEqual(path.stat().st_mtime_ns, expected_ns, path)
        first_tar = self.base / "first.tar"
        second_tar = self.base / "second.tar"
        first_sha = provenance.write_deterministic_tar(
            first,
            first_tar,
            source=self.repo.root,
            expected_provenance_sha256=self.provenance_sha256(first),
        )
        second_sha = provenance.write_deterministic_tar(
            second,
            second_tar,
            source=self.repo.root,
            expected_provenance_sha256=self.provenance_sha256(second),
        )
        self.assertEqual(first_tar.read_bytes(), second_tar.read_bytes())
        self.assertEqual(first_sha, second_sha)

    def test_rogue_self_reported_file_is_rejected_against_head_inventory(self) -> None:
        stage, original = self.stage("rogue-stage")
        rogue = stage / "rogue.txt"
        rogue.write_text("self-reported but not selected by committed policy\n", encoding="utf-8")
        rogue.chmod(0o644)
        manifest = json.loads(json.dumps(original))
        records = provenance._stage_records(stage)
        manifest["stage"]["fileCount"] = len(records)
        manifest["stage"]["stagedPayloadSha256"] = provenance._payload_digest(records)
        self.rewrite_manifest(stage, manifest)
        with self.assertRaisesRegex(provenance.ProvenanceError, "rogue self-reported"):
            provenance.verify_stage(
                stage,
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(stage),
            )

        directory_stage, directory_manifest = self.stage("rogue-directory-stage")
        (directory_stage / "rogue-empty-directory").mkdir()
        provenance._normalize_stage_mtime(
            directory_stage, int(directory_manifest["sourceDateEpoch"])
        )
        with self.assertRaisesRegex(provenance.ProvenanceError, "rogue directory"):
            provenance.verify_stage(
                directory_stage,
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(directory_stage),
            )

    def test_safety_and_plugin_identity_tampering_are_rejected(self) -> None:
        safety_stage, safety_original = self.stage("unsafe-claim")
        safety_manifest = json.loads(json.dumps(safety_original))
        safety_manifest["safety"]["installPerformed"] = True
        self.rewrite_manifest(safety_stage, safety_manifest)
        with self.assertRaisesRegex(provenance.ProvenanceError, "safety contract"):
            provenance.verify_stage(
                safety_stage,
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(safety_stage),
            )

        plugin_stage, plugin_original = self.stage("rogue-plugin")
        plugin_path = plugin_stage / ".codex-plugin" / "plugin.json"
        plugin_value = json.loads(plugin_path.read_text(encoding="utf-8"))
        plugin_value["name"] = "rogue"
        plugin_path.write_text(
            json.dumps(plugin_value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        plugin_manifest = json.loads(json.dumps(plugin_original))
        records = provenance._stage_records(plugin_stage)
        plugin_manifest["stage"]["stagedPayloadSha256"] = provenance._payload_digest(records)
        self.rewrite_manifest(plugin_stage, plugin_manifest)
        with self.assertRaisesRegex(provenance.ProvenanceError, "plugin identity/version"):
            provenance.verify_stage(
                plugin_stage,
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(plugin_stage),
            )

    def test_private_paths_in_source_or_artifact_payload_are_rejected(self) -> None:
        private_home_path = str(Path.home().resolve() / "private" / "state")
        self.repo.write("scripts/private-path", f"config={private_home_path}\n")
        self.repo.commit("private source payload")
        with self.assertRaisesRegex(provenance.ProvenanceError, "private absolute path"):
            self.stage("private-source")

        self.repo.write("scripts/private-path", "public-safe\n")
        self.repo.commit("safe source payload")
        artifact = self.base / "private-artifact"
        artifact.write_text(f"embedded={self.base / 'build' / 'root'}\n", encoding="utf-8")
        artifact.chmod(0o755)
        with self.assertRaisesRegex(provenance.ProvenanceError, "private absolute path"):
            self.stage(
                "private-artifact-stage",
                artifacts=[provenance.ArtifactSpec("rust-cli", artifact, "bin/harvis")],
            )

    def test_output_guard_rejects_formal_cache_and_runtime_roots(self) -> None:
        protected_outputs = (
            Path.home() / ".codex" / "plugins" / "cache" / "harvis" / "phase0-stage",
            Path.home() / ".harvis" / "phase0-stage",
        )
        for output in protected_outputs:
            with self.subTest(output=output.name), self.assertRaisesRegex(
                provenance.ProvenanceError, "protected|formal"
            ):
                provenance.create_stage(
                    self.repo.root,
                    output,
                    allowlist=self.repo.allowlist,
                    source_date_epoch=1,
                    toolchain_override=self.toolchain,
                )
        stage, _ = self.stage("guarded-tar-source")
        with self.assertRaisesRegex(provenance.ProvenanceError, "protected|formal"):
            provenance.write_deterministic_tar(
                stage,
                protected_outputs[0] / "release.tar",
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(stage),
            )

    def test_manifest_private_path_and_schema_identity_are_strict(self) -> None:
        stage, original = self.stage("manifest-private")
        manifest = json.loads(json.dumps(original))
        manifest["toolchain"]["platform"]["release"] = "/private/var/folders/example"
        without_aggregate = dict(manifest["toolchain"])
        without_aggregate.pop("aggregateSha256")
        manifest["toolchain"]["aggregateSha256"] = provenance._sha256_bytes(
            provenance._canonical_json(without_aggregate)
        )
        self.rewrite_manifest(stage, manifest)
        with self.assertRaisesRegex(provenance.ProvenanceError, "private absolute path"):
            provenance.verify_stage(
                stage,
                source=self.repo.root,
                expected_provenance_sha256=self.provenance_sha256(stage),
            )

    def test_repository_schema_and_allowlist_are_valid_data(self) -> None:
        schema = json.loads(
            (PROJECT_ROOT / "schemas" / "release-provenance-v2.schema.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(schema["properties"]["schemaVersion"]["const"], provenance.SCHEMA_VERSION)
        self.assertEqual(schema["properties"]["source"]["properties"]["repositoryId"]["const"], "harvis")
        self.assertEqual(schema["properties"]["cache"]["properties"]["namespace"]["const"], "personal/harvis")
        self.assertTrue(schema["properties"]["safety"]["properties"]["normalizedMtime"]["const"])
        allowlist = (
            PROJECT_ROOT / "packaging" / "plugin-stage-allowlist-v1.txt"
        ).read_text(encoding="utf-8")
        self.assertIn(".codex-plugin/plugin.json", allowlist)
        self.assertIn("schemas/", allowlist)
        self.assertIn("apps/HarvisBar/SystemExtensions/", allowlist)
        candidate_paths = run(
            "git",
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            cwd=PROJECT_ROOT,
        ).splitlines()
        for line in allowlist.splitlines():
            entry = line.strip()
            if not entry or entry.startswith("#"):
                continue
            matched = any(
                path.startswith(entry) if entry.endswith("/") else path == entry
                for path in candidate_paths
            )
            self.assertTrue(matched, f"allowlist entry does not match a release candidate path: {entry}")


if __name__ == "__main__":
    unittest.main()
