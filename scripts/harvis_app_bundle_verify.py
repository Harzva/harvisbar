#!/usr/bin/env python3
"""Read-only verifier for a Harvis macOS app bundle and its external provenance."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harvis_app_bundle_contract import (
    AppBundleContractError,
    load_provenance_contract,
    verify_bundle,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="Packaged .app to verify without modifying it.")
    parser.add_argument("--source", required=True, help="Clean Harvis Git repository root.")
    parser.add_argument("--provenance-stage", required=True, help="Verified release stage directory.")
    parser.add_argument(
        "--provenance-sha256",
        required=True,
        help="External SHA-256 trust anchor for release-provenance-v2.json.",
    )
    parser.add_argument("--variant", required=True, choices=("bar", "desktop"))
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--executable", required=True)
    parser.add_argument(
        "--codesign-policy",
        required=True,
        choices=("required", "skip"),
        help="Use required for packaged apps; skip is only for unsigned test fixtures.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        contract = load_provenance_contract(
            Path(args.provenance_stage),
            Path(args.source),
            args.provenance_sha256,
        )
        receipt = verify_bundle(
            Path(args.app),
            contract,
            variant=args.variant,
            expected_bundle_id=args.bundle_id,
            expected_version=args.version,
            expected_executable=args.executable,
            codesign_policy=args.codesign_policy,
        )
    except (AppBundleContractError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "cacheKey": receipt["provenance"]["cacheKey"],
                "ok": True,
                "payloadSha256": receipt["payload"]["sha256"],
                "provenanceSha256": receipt["provenance"]["sha256"],
                "schemaVersion": receipt["schemaVersion"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
