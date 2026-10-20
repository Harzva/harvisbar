#!/usr/bin/env python3
"""Verify a WeChat Official Account draft by media_id without exposing secrets.

This records API-level evidence that the draft media_id can be fetched from
WeChat and summarizes only safe metadata. For Harvis Lark smoke runs, this is
the completion proof that a draft exists in the official-account draft box.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TOKEN_URL = "https://api.weixin.qq.com/cgi-bin/token"
DRAFT_GET_URL = "https://api.weixin.qq.com/cgi-bin/draft/get"


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, raw = stripped.split("=", 1)
        key = key.strip()
        if not key:
            continue
        try:
            parsed = shlex.split(raw.strip(), posix=True)
            value = parsed[0] if parsed else ""
        except ValueError:
            value = raw.strip().strip("\"'")
        values[key] = value
    return values


def http_json(method: str, url: str, payload: dict[str, Any] | None = None, timeout: int = 30) -> dict[str, Any]:
    data = None
    headers = {"User-Agent": "harvis-draft-verify/1.0"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode("utf-8", errors="replace")
    value = json.loads(body)
    return value if isinstance(value, dict) else {"raw": value}


def summarize_draft(response: dict[str, Any]) -> dict[str, Any]:
    items = response.get("news_item") if isinstance(response.get("news_item"), list) else []
    summarized_items = []
    image_url_count = 0
    for item in items:
        if not isinstance(item, dict):
            continue
        content = str(item.get("content") or "")
        image_url_count += content.count("mmbiz.qpic.cn")
        summarized_items.append(
            {
                "title": item.get("title"),
                "digest": item.get("digest"),
                "thumb_media_id_present": bool(item.get("thumb_media_id")),
                "content_length": len(content),
                "content_mmbiz_image_refs": content.count("mmbiz.qpic.cn"),
                "url_present": bool(item.get("url")),
            }
        )
    return {
        "item_count": len(summarized_items),
        "items": summarized_items,
        "content_mmbiz_image_refs": image_url_count,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media-id", required=True)
    parser.add_argument(
        "--env-file",
        default=os.environ.get("HARVIS_WECHAT_ENV_FILE", "~/.config/harvis/wechat.env"),
    )
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout-seconds", type=int, default=30)
    args = parser.parse_args()

    env_file = Path(args.env_file).expanduser()
    env_values = load_env_file(env_file)
    appid = os.environ.get("WECHAT_APPID") or env_values.get("WECHAT_APPID")
    secret = os.environ.get("WECHAT_SECRET") or env_values.get("WECHAT_SECRET")
    output = Path(args.output).expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)

    result: dict[str, Any] = {
        "schemaVersion": "harvis.wechat-draft-verify.v0",
        "checked_at": utc_now(),
        "media_id": args.media_id,
        "env_file_configured": bool(args.env_file),
        "api": "draft/get",
        "success": False,
        "status": "not_started",
        "retryable": False,
    }
    if not appid or not secret:
        result.update(
            {
                "status": "missing_credentials",
                "reason": "WECHAT_APPID or WECHAT_SECRET is not available in the approved local environment.",
                "retryable": True,
            }
        )
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False))
        return 2

    try:
        token_query = urllib.parse.urlencode(
            {
                "grant_type": "client_credential",
                "appid": appid,
                "secret": secret,
            }
        )
        token = http_json("GET", f"{TOKEN_URL}?{token_query}", timeout=args.timeout_seconds)
        access_token = token.get("access_token")
        if not access_token:
            errcode = token.get("errcode")
            result.update(
                {
                    "status": "token_failed",
                    "errcode": errcode,
                    "errmsg": token.get("errmsg"),
                    "retryable": errcode in {45009, 45011, 89503, 89506},
                }
            )
            output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(result, ensure_ascii=False))
            return 1
        draft = http_json(
            "POST",
            f"{DRAFT_GET_URL}?access_token={urllib.parse.quote(str(access_token))}",
            {"media_id": args.media_id},
            timeout=args.timeout_seconds,
        )
        if draft.get("errcode"):
            result.update(
                {
                    "status": "draft_get_failed",
                    "errcode": draft.get("errcode"),
                    "errmsg": draft.get("errmsg"),
                    "retryable": draft.get("errcode") in {40001, 42001, 45009, 45011, 89503, 89506},
                }
            )
            output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(result, ensure_ascii=False))
            return 1
        summary = summarize_draft(draft)
        result.update(
            {
                "success": True,
                "status": "draft_get_ok",
                "draft_box_api_verified": True,
                "summary": summary,
            }
        )
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (urllib.error.URLError, TimeoutError) as exc:
        result.update({"status": "network_error", "reason": str(exc), "retryable": True})
    except Exception as exc:
        result.update({"status": "verify_failed", "reason": str(exc), "retryable": False})
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
