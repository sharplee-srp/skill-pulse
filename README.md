# skill-pulse

Daily tracker for hot AI coding skills trending on X/Twitter. Discovers skill repos via KOL monitoring and keyword search, extracts GitHub links, deduplicates at the repo level, and ranks by tiered engagement signals.

## How it works

```
KOL tweets (15 accounts)  ──┐
                             ├─→ normalize → dedup → filter → extract repos → tier & rank
Keyword search (14 queries) ─┘
```

**Tiered ranking:**
- **T0** — KOL-recommended repos (highest priority)
- **T1** — Repos mentioned by 3+ independent tweets
- **T2** — Single mention with high engagement (100+ likes)
- **T3** — Low signal

## Output

Daily JSON in `data/YYYY-MM-DD.json`:

```json
{
  "date": "2026-04-01",
  "stats": { "total_fetched": 360, "unique_repos": 30, "new_repos": 30 },
  "new_repos": [
    {
      "repo": "user/repo",
      "github_url": "https://github.com/user/repo",
      "tier": 0,
      "score": 17608,
      "mention_count": 1,
      "kol_mentions": ["steipete"],
      "best_tweet": { "author": "...", "text": "...", "url": "..." }
    }
  ]
}
```

## Usage

```bash
# Local (uses opencli browser bridge)
./track.sh

# CI (uses bird CLI with auth tokens)
BIRD_AUTH_TOKEN=xxx BIRD_CT0=yyy ./track.sh
```

## GitHub Actions

Runs daily at 17:00 GMT+8 via cron. Requires two repo secrets:
- `BIRD_AUTH_TOKEN` — Twitter auth_token cookie
- `BIRD_CT0` — Twitter ct0 cookie
