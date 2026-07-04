# People Intelligence: a living relationship graph

**Date:** 2026-07-04
**Status:** Approved (autonomous goal directive — decisions documented inline)

## Problem

The CRM ranks people with per-person arithmetic (`CommunicationScore`) and
surfaces reconnects from four static categories. Kent's ask: make the people
layer *evolve like PageRank* from real interactions across email, texts, and
calendar; surface people relevant to his goals; lead with people he is about
to meet; and enrich people from the public web when the CRM is thin. Today:

- No network effects: a person's importance ignores who else they connect to.
  The score cannot distinguish "assistant who emails a lot" from "person at
  the center of the meetings that matter."
- Goal matching (`GoalPeopleDiscovery`) is keyword overlap with hardcoded
  domain terms — contra the product principle that models make semantic
  decisions, and it misses everything phrased differently.
- Upcoming meetings drive briefing dossiers but not the People surface. "Who
  am I meeting in the next few weeks and what do I owe them?" has no lane.
- Web enrichment happens only transiently inside meeting briefings for
  *unmatched* attendee names; nothing durable ever lands on the person.

## Design

Four components, each behind the existing `Maraithon.Crm` API, all riding the
existing reactive job chain (ingest → window flush → `relationship_ingestion`
→ scoring jobs) so intelligence refreshes every time new interaction data
lands — that continuous re-ranking is the "grows and evolves" property.

### 1. `Maraithon.Crm.RelationshipGraph` — personalized PageRank

New module + migration `add_network_rank_to_crm_people` (integer 0–100,
default 0, indexed; `crm_people.metadata["graph_signals"]` carries detail).

**Graph construction** (180-day window, same recency decay as
`CommunicationScore`: `exp(-age_days/45)`):

- *Teleport vector (user → person):* direct interaction mass per person —
  the same event set `CommunicationScore` uses (messages, calendar,
  observations, todo links, with its source weights and direction
  multipliers), normalized to sum 1. People the user actually talks to
  anchor the walk.
- *Person ↔ person edges* (symmetric, decayed):
  - **Calendar co-attendance** (weight 2.0/pair/event): events with 2–10
    non-self attendees resolving to people → pairwise edges.
  - **Observation co-participants** (weight 1.0): `crm_observations` rows
    whose `resolved_person_ids` contain ≥2 people (email threads, Slack).
  - **Group-chat co-senders** (weight 1.0): people whose `sender_handle`s
    appear in the same `local_messages.chat_key` within the window (group
    chats only; senders are the only participants the mirror stores).

**Algorithm:** personalized PageRank, damping 0.85, teleport to the direct-
interaction vector; ≤30 iterations or L1 delta < 1e-8. Dangling mass returns
to the teleport vector. For a few thousand people this is milliseconds in
pure Elixir; no dependency needed.

**Output per person:** `network_rank` = percentile of PageRank mass among
people with nonzero mass, scaled 0–100. `graph_signals` = rank, percentile,
`direct_share` vs `network_share` (how much of their mass is network lift),
top 5 strongest connections (person_id + name + edge weight), computed_at.

**Trigger:** a `relationship_graph_refresh` background job enqueued alongside
`communication_score_refresh` in `background_job_handler.ex` (deduped per
user, same as its siblings).

**Consumption:** `ReconnectSuggestions.priority/7` blends `network_rank` into
the base (replacing part of the flat strength term), and candidate pooling
includes `network_rank > 0`. `communication_score` remains the direct-touch
score; `network_rank` is the graph view. Both serialize to mobile/web.

### 2. `Maraithon.Crm.UpcomingMeetings` — the meet-soon lane

`people_meeting_soon(user_id, days: 21, limit:)`: `local_calendar_events`
with `start_at` in `[now, now+days]`, not all-day, 1–10 non-self attendees;
resolve attendee/organizer emails through the person handle index; group by
person → `%{person, next_meeting_at, next_meeting_title, meeting_count}`.

`ReconnectSuggestions` gains category `:meeting_soon` at the **top** of the
classify precedence (Kent: "especially folks you are looking to meet in the
next few weeks"). Reason: "Meeting Sarah Thursday: Board prep — 3 open items,
last spoke 34 days ago." Suggested action: prep-oriented. Priority weight 95
(above open_work's 80), scaled by meeting proximity. Serializers (mobile
`reconnect_suggestion/1`, PeopleLive) add `next_meeting_at` /
`next_meeting_title`. `Crm.meeting_soon/2` exposes the lane directly for the
CoS and mobile.

### 3. Semantic goal matching — upgrade `GoalPeopleDiscovery`

Keep the lexical scorer as fallback; add an embedding path gated on
`PersonEmbeddings.embedding_storage_available?/0`:

- Embed `goal_text/1` via `Maraithon.LLM.Embeddings.embed/2`.
- pgvector cosine against `crm_people.embedding`, top 25 per goal,
  similarity threshold 0.45 (consistent with `semantic_find_person`).
- Candidate confidence = `max(lexical, similarity * 0.9)`, reason notes the
  semantic match. Hardcoded domain keyword table stays only as fallback.

Existing `goal_links` persistence, dedupe, and the reconnect goal lane are
unchanged — they just get better links.

### 4. `Maraithon.Crm.PersonEnrichment` — durable web enrichment

`ensure_enrichment(user_id, person, opts)`:

- Skip when `metadata["enrichment"]["fetched_at"]` is < 30 days old, when
  `WebSearch.enabled?()` is false, or when the person lacks a usable name.
- Query: display name + org/title/relationship hints from person fields and
  `local_contacts` org data when linked. `WebSearch.search/2` (existing
  DuckDuckGo backend, bounded), keep top 3 `{title, url, snippet}`; fetch
  the first result page for a bounded excerpt.
- Store `metadata["enrichment"] = %{"summary_snippets", "sources",
  "query", "fetched_at"}`. Never overwrite user-authored `notes`.

**Trigger:** `person_enrichment` background job after the graph refresh:
enrich people meeting in the next 21 days without fresh enrichment, capped
at 5 people per run (rate respect for the search backend). Meeting dossiers
(`MeetingEnrichment`) and the mobile person serializer include enrichment,
so pre-meeting prep gets public context even for well-known contacts.

## Data flow

```
device/connector ingest
  → Crm.Ingest window flush → relationship_ingestion
    → communication_score_refresh   (existing)
    → relationship_graph_refresh    (new)   → network_rank + graph_signals
    → goal_people_discovery         (upgraded: embeddings-first)
    → person_enrichment             (new, bounded to meet-soon people)
People surface: ReconnectSuggestions (meeting_soon → open_work → goal_aligned
→ overdue → going_quiet) + goal lane; CoS briefings pull the same context.
```

## Error handling

Each job is isolated and idempotent: graph refresh no-ops with < 2 people or
no events; embedding path degrades to lexical when pgvector/embeddings are
unavailable; enrichment no-ops when WebSearch is disabled or rate-capped;
all failures log and never block the score refresh chain.

## Testing

Deterministic unit tests: graph math on a small fixture (hub person outranks
high-volume broadcast sender; teleport dominance; convergence), meeting-soon
resolution incl. self-exclusion and all-day/large-event filtering, enrichment
staleness gating. Written to compile now; broad suite runs stay deferred per
current verification mode (compile-scoped checks + prod verification).

## Rollout

Single deploy (release migration runs automatically). Post-deploy: trigger
`relationship_graph_refresh` + `goal_people_discovery` for Kent's user via
remote eval, then verify `/api/mobile/people/reconnect` leads with
meeting-soon entries and people carry `network_rank`/`graph_signals`/
`enrichment` metadata.

## Decisions made autonomously (flag if wrong)

1. `network_rank` is a **new column**, not a rewrite of
   `relationship_strength` (that stays LLM/manual-owned) — the two measure
   different things and both feed priority.
2. Meeting-soon outranks open-work in the reconnect surface, per the goal's
   emphasis; open work about that person folds into the meeting-soon reason
   rather than competing with it.
3. Enrichment uses the existing DuckDuckGo `WebSearch` (no new API keys) and
   is capped, durable, and 30-day-stale-refreshed rather than per-briefing.
4. Person↔person message edges use group-chat co-senders only — the message
   mirror does not store full group membership, and senders are the honest
   signal available.
