# Spectacula Codebase Verification - 2026-05-20

Purpose: clean the active Spectacula queue so `docs/spectacula/ready` contains only specs that still need implementation against the current Maraithon codebase.

## Summary

- Before review: `50` ready manifests, `0` in progress, `17` done.
- Initial verification result: `4` ready manifests, `0` in progress, `23` done, `3` specs needing update/decision, `37` orphan ready manifests archived.
- Current active state after implementation work on 2026-05-20: `0` ready manifests, `1` in progress, `26` done, `3` specs needing update/decision.
- Archive path: `docs/spectacula/archive/orphaned-ready-manifests-2026-05-20/`.

## Ready To Build

No specs are currently ready to build.

| Spec | Current verdict | Evidence |
| --- | --- | --- |
| `ready/` | Empty. | `docs/spectacula/ready` has no active JSON manifests. |

## In Progress

| Spec | Current verdict | Evidence |
| --- | --- | --- |
| `spec-run-30-day-chief-of-staff-dogfood-with-crash-recovery-telemetry-ddb2542b` | Runtime telemetry code checkpoint implemented and verified; not eligible for `done` yet. | `runtime_incidents`, `IncidentLog`, boot/shutdown/db instrumentation, `AgentWatcher`, `DogfoodDigest`, dogfood baseline task, config, and focused tests exist. `mix precommit` passed with `1851` tests and `0` failures. Remaining acceptance requires the elapsed 30-day production run, daily digest archive, crash/recover artifact, and `docs/dogfood/2026-chief-of-staff-30-day.md`. |

## Moved To Done

| Spec | Reason |
| --- | --- |
| `define-the-next-high-leverage-milestone-for-maraithon-app-7b446471` | Planning deliverable completed: `.claude/plans/2026-05-14-proactive-delivery-planner.md` exists and the follow-on Spectacula implementation spec remains ready. |
| `fast-context-aware-telegram-answers-spec-1a2af4f9` | Implemented. Evidence includes Anthropic cache-control, parallel tool calls, routing model config, `ContextCache`, liveness edit delivery, pg_trgm CRM fuzzy resolve, parallel context fetch, rolling conversation summarization, and targeted tests. |
| `fast-context-aware-telegram-answers-spec-7526b4ec` | Duplicate closeout spec for the same implemented fast-answering work. |
| `logfire-opentelemetry-integration-implementation-plan-25736676` | Implemented. Evidence includes OpenTelemetry deps, opt-in Logfire runtime config, application setup calls, `Maraithon.Tracing`, assistant/LLM spans, and `tracing_test`. |
| `logfire-opentelemetry-integration-implementation-plan-3382bc3b` | Duplicate Logfire implementation plan, satisfied by current implementation. |
| `logfire-opentelemetry-integration-implementation-plan-cf6f000d` | Latest Logfire implementation plan, satisfied by current implementation. Live Logfire smoke still needs a real `LOGFIRE_WRITE_TOKEN`, but app implementation is present. |
| `proactive-delivery-planner-implementation-plan-a6547aa9` | Implemented after the initial verification pass: durable queue, flag-gated source enqueueing, one model planning pass per user, interrupt/digest/hold dispatch, runtime drain, stale expiry, config, and tests. |
| `spec-self-serve-install-flow-for-chief-of-staff-agent-7e902f13` | Implemented after the initial verification pass: connector readiness gating, `setup_required`, enabled/running install path, dashboard setup links, signed Telegram linking with email fallback, docs, and smoke tests. |
| `ship-memory-primitive-with-model-callable-read-write-tools-26355ff4` | Implemented after the initial verification pass: encrypted memory storage, recall ranking, supersession, update-confidence tooling, prompt injection, operator UI, and tests. |

## Moved Back To Specs

| Spec | Reason |
| --- | --- |
| `audit-maraithon-app-for-blocked-or-stale-work-0e7e7735` | Operational board audit, not an application build spec. No `docs/audits/backlog-audit-2026-05-14.md` exists and Orchestrator task MCP artifacts are not in the repo. |
| `decide-maraithon-s-6-month-path-double-down-fold-into-runner-or-pause-2d542828` | Strategic decision artifact, not buildable code. The expected `docs/decisions/2026-05-09-maraithon-path.md` and `goals.md` status banner are absent. |
| `ship-people-crm-data-model-with-semantic-merge-and-source-links-f6d69798` | Current code already has `Maraithon.Crm`, `crm_people`, `crm_person_links`, CRM tools, ingestion, fuzzy/semantic lookup, and relationship context. This spec should be upgraded into a CRM delta before implementation to avoid building a conflicting `Maraithon.People` model. |

## Archived Orphans

Archived `37` `fast-context-aware-telegram-answers-implementation-plan-*` ready manifests because each pointed to a missing canonical Markdown spec. They are outside the active lifecycle tree now and should not be treated as ready work unless the missing specs are restored.

## Verification Notes

- This pass used file/module evidence from `lib`, `priv/repo/migrations`, `test`, `.claude/plans`, and docs.
- Stage manifests were updated with `codebase_verified_*` history entries and review notes.
- The implementation follow-up ran `mix precommit` successfully after the dogfood telemetry code checkpoint: `1851` tests, `0` failures.
- No stale ready manifests remain in the active lifecycle tree.
