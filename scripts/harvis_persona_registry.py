#!/usr/bin/env python3
"""H.A.R.V.I.S. Persona / Copy-Me registry and personality review queue."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PERSONA_REGISTRY_VERSION = "v0.18-alpha"
REVIEW_QUEUE_VERSION = "v0.19-alpha"
STORE_FILES = {
    "memory_vault": "memory-vaults.jsonl",
    "persona_card": "persona-cards.jsonl",
    "twin_instance": "twin-instances.jsonl",
    "personality_candidate": "personality-candidates.jsonl",
    "review_decision": "review-decisions.jsonl",
}
VALID_CANDIDATE_DECISIONS = {"accepted", "edited", "rejected", "reject_forever", "deferred"}
VALID_RUN_TOOL_PERMISSIONS = {"disabled", "approval_required", "read_only"}


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def timestamp_compact() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def resolve_workspace_root(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def registry_dir(root: Path) -> Path:
    path = root / ".harvis" / "persona"
    path.mkdir(parents=True, exist_ok=True)
    return path


def store_path(root: Path, store: str) -> Path:
    if store not in STORE_FILES:
        raise ValueError(f"unknown store: {store}")
    return registry_dir(root) / STORE_FILES[store]


def stable_id(prefix: str, value: str) -> str:
    clean = "".join(char.lower() if char.isalnum() else "-" for char in value).strip("-")
    clean = "-".join(part for part in clean.split("-") if part)[:42] or prefix
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]
    return f"{prefix}_{clean}_{digest}"


def event_id(prefix: str, *parts: object) -> str:
    digest = hashlib.sha256("|".join(str(part) for part in parts).encode("utf-8")).hexdigest()[:10]
    return f"{prefix}_{timestamp_compact()}_{digest}"


def append_jsonl(path: Path, item: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(item, sort_keys=True) + "\n")


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    items: list[dict[str, Any]] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    for line in lines:
        if not line.strip():
            continue
        try:
            loaded = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(loaded, dict):
            items.append(loaded)
    return items


def latest_by_key(items: list[dict[str, Any]], key: str) -> list[dict[str, Any]]:
    latest: dict[str, dict[str, Any]] = {}
    for item in items:
        value = item.get(key)
        if isinstance(value, str) and value:
            latest[value] = item
    return list(latest.values())


def list_store(root: Path, store: str, limit: int = 100, status: str | None = None) -> list[dict[str, Any]]:
    key = {
        "memory_vault": "vault_id",
        "persona_card": "persona_id",
        "twin_instance": "instance_id",
        "personality_candidate": "candidate_id",
        "review_decision": "decision_id",
    }[store]
    rows = latest_by_key(read_jsonl(store_path(root, store)), key)
    if status:
        rows = [row for row in rows if row.get("status") == status]
    return sorted(rows, key=lambda row: str(row.get("updated_at", row.get("created_at", ""))), reverse=True)[:limit]


def clamp_tone(value: object, fallback: int = 7) -> int:
    if isinstance(value, bool):
        return fallback
    if isinstance(value, int):
        return max(0, min(value, 10))
    if isinstance(value, str) and value.strip():
        try:
            return max(0, min(int(value), 10))
        except ValueError:
            return fallback
    return fallback


def append_record(root: Path, store: str, record: dict[str, Any]) -> dict[str, Any]:
    record = dict(record)
    record.setdefault("registry_version", PERSONA_REGISTRY_VERSION)
    record.setdefault("created_at", now_utc())
    record["updated_at"] = now_utc()
    append_jsonl(store_path(root, store), record)
    return record


def init_persona_registry(root: Path) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    registry_dir(root)
    for store in STORE_FILES:
        store_path(root, store).touch(exist_ok=True)
    if not list_store(root, "memory_vault", limit=1):
        create_memory_vault(root, "Default Memory Vault", "vault_default_me", owner="harzva")
    if not list_store(root, "persona_card", limit=1):
        create_persona_card(
            root,
            "Core Male Assistant",
            "persona_core_male_assistant",
            visual_asset_id="core_male_default",
            warmth=7,
            directness=7,
            detail=8,
        )
        create_persona_card(
            root,
            "Core Female Assistant",
            "persona_core_female_assistant",
            visual_asset_id="core_female_default",
            warmth=8,
            directness=6,
            detail=8,
        )
    if not list_store(root, "twin_instance", limit=1):
        create_twin_instance(
            root,
            "H.A.R.V.I.S. Default",
            "vault_default_me",
            "persona_core_male_assistant",
            "copyme_default_harvis",
        )
    return list_persona_state(root)


def create_memory_vault(root: Path, display_name: str, vault_id: str | None = None, owner: str = "harzva") -> dict[str, Any]:
    root = resolve_workspace_root(root)
    vault_id = vault_id or stable_id("vault", display_name)
    return append_record(
        root,
        "memory_vault",
        {
            "vault_id": vault_id,
            "display_name": display_name,
            "owner": owner,
            "status": "active",
            "visibility": "private",
            "sources": ["project", "conversation", "manual_input", "local_engineering"],
            "memory_items": 0,
            "last_synced_at": None,
        },
    )


def create_persona_card(
    root: Path,
    display_name: str,
    persona_id: str | None = None,
    base_template: str = "Default Me",
    visual_asset_id: str = "",
    warmth: int = 7,
    directness: int = 7,
    humor: int = 3,
    detail: int = 8,
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    persona_id = persona_id or stable_id("persona", display_name)
    return append_record(
        root,
        "persona_card",
        {
            "persona_id": persona_id,
            "display_name": display_name,
            "base_template": base_template,
            "visual_asset_id": visual_asset_id or persona_id,
            "status": "active",
            "tone": {
                "warmth": max(0, min(warmth, 10)),
                "directness": max(0, min(directness, 10)),
                "humor": max(0, min(humor, 10)),
                "detail": max(0, min(detail, 10)),
            },
            "decision_style": {
                "evidence_first": True,
                "risk_tolerance": "medium",
                "challenge_user": True,
                "prefer_verification": True,
            },
            "behavior_rules": [
                "Inspect context before acting.",
                "Mark uncertainty when evidence is incomplete.",
                "Prefer executable next steps over broad narration.",
            ],
            "new_traits_require_human_review": True,
        },
    )


def find_persona_card(root: Path, persona_id: str) -> dict[str, Any]:
    for persona in list_store(root, "persona_card", limit=1000):
        if persona.get("persona_id") == persona_id:
            return persona
    raise SystemExit(f"persona card not found: {persona_id}")


def update_persona_card(
    root: Path,
    persona_id: str,
    display_name: str | None = None,
    visual_asset_id: str | None = None,
    base_template: str | None = None,
    status: str | None = None,
    tone: dict[str, Any] | None = None,
    decision_style: dict[str, Any] | None = None,
    behavior_rules: list[str] | None = None,
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    current = find_persona_card(root, persona_id)
    updated = dict(current)
    if display_name is not None and display_name.strip():
        updated["display_name"] = display_name.strip()
    if visual_asset_id is not None:
        updated["visual_asset_id"] = visual_asset_id.strip()
    if base_template is not None and base_template.strip():
        updated["base_template"] = base_template.strip()
    if status is not None and status.strip():
        normalized_status = status.strip().lower()
        if normalized_status not in {"active", "draft", "archived", "disabled"}:
            raise SystemExit("status must be one of: active, draft, archived, disabled")
        updated["status"] = normalized_status
    if isinstance(tone, dict):
        existing_tone = updated.get("tone") if isinstance(updated.get("tone"), dict) else {}
        merged_tone = dict(existing_tone)
        for key in ["warmth", "directness", "humor", "detail", "encouragement", "criticism"]:
            if key in tone:
                merged_tone[key] = clamp_tone(tone.get(key), clamp_tone(existing_tone.get(key), 7))
        updated["tone"] = merged_tone
    if isinstance(decision_style, dict):
        existing_style = updated.get("decision_style") if isinstance(updated.get("decision_style"), dict) else {}
        merged_style = dict(existing_style)
        for key, value in decision_style.items():
            if isinstance(key, str) and key.strip():
                if isinstance(value, (bool, int, float, str)) or value is None:
                    merged_style[key.strip()] = value
        updated["decision_style"] = merged_style
    if behavior_rules is not None:
        rules = [rule.strip() for rule in behavior_rules if isinstance(rule, str) and rule.strip()]
        updated["behavior_rules"] = rules[:12]
    updated["new_traits_require_human_review"] = True
    return append_record(root, "persona_card", updated)


def default_twin_permissions() -> dict[str, Any]:
    return {
        "read_memory": True,
        "write_candidate_memory": True,
        "write_accepted_memory": False,
        "run_tools": "approval_required",
    }


def normalize_twin_permissions(value: dict[str, Any] | None) -> dict[str, Any]:
    permissions = default_twin_permissions()
    if not isinstance(value, dict):
        return permissions
    for key in ["read_memory", "write_candidate_memory", "write_accepted_memory"]:
        if key in value and isinstance(value.get(key), bool):
            permissions[key] = value[key]
    run_tools = value.get("run_tools")
    if isinstance(run_tools, str) and run_tools in VALID_RUN_TOOL_PERMISSIONS:
        permissions["run_tools"] = run_tools
    return permissions


def create_twin_instance(
    root: Path,
    display_name: str,
    memory_vault_id: str,
    persona_card_id: str,
    instance_id: str | None = None,
    overlay_memory_id: str | None = None,
    permissions: dict[str, Any] | None = None,
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    instance_id = instance_id or stable_id("copyme", display_name)
    return append_record(
        root,
        "twin_instance",
        {
            "instance_id": instance_id,
            "display_name": display_name,
            "memory_vault_id": memory_vault_id,
            "persona_card_id": persona_card_id,
            "overlay_memory_id": overlay_memory_id,
            "status": "running",
            "permissions": normalize_twin_permissions(permissions),
        },
    )


def create_personality_candidate(
    root: Path,
    trait: str,
    target_persona_id: str,
    source_type: str = "manual",
    source_refs: list[str] | None = None,
    trait_type: str = "decision_style",
    confidence: float = 0.5,
    stability: str = "observed_once",
    risk: str = "low",
    suggested_action: str = "review",
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    if not trait.strip():
        raise SystemExit("trait is required")
    candidate_id = event_id("pc", target_persona_id, trait)
    return append_record(
        root,
        "personality_candidate",
        {
            "review_queue_version": REVIEW_QUEUE_VERSION,
            "candidate_id": candidate_id,
            "target_persona_id": target_persona_id,
            "source_type": source_type,
            "source_refs": source_refs or [],
            "trait": trait.strip(),
            "trait_type": trait_type,
            "confidence": max(0.0, min(float(confidence), 1.0)),
            "stability": stability,
            "risk": risk,
            "suggested_action": suggested_action,
            "status": "pending_review",
        },
    )


def find_candidate(root: Path, candidate_id: str) -> dict[str, Any]:
    for candidate in list_store(root, "personality_candidate", limit=1000):
        if candidate.get("candidate_id") == candidate_id:
            return candidate
    raise SystemExit(f"personality candidate not found: {candidate_id}")


def decide_personality_candidate(
    root: Path,
    candidate_id: str,
    decision: str,
    decided_by: str = "human",
    notes: str = "",
    edited_trait: str = "",
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    decision = decision.strip().lower()
    if decision not in VALID_CANDIDATE_DECISIONS:
        raise SystemExit(f"decision must be one of: {', '.join(sorted(VALID_CANDIDATE_DECISIONS))}")
    candidate = find_candidate(root, candidate_id)
    status = "pending_review" if decision == "deferred" else decision
    updated = dict(candidate)
    updated["status"] = status
    if edited_trait.strip():
        updated["trait"] = edited_trait.strip()
        updated["edited"] = True
    append_record(root, "personality_candidate", updated)
    decision_record = append_record(
        root,
        "review_decision",
        {
            "review_queue_version": REVIEW_QUEUE_VERSION,
            "decision_id": event_id("pdec", candidate_id, decision),
            "candidate_id": candidate_id,
            "decision": decision,
            "decided_by": decided_by,
            "notes": notes.strip(),
            "status_after": status,
        },
    )
    return {
        "candidate": updated,
        "decision": decision_record,
    }


def list_persona_state(root: Path, limit: int = 100) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    return {
        "persona_registry_version": PERSONA_REGISTRY_VERSION,
        "review_queue_version": REVIEW_QUEUE_VERSION,
        "workspace": {"label": root.name or "workspace"},
        "memory_vaults": list_store(root, "memory_vault", limit),
        "persona_cards": list_store(root, "persona_card", limit),
        "twin_instances": list_store(root, "twin_instance", limit),
        "personality_candidates": list_store(root, "personality_candidate", limit),
        "pending_personality_review": list_store(root, "personality_candidate", limit, status="pending_review"),
    }


def print_json(data: Any) -> None:
    print(json.dumps(data, indent=2, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage H.A.R.V.I.S. Persona / Copy-Me registry.")
    parser.add_argument("--root", default=".", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("init")

    list_parser = subparsers.add_parser("list")
    list_parser.add_argument("--limit", type=int, default=100)

    vault_parser = subparsers.add_parser("create-vault")
    vault_parser.add_argument("--display-name", required=True)
    vault_parser.add_argument("--vault-id", default="")

    persona_parser = subparsers.add_parser("create-persona")
    persona_parser.add_argument("--display-name", required=True)
    persona_parser.add_argument("--persona-id", default="")
    persona_parser.add_argument("--visual-asset-id", default="")

    update_persona_parser = subparsers.add_parser("update-persona")
    update_persona_parser.add_argument("--persona-id", required=True)
    update_persona_parser.add_argument("--display-name", default="")
    update_persona_parser.add_argument("--visual-asset-id", default="")
    update_persona_parser.add_argument("--base-template", default="")
    update_persona_parser.add_argument("--status", default="")
    update_persona_parser.add_argument("--warmth", type=int, default=-1)
    update_persona_parser.add_argument("--directness", type=int, default=-1)
    update_persona_parser.add_argument("--humor", type=int, default=-1)
    update_persona_parser.add_argument("--detail", type=int, default=-1)
    update_persona_parser.add_argument("--behavior-rule", action="append", default=[])

    twin_parser = subparsers.add_parser("create-twin")
    twin_parser.add_argument("--display-name", required=True)
    twin_parser.add_argument("--memory-vault-id", required=True)
    twin_parser.add_argument("--persona-card-id", required=True)
    twin_parser.add_argument("--instance-id", default="")

    candidate_parser = subparsers.add_parser("create-candidate")
    candidate_parser.add_argument("--trait", required=True)
    candidate_parser.add_argument("--target-persona-id", required=True)
    candidate_parser.add_argument("--source-type", default="manual")
    candidate_parser.add_argument("--trait-type", default="decision_style")
    candidate_parser.add_argument("--confidence", type=float, default=0.5)

    decide_parser = subparsers.add_parser("decide-candidate")
    decide_parser.add_argument("--candidate-id", required=True)
    decide_parser.add_argument("--decision", required=True)
    decide_parser.add_argument("--decided-by", default="human")
    decide_parser.add_argument("--notes", default="")
    decide_parser.add_argument("--edited-trait", default="")

    args = parser.parse_args()
    root = resolve_workspace_root(args.root)
    if args.command == "init":
        print_json(init_persona_registry(root))
        return 0
    if args.command == "list":
        print_json(list_persona_state(root, args.limit))
        return 0
    if args.command == "create-vault":
        print_json(create_memory_vault(root, args.display_name, args.vault_id or None))
        return 0
    if args.command == "create-persona":
        print_json(create_persona_card(root, args.display_name, args.persona_id or None, visual_asset_id=args.visual_asset_id))
        return 0
    if args.command == "update-persona":
        tone = {
            key: value
            for key, value in {
                "warmth": args.warmth,
                "directness": args.directness,
                "humor": args.humor,
                "detail": args.detail,
            }.items()
            if value >= 0
        }
        print_json(
            update_persona_card(
                root,
                args.persona_id,
                display_name=args.display_name or None,
                visual_asset_id=args.visual_asset_id,
                base_template=args.base_template or None,
                status=args.status or None,
                tone=tone or None,
                behavior_rules=args.behavior_rule or None,
            )
        )
        return 0
    if args.command == "create-twin":
        print_json(create_twin_instance(root, args.display_name, args.memory_vault_id, args.persona_card_id, args.instance_id or None))
        return 0
    if args.command == "create-candidate":
        print_json(
            create_personality_candidate(
                root,
                args.trait,
                args.target_persona_id,
                source_type=args.source_type,
                trait_type=args.trait_type,
                confidence=args.confidence,
            )
        )
        return 0
    if args.command == "decide-candidate":
        print_json(decide_personality_candidate(root, args.candidate_id, args.decision, args.decided_by, args.notes, args.edited_trait))
        return 0
    return 1


def rust_persona_argv(argv: list[str]) -> list[str]:
    from harvis_rust_shim import split_leading_options

    global_args, rest = split_leading_options(argv, value_options={"--root"})
    if not rest:
        return ["persona", *global_args, "list"]
    command, *tail = rest
    command = {
        "create-persona": "create-card",
        "update-persona": "update-card",
    }.get(command, command)

    mapped_tail: list[str] = []
    iterator = iter(tail)
    for item in iterator:
        if item == "--trait":
            mapped_tail.append("--trait-text")
            mapped_tail.append(next(iterator, ""))
        elif item.startswith("--trait="):
            mapped_tail.append(f"--trait-text={item.split('=', 1)[1]}")
        else:
            mapped_tail.append(item)
    return ["persona", *global_args, command, *mapped_tail]


if __name__ == "__main__":
    import sys

    from harvis_rust_shim import exec_harvis, use_legacy_python_entrypoint

    if use_legacy_python_entrypoint():
        raise SystemExit(main())
    raise SystemExit(exec_harvis(rust_persona_argv(sys.argv[1:])))
