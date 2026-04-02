---
name: twitter-hot-topics
description: "Find the hottest tweets on any topic from the past 24 hours on Twitter/X, ranked by an engagement score. Use this skill whenever the user wants to discover trending tweets, find viral posts about a topic, check what's blowing up on Twitter, see the most popular tweets on a subject, or monitor Twitter buzz around a keyword. Also trigger when the user mentions 'hot tweets', 'trending on Twitter', 'viral tweets', 'Twitter engagement', or asks what people are saying on Twitter/X about something."
---

# Twitter Hot Topics Finder

Find and rank the hottest tweets on any given topic from the past 24 hours. Uses multi-angle search, noise filtering, RT aggregation, and a weighted engagement score to surface genuinely high-signal content.

## Step-by-Step Workflow

### 0. Prerequisites Check

Before starting, verify `opencli` is available:

```bash
which opencli
```

If `opencli` is not found:
1. Install: `npm install -g @jackwener/opencli`
2. Verify browser bridge: `opencli doctor`

The `twitter` command is built-in (not a plugin). If `opencli doctor` reports connectivity issues, tell the user to check their browser bridge setup.

Do NOT proceed until `which opencli` passes.

### 1. Extract the Topic

Identify the topic/keyword from the user's message. If the user gives a vague request, ask them to clarify the topic before proceeding.

### 2. Compute the Date Window

Calculate the `since:` date in `YYYY-MM-DD` format (UTC). Use the current UTC date minus 1 day, NOT the local date. For example, if it's 2026-04-02 16:00 UTC+8 (= 2026-04-02 08:00 UTC), the since date is `2026-04-01`.

### 3. Generate Search Queries (LLM Query Expansion)

Twitter search returns at most ~20 results per query. To get enough coverage for 50 results, you need 5-8 diverse query variations.

**Generate the queries yourself** by thinking about:
- The exact topic keyword(s) as-is
- Synonyms and abbreviations (e.g., "AI" ↔ "artificial intelligence")
- Related community slang and hashtags
- Different phrasings (noun vs verb form)
- Bilingual variants if the topic has a non-English audience (e.g., Chinese tech Twitter is huge)
- Narrower or broader scopes

For higher-signal queries, use Twitter's `min_faves:` operator to pre-filter noise. Use higher thresholds for broad/generic queries, lower for specific ones:
- Broad queries (single common word): add `min_faves:10` or `min_faves:20`
- Specific queries (multi-word phrases): no min_faves needed

**Example for topic "AI skills":**
```
"AI skills since:2026-04-01"
"AI agent skills since:2026-04-01"
"Claude skills since:2026-04-01"
"coding agent skill since:2026-04-01"
"npx skills add since:2026-04-01"
"skill min_faves:10 since:2026-04-01"
"MCP skill since:2026-04-01"
```

### 4. Fetch Tweets

Run each query with `--filter live` to get chronological results without personalization bias:

```bash
opencli twitter search "<query>" --filter live --limit 50 --format json
```

**Why `live` only:** `--filter top` is personalized to the logged-in account's interest graph, creating a filter bubble. `live` gives broader, unbiased coverage.

**Why `--limit 50`:** Twitter returns up to ~40 results at this limit. Higher values (e.g. 100) paradoxically return fewer results.

Collect all results into one pool.

### 5. Clean the Data

This step is critical for quality. Process the raw tweet pool through these filters:

#### 5a. Deduplicate by Tweet ID

When the same tweet appears in multiple searches, keep the version with the highest view count (views can update between fetches).

#### 5b. Three-Layer Relevance Filter

Apply a three-layer filter in order: blacklist → high-confidence pass → medium-confidence check. A tweet must survive the blacklist AND pass either the high-confidence or medium-confidence gate.

**Layer 1: NOISE BLACKLIST (hard reject)**

Before anything else, generate a blacklist of off-topic patterns **specific to this topic**. Think about what the keyword means in unrelated contexts and blacklist those uses. Be aggressive — false negatives (missing a good tweet) are much less costly than false positives (including junk).

How to generate the blacklist: for each keyword in the topic, ask "what other domains use this word?" and list 10-20 phrases from those domains.

**Layer 2: HIGH CONFIDENCE (auto-pass)**

Generate a list of phrases that **uniquely** identify on-topic usage with near-zero ambiguity. These are domain-specific jargon, product names, commands, or multi-word phrases that only appear in the context you care about. Pass tweets matching any of these immediately.

**Layer 3: MEDIUM CONFIDENCE (topic keyword as SUBJECT)**

For remaining tweets, apply the **subject test**: is the topic keyword the **subject** of the tweet (what it's about), or just **mentioned in passing**?

- ACCEPT if the tweet's core message is about the topic (announcing, reviewing, building, discussing it)
- REJECT if the topic word appears but the tweet is fundamentally about something else

**The filtering logic:**
```
if tweet matches BLACKLIST → REJECT
if tweet matches HIGH_CONFIDENCE → ACCEPT
if topic keyword is the SUBJECT of the tweet → ACCEPT
else → REJECT (when in doubt, reject — precision over recall)
```

#### 5c. Deduplicate Same-Author Same-Content

When the same author posts multiple tweets promoting the same product/link/content, keep only the highest-scoring one. Indicators of duplication:
- Same author + same URL or repo link
- Same author + overlapping text (>50% similar)
- Same install command or product name across tweets from the same author

This prevents the same content from inflating the results even when posted as separate tweets.

#### 5d. Aggregate Retweets

Pure retweets (text starting with "RT @username:") should be merged into their original tweet rather than listed separately. When you find a RT:
1. Match it to the original by comparing the RT's quoted author + text prefix against other tweets in the pool
2. If the original is found, add the RT's engagement (views, likes) to the original
3. Track who retweeted it (useful for identifying amplifiers)
4. Remove the RT entry from the pool

This prevents the same content from appearing multiple times and correctly stacks engagement.

#### 5e. Minimum Views Threshold

Discard tweets with fewer than 500 views. Low-view tweets are noise — they haven't been seen by enough people to matter.

#### 5f. Verify Recency

Double-check that all remaining tweets have a `created_at` within the last 24 hours. The `since:` operator handles most of this, but discard any stragglers.

### 6. Compute Engagement Score

`opencli twitter search` returns: `id, author, text, created_at, likes, views, url`. Calculate:

```
score = views + likes × 100 + retweets × 50
```

- **Views** (×1): passive impressions, high volume but lowest signal
- **Likes** (×100): active approval — someone deliberately tapped it; weighted heavily to prioritize genuine engagement over algorithmic reach
- **Retweets** (×50): active amplification — someone chose to share it with their followers

### 7. Rank and Select Top Results

Sort all tweets by `score` descending. Take the top 50 for the report (or fewer if less than 50 exist within 24h).

### 8. Output Format

Produce a report with two sections:

#### Summary Section

Write a brief analysis (3-5 sentences) covering:
- Total tweets found and how many unique after dedup/filtering
- The dominant themes or narratives across the top tweets
- Notable accounts driving the conversation (flag any KOLs / official accounts / high-follower authors)
- Any particularly viral outliers worth calling out

#### Ranked Table

Present results as a markdown table:

```markdown
| Rank | Author | Tweet | Likes | Views | Score | Link |
|------|--------|-------|-------|-------|-------|------|
| 1 | @handle | First 80 chars of tweet text... | 5.2K | 1.3M | 65,000 | [link](url) |
```

Formatting rules:
- **Tweet**: Truncate to ~80 characters, append `...` if truncated. Replace newlines with spaces.
- **Likes/Views**: Use human-readable format (1.2K, 3.5M, etc.)
- **Score**: Use comma-separated integers
- **Link**: Hyperlink text `[link]` pointing to the tweet URL

### 9. Save Results

Save the complete results to `.data/hot-tweets/` in the project directory for future reference.

**File path**: `.data/hot-tweets/<YYYY-MM-DD>_<topic-slug>.json`

- `<topic-slug>`: lowercase, spaces replaced with hyphens, max 50 chars (e.g., `agent-skill`, `ai-coding`)
- Create the directory if it doesn't exist: `mkdir -p .data/hot-tweets`
- If a `.gitignore` exists and does not already contain `.data/`, append `.data/` to it

**File format**:
```json
{
  "topic": "agent skill",
  "date": "2026-04-02",
  "since": "2026-04-01",
  "queries": ["query1", "query2", ...],
  "total_raw": 120,
  "total_filtered": 75,
  "tweets": [
    {
      "rank": 1,
      "id": "2039240359197438229",
      "author": "openclaw",
      "text": "full tweet text...",
      "created_at": "Wed Apr 01 07:16:03 +0000 2026",
      "likes": 2060,
      "views": 376435,
      "score": 397035,
      "url": "https://x.com/i/status/2039240359197438229"
    }
  ]
}
```

After saving, tell the user where the file was written.

### 10. Edge Cases

- **No results within 24h**: Tell the user no hot tweets were found for this topic in the last 24 hours. Run the search again without `since:` and show the most recent top results as a fallback.
- **Few results** (<10 tweets): Note this in the summary — the topic may not be actively discussed right now. Consider broadening the query variations.
- **Command failure**: If `opencli twitter search` fails, inform the user and suggest they check their browser session (opencli uses browser interception for Twitter search).
