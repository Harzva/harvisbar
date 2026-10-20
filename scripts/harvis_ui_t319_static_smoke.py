#!/usr/bin/env python3
"""Static contract smoke for the T319 operator-experience upgrade."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FILES = {
    name: (ROOT / path).read_text(encoding="utf-8")
    for name, path in {
        "studio_html": "studio/index.html",
        "studio_js": "studio/studio.js",
        "panel_html": "panel/index.html",
        "panel_js": "panel/panel.js",
        "mobile_html": "studio/mobile.html",
        "mobile_js": "studio/mobile.js",
        "operator_js": "ui/operator.js",
        "operator_css": "ui/operator.css",
        "routes": "crates/harvis-http/src/routes.rs",
        "auth": "crates/harvis-http/src/auth.rs",
    }.items()
}

errors: list[str] = []
checks = 0


def require(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if not condition:
        errors.append(message)


def contains(source: str, needle: str, message: str) -> None:
    require(needle in FILES[source], message)


nav_labels = re.findall(r'<button class="nav-item[^>]*>([^<]+)</button>', FILES["studio_html"])
require(nav_labels == ["Overview", "Work", "Decisions", "Knowledge", "Persona", "Integrations", "Settings"], "operator IA labels/order changed")
require(FILES["studio_html"].count('class="nav-item') == 7, "operator IA must expose exactly seven primary items")

for name in ["loading", "empty", "error", "blocked", "permission", "approval", "success"]:
    contains("operator_js", f'"{name}"', f"missing stable {name} fixture")
for surface in ["studio_html", "panel_html", "mobile_html"]:
    contains(surface, "/ui/operator.css", f"{surface} does not load shared operator CSS")
    contains(surface, "/ui/operator.js", f"{surface} does not load shared operator JS")
    contains(surface, "data-ui-state", f"{surface} lacks semantic UI state")

for surface in ["studio_html", "panel_html", "mobile_html"]:
    contains(surface, "op-next-action", f"{surface} lacks a next-safe-action card")
    contains(surface, "op-lineage", f"{surface} lacks explicit lineage")

contains("studio_html", "aria-current=\"page\"", "active operator nav lacks aria-current")
contains("studio_html", "operatorConfirmDialog", "Studio lacks native confirmation dialog")
contains("panel_html", "panelConfirmDialog", "Panel lacks native confirmation dialog")
contains("panel_html", "panel-diagnostics", "Panel raw diagnostics are not disclosed separately")
contains("panel_html", "panel-controls-detail", "Panel controls are not disclosed separately")
contains("panel_js", 'confirmAction("scan"', "Scan can mutate packet state and must be confirmed")
for action in ["tick", "snapshot", "workbench"]:
    contains("panel_js", f'confirmAction("{action}"', f"Panel {action} lacks confirmation")

for section in ["mobile-session-detail", "Pins", "Timeline", "Bindings", "Lark callbacks", "Diagnostics"]:
    contains("mobile_html", section, f"mobile default-fold section missing: {section}")
contains("mobile_js", "pending.slice(0, 3)", "mobile approval list is not capped at three")
contains("mobile_html", "mobile-six", "mobile six-question summary missing")
contains("mobile_js", "Redacted conversation", "mobile bindings are not redacted")
contains("mobile_js", "identifiers hidden", "mobile callback identifiers are not explicitly hidden")
require(not re.search(r'firstText\([^\n]+\[(?:"chat_id"|"message_id")', FILES["mobile_js"]), "mobile renders raw Lark identifiers")
contains("studio_js", 'pin.label || "Redacted Codex pin"', "Studio Codex pins can expose raw thread/session identifiers")
require(not re.search(r'item\(pin\.label \|\| (?:thread|pin\.codex_(?:thread|session)_id)', FILES["studio_js"]), "Studio renders a raw Codex thread/session identifier")

contains("routes", '.route("/ui/integrations", get(ui_integrations_get))', "safe integration evidence route missing")
contains("auth", 'assert!(!endpoint_is_public("/ui/integrations"))', "integration evidence endpoint must remain protected")
for field in ["profile_role", "listener_health", "last_card_action_age_seconds", "duplicate_guard", "scope_status", "membership_status", "evidence_mode", "live_complete", "source_commit"]:
    contains("routes", f'"{field}"', f"integration evidence omits {field}")
contains("studio_html", "Last card action", "Lark action age label is ambiguous")
contains("studio_js", "pending owner confirmation", "listener reachability is conflated with live E2E")
contains("mobile_js", "在线·待验", "mobile reachability is conflated with business verification")

contains("operator_css", ":focus-visible", "shared focus-visible styling missing")
contains("operator_css", "overflow-wrap", "shared cards do not guard long text")
contains("studio_js", "statusIsBlocked", "Studio lacks blocked-state derivation")
contains("studio_js", "runLimitedRequests(requests, 3)", "Studio refresh can saturate the resident runtime with unbounded request fan-out")
contains("panel_js", "explicitLineage", "Panel lacks explicit lineage resolution")
contains("mobile_js", "explicitLineage", "Mobile lacks explicit lineage resolution")

for script in ["ui/operator.js", "studio/studio.js", "panel/panel.js", "studio/mobile.js"]:
    result = subprocess.run(["node", "--check", str(ROOT / script)], capture_output=True, text=True)
    require(result.returncode == 0, f"JavaScript syntax failed for {script}: {result.stderr.strip()}")

print(json.dumps({"ok": not errors, "smoke": "harvis_ui_t319_static", "checks": checks, "errors": errors}, ensure_ascii=False))
raise SystemExit(0 if not errors else 1)
