---
created_at: 2026-05-15T04:06:35Z
created_by: cybrus
cybrus_task_id: F6D69798-494B-48BC-AB89-A19941A826E6
project: Maraithon App
status: inprogress
---
# Ship People/CRM data model with semantic merge and source links

Status: In progress - upgraded as a delta against the existing `Maraithon.Crm` implementation
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: F6D69798-494B-48BC-AB89-A19941A826E6
- Workflow: WORKFLOW.md

## Dependencies

- None

## Notes

Cybrus PM Summary
Give Maraithon a first-class People layer so the assistant can answer who someone is, how Kent knows them, and what he owes them — unlocking the entire relationship-shaped product surface.

Why This Matters
The goals doc treats People/CRM as a core data model alongside Todos and Memory, but the existing backlog has nothing for it. Almost every "Next" feature (waiting-on, relationship maintenance, connected context review, action drafting) is gated on having a real People layer with source links. This is the highest-leverage Phase A ticket.

## Workflow Context

Deterministic Cybrus configuration:
- Execution mode: local Codex CLI with full local workspace access.
- Task source: Orchestrator/Cybrus task queue.
- Workflow file: WORKFLOW.md
- Workflow file found: no
- Human handoff: produce proof of work, then Cybrus writes a local review packet.

Repository workflow instructions:
No repository workflow instructions were found. Use the existing codebase conventions.

## Objective

Ship a durable People/CRM data layer in Maraithon (Phoenix 1.8 + Ecto + Postgres) that supports:

- Per-user `people` records with structured identity, preferred channel, cadence, and metadata.
- Multi-identifier identity resolution (email, slack_id, telegram_id, phone, github, whatsapp).
- Polymorphic `person_links` to todos, emails, Slack threads, calendar events, memories, and projects, each carrying source system, account, item id, evidence quote, and model rationale.
- Tool-callable CRUD plus a semantic merge primitive that lets the model collapse near-duplicates (e.g. "Charlie" in Slack and "Charles Smith" in Gmail) with auditable evidence.
- A one-shot backfill that seeds People from existing source-tagged todos.
- A Telegram-friendly person card serializer.

This is Phase A — pure data layer, tools, backfill, serializer. Drift detection, waiting-on, and action drafting are explicitly out of scope.

## 2026-05-20 Delta Decision

The current codebase already ships the Phase A CRM foundation under `Maraithon.Crm`:

- `crm_people` and `crm_person_links` migrations and schemas exist.
- `Maraithon.Crm` supports list/search/get/create/update/upsert, contact-detail identity matching, fuzzy name matching, pgvector semantic lookup, resource links, relationship context, and ingestion paths.
- Model-callable CRM tools already exist: `list_people`, `get_person`, `upsert_person`, `delete_person`, `link_person_data`, `get_relationship_context`, and `learn_relationship_context`.

Do **not** create a new `Maraithon.People` context or duplicate `people` tables. The implementation target is a focused delta on top of the existing CRM surface:

1. Add auditable model-callable merge to `Maraithon.Crm`.
2. Add source-evidence fields to `crm_person_links` without breaking existing `resource_source` / `relationship_note` callers.
3. Add a Telegram-friendly person card serializer for compact relationship answers.
4. Keep merged people hidden from normal list/search/upsert resolution while preserving the row and audit trail.
5. Register the merge tool in the same first-party tool registry and Chief of Staff allowlists as the existing CRM tools.

Separate identifier tables, a full People LiveView, and one-shot historical backfill are deferred unless this delta exposes a real blocker. The existing `contact_details` map, CRM ingestion loop, and local source ingestion already cover the immediate product need with less schema churn.

## Delta Acceptance Checks

- [ ] `crm_people` has `status`, `merged_into_id`, and `merged_at`; default list/search/upsert resolution ignores merged rows.
- [ ] `crm_person_links` can store `role`, `source_system`, `source_account`, `source_ref`, `evidence_quote`, `model_rationale`, and `confidence`.
- [ ] `crm_person_merges` records every merge with user id, surviving person, merged person, evidence, rationale, performer, metadata, and timestamp.
- [ ] `Maraithon.Crm.merge_people/4` runs transactionally, verifies same-user ownership, rejects self/double merges, repoints non-duplicate links, collapses duplicate links deterministically, merges contact details/relationship metrics, marks the merged row, and writes an audit row.
- [ ] A model-callable `merge_people` tool exists with JSON schema and tool-catalog/capability registration.
- [ ] `Maraithon.Crm.Serializer.telegram_card/2` renders a compact Markdown person card with name, relationship, preferred channel, last touch, open-loop count, recent sources, and no tables.
- [ ] Tests cover successful merge, invalid ownership/self merges, duplicate link collapse, source-evidence serialization, tool execution, and Telegram card output.
- [ ] `mix precommit` passes before this spec can move to `done`.

---

## Assumptions and Decisions

**Stack and conventions**
- Phoenix 1.8 + Ecto + Postgres (matches current Maraithon deployment).
- New context module `Maraithon.People` follows existing context pattern (parallel to `Maraithon.Todos`, `Maraithon.Memory` if present).
- Migrations use `Ecto.Migration` with `:bigint` primary keys to match existing schema convention (verify against existing migrations during implementation; fall back to whatever convention `priv/repo/migrations` already uses).
- Tool surface uses the same MCP-style tool registration used by other Chief of Staff tools (todos, memory). If a `Maraithon.Tools.Registry` (or equivalent) exists, register there; otherwise mirror the pattern used by `Maraithon.Todos` tools.

**Identity model**
- A Person is **per user** (`user_id` FK, `on_delete: :delete_all`). No cross-user sharing in Phase A.
- Identifiers live in a separate `person_identifiers` table, not as columns on `people`, because one person commonly has multiple emails, multiple Slack workspaces, etc.
- Identifier values are encrypted via Cloak; a `normalized_value` column (lowercased, trimmed; for phone, E.164) is stored **unencrypted but hashed via `Cloak.Fields.SHA256`** (or equivalent blind-index pattern) so the assistant can look up by identifier without decrypting every row. Mirror whatever blind-index approach Maraithon already uses for credentials/email lookup.
- Unique constraint on `(user_id, kind, normalized_hash)` to prevent duplicate identifiers within a user.

**Links**
- `person_links` is polymorphic by string `linkable_type` + `linkable_id`. Supported types in Phase A: `"todo"`, `"email"`, `"slack_thread"`, `"calendar_event"`, `"memory"`, `"project"`.
- Each link records `source_system`, `source_account`, `source_ref`, `role` (free-form string, model-chosen but validated against an allowlist: `mentioned`, `sender`, `recipient`, `attendee`, `owed_by`, `owed_to`, `participant`, `subject_of`), `evidence_quote` (encrypted), `model_rationale` (encrypted), `confidence` (`:float`).
- Unique constraint on `(person_id, linkable_type, linkable_id, role)` to prevent duplicate links.

**Merge**
- Merge is a **model-proposed, runtime-validated** operation. The model calls `people.merge(surviving_id, merged_id, evidence)` with a rationale; the runtime:
  1. Confirms both persons belong to the same user.
  2. Confirms neither is already merged (no double-merge).
  3. Re-points all identifiers, links, and notes from `merged_id` to `surviving_id`, resolving identifier-uniqueness collisions by keeping the surviving person's identifier and discarding the duplicate.
  4. Soft-deletes the merged person (status `:merged`, `merged_into_id` set).
  5. Writes a `person_merges` audit row with evidence and rationale.
- Merges are reversible only via manual SQL in Phase A; no `unmerge` tool yet (recorded as Phase B risk).

**Preferred channel**
- Stored as a column (`preferred_channel` string) but **inferred** rather than user-declared. Phase A: the field exists and can be set via `people.update`; an `infer_preferred_channel/1` helper looks at the most recent N links by `source_system` and picks the dominant one. No background recomputation job in Phase A — call it inline when serializing for Telegram.

**Backfill**
- One-shot Oban job (or whatever durable queue Maraithon uses — check `lib/maraithon/workers/` for existing job pattern) iterates the user's todos that have `source_account` and `source_ref`.
- For each todo, fetch the underlying source item (gmail message, slack message, calendar event) via existing connectors and extract participant identifiers.
- For each unique identifier, call an LLM-backed `propose_person/2` step that either matches an existing Person (and adds the identifier + link) or creates a new Person.
- Backfill is **idempotent**: re-running should produce zero net changes once stable. Idempotency comes from identifier-uniqueness and link-uniqueness constraints, not from a "have we processed this" flag.
- Backfill is per-user, triggered by an admin LiveView button or `mix maraithon.people.backfill <user_id>`.

**Telegram serializer**
- `Maraithon.People.Serializer.telegram_card/1` returns a short Markdown block: name, preferred channel, last touch (relative), 1–2 open loops linked to the person, and a "Sources: Gmail (2), Slack (1)" footer. No tables.

**Out of scope (explicit)**
- Drift detection, waiting-on tracker, action drafting, relationship maintenance check-ins — Phase B tickets.
- Cross-user sharing.
- iMessage / WhatsApp identifier ingestion (column allowed, but no source pipeline).
- Unmerge tool.
- LiveView person browser UI beyond a minimal index/show for verification.

---

## Implementation Plan

**Step 1 — Schema and migrations**
1. Create migration `add_people_tables`:
   - `people`: `id`, `user_id` (FK), `first_name`, `last_name`, `display_name`, `preferred_channel`, `relationship_to_user`, `communication_cadence`, `notes` (encrypted text), `metadata` (jsonb default `{}`), `last_touch_at` (utc_datetime), `status` (string default `"active"`, allowed: `active|merged|archived`), `merged_into_id` (FK to `people`, nullable), timestamps.
   - `person_identifiers`: `id`, `person_id` (FK, on_delete: delete_all), `kind` (string), `value` (encrypted binary), `normalized_hash` (binary, blind index), `source` (string), `confidence` (float), `verified_at` (utc_datetime, nullable), timestamps.
   - `person_links`: `id`, `person_id` (FK), `linkable_type` (string), `linkable_id` (bigint), `role` (string), `source_system` (string), `source_account` (string), `source_ref` (string), `evidence_quote` (encrypted text), `model_rationale` (encrypted text), `confidence` (float), timestamps.
   - `person_notes`: `id`, `person_id` (FK), `body` (encrypted text), `author` (string), `source` (string), timestamps.
   - `person_merges`: `id`, `user_id`, `surviving_person_id`, `merged_person_id`, `evidence` (encrypted text), `model_rationale` (encrypted text), `performed_by` (string), `performed_at` (utc_datetime), timestamps.
2. Indexes:
   - `people`: `(user_id)`, `(user_id, status)`.
   - `person_identifiers`: unique `(person_id, kind, normalized_hash)`, lookup `(kind, normalized_hash)` (scoped to user via join).
   - `person_links`: unique `(person_id, linkable_type, linkable_id, role)`, lookup `(linkable_type, linkable_id)`.
   - `person_merges`: `(surviving_person_id)`, `(merged_person_id)`.

**Step 2 — Ecto schemas + changesets**
- `Maraithon.People.Person` with `has_many :identifiers`, `has_many :links`, `has_many :notes`, `belongs_to :merged_into, __MODULE__`.
- `Maraithon.People.Identifier` with `belongs_to :person`. Changeset normalizes value (downcase email, E.164 phone) and computes `normalized_hash` via existing Cloak `HashField` helper.
- `Maraithon.People.Link` with polymorphic helpers `linkable/2` and role allowlist validation.
- `Maraithon.People.Note`, `Maraithon.People.Merge` straightforward.

**Step 3 — Context API (`Maraithon.People`)**
- `list_people(user, opts)` with status filter.
- `get_person!(user, id)` user-scoped.
- `search(user, query, opts)` — fuzzy on name (pg trigram if available; otherwise `ILIKE`), plus identifier hash exact match if query parses as email/slack handle/phone.
- `create_person(user, attrs)` — accepts nested identifiers and an initial link.
- `update_person(user, id, attrs)`.
- `merge_people(user, surviving_id, merged_id, evidence, rationale)` — runs in a transaction; re-points identifiers, links, notes; collapses duplicates; writes audit row; sets `status: :merged`, `merged_into_id` on the merged record.
- `link(user, person_id, linkable_ref, role, source_meta, evidence, rationale)` — upserts on the unique key.
- `unlink(user, link_id)`.
- `timeline(user, person_id, limit)` — reads `person_links` ordered by `inserted_at` desc with eager-loaded `linkable` records.
- `infer_preferred_channel(person)` — pure function over loaded links.
- `touch_last_seen(person, at)` — updates `last_touch_at`.

**Step 4 — Tool surface**
- Add `Maraithon.People.Tools` module exposing tool definitions in the same shape as existing Maraithon tools (check `lib/maraithon/tools/` for the convention — likely `name`, `description`, `parameters` JSON schema, `execute/2`).
- Tools: `people.search`, `people.get`, `people.create`, `people.update`, `people.merge`, `people.link`, `people.unlink`, `people.timeline`.
- Each tool receives a `user_id` from the calling agent's context; never trust a user_id passed in by the model.
- Register the tools with whatever registry the Chief of Staff and Telegram assistant use.

**Step 5 — Backfill job**
- `Maraithon.People.Backfill` worker (Oban or existing queue):
  - Args: `%{user_id: id}`.
  - Streams `Todos` where `source_account` and `source_ref` are present, batched (e.g. 50).
  - For each batch, calls a per-source extractor (`Maraithon.People.Backfill.GmailExtractor`, `SlackExtractor`, `CalendarExtractor`) that already knows how to fetch participants via existing connector modules.
  - Calls `propose_person/2` (LLM-backed in `Maraithon.People.Proposer`) with candidate identifier + existing user People as context; the model returns either `{:match, person_id}` or `{:create, attrs}`.
  - Applies result via `link/7` or `create_person/2 + link/7`.
- Admin trigger: a small LiveView button on the existing operator workspace, plus a `mix maraithon.people.backfill USER_ID` task that enqueues the job.

**Step 6 — Telegram serializer + minimal LiveView**
- `Maraithon.People.Serializer.telegram_card/1` produces the short Markdown card described above.
- Add a minimal `PeopleLive.Index` and `PeopleLive.Show` under the operator workspace using existing Catalyst/Tailwind primitives (`core_components.ex` first, then `~/bliss/aitools/catalyst-ui-kit`). Index = row list with name, preferred channel, last touch, open-loop count. Show = card + identifiers + timeline. **Do not** build a one-off table component; use the same row pattern already used for todos/connectors.

**Step 7 — Tests**
- Schema tests for each changeset (encryption, normalization, blind-index hash, role allowlist).
- Context tests for `merge_people` covering: identifier collision, link collision, audit row written, status transitions.
- Tool integration tests that exercise the model-facing tool contract (validate JSON schema, user_id injection, error envelope).
- Backfill test with a fixture user that has 5 todos across 3 sources, asserting idempotency on second run.

**Step 8 — Verification**
- `mix ecto.migrate` clean in dev and staging.
- `mix test` green.
- Manually run backfill against Kent's dev user and spot-check: at least one Person created per active source, no obvious dupes, identifiers correctly attached.
- Manually exercise tools from `iex` (or via Telegram if the registry is live): create → link → search → merge → timeline.

---

## Files and Interfaces

**New files**
- `priv/repo/migrations/<timestamp>_add_people_tables.exs`
- `lib/maraithon/people.ex` (context)
- `lib/maraithon/people/person.ex`
- `lib/maraithon/people/identifier.ex`
- `lib/maraithon/people/link.ex`
- `lib/maraithon/people/note.ex`
- `lib/maraithon/people/merge.ex`
- `lib/maraithon/people/search.ex`
- `lib/maraithon/people/serializer.ex`
- `lib/maraithon/people/tools.ex`
- `lib/maraithon/people/proposer.ex`
- `lib/maraithon/people/backfill.ex` (Oban worker or equivalent)
- `lib/maraithon/people/backfill/gmail_extractor.ex`
- `lib/maraithon/people/backfill/slack_extractor.ex`
- `lib/maraithon/people/backfill/calendar_extractor.ex`
- `lib/maraithon_web/live/people_live/index.ex`
- `lib/maraithon_web/live/people_live/show.ex`
- `lib/mix/tasks/maraithon.people.backfill.ex`
- `test/maraithon/people_test.exs`
- `test/maraithon/people/merge_test.exs`
- `test/maraithon/people/tools_test.exs`
- `test/maraithon/people/backfill_test.exs`

**Modified files**
- `lib/maraithon_web/router.ex` — mount `/people` routes inside the existing authenticated operator scope.
- The tool registry module wherever Chief-of-Staff and Telegram tools register (search `lib/maraithon` for `def tools` or `register_tool`).
- The operator workspace LiveView — add a "People" nav row.

**Tool contract (JSON schema sketch)**
- `people.search`: `{ query: string, limit?: int }` → `{ results: [{ id, display_name, preferred_channel, last_touch_at, identifier_hint }] }`
- `people.get`: `{ id: int }` → full person + identifiers + recent links
- `people.create`: `{ first_name?, last_name?, display_name, identifiers: [{kind, value}], initial_link?: {...} }` → `{ id }`
- `people.update`: `{ id, patch: {...} }` → `{ id }`
- `people.merge`: `{ surviving_id, merged_id, evidence: string, rationale: string }` → `{ surviving_id, merged_link_count, merged_identifier_count }`
- `people.link`: `{ person_id, linkable: {type, id}, role, source: {system, account, ref}, evidence, rationale, confidence? }` → `{ link_id }`
- `people.unlink`: `{ link_id }` → `{ ok: true }`
- `people.timeline`: `{ person_id, limit?: int }` → `{ entries: [{linkable_type, linkable_id, role, source_system, at, summary}] }`

---

## Acceptance Checks

1. `mix ecto.migrate` applies cleanly on a fresh database and on a database with existing Maraithon production schema.
2. `mix test` green, including new schema, context, tool, and backfill tests.
3. From `iex`:
   - Create a Person with two email identifiers and one Slack identifier.
   - `people.search` finds the Person by either email and by Slack handle.
   - Create a second near-duplicate Person; `people.merge` collapses them; identifiers re-point; audit row exists; second Person has `status: :merged`.
   - `people.link` ties the Person to an existing Todo; `people.timeline` returns the link with source metadata and evidence quote.
4. Backfill run for Kent's dev user produces at least one Person per active source, with identifiers and links. A second run produces zero new Persons and zero new links (idempotent).
5. Telegram serializer produces a card under ~600 characters with no Markdown tables.
6. LiveView `/people` index and show pages render using existing Catalyst components — no new bespoke table/list primitives.
7. All encrypted columns are unreadable via raw SQL; blind-index lookups still work.
8. Tool call from the Chief of Staff agent (via the registry) can create a Person end-to-end without exception.

---

## Proof of Work Expectations

The coding agent should produce, in the local workspace:

- A single feature branch with all migrations, schemas, context, tools, backfill, serializer, minimal LiveView, and tests.
- `mix test` output captured showing the full new suite green.
- `mix ecto.migrate` and `mix ecto.rollback` output for the new migration, demonstrating the migration is reversible.
- An `iex` transcript or test fixture showing the create → link → search → merge → timeline flow described in acceptance check 3.
- A backfill transcript against the dev user showing first-run creations and second-run zero-delta idempotency.
- A short note in the PR description listing any assumption from this plan that turned out to be wrong and how the implementation diverged, plus a screenshot of the `/people` index and a sample `telegram_card/1` rendering.

---

## Risks

- **Blind-index lookup pattern mismatch.** Maraithon may not yet have a Cloak blind-index helper. If not, the implementation must add one (small, well-trodden pattern) or fall back to encrypting `value` and storing a separate plaintext `normalized_value` with an application-level constraint. Decide during Step 1 after reading existing Cloak usage.
- **Polymorphic links without DB-level FK.** `person_links.linkable_id` cannot be FK-enforced across tables. Mitigation: validate `linkable_type` against an allowlist in the changeset and add an application-level existence check in `link/7`. Accept that orphaned links are possible if the underlying record is hard-deleted; today's Maraithon mostly soft-deletes, so this is low risk in practice.
- **Semantic merge collisions.** When merging two Persons with overlapping identifiers or links, the merge transaction must deterministically pick a winner. Plan: always keep the surviving Person's row, drop the duplicate on a unique-key conflict; record the dropped row in the audit `evidence` field for reversibility.
- **Backfill cost.** LLM-backed `propose_person` per identifier across a user's full todo history can be expensive. Mitigation: dedupe candidate identifiers before calling the model; cap per-run identifier count (e.g. 500) and resume on next invocation; log token spend via the existing instrumentation.
- **No unmerge in Phase A.** A bad merge requires manual SQL. Acceptable for a single-user dogfood phase, but flag for Phase B.
- **PII encryption + search tradeoff.** Encrypting names would break trigram fuzzy search. Decision: leave `display_name`, `first_name`, `last_name` **unencrypted** (they are operationally needed for search and Telegram display); encrypt `notes`, identifier `value`, `evidence_quote`, `model_rationale`. Revisit if compliance posture changes.
- **Drift with existing Todo schema.** If the existing `todos` table does not already carry `source_account` / `source_ref` consistently, backfill coverage will be partial. Mitigation: backfill simply skips todos without source metadata and logs the skip count; this is expected and not a blocker.
