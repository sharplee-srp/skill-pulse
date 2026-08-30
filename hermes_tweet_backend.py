#!/usr/bin/env python3
"""Hermes Tweet / Xquik fetch adapter for skill-pulse."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

DEFAULT_BASE_URL = "https://xquik.com"


class HermesTweetError(Exception):
    """Raised when the Hermes Tweet backend cannot fetch results."""


def get_api_key() -> str:
    """Read an API key from supported environment variables."""
    return os.getenv("XQUIK_API_KEY") or os.getenv("HERMES_TWEET_API_KEY") or ""


def get_base_url() -> str:
    """Read the configured Xquik base URL."""
    return os.getenv("XQUIK_BASE_URL", DEFAULT_BASE_URL).rstrip("/")


def build_headers(api_key: str) -> dict[str, str]:
    """Build headers accepted by Xquik."""
    if not api_key:
        raise HermesTweetError("XQUIK_API_KEY is required for Hermes Tweet backend.")
    headers = {"User-Agent": "skill-pulse/hermes-tweet"}
    if api_key.startswith("xq_"):
        headers["x-api-key"] = api_key
    else:
        headers["Authorization"] = f"Bearer {api_key}"
    return headers


def build_url(path: str, params: dict[str, Any] | None = None) -> str:
    """Build a Xquik API URL."""
    query = urllib.parse.urlencode({k: v for k, v in (params or {}).items() if v not in (None, "")})
    return f"{get_base_url()}{path}" + (f"?{query}" if query else "")


def request_json(path: str, params: dict[str, Any] | None = None) -> Any:
    """Fetch JSON from Xquik."""
    request = urllib.request.Request(
        build_url(path, params),
        headers=build_headers(get_api_key()),
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def first_present(mapping: dict[str, Any], keys: list[str], default: Any = "") -> Any:
    """Return the first non-empty mapping value."""
    for key in keys:
        value = mapping.get(key)
        if value not in (None, ""):
            return value
    return default


def to_int(value: Any) -> int:
    """Parse numeric counters from API payloads."""
    try:
        return int(str(value or 0).replace(",", ""))
    except ValueError:
        return 0


def extract_items(payload: Any) -> list[dict[str, Any]]:
    """Extract tweet rows from common response envelopes."""
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if not isinstance(payload, dict):
        return []
    for key in ("tweets", "items", "results"):
        value = payload.get(key)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
    data = payload.get("data")
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    if isinstance(data, dict):
        nested = extract_items(data)
        return nested or [data]
    return []


def normalize_author(raw: Any) -> dict[str, Any]:
    """Normalize author data for track.sh's existing parser."""
    if not isinstance(raw, dict):
        return {"username": str(raw or ""), "name": ""}
    legacy = raw.get("legacy") if isinstance(raw.get("legacy"), dict) else {}
    return {
        "username": str(first_present(raw, ["username", "screen_name", "handle"], legacy.get("screen_name", ""))),
        "name": str(first_present(raw, ["name", "display_name"], legacy.get("name", ""))),
    }


def normalize_tweet(raw: dict[str, Any]) -> dict[str, Any]:
    """Normalize Xquik tweet data into the raw shape track.sh already accepts."""
    legacy = raw.get("legacy") if isinstance(raw.get("legacy"), dict) else {}
    metrics = raw.get("public_metrics") if isinstance(raw.get("public_metrics"), dict) else {}
    core = raw.get("core") if isinstance(raw.get("core"), dict) else {}
    user_result = core.get("user_results", {}).get("result", {}) if core else {}
    author = raw.get("author") or raw.get("user") or user_result or raw.get("screen_name") or ""
    tweet_id = str(first_present(raw, ["id", "id_str", "tweet_id", "rest_id"], legacy.get("id_str", "")))
    return {
        "id": tweet_id,
        "author": normalize_author(author),
        "text": str(first_present(raw, ["text", "full_text", "content"], legacy.get("full_text", ""))),
        "likeCount": to_int(first_present(raw, ["like_count", "favorite_count"], metrics.get("like_count", legacy.get("favorite_count", 0)))),
        "retweetCount": to_int(first_present(raw, ["retweet_count"], metrics.get("retweet_count", legacy.get("retweet_count", 0)))),
        "viewCount": to_int(first_present(raw, ["view_count", "views"], metrics.get("view_count", legacy.get("view_count", 0)))),
        "url": raw.get("url") or f"https://x.com/i/status/{tweet_id}",
    }


def search_tweets(query: str, limit: int) -> list[dict[str, Any]]:
    """Search X and return raw tweets for track.sh."""
    payload = request_json("/api/v1/x/tweets/search", {"q": query, "limit": min(limit, 100)})
    return [normalize_tweet(item) for item in extract_items(payload)]


def main(argv: list[str]) -> int:
    """CLI entrypoint used by track.sh."""
    if len(argv) != 4 or argv[1] != "search":
        print("Usage: hermes_tweet_backend.py search <query> <limit>", file=sys.stderr)
        return 2
    try:
        limit = int(argv[3])
        results = search_tweets(argv[2], limit)
    except (HermesTweetError, ValueError, urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        results = []
    print(json.dumps(results, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
