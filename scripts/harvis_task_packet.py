#!/usr/bin/env python3
"""Create a deterministic H.A.R.V.I.S. work packet from a user request."""

from __future__ import annotations

import argparse
import textwrap


def build_packet(request: str, scope: str) -> str:
    cleaned_request = " ".join(request.split())
    cleaned_scope = " ".join(scope.split())
    return textwrap.dedent(
        f"""\
        **H.A.R.V.I.S. Work Packet**
        Goal: {cleaned_request}
        Scope: {cleaned_scope}
        Inputs: user request plus current Codex workspace context
        Risks: privacy boundaries, destructive operations, stale facts, ambiguous scope
        Plan:
        1. Read local project rules and relevant docs.
        2. Identify the smallest safe next action and execute or ask one focused question.
        3. Verify the result and report files touched, checks run, and follow-ups.
        Done When: the requested work has a verified result or a clear handoff.
        """
    ).strip()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a H.A.R.V.I.S. markdown work packet."
    )
    parser.add_argument("request", help="The delegated @harvis request.")
    parser.add_argument(
        "--scope",
        default="current Codex workspace",
        help="Workspace, repository, thread, or channel boundary.",
    )
    args = parser.parse_args()
    print(build_packet(args.request, args.scope))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
