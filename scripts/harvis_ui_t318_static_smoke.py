#!/usr/bin/env python3
"""Static T318 security, accessibility, and responsive contract smoke."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


SURFACES = {
    "studio": ("studio/index.html", "studio/studio.js"),
    "mobile": ("studio/mobile.html", "studio/mobile.js"),
    "roundtable": ("studio/roundtable.html", "studio/roundtable.html"),
    "panel": ("panel/index.html", "panel/panel.js"),
    "presence": ("presence/index.html", "presence/presence.js"),
}

FORBIDDEN = {
    "credential_from_location": re.compile(
        r"(?:searchParams|hashParams|params)\s*\.\s*get\s*\(\s*['\"](?:token|bearer|authorization|access_token|root|profile_root)['\"]"
    ),
    "credential_or_root_storage": re.compile(
        r"(?:localStorage|sessionStorage)\s*\.\s*(?:getItem|setItem)\s*\(\s*['\"][^'\"]*(?:token|bearer|root)[^'\"]*['\"]",
        re.IGNORECASE,
    ),
    "credential_in_url_builder": re.compile(r"[?&#](?:token|bearer|authorization|access_token)=", re.IGNORECASE),
}


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def run(root: Path) -> dict[str, object]:
    errors: list[str] = []
    checks = 0
    runtime_path = root / "ui/runtime.js"
    tokens_path = root / "ui/tokens.css"
    require(runtime_path.is_file(), "missing ui/runtime.js", errors)
    require(tokens_path.is_file(), "missing ui/tokens.css", errors)
    if errors:
        return {"ok": False, "checks": checks, "errors": errors}

    runtime = runtime_path.read_text(encoding="utf-8")
    tokens = tokens_path.read_text(encoding="utf-8")
    for marker in [
        'fetch("/ui/bootstrap"',
        'url.searchParams.delete(key)',
        'url.hash = ""',
        'token_included !== false',
        "applyWorkspaceLabel",
        "bearerHeaders",
    ]:
        checks += 1
        require(marker in runtime, f"runtime bootstrap missing marker: {marker}", errors)

    for marker in [
        "--harvis-touch: 44px",
        ":focus-visible",
        "overflow-x: clip",
        "@media (max-width: 430px)",
        "prefers-reduced-motion",
        '--harvis-verified',
        '--harvis-blocked',
    ]:
        checks += 1
        require(marker in tokens, f"shared tokens missing marker: {marker}", errors)

    all_static = runtime + "\n" + tokens
    for name, (html_rel, js_rel) in SURFACES.items():
        html_path = root / html_rel
        js_path = root / js_rel
        checks += 2
        require(html_path.is_file(), f"{name}: missing HTML", errors)
        require(js_path.is_file(), f"{name}: missing script", errors)
        if not html_path.is_file() or not js_path.is_file():
            continue
        html = html_path.read_text(encoding="utf-8")
        script = js_path.read_text(encoding="utf-8")
        all_static += "\n" + html + "\n" + script

        for marker, label in [
            ('<main', "main landmark"),
            ('/ui/tokens.css', "shared design tokens"),
            ('/ui/runtime.js', "trusted runtime bootstrap"),
            ('placeholder="Runtime workspace"', "redacted workspace label"),
        ]:
            checks += 1
            require(marker in html, f"{name}: missing {label}", errors)

        checks += 1
        require("HarvisRuntime.bootstrap()" in script, f"{name}: bootstrap not consumed", errors)
        checks += 1
        require("localStorage" not in script and "sessionStorage" not in script, f"{name}: browser storage remains", errors)
        checks += 1
        require("aria-label" in html or "<label" in html, f"{name}: controls lack accessible labels", errors)

    for label, pattern in FORBIDDEN.items():
        checks += 1
        match = pattern.search(all_static)
        require(match is None, f"forbidden {label} pattern remains", errors)

    routes = (root / "crates/harvis-http/src/routes.rs").read_text(encoding="utf-8")
    auth = (root / "crates/harvis-http/src/auth.rs").read_text(encoding="utf-8")
    service = (root / "crates/harvis-macos/src/service_manager.rs").read_text(encoding="utf-8")
    for marker, source, label in [
        ('route("/ui/bootstrap"', routes, "bootstrap route"),
        ("loopback_required", routes, "non-loopback refusal"),
        ('"token_included": false', routes, "credential-free response"),
        ('endpoint == "/ui/bootstrap"', auth, "bootstrap auth policy"),
        ('"--root".to_string()', service, "trusted LaunchAgent root"),
    ]:
        checks += 1
        require(marker in source, f"server missing {label}", errors)

    for script in ["ui/runtime.js", "studio/studio.js", "studio/mobile.js", "panel/panel.js", "presence/presence.js"]:
        checks += 1
        result = subprocess.run(["node", "--check", str(root / script)], capture_output=True, text=True, check=False)
        require(result.returncode == 0, f"JavaScript syntax failed: {script}", errors)

    checks += 1
    runtime_unit = subprocess.run(
        ["node", str(root / "scripts/harvis_ui_runtime_unit_smoke.mjs")],
        capture_output=True,
        text=True,
        check=False,
    )
    require(runtime_unit.returncode == 0, "runtime URL/path redaction fixture failed", errors)

    return {
        "ok": not errors,
        "smoke": "harvis_ui_t318_static",
        "checks": checks,
        "surfaces": len(SURFACES),
        "viewports": [390, 430, 768, 1440],
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    payload = run(args.plugin_root.resolve())
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
