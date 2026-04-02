#!/usr/bin/env bash
# hot24h.sh — Find the hottest skill-related tweets in the past 24 hours
#
# Features:
#   - Broad search + local relevance filtering (not keyword-fragmented)
#   - RT aggregation: pure RTs merge into original, engagement stacks
#   - Cross-day dedup: seen tweets only resurface if score jumps 3x+
#   - Noise blacklist: excludes soft skill, job skill, etc.
#
# Usage:
#   Local:  ./hot24h.sh
#   CI:     BIRD_AUTH_TOKEN=xxx BIRD_CT0=yyy ./hot24h.sh
#
# Output: data/hot24h-YYYY-MM-DD.json
#         data/seen_hot.json (cross-day dedup state)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
RAW_DIR="$DATA_DIR/raw"
mkdir -p "$DATA_DIR" "$RAW_DIR"

TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d "yesterday" +%Y-%m-%d)
RUN_ID=$(date -u +%H%M)
OUTPUT="$DATA_DIR/hot24h-$TODAY.json"
SEEN_HOT="$DATA_DIR/seen_hot.json"

[[ -f "$SEEN_HOT" ]] || echo '{}' > "$SEEN_HOT"

# ============================================================
# Search queries — few wide queries, filter locally
# ============================================================
QUERIES=(
  "skill since:$YESTERDAY"
  "\"agent skill\" since:$YESTERDAY"
  "\"claude code\" skill since:$YESTERDAY"
  "\"coding agent\" skill since:$YESTERDAY"
  "\"npx skills\" since:$YESTERDAY"
  "openclaw skill since:$YESTERDAY"
  "codex skill since:$YESTERDAY"
)

LIMIT=100

# --- Detect backend ---
if [[ -n "${BIRD_AUTH_TOKEN:-}" && -n "${BIRD_CT0:-}" ]]; then
  BACKEND="bird"
  echo "[info] Using bird backend (CI mode)"
else
  BACKEND="opencli"
  echo "[info] Using opencli backend (local mode)"
fi

search_tweets() {
  local query="$1"
  local limit="$2"
  local outfile="$3"

  if [[ "$BACKEND" == "bird" ]]; then
    bird search "$query" \
      --count "$limit" \
      \
      --json \
      --plain \
      --auth-token "$BIRD_AUTH_TOKEN" \
      --ct0 "$BIRD_CT0" \
      2>/dev/null | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  tweets=d.get('tweets',d) if isinstance(d,dict) else d
  json.dump(tweets if isinstance(tweets,list) else [],sys.stdout)
except: json.dump([],sys.stdout)
" > "$outfile" || echo '[]' > "$outfile"
  else
    opencli twitter search "$query" \
      --filter top \
      --limit "$limit" \
      --format json \
      2>/dev/null | grep -v "MODULE_TYPELESS\|Reparsing\|node --trace" > "$outfile" || echo '[]' > "$outfile"
  fi
}

# ============================================================
# Phase 1: Fetch
# ============================================================
echo "[info] Searching ${#QUERIES[@]} queries (limit=$LIMIT each)..."

for i in "${!QUERIES[@]}"; do
  q="${QUERIES[$i]}"
  tmpfile="$RAW_DIR/hot24h-${RUN_ID}-q${i}-$TODAY.json"
  echo "  [$((i+1))/${#QUERIES[@]}] \"$q\""
  search_tweets "$q" "$LIMIT" "$tmpfile"
  sleep 2
done

# ============================================================
# Phase 2: Merge, dedup, filter, rank
# ============================================================
echo "[info] Processing..."

python3 << 'PYEOF'
import json, glob, os, re
from collections import defaultdict
from datetime import datetime

script_dir = os.path.dirname(os.path.abspath("hot24h.sh"))
if not os.path.isdir(os.path.join(script_dir, "data")):
    script_dir = os.getcwd()
data_dir = os.path.join(script_dir, "data")
raw_dir = os.path.join(data_dir, "raw")
today = datetime.now().strftime("%Y-%m-%d")
output_file = os.path.join(data_dir, f"hot24h-{today}.json")
seen_hot_file = os.path.join(data_dir, "seen_hot.json")

OWN_ACCOUNTS = {"sharp_lee1485", "ZooClawAI", "openclaw"}

with open(seen_hot_file) as f:
    seen_hot = json.load(f)

# ── Load all raw files ──
all_tweets = []
for fpath in sorted(glob.glob(os.path.join(raw_dir, f"hot24h-*-q*-{today}.json"))):
    try:
        with open(fpath) as f:
            data = json.load(f)
            if isinstance(data, list):
                all_tweets.extend(data)
    except (json.JSONDecodeError, IOError):
        continue

print(f"  Raw tweets fetched: {len(all_tweets)}")

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

# ── Tweet-level dedup ──
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

# ══════════════════════════════════════════════════════════════
# RT aggregation
# ══════════════════════════════════════════════════════════════
# Pure RT pattern: "RT @user: original text..."
RT_RE = re.compile(r'^RT @(\w+):\s*(.+)', re.DOTALL)

originals = {}      # tid -> tweet (original tweets)
rt_boost = defaultdict(lambda: {"views": 0, "likes": 0, "retweets": 0, "rt_by": []})

for tid, t in list(unique.items()):
    m = RT_RE.match(t["text"])
    if m:
        # This is a pure RT — find the original by matching text
        rt_text_prefix = m.group(2)[:80].lower().strip()
        matched_original = None
        for oid, o in unique.items():
            if oid == tid:
                continue
            if o["author"].lower() == m.group(1).lower() and o["text"][:80].lower().strip() == rt_text_prefix:
                matched_original = oid
                break
        if matched_original:
            # Merge RT engagement into original
            rt_boost[matched_original]["views"] += t["views"]
            rt_boost[matched_original]["likes"] += t["likes"]
            rt_boost[matched_original]["retweets"] += t["retweets"]
            rt_boost[matched_original]["rt_by"].append(t["author"])
        else:
            # Can't find original in our set — keep RT as standalone
            originals[tid] = t
    else:
        originals[tid] = t

# Apply RT boosts to originals
for tid, boost in rt_boost.items():
    if tid in originals:
        originals[tid]["views"] += boost["views"]
        originals[tid]["likes"] += boost["likes"]
        originals[tid]["retweets"] += boost["retweets"]
        originals[tid].setdefault("rt_by", []).extend(boost["rt_by"])

rt_merged = len(unique) - len(originals)
if rt_merged:
    print(f"  RT aggregation: merged {rt_merged} RTs into originals → {len(originals)} tweets")

unique = originals

# ══════════════════════════════════════════════════════════════
# Relevance filter (layered)
# ══════════════════════════════════════════════════════════════
NOISE_BLACKLIST = [
    "soft skill", "soft skills",
    "job skill", "job skills",
    "interview skill", "interview skills",
    "life skill", "life skills",
    "communication skill", "communication skills",
    "leadership skill", "leadership skills",
    "management skill", "management skills",
    "people skill", "people skills",
    "social skill", "social skills",
    "language skill", "language skills",
    "writing skill", "writing skills",
    "reading skill", "reading skills",
    "problem solving skill",
    "critical thinking skill",
    "time management skill",
    "negotiation skill",
    "presentation skill",
    "resume", "hiring", "recruiter",
    "skillshare",
]

# High-confidence signals — auto-pass
HIGH_CONFIDENCE = [
    "npx skills add",
    "npx skill add",
    "skills add ",
    "/skill",
    "agent skill",
    "agent skills",
    "coding skill",
    "coding skills",
    "claude code skill",
    "claude skill",
    "codex skill",
    "openclaw",
    "open claw",
    "claude.md",
    ".claude/",
    "slash command",
]

# Medium-confidence — "skill" + at least one tech context word
TECH_CONTEXT = [
    "claude", "agent", "codex", "opencode", "coding",
    "github", "repo", "install", "plugin",
    "prompt", "cli", "terminal", "api",
    "ai ", "llm", "gpt", "model",
    "typescript", "python", "javascript",
    "vibe coding", "cursor", "windsurf",
    "copilot", "automation",
]

def is_relevant(t):
    text = t["text"].lower()

    # Blacklist check first
    if any(bl in text for bl in NOISE_BLACKLIST):
        return False

    # High confidence — auto pass
    if any(hc in text for hc in HIGH_CONFIDENCE):
        return True

    # Medium confidence — "skill" + tech context
    if "skill" in text:
        if any(tc in text for tc in TECH_CONTEXT):
            return True

    return False

before = len(unique)
unique = {tid: t for tid, t in unique.items() if is_relevant(t)}
print(f"  After relevance filter: {len(unique)} (removed {before - len(unique)} noise)")

# ══════════════════════════════════════════════════════════════
# Cross-day dedup
# ══════════════════════════════════════════════════════════════
def hot_score(t):
    return t["views"] + t["likes"] * 100 + t["retweets"] * 50

# ── Min engagement filter ──
# bird CLI doesn't return view counts, so filter on likes instead
MIN_LIKES = 2
before_engage = len(unique)
unique = {tid: t for tid, t in unique.items() if t["likes"] >= MIN_LIKES or t["views"] >= 500}
print(f"  After min engagement (likes>={MIN_LIKES} or views>=500): {len(unique)} (removed {before_engage - len(unique)})")

# ── Same-author same-content dedup ──
# Group by author, cluster by text similarity + URL overlap, keep best per cluster
import urllib.parse

TCO_RE_HOT = re.compile(r'https://t\.co/\S+')

def extract_urls(text):
    return set(TCO_RE_HOT.findall(text))

def text_similarity(a, b):
    wa = set(a[:200].lower().split())
    wb = set(b[:200].lower().split())
    union = wa | wb
    return len(wa & wb) / len(union) if union else 0

author_groups = defaultdict(list)
for tid, t in unique.items():
    author_groups[t["author"]].append((tid, t))

keep_tids = set()
dedup_removed = 0
for author, tweets in author_groups.items():
    # Cluster: each tweet either joins an existing cluster or starts a new one
    clusters = []  # list of (best_tid, best_score, best_tweet, urls)
    for tid, t in tweets:
        score = hot_score(t)
        urls = extract_urls(t["text"])
        merged = False
        for i, (c_tid, c_score, c_tweet, c_urls) in enumerate(clusters):
            # Same URL = same content (strongest signal)
            if urls and c_urls and (urls & c_urls):
                if score > c_score:
                    clusters[i] = (tid, score, t, urls | c_urls)
                else:
                    clusters[i] = (c_tid, c_score, c_tweet, urls | c_urls)
                merged = True
                break
            # Text similarity > 50% = same content
            if text_similarity(t["text"], c_tweet["text"]) > 0.5:
                if score > c_score:
                    clusters[i] = (tid, score, t, urls | c_urls)
                else:
                    clusters[i] = (c_tid, c_score, c_tweet, urls | c_urls)
                merged = True
                break
        if not merged:
            clusters.append((tid, score, t, urls))
    for c_tid, _, _, _ in clusters:
        keep_tids.add(c_tid)
    dedup_removed += len(tweets) - len(clusters)

before_author = len(unique)
unique = {tid: t for tid, t in unique.items() if tid in keep_tids}
if dedup_removed:
    print(f"  After same-author dedup: {len(unique)} (removed {dedup_removed})")

new_tweets = {}
resurfaced = {}

for tid, t in unique.items():
    score = hot_score(t)
    if tid in seen_hot:
        first_seen = seen_hot[tid].get("first_seen", "")
        if first_seen == today:
            # Same day (earlier run) — treat as current, update score
            new_tweets[tid] = t
        else:
            # Cross-day dedup — only resurface if score jumped 3x
            old_score = seen_hot[tid].get("score", 0)
            if score >= old_score * 3:
                resurfaced[tid] = t
                resurfaced[tid]["_resurfaced"] = True
                resurfaced[tid]["_old_score"] = old_score
    else:
        new_tweets[tid] = t

deduped_count = len(unique) - len(new_tweets) - len(resurfaced)
if deduped_count:
    print(f"  Cross-day dedup: skipped {deduped_count} already-seen tweets, {len(resurfaced)} resurfaced")

# Merge new + resurfaced
final = {**new_tweets, **resurfaced}

# ── Sort by score ──
ranked = sorted(final.values(), key=hot_score, reverse=True)

# ── Extract GitHub repos ──
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

# ── Build output ──
results = []
for t in ranked:
    score = hot_score(t)
    repos = extract_repos(t["text"])
    entry = {
        "rank": len(results) + 1,
        "score": score,
        "views": t["views"],
        "likes": t["likes"],
        "retweets": t["retweets"],
        "author": t["author"],
        "text": t["text"][:500],
        "url": t["url"],
        "repos": repos,
        "created_at": t["created_at"],
    }
    if t.get("rt_by"):
        entry["rt_by"] = t["rt_by"]
    if t.get("_resurfaced"):
        entry["resurfaced"] = True
        entry["previous_score"] = t["_old_score"]
    results.append(entry)

output = {
    "date": today,
    "window": "24h",
    "stats": {
        "total_fetched": len(all_tweets),
        "after_dedup": before,
        "after_noise_filter": len(unique),
        "skipped_seen": deduped_count,
        "resurfaced": len(resurfaced),
        "final": len(results),
        "with_repos": sum(1 for r in results if r["repos"]),
    },
    "tweets": results,
}

with open(output_file, "w") as f:
    json.dump(output, f, ensure_ascii=False, indent=2)

# ── Update seen state ──
for t in ranked:
    score = hot_score(t)
    tid = t["id"]
    seen_hot[tid] = {"first_seen": today, "score": score}

with open(seen_hot_file, "w") as f:
    json.dump(seen_hot, f, ensure_ascii=False, indent=2)

# ── Print top 25 ──
print(f"\n{'='*70}")
print(f"  Hot Skill Tweets — Past 24h ({today})")
print(f"  {len(results)} tweets | {sum(1 for r in results if r['repos'])} with repos")
print(f"{'='*70}")
for r in results[:25]:
    repos_str = f" → {', '.join(r['repos'])}" if r["repos"] else ""
    resurface_str = " [RESURFACED]" if r.get("resurfaced") else ""
    rt_str = f" (RT by {', '.join(r['rt_by'][:3])})" if r.get("rt_by") else ""
    print(f"\n  #{r['rank']} score={r['score']:>10,}  👀{r['views']:>9,} ❤{r['likes']:>5,} 🔁{r['retweets']:>4d}{resurface_str}")
    print(f"  @{r['author']}{repos_str}{rt_str}")
    print(f"  {r['text'][:140]}")
    print(f"  {r['url']}")

print(f"\n  Output: {output_file}")

# Clean up previous days' raw files (keep today's for cross-run merging)
for f in glob.glob(os.path.join(raw_dir, "hot24h-*.json")):
    if today not in f:
        os.remove(f)
PYEOF

echo "[done]"
