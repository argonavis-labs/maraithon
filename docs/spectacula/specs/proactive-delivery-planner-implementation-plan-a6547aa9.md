---
status: ready
cybrus_task_id: A6547AA9-52E7-42A3-ADB9-27E6B036BB32
project: Maraithon App
created_by: cybrus
created_at: 2026-05-14T19:23:06Z
---

# Proactive Delivery Planner Implementation Plan

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: A6547AA9-52E7-42A3-ADB9-27E6B036BB32
- Workflow: WORKFLOW.md

## Dependencies

- None

## Notes

No additional notes were attached to this task.

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

Insert a single per-user, model-driven planning stage between proactive **candidate generation** and **Telegram delivery**. Today three proactive paths — `Runtime.ProactiveCheckIn`, `InsightNotifications`, and `BriefingCron`/`Briefs` — each call `PushBroker.deliver*` directly and independently. Only the check-in path has a model interrupt decision; insights and briefs hardcode `interrupt_now: true`. The only cross-path guardrail is `PushBroker.suppress_for_rate_limit?`, which *drops* low-urgency sends after 3/hour rather than batching them, and the `PushReceipt` decisions `queued_digest` and `merged` are declared but never produced.

This milestone adds a durable `proactive_candidates` queue that all three sources enqueue into, and a `DeliveryPlanner` that gathers a user's pending candidates, makes **one** `AssistantHarness.plan_delivery/2` model call assigning each candidate a disposition (`interrupt_now` / `digest` / `hold`), then dispatches: interrupt-now items sent individually, digest items bundled into one message plus per-candidate cards, held items left queued. Everything is gated behind a new `:proactive_delivery_planner_enabled` flag (default `false`); legacy direct-delivery paths stay intact and exercised by existing tests until the flag is flipped.

**Out of scope:** insight scoring thresholds, briefing cadence, the inbound chat `Runner`, the proactive check-in *content* model call (`Proactive.plan_check_in` still generates message content — only *where it goes* changes), and removal of legacy delivery paths (a deliberate follow-up).

---

## Assumptions and Decisions

- **No WORKFLOW.md found.** Following existing codebase conventions: `Maraithon.DataCase` + ExUnit, TDD task ordering, binary_id PKs, `:utc_datetime_usec` timestamps, `references(:users, type: :string)`, `~w(...)` constant lists, OpenTelemetry via `Maraithon.Tracing`, LLM stubbed in tests via `llm_complete:` opt.
- **Flag-gated, dormant-by-default.** Every change is inert until `PROACTIVE_DELIVERY_PLANNER_ENABLED=true`. This keeps the milestone safe to merge and lets existing tests act as the legacy-path regression guard.
- **Queue idempotency** via a partial unique index on `(user_id, dedupe_key) WHERE status IN ('pending','planned')`. A second enqueue of a live key returns the existing row unchanged rather than erroring or overwriting.
- **`queued` counts as `sent`** in the check-in cron reducer, so the existing log line stays meaningful ("candidates produced this cycle").
- **`telegram_opts` stored as a `:map`** (string keys); `DeliveryPlanner` converts back to the keyword list `TelegramResponder`/`send_turn` expect via a `telegram_opts_to_keyword/1` helper that prefers `String.to_existing_atom/1`.
- **Disposition vocabulary** is fixed at `interrupt_now` / `digest` / `hold`, validated in both the schema (`@dispositions`) and the harness (`@valid_dispositions`).
- **Origin-type mapping for dispatch:** `insight → "insight"`, `brief → "brief"`, `proactive_check_in → "assistant_digest"`; the digest parent always uses `"assistant_digest"`.
- **Stale candidates expire** after a configurable TTL (`proactive_candidate_ttl_minutes`, default 120) swept once per check-in tick.
- **Fixture field names** for `Maraithon.Insights.create_insight/1`, `InsightNotifications.Delivery`, and `Briefs.Brief` must be confirmed against the live files during implementation; the behaviour under test does not change if names differ.
- **Test file existence** for `assistant_harness_test.exs` and `proactive_check_in_test.exs` must be confirmed; if absent, create following `DataCase` / `briefing_cron_test.exs` conventions.
- **Audit trail:** one `ActionLedger` entry per planning cycle (`event_type: "proactive.delivery_planned"`), mirroring `Proactive.record_proactive_decision/5` — best-effort, never raises.

---

## Implementation Plan

Four phases, TDD throughout (failing test → implementation → passing test → commit per task).

### Phase 1 — Candidate queue (schema + context)
Adds the durable queue. No behavior change to any delivery path.

- **1.1 Migration** — `proactive_candidates` table: binary_id PK, `user_id` FK, `source`/`source_id`/`dedupe_key`, `title`/`body`/`urgency`/`why_now`, `structured_data`/`telegram_opts` maps, `status`/`disposition`/`plan_reason`, `planned_at`/`delivered_at`/`expires_at`. Indexes on `[:user_id, :status]` and `[:status, :inserted_at]`, plus partial unique index `proactive_candidates_live_dedupe_index`. Verify `change/0` round-trips via rollback/migrate.
- **1.2 `ProactiveCandidate` schema** — mirrors `push_receipt.ex` style. `enqueue_changeset/2` (validates required fields, source inclusion, dedupe_key length, urgency 0.0–1.0, FK + unique constraints), `plan_changeset/3`, `status_changeset/2`. Compile clean with `--warnings-as-errors`.
- **1.3 `ProactiveQueue` context** — `enqueue/1` (idempotent: catches the live-dedupe unique violation and returns the existing row), `list_pending_for_user/1` (urgency desc), `pending_user_ids/1`, `mark_planned/3`, `mark_delivered/1`, `mark_held/1`, `expire_stale/1`. Full test file: enqueue, idempotency, ordering, distinct users, status transitions, expiry.

### Phase 2 — Sources enqueue (flag-gated)
Each source learns to enqueue instead of deliver, only when the flag is on. Flag off = unchanged.

- **2.1 Flag + delegate** — add `TelegramAssistant.proactive_delivery_planner_enabled?/0` (reads `:telegram_assistant` config, strictly coerces to boolean) and `defdelegate enqueue_proactive_candidate/1` to `ProactiveQueue.enqueue`.
- **2.2 `PushBroker.deliver_insight/1`** — `cond`: unified-push off → `{:fallback, :disabled}`; planner on → `enqueue_insight_candidate/1` (builds candidate from `Actions.telegram_payload/1`, `dedupe_key: "insight_delivery:#{id}"`, urgency from `delivery.score`); else → extracted `deliver_insight_now/1` (legacy body, guard removed since outer `cond` already checked). Delivery stays `pending`.
- **2.3 `PushBroker.deliver_brief/1`** — same `cond` shape; `enqueue_brief_candidate/1` handles both the todo-digest and standard-brief shapes, `dedupe_key: "brief:#{id}"`, urgency `0.7`. Legacy branch unchanged.
- **2.4 `Proactive.deliver_plan/4`** — branch at top: planner on → `enqueue_plan_candidate/4` (source `proactive_check_in`, body = generated `assistant_message`, carries `message_class`/`summary`/`todo_ids`/`interrupt_now` hint/`trigger` in `structured_data`, returns `decision: "queued"`); else → extracted `deliver_plan_now/5` (trigger + dedupe_key passed in). Add a `"queued"` clause to the `deliver_due_check_ins/1` reducer counting under `sent`.

### Phase 3 — The DeliveryPlanner
The model contract and the gather → plan → dispatch module.

- **3.1 `AssistantHarness.plan_delivery/2` contract** — add `@valid_dispositions`, `plan_delivery/2`, `build_delivery_plan_request/2`, `build_delivery_plan_prompt/1`, `normalize_delivery_plan/1` + `normalize_dispositions/1`. Response shape: `{"dispositions": [{"candidate_id","disposition","reason"}], "digest_intro", "summary"}`. Reuses existing `complete_json/2`, `runtime_policy/1`, `system_prompt/0`, `PromptStability.encode!/1`, `policy.proactive_request`. Rejects unknown dispositions with `:assistant_harness_invalid_disposition`.
- **3.2 `DeliveryPlanner` gather + plan** — `run_for_user/2` (loads pending candidates, resolves chat_id, calls `plan_delivery/2`, writes each disposition back via `mark_planned/3`), `run_for_due_users/1` (iterates `pending_user_ids/1` up to `:batch_size`, aggregates summary). Builds payload with candidate snapshots, context, and recent `PushReceipt` rows (`@recent_push_limit 8`). `dispatch/4` is an explicit stub returning `0`, replaced in 3.3. `:dispatch` opt allows plan-only.
- **3.3 `DeliveryPlanner` dispatch** — replace the stub:
  - `interrupt_now` → `PushBroker.deliver/1` with mapped `origin_type`; on `sent_now` → `mark_delivered/1`.
  - `digest` → one `PushBroker.deliver/1` (`origin_type: "assistant_digest"`, body = `digest_intro`, dedupe `delivery_digest:#{user}:#{date}`), then one `TelegramAssistant.send_turn/4` card per candidate; mark each `delivered` and record a `merged` `PushReceipt`.
  - `hold` → `mark_held/1`, no send, no receipt.
  - Returns count of candidates actually delivered. Uses `CapturingTelegram` test support (copy `setup` + `telegram_messages/0` from `proactive_test.exs`).

### Phase 4 — Cron wiring, telemetry, config, cutover prep

- **4.1 Run from `ProactiveCheckIn`** — add `run_delivery_planner/1` (`:disabled` when flag off, else `DeliveryPlanner.run_for_due_users/1`); call it in `handle_info(:tick, ...)` after `run_local_pattern_detectors()`, before `schedule_tick`, logging non-empty cycles.
- **4.2 Tracing + ActionLedger** — wrap `run_for_user/2` in `Tracing.with_span("telegram_assistant.delivery_planner", ...)`; add `record_planning_decision/4` writing one `proactive.delivery_planned` ledger entry per cycle with `interrupt_now_count`/`digest_count`/`hold_count` metadata (best-effort, `rescue → :ok`).
- **4.3 Config + expiry** — add `proactive_delivery_planner_enabled: false` and `proactive_candidate_ttl_minutes: 120` to `config/config.exs`; add `PROACTIVE_DELIVERY_PLANNER_ENABLED` env wiring to `config/runtime.exs`. Add `ProactiveCheckIn.expire_stale_candidates/0` and call it once per tick before `run_delivery_planner/1`. Verify prod + dev compile.
- **4.4 Full-suite verification** — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` (0 failures, legacy tests still green), migration round-trip.

---

## Files and Interfaces

**New files**
- `priv/repo/migrations/20260514000000_create_proactive_candidates.exs` — `proactive_candidates` table.
- `lib/maraithon/telegram_assistant/proactive_candidate.ex` — `ProactiveCandidate` Ecto schema. Public: `sources/0`, `statuses/0`, `dispositions/0`, `enqueue_changeset/2`, `plan_changeset/3`, `status_changeset/2`.
- `lib/maraithon/telegram_assistant/proactive_queue.ex` — `ProactiveQueue` context. Public: `enqueue/1`, `list_pending_for_user/1`, `pending_user_ids/1`, `mark_planned/3`, `mark_delivered/1`, `mark_held/1`, `expire_stale/1`.
- `lib/maraithon/telegram_assistant/delivery_planner.ex` — `DeliveryPlanner`. Public: `run_for_user/2`, `run_for_due_users/1`.
- `test/maraithon/telegram_assistant/proactive_queue_test.exs`
- `test/maraithon/telegram_assistant/delivery_planner_test.exs`

**Modified files**
- `lib/maraithon/telegram_assistant.ex` — `proactive_delivery_planner_enabled?/0`, `enqueue_proactive_candidate/1` delegate.
- `lib/maraithon/telegram_assistant/push_broker.ex` — `deliver_insight/1` + `deliver_brief/1` branch to enqueue; extracted `deliver_insight_now/1`, `enqueue_insight_candidate/1`, `enqueue_brief_candidate/1`.
- `lib/maraithon/telegram_assistant/proactive.ex` — `deliver_plan/4` branches; new `enqueue_plan_candidate/4`, extracted `deliver_plan_now/5`; reducer gains `"queued"` clause.
- `lib/maraithon/assistant_harness.ex` — `plan_delivery/2`, `build_delivery_plan_request/2`, `build_delivery_plan_prompt/1`, `normalize_delivery_plan/1`, `@valid_dispositions`.
- `lib/maraithon/runtime/proactive_check_in.ex` — `run_delivery_planner/1`, `expire_stale_candidates/0`, `@default_candidate_ttl_minutes`; `handle_info(:tick, ...)` updated.
- `config/config.exs` — `:telegram_assistant` defaults.
- `config/runtime.exs` — `PROACTIVE_DELIVERY_PLANNER_ENABLED` env wiring.
- `test/maraithon/assistant_harness_test.exs`, `test/maraithon/runtime/proactive_check_in_test.exs` — extended.
- `test/maraithon/telegram_assistant/proactive_test.exs` — no edits; must keep passing with flag off (regression guard).

**Model contract — `plan_delivery/2` response**
```json
{
  "dispositions": [
    {"candidate_id": "uuid", "disposition": "interrupt_now|digest|hold", "reason": "short reason"}
  ],
  "digest_intro": "Telegram-ready digest intro, or \"\" when nothing is in the digest",
  "summary": "short reasoning summary"
}
```

---

## Acceptance Checks

- `mix ecto.migrate` then `mix ecto.rollback` then `mix ecto.migrate` — clean round-trip of `proactive_candidates`.
- `mix test test/maraithon/telegram_assistant/proactive_queue_test.exs` — enqueue, idempotency, ordering, `pending_user_ids`, status transitions, `expire_stale`, flag + delegate all pass.
- `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs` — with the flag on: insight/brief/check-in sources enqueue instead of sending; planner writes dispositions back; `interrupt_now` sends individually + marks delivered; `digest` produces one intro + N cards + N `merged` receipts; `hold` marks held with no send; ActionLedger entry recorded.
- `mix test test/maraithon/assistant_harness_test.exs` — `plan_delivery/2` normalizes a valid plan and rejects unknown dispositions.
- `mix test test/maraithon/runtime/proactive_check_in_test.exs` — `run_delivery_planner/1` drains candidates when flag on, returns `:disabled` when off; `expire_stale_candidates/0` expires stale rows.
- **Regression:** `mix test test/maraithon/telegram_assistant/proactive_test.exs test/maraithon/insight_notifications_test.exs test/maraithon/briefs_test.exs` — all pass unchanged with the flag off (exercising legacy `deliver_plan_now/5`, `deliver_insight_now/1`, `deliver_brief/1` branches).
- `mix format --check-formatted` — clean.
- `mix compile --warnings-as-errors` and `MIX_ENV=prod mix compile --warnings-as-errors` — both clean.
- `mix test` — full suite, 0 failures.

---

## Proof of Work Expectations

The human review packet should contain:

- **Per-task commit history** — one commit per task as specified (e.g. `Add proactive_candidates table…`, `Add ProactiveQueue context…`, `Implement DeliveryPlanner dispatch…`), each with its failing-then-passing test.
- **Test output** — captured runs of each new/extended test file showing the expected pass counts, plus the final full-suite `mix test` summary (0 failures).
- **Regression evidence** — explicit `mix test` output for `proactive_test.exs`, `insight_notifications_test.exs`, `briefs_test.exs` proving the flag-off legacy paths are untouched.
- **Compile + format evidence** — `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `MIX_ENV=prod mix compile --warnings-as-errors` output.
- **Migration round-trip log** — `ecto.migrate` / `ecto.rollback` / `ecto.migrate`.
- **Cutover note** — confirmation that all changes are dormant with the flag unset, and the recommended staging → production rollout sequence (watch `telegram_assistant.delivery_planner` spans and `proactive.delivery_planned` ledger entries; confirm ≤1 stand-alone interrupt + ≤1 digest per cycle; confirm no `proactive_candidates` rows stuck `pending`).

---

## Risks

- **Fixture drift** — `Insights.create_insight/1`, `InsightNotifications.Delivery`, and `Briefs.Brief` field names are assumed from the original plan; if they differ, the Phase 2 test fixtures need adjustment. Mitigation: confirm against live files before writing the tests; the behaviour under test is unaffected.
- **Missing test files** — `assistant_harness_test.exs` and `proactive_check_in_test.exs` may not exist; the agent must create them following `DataCase` / `briefing_cron_test.exs` conventions rather than assuming an append target.
- **`telegram_opts` key coercion** — `String.to_existing_atom/1` raises if the model or a source emits an unexpected key. Mitigation: explicit clauses for `parse_mode`/`reply_markup`; add new keys explicitly rather than switching to `String.to_atom/1`.
- **Reducer/log semantics** — counting `queued` under `sent` is a deliberate choice; if operators read the cron log as "messages delivered" it will now mean "candidates produced". Documented in the plan; revisit if it causes confusion.
- **Double-delivery during cutover** — if the flag is flipped mid-cycle while candidates from the legacy path are in flight, a message could theoretically be sent twice. Low risk because sources either enqueue *or* deliver per call (never both), but operators should flip the flag during a quiet window.
- **Digest parent dependency on `conversation_id`** — `dispatch_digest/4` relies on `PushBroker.deliver/1` returning `{:ok, %{decision: "sent_now", conversation_id: ...}}`; if `PushBroker` ever returns a different success shape, digest cards silently won't send. Mitigation: the dispatch test asserts the 3-message digest shape explicitly.
- **Stuck `pending` rows** — if the planner errors repeatedly for a user, candidates accumulate until TTL expiry. Mitigated by `expire_stale_candidates/0` per tick and the `run_for_due_users/1` failure counter, but worth watching in the rollout.
- **Legacy-path debt** — two delivery code paths coexist behind the flag until the post-rollout cleanup. Intentional and scoped out, but the longer the flag lives in both states, the larger the divergence risk.