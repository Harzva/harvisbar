#!/usr/bin/env python3
"""Keep local HarvisBar upgrades on a pinned, certificate-backed identity.

Private keys live in Keychain, never in the repository or release payload.
This does not grant TCC permissions, trust roots, or notarize local packages.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import ssl
import subprocess
import sys

BUNDLE_ID = "local.harzva.harvisbar"


class SigningError(ValueError):
    pass


def config_path() -> Path:
    return Path.home() / "Library/Application Support/Harvis/signing/local-signing.json"


def load_config(path: Path | None = None) -> dict | None:
    path = path or config_path()
    if not path.exists() and not path.is_symlink():
        return None
    if path.is_symlink() or not path.is_file():
        raise SigningError("Local signing configuration is not a regular file")
    metadata = path.stat()
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
        raise SigningError("Local signing configuration has unsafe ownership or permissions")
    try:
        value = json.loads(path.read_text())
        if value["schemaVersion"] != 1 or value["bundleIdentifiers"] != [BUNDLE_ID]:
            raise ValueError()
        sha1, sha256 = value["certificateSha1"], value["certificateSha256"]
        if not re.fullmatch(r"[A-F0-9]{40}", sha1) or not re.fullmatch(r"[a-f0-9]{64}", sha256):
            raise ValueError()
        cert = Path(value["certificatePath"])
        if not cert.is_absolute() or cert.is_symlink() or not cert.is_file():
            raise ValueError()
        der = ssl.PEM_cert_to_DER_cert(cert.read_text())
        if hashlib.sha1(der).hexdigest().upper() != sha1 or hashlib.sha256(der).hexdigest() != sha256:
            raise ValueError()
        return value
    except (KeyError, TypeError, ValueError, OSError) as exc:
        raise SigningError("Local signing configuration/certificate is invalid; refusing identity fallback") from exc


def resolve(identity: str, config: dict | None) -> str:
    if config:
        if identity not in {"auto", config["certificateSha1"], config["name"]}:
            raise SigningError("Pinned HarvisBar identity exists; refusing an ad-hoc or different signer")
        return config["certificateSha1"]
    if identity == "auto":
        raise SigningError("No pinned local signing identity; configure it or explicitly request an ad-hoc test candidate")
    if not identity:
        raise SigningError("Signing identity is empty")
    return identity


def requirement(config: dict) -> str:
    return f'identifier "{BUNDLE_ID}" and certificate leaf = H"{config["certificateSha1"].lower()}"'


def run(argv: list[str]) -> None:
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode:
        # Never print private key material or command environments.
        raise SigningError(result.stderr.strip() or "Code signing failed")


def verify(app: Path, config: dict) -> None:
    run(["/usr/bin/codesign", "--verify", "--strict", "--test-requirement", "=" + requirement(config), str(app)])
    result = subprocess.run(["/usr/bin/codesign", "-d", "-r-", str(app)], capture_output=True, text=True, check=True)
    expected = "designated => " + requirement(config)
    if expected not in result.stdout.splitlines():
        raise SigningError("App does not preserve the explicit pinned designated requirement")


def sign(app: Path, entitlements: Path, identity: str, config: dict | None) -> None:
    identity = resolve(identity, config)
    if config:
        with (app / "Contents/Info.plist").open("rb") as handle:
            if plistlib.load(handle).get("CFBundleIdentifier") != BUNDLE_ID:
                raise SigningError("Pinned identity is scoped to HarvisBar")
        run(["/usr/bin/codesign", "--force", "--timestamp=none", "--sign", identity,
             "--requirements", "=designated => " + requirement(config),
             "--entitlements", str(entitlements), str(app)])
        verify(app, config)
    elif identity == "-":
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)])
    else:
        run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity,
             "--entitlements", str(entitlements), str(app)])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["resolve", "mode", "sign", "verify"])
    parser.add_argument("--identity", default="auto")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--entitlements", type=Path)
    args = parser.parse_args()
    try:
        config = load_config()
        identity = resolve(args.identity, config)
        if args.action == "resolve":
            print(identity)
        elif args.action == "mode":
            print("local-certificate" if config else "adhoc" if identity == "-" else "developer")
        elif args.action == "verify":
            if not args.app:
                raise SigningError("--app is required")
            if config:
                verify(args.app, config)
        else:
            if not args.app or not args.entitlements:
                raise SigningError("--app and --entitlements are required")
            sign(args.app, args.entitlements, identity, config)
    except (SigningError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"ERROR: {exc}\n")


if __name__ == "__main__":
    main()
