#!/usr/bin/env python3
"""Generate a public-safe HarvisBar release manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def codesign_summary(path: Path) -> dict[str, Any]:
    try:
        result = subprocess.run(
            ["/usr/bin/codesign", "-dv", "--verbose=2", str(path)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except OSError:
        return {"checked": False, "signed": False, "identity": "codesign unavailable"}

    text = result.stdout
    signed = "Signature=" in text or "Authority=" in text
    identity = "unknown"
    for line in text.splitlines():
        if line.startswith("Authority="):
            identity = line.split("=", 1)[1].strip()
            break
        if line.startswith("Signature="):
            identity = line.split("=", 1)[1].strip()
    return {
        "checked": True,
        "signed": signed,
        "identity": identity,
        "developerId": "Developer ID Application" in text,
        "adhoc": "adhoc" in text.lower(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", required=True, help="DMG or ZIP artifact path.")
    parser.add_argument("--version", required=True)
    parser.add_argument("--channel", default="local")
    parser.add_argument("--output", default="")
    parser.add_argument("--notarized", action="store_true")
    args = parser.parse_args()

    artifact = Path(args.artifact).expanduser()
    if not artifact.is_absolute():
        artifact = Path.cwd() / artifact
    if not artifact.exists():
        raise SystemExit(f"artifact not found: {artifact}")
    output = Path(args.output).expanduser() if args.output else artifact.with_suffix(artifact.suffix + ".json")
    if not output.is_absolute():
        output = Path.cwd() / output

    manifest = {
        "schemaVersion": "harvis.bar.release-manifest.v0",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "product": "HarvisBar",
        "version": args.version,
        "channel": args.channel,
        "artifact": {
            "fileName": artifact.name,
            "type": artifact.suffix.lstrip("."),
            "sizeBytes": artifact.stat().st_size,
            "sha256": sha256(artifact),
        },
        "distribution": {
            "notarized": bool(args.notarized),
            "safeForPublicMetadata": True,
            "includesSecrets": False,
            "includesRawMemory": False,
            "includesWorkspaceData": False,
            "codesign": codesign_summary(artifact),
        },
    }
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"HarvisBar release manifest written: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
