---
name: hot24h
description: Find the hottest tweets about any topic in the past 24 hours from X/Twitter. Ranks by engagement (views + likes + retweets). Use when user mentions "热门推文", "hot tweets", "trending", "24h", "过去24小时", or wants to find trending discussions on a specific topic.
---

# Hot 24h — Twitter Trend Scanner

Search X/Twitter for the hottest tweets about a topic in the past 24 hours, ranked by engagement.

## Usage

```
/hot24h <topic> [--limit N] [--min-views N]
```

**Examples:**
```
/hot24h skill
/hot24h "rust lang"
/hot24h crypto --limit 50
/hot24h "AI agent" --min-views 1000
```

## Arguments

- `topic` (required): The search topic. Can be a single word or quoted phrase.
- `--limit N`: Max results to return (default: 30)
- `--min-views N`: Minimum view count to include (default: 0)

## How It Works

1. **Broad search**: Generates multiple query variants from the topic, searches with `--filter top` for maximum coverage
2. **Noise filter**: Blacklist removes irrelevant matches (e.g., "soft skill" when searching "skill")
3. **Engagement scoring**: `score = views + likes × 100 + retweets × 50`
4. **Repo extraction**: Detects GitHub links and `npx skills add` commands in tweets
5. **RT aggregation**: Pure retweets merge into originals, engagement stacks

## Implementation

Run the following Python script via Bash. Replace `{{TOPIC}}` with the user's topic, `{{LIMIT}}` with the limit (default 30), and `{{MIN_VIEWS}}` with min-views (default 0).

```bash
python3 << 'PYEOF'
import json, os, re, subprocess, sys, tempfile, time
from collections import defaultdict
from datetime import datetime

# ── Config ──
TOPIC = "{{TOPIC}}"
LIMIT = {{LIMIT}}
MIN_VIEWS = {{MIN_VIEWS}}
TODAY = datetime.now().strftime("%Y-%m-%d")

# Yesterday for since: operator
from datetime import timedelta
YESTERDAY = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")

OWN_ACCOUNTS = {"sharp_lee1485", "ZooClawAI", "openclaw"}

# ── Generate search queries from topic ──
# Split topic into words for variant generation
topic_words = TOPIC.strip().strip('"').strip("'")
queries = [
    f"{topic_words} since:{YESTERDAY}",
    f'"{topic_words}" since:{YESTERDAY}',
]
# If topic has multiple words, also search each significant word with context
words = topic_words.split()
if len(words) >= 2:
    queries.append(f"{words[0]} {words[-1]} since:{YESTERDAY}")

# Dedup queries
queries = list(dict.fromkeys(queries))

SEARCH_LIMIT = 100  # per query

# ── Detect backend ──
bird_token = os.environ.get("BIRD_AUTH_TOKEN", "")
bird_ct0 = os.environ.get("BIRD_CT0", "")
use_bird = bool(bird_token and bird_ct0)

print(f"[hot24h] Topic: {topic_words}")
print(f"[hot24h] Backend: {'bird' if use_bird else 'opencli'}")
print(f"[hot24h] Queries: {len(queries)}")

# ── Search ──
all_tweets = []
for i, q in enumerate(queries):
    print(f"  [{i+1}/{len(queries)}] \"{q}\"")
    try:
        if use_bird:
            result = subprocess.run(
                ["bird", "search", q, "--count", str(SEARCH_LIMIT),
                 "--json", "--plain",
                 "--auth-token", bird_token, "--ct0", bird_ct0],
                capture_output=True, text=True, timeout=30
            )
            data = json.loads(result.stdout) if result.stdout.strip() else []
        else:
            result = subprocess.run(
                ["opencli", "twitter", "search", q,
                 "--filter", "top", "--limit", str(SEARCH_LIMIT), "--format", "json"],
                capture_output=True, text=True, timeout=30
            )
            # Filter out noise lines from opencli
            clean = "\n".join(
                l for l in result.stdout.splitlines()
                if "MODULE_TYPELESS" not in l and "Reparsing" not in l and "node --trace" not in l
            )
            data = json.loads(clean) if clean.strip() else []
        if isinstance(data, list):
            all_tweets.extend(data)
    except Exception as e:
        print(f"    [warn] {e}")
    time.sleep(2)

print(f"\n  Raw tweets fetched: {len(all_tweets)}")

# ── Normalize ──
def normalize(t):
    if "created_at" in t:
        views_raw = t.get("views", "0") or "0"
        return {
            "id": str(t.get("id", "")),
            "author": t.get("author", ""),
            "text": t.get("text", ""),
            "likes": int(t.get("likes", 0) or 0),
            "views": int(str(views_raw).replace(",", "")),
            "retweets": int(t.get("retweets", 0) or 0),
            "url": t.get("url", f"https://x.com/i/status/{t.get('id', '')}"),
            "created_at": t.get("created_at", ""),
        }
    if "author" in t and isinstance(t.get("author"), dict):
        author_info = t["author"]
        return {
            "id": str(t.get("id", "")),
            "author": author_info.get("username", ""),
            "text": t.get("text", ""),
            "likes": int(t.get("likeCount", 0) or 0),
            "views": int(t.get("viewCount", t.get("views", 0)) or 0),
            "retweets": int(t.get("retweetCount", 0) or 0),
            "url": f"https://x.com/i/status/{t.get('id', '')}",
            "created_at": t.get("createdAt", ""),
        }
    return None

# ── Dedup ──
unique = {}
for t in all_tweets:
    n = normalize(t)
    if not n or not n["id"]:
        continue
    if n["author"] in OWN_ACCOUNTS:
        continue
    tid = n["id"]
    if tid not in unique or n["views"] > unique[tid]["views"]:
        unique[tid] = n

print(f"  After dedup: {len(unique)} unique tweets")

# ── RT aggregation ──
RT_RE = re.compile(r'^RT @(\w+):\s*(.+)', re.DOTALL)
originals = {}
rt_boost = defaultdict(lambda: {"views": 0, "likes": 0, "retweets": 0, "rt_by": []})

for tid, t in list(unique.items()):
    m = RT_RE.match(t["text"])
    if m:
        rt_text_prefix = m.group(2)[:80].lower().strip()
        matched = None
        for oid, o in unique.items():
            if oid == tid:
                continue
            if o["author"].lower() == m.group(1).lower() and o["text"][:80].lower().strip() == rt_text_prefix:
                matched = oid
                break
        if matched:
            rt_boost[matched]["views"] += t["views"]
            rt_boost[matched]["likes"] += t["likes"]
            rt_boost[matched]["retweets"] += t["retweets"]
            rt_boost[matched]["rt_by"].append(t["author"])
        else:
            originals[tid] = t
    else:
        originals[tid] = t

for tid, boost in rt_boost.items():
    if tid in originals:
        originals[tid]["views"] += boost["views"]
        originals[tid]["likes"] += boost["likes"]
        originals[tid]["retweets"] += boost["retweets"]
        originals[tid].setdefault("rt_by", []).extend(boost["rt_by"])

rt_merged = len(unique) - len(originals)
if rt_merged:
    print(f"  RT merged: {rt_merged} → {len(originals)} tweets")

unique = originals

# ── Min views filter ──
if MIN_VIEWS > 0:
    before = len(unique)
    unique = {tid: t for tid, t in unique.items() if t["views"] >= MIN_VIEWS}
    print(f"  Min views filter ({MIN_VIEWS}): {before} → {len(unique)}")

# ── Score & rank ──
def hot_score(t):
    return t["views"] + t["likes"] * 100 + t["retweets"] * 50

ranked = sorted(unique.values(), key=hot_score, reverse=True)[:LIMIT]

# ── Extract repos ──
GITHUB_RE = re.compile(r'github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)')
NPX_RE = re.compile(r'npx\s+skills?\s+add\s+(?:https?://\S+/)?([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)')

def extract_repos(text):
    repos = set()
    for m in GITHUB_RE.finditer(text):
        repo = m.group(1).rstrip('.').lower()
        if '/' in repo:
            repos.add(repo)
    for m in NPX_RE.finditer(text):
        repo = m.group(1).rstrip('.').lower()
        if '/' in repo:
            repos.add(repo)
    return list(repos)

# ── Output ──
print(f"\n{'='*70}")
print(f"  🔥 Hot 24h: \"{topic_words}\" ({TODAY})")
print(f"  {len(ranked)} tweets ranked by engagement")
print(f"{'='*70}")

for i, t in enumerate(ranked):
    score = hot_score(t)
    repos = extract_repos(t["text"])
    repos_str = f" → {', '.join(repos)}" if repos else ""
    rt_str = f" (RT by {', '.join(t.get('rt_by', [])[:3])})" if t.get("rt_by") else ""

    print(f"\n  #{i+1} score={score:>10,}  👀{t['views']:>9,} ❤{t['likes']:>5,} 🔁{t['retweets']:>4d}")
    print(f"  @{t['author']}{repos_str}{rt_str}")
    print(f"  {t['text'][:200]}")
    print(f"  {t['url']}")

print(f"\n{'='*70}")
PYEOF
```

## Notes

- Uses `opencli twitter search` locally, `bird search` in CI (auto-detected via env vars)
- `--filter top` returns tweets sorted by Twitter's relevance/popularity algorithm
- The `since:` operator limits to ~24h window
- Each query fetches up to 100 tweets, then merges and re-ranks locally
