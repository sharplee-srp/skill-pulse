#!/usr/bin/env bash
# track.sh — Fetch hot skill-related tweets from X, deduplicate, and rank by engagement
#
# Usage:
#   Local (opencli):  ./track.sh
#   CI    (bird):     BIRD_AUTH_TOKEN=xxx BIRD_CT0=yyy ./track.sh
#
# Output: data/YYYY-MM-DD.json  (today's ranked results)
#         data/seen.json        (cumulative dedup index)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
mkdir -p "$DATA_DIR"

TODAY=$(date +%Y-%m-%d)
OUTPUT="$DATA_DIR/$TODAY.json"
SEEN_FILE="$DATA_DIR/seen.json"
RAW_DIR="$DATA_DIR/raw"
mkdir -p "$RAW_DIR"

# Initialize seen.json if missing
if [[ ! -f "$SEEN_FILE" ]]; then
  echo '{}' > "$SEEN_FILE"
fi

# --- Search keywords ---
# Each query targets a different angle of the "skill" ecosystem
QUERIES=(
  "claude code skill"
  "claude skill min_faves:20"
  "MCP server min_faves:50"
  "cursor rules min_faves:30"
  "AI coding skill"
  "npx skills add"
  "claude code plugin"
  ".claude skill"
)

LIMIT=15  # per query

# --- Detect backend ---
if [[ -n "${BIRD_AUTH_TOKEN:-}" && -n "${BIRD_CT0:-}" ]]; then
  BACKEND="bird"
  echo "[info] Using bird backend (CI mode)"
else
  BACKEND="opencli"
  echo "[info] Using opencli backend (local mode)"
fi

# --- Search function ---
search_tweets() {
  local query="$1"
  local limit="$2"
  local outfile="$3"

  if [[ "$BACKEND" == "bird" ]]; then
    bird search "$query" \
      --count "$limit" \
      --json \
      --plain \
      --auth-token "$BIRD_AUTH_TOKEN" \
      --ct0 "$BIRD_CT0" \
      2>/dev/null > "$outfile" || echo '[]' > "$outfile"
  else
    # opencli — filter out node warnings
    opencli twitter search "$query" \
      --limit "$limit" \
      --format json \
      2>/dev/null | grep -v "MODULE_TYPELESS\|Reparsing\|node --trace" > "$outfile" || echo '[]' > "$outfile"
  fi
}

# --- Fetch all queries ---
echo "[info] Searching ${#QUERIES[@]} queries (limit=$LIMIT each)..."
ALL_RAW="$RAW_DIR/$TODAY-raw.json"
echo '[]' > "$ALL_RAW"

for i in "${!QUERIES[@]}"; do
  q="${QUERIES[$i]}"
  tmpfile="$RAW_DIR/$TODAY-q${i}.json"
  echo "  [$((i+1))/${#QUERIES[@]}] \"$q\""
  search_tweets "$q" "$LIMIT" "$tmpfile"
  sleep 2  # rate limit courtesy
done

# --- Merge, deduplicate, rank ---
python3 << 'PYEOF'
import json, glob, os, sys
from datetime import datetime

script_dir = os.environ.get("SCRIPT_DIR", os.path.dirname(os.path.abspath(__file__)))
data_dir = os.path.join(script_dir, "data")
raw_dir = os.path.join(data_dir, "raw")
today = datetime.now().strftime("%Y-%m-%d")
output = os.path.join(data_dir, f"{today}.json")
seen_file = os.path.join(data_dir, "seen.json")

# Load seen index
with open(seen_file, "r") as f:
    seen = json.load(f)

# Normalize tweet format (bird vs opencli have different field names)
def normalize(t):
    """Unify bird and opencli tweet formats into a common schema."""
    # bird uses nested author object; opencli uses flat fields
    if "author" in t and isinstance(t["author"], dict):
        # bird format (no viewCount in search results)
        author_info = t["author"]
        return {
            "id": str(t.get("id", "")),
            "author": author_info.get("username", ""),
            "name": author_info.get("name", ""),
            "text": t.get("text", ""),
            "likes": int(t.get("likeCount", 0) or 0),
            "views": int(t.get("viewCount", t.get("views", 0)) or 0),
            "retweets": int(t.get("retweetCount", 0) or 0),
            "replies": int(t.get("replyCount", 0) or 0),
            "url": f"https://x.com/i/status/{t.get('id', '')}",
            "created_at": t.get("createdAt", t.get("created_at", "")),
        }
    else:
        # opencli format — already mostly flat
        views_raw = t.get("views", "0") or "0"
        return {
            "id": str(t.get("id", "")),
            "author": t.get("author", ""),
            "name": t.get("name", ""),
            "text": t.get("text", ""),
            "likes": int(t.get("likes", 0) or 0),
            "views": int(str(views_raw).replace(",", "")),
            "retweets": int(t.get("retweets", 0) or 0),
            "url": t.get("url", f"https://x.com/i/status/{t.get('id', '')}"),
            "created_at": t.get("created_at", ""),
        }

# Merge all raw results
all_tweets = []
for fpath in sorted(glob.glob(os.path.join(raw_dir, f"{today}-q*.json"))):
    try:
        with open(fpath, "r") as f:
            data = json.load(f)
            if isinstance(data, list):
                all_tweets.extend([normalize(t) for t in data])
    except (json.JSONDecodeError, IOError):
        continue

# Deduplicate by tweet ID
unique = {}
for t in all_tweets:
    tid = str(t.get("id", ""))
    if not tid:
        continue
    if tid in unique:
        continue  # keep first occurrence
    unique[tid] = t

# Separate new vs previously seen
new_tweets = []
old_tweets = []
for tid, t in unique.items():
    if tid in seen:
        old_tweets.append(t)
    else:
        new_tweets.append(t)

# Parse engagement score (fields already normalized to int)
def engagement(t):
    likes = t.get("likes", 0)
    views = t.get("views", 0)
    retweets = t.get("retweets", 0)
    # Weighted score: likes * 3 + retweets * 5 + views * 0.01
    return likes * 3 + retweets * 5 + views * 0.01

# Sort by engagement
new_tweets.sort(key=engagement, reverse=True)
old_tweets.sort(key=engagement, reverse=True)

# Mark new tweets as seen
for t in new_tweets:
    tid = str(t.get("id", ""))
    seen[tid] = {"first_seen": today, "author": t.get("author", "")}

# Build output
result = {
    "date": today,
    "total_fetched": len(all_tweets),
    "unique": len(unique),
    "new": len(new_tweets),
    "previously_seen": len(old_tweets),
    "new_tweets": [],
    "previously_seen_tweets": [],
}

for t in new_tweets:
    result["new_tweets"].append({
        "id": t["id"],
        "author": t["author"],
        "text": t["text"][:280],
        "likes": t["likes"],
        "views": t["views"],
        "retweets": t["retweets"],
        "url": t["url"],
        "score": round(engagement(t), 1),
    })

for t in old_tweets[:10]:  # keep top 10 old ones for reference
    result["previously_seen_tweets"].append({
        "id": t["id"],
        "author": t["author"],
        "text": t["text"][:280],
        "likes": t["likes"],
        "views": t["views"],
        "url": t["url"],
        "first_seen": seen.get(t["id"], {}).get("first_seen", ""),
        "score": round(engagement(t), 1),
    })

# Write outputs
with open(output, "w") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)

with open(seen_file, "w") as f:
    json.dump(seen, f, ensure_ascii=False, indent=2)

# Summary
print(f"\n{'='*60}")
print(f"  Date: {today}")
print(f"  Fetched: {result['total_fetched']} | Unique: {result['unique']} | New: {result['new']} | Seen before: {result['previously_seen']}")
print(f"{'='*60}")
if new_tweets:
    print(f"\n  Top 5 NEW hot skills tweets:")
    for i, t in enumerate(result["new_tweets"][:5]):
        print(f"  {i+1}. @{t['author']} (❤ {t['likes']} 👁 {t['views']}) score={t['score']}")
        print(f"     {t['text'][:120]}...")
        print(f"     {t['url']}")
        print()
else:
    print("\n  No new tweets found today.")

print(f"  Output: {output}")
PYEOF

# Cleanup raw files
rm -f "$RAW_DIR/$TODAY"-q*.json

echo "[done] Tracking complete."
