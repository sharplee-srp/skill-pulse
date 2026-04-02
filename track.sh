#!/usr/bin/env bash
# track.sh — Track hot AI skills from X, extract repos, rank by buzz
#
# Usage:
#   Local (opencli):  ./track.sh
#   CI    (bird):     BIRD_AUTH_TOKEN=xxx BIRD_CT0=yyy ./track.sh
#
# Output: data/YYYY-MM-DD.json  (today's ranked skill repos + tweets)
#         data/seen_repos.json  (cumulative repo dedup index)
#         data/seen_tweets.json (tweet-level dedup index)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
RAW_DIR="$DATA_DIR/raw"
mkdir -p "$DATA_DIR" "$RAW_DIR"

TODAY=$(date -u +%Y-%m-%d)
RUN_ID=$(date -u +%H%M)
OUTPUT="$DATA_DIR/$TODAY.json"
SEEN_REPOS="$DATA_DIR/seen_repos.json"
SEEN_TWEETS="$DATA_DIR/seen_tweets.json"

[[ -f "$SEEN_REPOS" ]]  || echo '{}' > "$SEEN_REPOS"
[[ -f "$SEEN_TWEETS" ]] || echo '{}' > "$SEEN_TWEETS"

# ============================================================
# KOL Watchlist — high-signal accounts in the AI skill ecosystem
# ============================================================
KOLS=(
  steipete        # bird author, skill ecosystem pioneer
  shao__meng      # CN AI tool blogger, deep skill reviews
  lianyanshe      # CN skill recommendation KOL
  hooeem          # claude skill tutorials
  songguoxiansen  # CN AI dev tools
  bozhou_ai       # claude skill combos
  aigclink        # AI tool reviews
  GitHub_Daily    # daily GitHub trending
  rohanpaul_ai    # AI dev tutorials
  geekbb          # dev tools curator
  heyrimsha       # claude code repos
  AnthropicAI     # official
  claudeai        # official
  figma           # MCP ecosystem
  github          # MCP ecosystem
)

# ============================================================
# Search queries — keyword-based discovery
# ============================================================
QUERIES=(
  # Core product & ecosystem
  "openclaw skill"
  "open claw skill"
  "claw skill"
  # Claude ecosystem
  "claude code skill"
  "claude skill min_faves:10"
  "claude code plugin"
  "npx skills add"
  ".claude skill"
  # Agent skills
  "AI agent skill"
  "coding agent skill"
  "agent skill min_faves:20"
  # MCP ecosystem
  "MCP server min_faves:30"
  "MCP tool min_faves:20"
  # Other
  "codex skill"
)

LIMIT=30  # per query

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
      --all --max-pages 5 \
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
      --limit "$limit" \
      --format json \
      2>/dev/null | grep -v "MODULE_TYPELESS\|Reparsing\|node --trace" > "$outfile" || echo '[]' > "$outfile"
  fi
}

# --- Fetch KOL user tweets ---
fetch_kol_tweets() {
  local username="$1"
  local outfile="$2"

  if [[ "$BACKEND" == "bird" ]]; then
    bird search "from:${username} skill OR mcp OR plugin OR tool OR agent" \
      --count 10 \
      --all --max-pages 5 \
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
    opencli twitter search "from:${username} skill OR mcp OR plugin OR tool OR agent" \
      --limit 10 \
      --format json \
      2>/dev/null | grep -v "MODULE_TYPELESS\|Reparsing\|node --trace" > "$outfile" || echo '[]' > "$outfile"
  fi
}

# ============================================================
# Phase 1: Fetch KOL tweets
# ============================================================
echo "[info] Phase 1: Fetching KOL tweets (${#KOLS[@]} accounts)..."
for i in "${!KOLS[@]}"; do
  kol="${KOLS[$i]}"
  tmpfile="$RAW_DIR/$TODAY-${RUN_ID}-kol-${kol}.json"
  echo "  [$((i+1))/${#KOLS[@]}] @$kol"
  fetch_kol_tweets "$kol" "$tmpfile"
  sleep 1
done

# ============================================================
# Phase 2: Fetch keyword search results
# ============================================================
echo "[info] Phase 2: Searching ${#QUERIES[@]} queries..."
for i in "${!QUERIES[@]}"; do
  q="${QUERIES[$i]}"
  tmpfile="$RAW_DIR/$TODAY-${RUN_ID}-q${i}.json"
  echo "  [$((i+1))/${#QUERIES[@]}] \"$q\""
  search_tweets "$q" "$LIMIT" "$tmpfile"
  sleep 1
done

# ============================================================
# Phase 3: Merge, extract repos, rank
# ============================================================
echo "[info] Phase 3: Processing results..."

python3 << 'PYEOF'
import json, glob, os, re, urllib.request
from datetime import datetime
from collections import defaultdict

script_dir = os.path.dirname(os.path.abspath("track.sh"))
if not os.path.isdir(os.path.join(script_dir, "data")):
    script_dir = os.getcwd()
data_dir = os.path.join(script_dir, "data")
raw_dir = os.path.join(data_dir, "raw")
today = datetime.now().strftime("%Y-%m-%d")
output_file = os.path.join(data_dir, f"{today}.json")
seen_repos_file = os.path.join(data_dir, "seen_repos.json")
seen_tweets_file = os.path.join(data_dir, "seen_tweets.json")

# KOL set (for tier tagging)
KOL_SET = {
    "steipete", "shao__meng", "lianyanshe", "hooeem", "songguoxiansen",
    "bozhou_ai", "aigclink", "GitHub_Daily", "rohanpaul_ai", "geekbb",
    "heyrimsha", "AnthropicAI", "claudeai", "figma", "github",
}
OWN_ACCOUNTS = {"sharp_lee1485", "ZooClawAI", "openclaw"}

# Load state
with open(seen_repos_file) as f:
    seen_repos = json.load(f)
with open(seen_tweets_file) as f:
    seen_tweets = json.load(f)

# ── Normalize ──
def normalize(t, source="search"):
    if "author" in t and isinstance(t["author"], dict):
        author_info = t["author"]
        return {
            "id": str(t.get("id", "")),
            "author": author_info.get("username", ""),
            "text": t.get("text", ""),
            "likes": int(t.get("likeCount", 0) or 0),
            "views": int(t.get("viewCount", t.get("views", 0)) or 0),
            "retweets": int(t.get("retweetCount", 0) or 0),
            "url": f"https://x.com/i/status/{t.get('id', '')}",
            "source": source,
        }
    else:
        views_raw = t.get("views", "0") or "0"
        return {
            "id": str(t.get("id", "")),
            "author": t.get("author", ""),
            "text": t.get("text", ""),
            "likes": int(t.get("likes", 0) or 0),
            "views": int(str(views_raw).replace(",", "")),
            "retweets": int(t.get("retweets", 0) or 0),
            "url": t.get("url", f"https://x.com/i/status/{t.get('id', '')}"),
            "source": source,
        }

# ── Load all tweets ──
all_tweets = []
# KOL tweets
for fpath in sorted(glob.glob(os.path.join(raw_dir, f"{today}-*-kol-*.json"))):
    try:
        with open(fpath) as f:
            data = json.load(f)
            if isinstance(data, list):
                all_tweets.extend([normalize(t, "kol") for t in data])
    except (json.JSONDecodeError, IOError):
        continue
# Search tweets
for fpath in sorted(glob.glob(os.path.join(raw_dir, f"{today}-*-q*.json"))):
    try:
        with open(fpath) as f:
            data = json.load(f)
            if isinstance(data, list):
                all_tweets.extend([normalize(t, "search") for t in data])
    except (json.JSONDecodeError, IOError):
        continue

# ── Tweet-level dedup ──
unique = {}
for t in all_tweets:
    tid = t["id"]
    if not tid or tid in unique:
        continue
    unique[tid] = t
print(f"  Raw: {len(all_tweets)} → Deduped: {len(unique)}")

# ── Relevance filter ──
SKILL_KEYWORDS = [
    "skill", "skills", "mcp", "plugin", "plugins",
    "rule", "rules", ".claude", "claude.md",
    "npx skills", "slash command",
    "openclaw", "open claw", "claw",
    "agent tool", "coding tool", "dev tool",
    "extension", "server",
]

def is_relevant(t):
    if t["author"] in OWN_ACCOUNTS:
        return False
    text = t["text"].lower()
    if len(text.strip()) < 30:
        return False
    return any(kw in text for kw in SKILL_KEYWORDS)

before = len(unique)
unique = {tid: t for tid, t in unique.items() if is_relevant(t)}
print(f"  After filter: {len(unique)} (removed {before - len(unique)} noise)")

# ── Extract GitHub repos and skill identifiers ──
GITHUB_RE = re.compile(r'github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)')
NPX_RE = re.compile(r'npx\s+skills?\s+add\s+(?:https?://\S+/)?([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)')
TCO_RE = re.compile(r'https://t\.co/\S+')

def resolve_tco(url):
    """Resolve t.co short URL to find GitHub repo."""
    try:
        req = urllib.request.Request(url, method='HEAD')
        req.add_header('User-Agent', 'Mozilla/5.0')
        resp = urllib.request.urlopen(req, timeout=5)
        final = resp.url
        m = GITHUB_RE.search(final)
        return m.group(1).rstrip('.') if m else None
    except:
        return None

def extract_repos(text):
    """Extract GitHub repo identifiers from tweet text."""
    repos = set()
    # Direct github.com links
    for m in GITHUB_RE.finditer(text):
        repo = m.group(1).rstrip('.')
        # Skip non-repo paths
        if '/' in repo and not repo.endswith('.git'):
            repos.add(repo.lower())
    # npx skills add commands
    for m in NPX_RE.finditer(text):
        repo = m.group(1).rstrip('.')
        if '/' in repo:
            repos.add(repo.lower())
    return repos

# First pass: extract from direct URLs
tweet_repos = {}  # tid -> set of repos
unresolved_tco = {}  # tid -> list of t.co URLs to try

for tid, t in unique.items():
    text = t["text"]
    repos = extract_repos(text)
    if repos:
        tweet_repos[tid] = repos
    else:
        # Collect t.co URLs for resolution
        tco_urls = TCO_RE.findall(text)
        if tco_urls:
            unresolved_tco[tid] = tco_urls

# Second pass: resolve t.co URLs (limited to avoid rate limits)
MAX_RESOLVE = 50
resolved_count = 0
for tid, urls in list(unresolved_tco.items()):
    if resolved_count >= MAX_RESOLVE:
        break
    for url in urls:
        repo = resolve_tco(url)
        resolved_count += 1
        if repo:
            tweet_repos.setdefault(tid, set()).add(repo.lower())
            break
    if resolved_count >= MAX_RESOLVE:
        break

print(f"  Tweets with repos: {len(tweet_repos)} | t.co resolved: {resolved_count}")

# ── Group by repo ──
repo_data = defaultdict(lambda: {
    "tweets": [],
    "total_likes": 0,
    "total_retweets": 0,
    "total_views": 0,
    "kol_mentions": [],
    "mention_count": 0,
})

for tid, repos in tweet_repos.items():
    t = unique[tid]
    for repo in repos:
        rd = repo_data[repo]
        rd["tweets"].append(t)
        rd["total_likes"] += t["likes"]
        rd["total_retweets"] += t["retweets"]
        rd["total_views"] += t["views"]
        rd["mention_count"] += 1
        if t["author"] in KOL_SET:
            rd["kol_mentions"].append(t["author"])

# Tweets without repos (still valuable for discovery)
no_repo_tweets = [unique[tid] for tid in unique if tid not in tweet_repos]

# ── Engagement scoring ──
def tweet_score(t):
    return t["likes"] * 3 + t["retweets"] * 5 + t["views"] * 0.01

def repo_score(repo, rd):
    base = rd["total_likes"] * 3 + rd["total_retweets"] * 5 + rd["total_views"] * 0.01
    mention_bonus = rd["mention_count"] * 100  # more mentions = hotter
    kol_bonus = len(rd["kol_mentions"]) * 500   # KOL mention = big signal
    return base + mention_bonus + kol_bonus

# ── Tier assignment ──
def assign_tier(repo, rd):
    if rd["kol_mentions"]:
        return 0  # KOL recommended
    if rd["mention_count"] >= 3:
        return 1  # Multiple mentions
    if rd["total_likes"] >= 100:
        return 2  # High engagement single mention
    return 3  # Low signal

# ── Build ranked repo list ──
ranked_repos = []
for repo, rd in repo_data.items():
    tier = assign_tier(repo, rd)
    score = repo_score(repo, rd)
    is_new = repo not in seen_repos or seen_repos[repo].get("first_seen") == today

    best_tweet = max(rd["tweets"], key=tweet_score)
    ranked_repos.append({
        "repo": repo,
        "github_url": f"https://github.com/{repo}",
        "tier": tier,
        "is_new": is_new,
        "score": round(score, 1),
        "mention_count": rd["mention_count"],
        "kol_mentions": list(set(rd["kol_mentions"])),
        "total_likes": rd["total_likes"],
        "total_retweets": rd["total_retweets"],
        "total_views": rd["total_views"],
        "best_tweet": {
            "author": best_tweet["author"],
            "text": best_tweet["text"][:280],
            "likes": best_tweet["likes"],
            "url": best_tweet["url"],
        },
        "all_tweet_urls": [t["url"] for t in rd["tweets"]],
    })

# Sort: tier ASC, score DESC
ranked_repos.sort(key=lambda r: (r["tier"], -r["score"]))

# Top no-repo tweets (for manual review)
no_repo_tweets.sort(key=tweet_score, reverse=True)
top_no_repo = []
for t in no_repo_tweets[:20]:
    if t["id"] not in seen_tweets:
        top_no_repo.append({
            "id": t["id"],
            "author": t["author"],
            "text": t["text"][:280],
            "likes": t["likes"],
            "views": t["views"],
            "url": t["url"],
            "is_kol": t["author"] in KOL_SET,
            "score": round(tweet_score(t), 1),
        })

# ── Update seen state ──
for r in ranked_repos:
    if r["repo"] not in seen_repos:
        seen_repos[r["repo"]] = {"first_seen": today, "tier": r["tier"]}
for tid in unique:
    if tid not in seen_tweets:
        seen_tweets[tid] = today

# ── Build output ──
new_repos = [r for r in ranked_repos if r["is_new"]]
old_repos = [r for r in ranked_repos if not r["is_new"]]

result = {
    "date": today,
    "stats": {
        "total_fetched": len(all_tweets),
        "unique_tweets": len(unique),
        "tweets_with_repos": len(tweet_repos),
        "unique_repos": len(repo_data),
        "new_repos": len(new_repos),
        "previously_seen_repos": len(old_repos),
    },
    "new_repos": new_repos,
    "previously_seen_repos": old_repos[:10],
    "no_repo_tweets": top_no_repo,
}

# ── Write outputs ──
with open(output_file, "w") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
with open(seen_repos_file, "w") as f:
    json.dump(seen_repos, f, ensure_ascii=False, indent=2)
with open(seen_tweets_file, "w") as f:
    json.dump(seen_tweets, f, ensure_ascii=False, indent=2)

# ── Summary ──
print(f"\n{'='*60}")
print(f"  {today} — Skill Pulse Report")
print(f"{'='*60}")
print(f"  Tweets: {len(all_tweets)} fetched → {len(unique)} relevant")
print(f"  Repos:  {len(repo_data)} found | {len(new_repos)} new | {len(old_repos)} seen before")
print(f"{'='*60}")

tier_names = {0: "T0 KOL", 1: "T1 Multi", 2: "T2 Hot", 3: "T3 Low"}
for tier in [0, 1, 2, 3]:
    tier_repos = [r for r in new_repos if r["tier"] == tier]
    if not tier_repos:
        continue
    print(f"\n  [{tier_names[tier]}] ({len(tier_repos)} repos)")
    for r in tier_repos[:5]:
        kol_str = f" (via {', '.join(r['kol_mentions'])})" if r['kol_mentions'] else ""
        print(f"    {r['repo']:40s} score={r['score']:>8.0f} ❤{r['total_likes']:>5d} mentions={r['mention_count']}{kol_str}")

if top_no_repo:
    print(f"\n  [No repo - manual review] ({len(top_no_repo)} tweets)")
    for t in top_no_repo[:5]:
        kol = " [KOL]" if t["is_kol"] else ""
        print(f"    @{t['author']:20s} ❤{t['likes']:>5d}{kol} {t['text'][:80]}...")

print(f"\n  Output: {output_file}")
PYEOF

# Clean up previous days' raw files (keep today's for cross-run merging)
find "$RAW_DIR" -name "*.json" ! -name "${TODAY}-*" -delete 2>/dev/null || true

echo "[done] Tracking complete."
