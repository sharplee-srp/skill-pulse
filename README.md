# x-skill-track

Twitter/X skill trend tracker and agent skills for discovering hot content.

## Install Skills

```bash
npx skills add sharp/x-skill-track
```

### Available Skills

| Skill | Description |
|-------|-------------|
| `twitter-hot-topics` | Find the hottest tweets on any topic from the past 24h, ranked by engagement |
| `hot24h` | Quick hot tweet scanner with Haiku-powered query expansion |

## Automated Tracking (GitHub Actions)

Runs twice daily via cron to cover both Asia and US peak hours:
- **09:00 UTC** (17:00 GMT+8) — Asia peak
- **18:00 UTC** (02:00 GMT+8) — US peak

Each run executes two scripts:

### track.sh — Repo Discovery

Monitors 15 KOL accounts + 14 keyword searches, extracts GitHub repos, and ranks by tiered engagement:

- **T0** — KOL-recommended repos
- **T1** — 3+ independent mentions
- **T2** — High engagement single mention (100+ likes)
- **T3** — Low signal

Output: `data/YYYY-MM-DD.json`

### hot24h.sh — Hot Tweet Ranking

Broad search with local relevance filtering, RT aggregation, and cross-day dedup.

- Scoring: `views + likes × 100 + retweets × 50`
- Min views: 500
- Same-author dedup for duplicate promotions
- Cross-day intelligence: seen tweets only resurface if score jumps 3x

Output: `data/hot24h-YYYY-MM-DD.json`

## Local Usage

```bash
# Local (uses opencli browser bridge)
./track.sh
./hot24h.sh

# CI mode (uses bird CLI with auth tokens)
BIRD_AUTH_TOKEN=xxx BIRD_CT0=yyy ./track.sh
BIRD_AUTH_TOKEN=xxx BIRD_CT0=yyy ./hot24h.sh
```

## GitHub Actions Setup

Requires two repo secrets:
- `BIRD_AUTH_TOKEN` — Twitter auth_token cookie
- `BIRD_CT0` — Twitter ct0 cookie
