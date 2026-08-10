# Maraithon architecture audit refresh

**Status:** Final release-candidate audit. The exact deployed SHA is reported in the accompanying release record because a file cannot contain the hash of the commit that contains itself.  
**Production baseline at audit time:** Fly release 1430, commit `48b72a75b81b522ae80da9900c3ad454470c37fb`.  
**Candidate code anchor before this report:** `73b842c` on the fresh production-lineage integration worktree.  
**Method:** Source/history review, independent P0/P1 reviews of immutable component SHAs, focused OTP 26 validation, migration proofs, and production postflight evidence. Candidate statements below are not claims about production until the release record confirms deployment.

## Executive conclusion

Maraithon should remain an Elixir/Erlang/OTP application. Its core product is not a collection of independent cron jobs: it is a resident, Telegram/mobile-mediated personal operating system with per-user conversations, durable open work, relationship evidence, encrypted memory, supervised long-running agents, scheduled wakeups, and external side effects whose outcomes must be reconciled across crashes. OTP is a strong fit for resident identity, explicit state machines, cheap concurrency, supervision, and co-location with Phoenix/LiveView.

The audit does **not** conclude that every custom runtime primitive is justified. The recurring defects occur where volatile BEAM process semantics—mailbox admission, PubSub delivery, a live Task, a lease timestamp—were treated as if they were durable queue or external-effect completion semantics. Those boundaries need Postgres-authoritative inbox/outbox records, exact generation fencing, monotone transitions, bounded payloads, explicit ambiguity states, and conservative cancellation/recovery. Ordinary jobs and schedules should use a mature BEAM job layer such as Oban when it lowers the amount of custom queue code.

A Python rewrite would not remove the difficult problems. Cron would lose warm state and serialized identity entirely. Celery would provide mature ordinary-job mechanics, but Maraithon would still need idempotency keys, exact ownership generations, cancellation proof, durable ingress, replay rules, and treatment of provider-success/local-checkpoint ambiguity—while adding a broker/worker stack and splitting the Phoenix control plane from the runtime. Python remains appropriate for isolated ML/data tasks when its libraries provide a clear advantage, not as the primary orchestration runtime.

## What is distinctive

Maraithon combines four things that are usually separate:

1. **Durable open loops:** Todos retain source evidence, counterparty/direction, next action, draft, urgency and completion state rather than behaving like a shallow checklist.
2. **Relationship and memory context:** relationship links retain evidence and confidence, while memory items are encrypted and can inform later decisions.
3. **Respectful proactivity:** urgency, why-now, quiet hours, interruption budgets, dispositions and receipts are persisted decision surfaces rather than fire-and-forget notifications.
4. **Conversational operation:** Telegram/mobile is the daily interaction surface; Phoenix LiveView is the calm operational control plane.

The differentiator is this combination, not any single connector, LLM, or scheduler.

## What the architecture actually is

Maraithon is best described as **durable state machines with snapshots, audit history, and database-backed effects/jobs**, not strict event sourcing.

- Phoenix starts Repo/PubSub, registries, dynamic supervisors, task supervisors, the runtime tree, periodic services and web/control surfaces.
- Installed agents are supervised state machines with identity-local serialization and persisted snapshots.
- Scheduler/background-job/effect tables provide several separate durable-work substrates.
- Interactive Telegram/mobile conversations use their own worker/run/turn paths rather than one universal actor runtime.
- Snapshots are recovery boundaries; the application does not reconstruct all state by reducing a replayable event log.

That hybrid is reasonable, but each durable-work substrate must share the same safety vocabulary: accepted, claimed by exact generation, executing, provider outcome known/unknown, locally checkpointed, presented, acknowledged, cancelled, and terminal.

## OTP versus Python/cron/Celery

| Concern | Elixir/OTP in Maraithon | Python + cron/Celery |
|---|---|---|
| Resident per-user/agent state | Natural process identity and explicit state machines | Reconstruct state per task or maintain a separate actor/service layer |
| Serialization | Registry/mailbox is efficient while live | Requires queue routing, locks or workflow orchestration |
| Crash isolation/restart | Native supervision and monitors | Worker/process manager plus broker redelivery |
| Durable acceptance | Must be implemented in Postgres; a mailbox is not durable | Broker can help, but business acceptance/idempotency still belongs in durable state |
| External side effects | Requires the same idempotency/ambiguity protocol in any language | Same; Celery ACKs do not prove provider outcome |
| Operational footprint | Phoenix/runtime/database in one deployment | Web app + broker + scheduler + worker fleet, often separate services |
| ML/data ecosystem | Weaker for some specialist libraries | Strong advantage for isolated ML/data workloads |
| Recommended use | Core orchestration, state machines, web/control plane | Isolated tools/services only where library leverage outweighs boundary cost |

## Finding disposition before the combined release

### P0 — Telegram ingress and end-to-end durable processing

**Production baseline:** not present on release 1430; the earlier product direction had retired Telegram ingress.  
**Release candidate:** restores a static `/webhooks/telegram` endpoint with exact header-secret authentication before body parsing, bounded body/gzip handling, permanent sanitized update receipts, durable processing, per-bot ordering, and claim fencing. Independent P0/P1 review accepted Insight at `4e781a2`, Todo/Brief at `c2ff9f9`, and PreparedAction at `31bd99f`. Ambiguous non-idempotent provider outcomes become non-resendable manual-reconciliation states; Telegram presentation uses durable pre-send ownership.  
**Disposition:** resolved in the candidate, subject to exact-deployment and webhook postflight. Registration remains a release operation: a freshly staged secret, static URL, `max_connections=1`, and `getWebhookInfo` verification.

### P0 — Background-job generation fencing

**Production baseline:** terminal/retry/cancel writes are not fully fenced by an immutable claim generation.  
**Release candidate:** `23fe1eb` + `dd629c7`, followed by the reviewed Telegram ordering blob union, introduce UUID claim tokens, exact owned terminal/retry writes, stale-reclaim fencing, exact task termination on ownership loss, cancellation CAS, protected Telegram job ordering, and permanent receipt deduplication.  
**Disposition:** resolved in the candidate. The non-rolling old-runner drain remains mandatory because the protocol is not mixed-fleet compatible.

### P1 — Durable two-phase messages, connector events and wakeups

**Production:** generic Scheduler/PubSub/mailbox admission can still be treated as completion; capped deferred mailboxes remain volatile.  
**Successor work:** the accepted feature-dark foundation through `b92b5ea` adds durable directive/ownership primitives, but ordinary `Runtime.send_message`, Scheduler and connector producers are not yet cut over ACK-last.  
**Disposition:** open architectural work. Do not claim completion merely because the Telegram path is durable.

### P1 — Bootstrap/restart/desired-state authority

**Production baseline:** temporary Bootstrap, transient Agent restart and Watcher recovery remain competing policies.  
**Reviewed work:** the accepted foundation through `b92b5ea` supplies feature-dark leases, guards, database clock, and directives. Successive lifecycle candidates (`2f1b5d6`, `faa4f7a`, and `2016093`) exposed composite races, consent/legacy-fleet problems, forged terminal timestamps, and mixed-key terminal crashes. A later narrow descendant `dbde557` was still under review when the release decision was made.  
**Disposition:** deliberately deferred from this release. No lifecycle delta from `2f1b5d6` onward is integrated, `exact_agent_runtime_enabled` remains false, and activation requires a separately reviewed release and non-rolling cutover. This finding remains open rather than being hidden behind green partial tests.

### P1 — Effect cancellation and exact ownership

**Reviewed work:** the accepted foundation retains durable terminal envelopes and database-authoritative terminal results. The raw cancellation tip `e8ff71d` was rejected because its migrations/cutover were not retry-safe and mixed legacy/exact fleet modes could mutate each other's rows; its repair did not reach clean independent review before the release decision.  
**Disposition:** deliberately deferred. Neither `e8ff71d` nor its dirty repair is integrated; `durable_effect_cancellation_enabled` remains false, the epoch remains nil, and protocol version remains 2. A future release must prove retry-safe migrations, DB-authoritative cutover, nil-lineage isolation, and no mixed-fleet mutation.

### P1 — Chief durable lineage

**Reviewed work:** the raw `f7c1a33` tip exposed seven data-contract holes. The complete descendant through `e0f8eac` and documentation correction `a061585` closes terminal-page extension, composable-write, cursor-CAS, semantic-closure, acquisition-identity, Directive-correlation, and immutable provider-account/retry facts. It passed independent executable and migration review.  
**Disposition:** resolved as an additive, old-code-safe, feature-dark data foundation in the candidate. It has no live acquisition/Todo/SurfaceQuality activation wiring; activation remains a separate product/runtime decision.

### P1 — Sensitive data and snapshot safety

Snapshots remain base64 ETF in JSONB and decode without `[:safe]`; several events/effects/run-step/turn payloads remain broad plaintext maps. Memory encryption alone does not close the retention problem.  
**Disposition:** open. Define field-level retention/redaction/encryption, bounded payload schemas and a safe snapshot migration before calling this complete.

### P2 — Periodic service consolidation and multi-node authority

The supervisor still starts many cron-like GenServers. One production Machine limits immediate split-brain exposure but is not a scaling design.  
**Disposition:** deliberate pre-scale debt. Consolidate ordinary schedules/jobs and introduce explicit leader/partition authority before multi-node scaling.

### P2 — Terminology and module reviewability

The README still uses “event sourcing” although snapshots, not replayable reducers, are the recovery boundary. Several runtime and LiveView modules remain very large.  
**Disposition:** open documentation/decomposition work. Rename the architecture honestly and split modules along transition/repository/presentation boundaries without weakening safety semantics.

## Release-candidate disposition manifest

Integrated reviewed lineages:

- CI/TestFlight certificate serialization and Fly timeouts: `5051562`, `e0cf545`.
- Durable Telegram ingress/processing and assistant base through `0bdd53f`, with the stronger source-backed fixture `2eca5f3` and focused contracts `5693995`.
- LLM timeout recovery: `5ac69f4`.
- Insight provider fencing: final accepted descendant `4e781a2`.
- Todo/Brief presentation and ambiguity fencing: final accepted descendant `c2ff9f9`.
- PreparedAction execution/result fencing: final accepted descendant `31bd99f`.
- Feature-dark runtime foundation: `7926592`, `507050a`, `7003891`, `b92b5ea`.
- Feature-dark Chief lineage: final accepted descendant `a061585`.
- Background-job claim generations: `23fe1eb`, `dd629c7`, plus the exact `0bdd53f` Telegram background-job path union.

Explicitly excluded:

- Quarantined mega-merges and archive tips, including `dcfe7fa`, `1cee860`, and `300ad84`.
- Rejected or deliberately deferred lifecycle range `2f1b5d6` through `dbde557`.
- Rejected Effects tip `e8ff71d` and its unreviewed repair.
- Rejected intermediate component tips are present only when they are ancestors of an independently accepted final descendant, never as standalone release claims.

## Recommended architecture roadmap

### Ship gate

1. Preserve the completed independent review evidence for durable Telegram ingress, processing, action execution and presentation.
2. Deploy only the clean fresh production-lineage candidate containing the immutable reviewed lineages above.
3. Keep all new runtime gates default false and migrations expansion/old-code safe.
4. Deploy one exact SHA, prove the old Machine is gone, then perform any non-rolling DB cutover.
5. Rotate/register the Telegram webhook secret without exposing it and verify `max_connections=1` through `getWebhookInfo`.
6. Verify exact backend SHA/image, migrations, runtime invariants, pause behavior, TestFlight build and tester access.

### Next

1. Finish a single Postgres-authoritative Directive/inbox protocol: atomic acceptance, ID-only process hints, ready-fenced claims, renewals, terminal transaction and ACK-last producer cutover.
2. Standardize external-effect states: live owner, bounded lease, result known, outcome unknown, locally checkpointed, presented and acknowledged.
3. Replace ordinary custom job/schedule machinery with Oban where it reduces risk and preserves tenant fairness.
4. Make one desired-state reconciler authoritative for Agent startup/recovery and expose BootGate/lease health.
5. Establish a sensitive-payload inventory, retention policy, redaction vocabulary and safe snapshot format.

### Later

1. Multi-node authority, per-user fairness and partition behavior.
2. Decompose the largest runtime and UI modules.
3. Correct event-sourcing terminology and publish an operator-facing runtime contract.

## Final decision

**Continue with Elixir/Erlang/OTP. Do not rewrite Maraithon as Python plus cron.** Harden the durable boundaries, reduce the number of bespoke queue implementations, and use Python selectively behind explicit, idempotent interfaces when its ecosystem is uniquely valuable.
