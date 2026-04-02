---
description: Find the hottest tweets about any topic in the past 24 hours from X/Twitter, ranked by engagement.
allowed-tools: Bash, Read, Write, Edit
---

# Hot 24h — Twitter Trend Scanner

The user wants to find the hottest tweets about a topic. Parse their input to extract:
- **topic** (required): the search topic
- **limit** (optional, default 30): max results  
- **min-views** (optional, default 0): minimum view count

User input: $ARGUMENTS

## Instructions

Run the following Python script via Bash tool. Before running, replace these placeholders in the script:
- Replace `TOPIC_VALUE` with the extracted topic (e.g., `skill`, `rust lang`, `AI agent`)
- Replace `LIMIT_VALUE` with the limit number (default: `30`)
- Replace `MIN_VIEWS_VALUE` with the min-views number (default: `0`)

```python
import json, os, re, subprocess, sys, time
from collections import defaultdict
from datetime import datetime, timedelta

# ── Config ──
TOPIC = "TOPIC_VALUE"
LIMIT = LIMIT_VALUE
MIN_VIEWS = MIN_VIEWS_VALUE
TODAY = datetime.now().strftime("%Y-%m-%d")
YESTERDAY = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")

OWN_ACCOUNTS = {"sharp_lee1485", "ZooClawAI", "openclaw"}

# ── LLM query expansion via Haiku ──
topic_words = TOPIC.strip().strip('"').strip("'")

def expand_queries(topic):
    """Use Claude Haiku to generate search query variants for the topic."""
    try:
        import anthropic
        client = anthropic.Anthropic()
        resp = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=300,
            messages=[{
                "role": "user",
                "content": f"""Generate 5-8 Twitter/X search query variants for the topic: "{topic}"

Rules:
- Each query should be a different angle/synonym/related term that people might use when tweeting about this topic
- Include the exact topic as-is, plus variations (synonyms, abbreviations, related hashtags, community slang)
- Keep queries short (1-4 words each), optimized for Twitter search
- Do NOT add operators like since: or min_faves: — I will add those
- Return ONLY the queries, one per line, no numbering, no explanation"""
            }]
        )
        lines = [l.strip() for l in resp.content[0].text.strip().splitlines() if l.strip()]
        print(f"[hot24h] Haiku expanded \"{topic}\" → {len(lines)} queries")
        return lines
    except Exception as e:
        print(f"[hot24h] Haiku expansion failed ({e}), using fallback")
        return [topic, f'"{topic}"']

expanded = expand_queries(topic_words)
queries = list(dict.fromkeys([f'{q} since:{YESTERDAY}' for q in expanded]))

SEARCH_LIMIT = 100

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
print(f"  Hot 24h: \"{topic_words}\" ({TODAY})")
print(f"  {len(ranked)} tweets ranked by engagement")
print(f"{'='*70}")

for i, t in enumerate(ranked):
    score = hot_score(t)
    repos = extract_repos(t["text"])
    repos_str = f" -> {', '.join(repos)}" if repos else ""
    rt_str = f" (RT by {', '.join(t.get('rt_by', [])[:3])})" if t.get("rt_by") else ""

    print(f"\n  #{i+1} score={score:>10,}  views={t['views']:>9,} likes={t['likes']:>5,} rt={t['retweets']:>4d}")
    print(f"  @{t['author']}{repos_str}{rt_str}")
    print(f"  {t['text'][:200]}")
    print(f"  {t['url']}")

print(f"\n{'='*70}")
```

After running, present the results to the user in a clean summary. Highlight tweets that contain GitHub repos or `npx skills add` commands — these are the most actionable.
