# Restore the Sep 11 server work

The restoration is blocked on slice 1's required production observation.
The [approved scope](superpowers/specs/2026-09-22-restore-branch-server-work-design.md)
has three slices, each deployed and verified before the next starts. The
Electron app and the three out-of-scope server features stay outside this work.

## Slice 1: calendar check-in budget

Restored `1e8b81eb` as `2da4675a` with `git cherry-pick -x`, in the
`codex/restore-calendar-check-in` worktree branched from current `main`.

The prompt now uses nine todo fields, caps strings at 240 characters, reduces
the list limits, and describes delivery through brief channels. The retired
Telegram requirement is removed. No migrations changed.

`make build` passed with warnings treated as errors, using Elixir 1.19.5 and
OTP 28 with the worktree's locked dependencies. No tests were added or run,
under [the current development policy](development-mode.md).

The file diff was reviewed before fast-forwarding `main` and pushing.
[CI deployment 35815778087](https://github.com/argonavis-labs/maraithon/actions/runs/35815778087)
passed. Cloud Build `198c4e0f-56d2-41ad-8f35-2eb0991a3f89` succeeded, and
`maraithon-00467-874` became ready at `2026-09-23T03:51:56Z`, serving 100%
of traffic. CI skipped migrations because the migration digest was unchanged.

After the read-only checks, `LLM_DEVELOPMENT_SPENDING` was restored to `false`
on the service and eval job while waiting for the next workday check-in.
The resulting ready revision, `maraithon-00468-crv`, serves 100% of traffic
with the same `dev-2da4675ab628-35815778087-1` image.

Before deployment, Cloud Logging contained 40 occurrences of
`Calendar check-in model synthesis failed` in the preceding 24 hours, all on
`maraithon-00465-txf`. The last was at `2026-09-22T21:04:15.542263Z`.

Two read-only Cloud Run executions compared the same user's live todo input
at `2026-09-23T03:54:33Z`. Both completed successfully with `POOL_SIZE=2`.
They made no model calls, sent no messages, and ran their database reads in
read-only transactions.

| Measurement | Before | Restored |
| --- | ---: | ---: |
| Input bytes, excluding calendar data | 292,327 | 16,477 |
| Todos across the three prompt lists | 43 | 25 |
| Maximum fields per todo | 33 | 9 |
| Longest top-level todo string | 411 characters | 165 characters |

The before execution was `maraithon-todo-validation-rv797`, using image
`sha256:060c31ae56506dae35aa8ba9110250b8eb13ccc051da10b91eda321ff67ed273`.
The restored execution was `maraithon-todo-validation-fhkb4`, using
`dev-2da4675ab628-35815778087-1`. These measurements establish that the todo
input no longer exceeds the 128,000-byte request cap by itself. They do not
prove the complete calendar request, model response, or delivery.

The same reads found two recorded sent check-ins and three failed check-ins.
The latest sent check-in was delivered at `2026-09-14T19:25:25.509503Z`.

Production verification remains open. A quiet overnight log is not evidence
that a workday check-in succeeded. Before starting slice 2, confirm that the
failures stop and a check-in reaches a brief channel when a calendar opening
and useful work warrant one.

For that follow-up, use Cloud Logging for synthesis failures after this
deployment and a Cloud Run `eval` execution for new `briefs` rows with
`cadence = 'check_in'` and `metadata->>'origin_skill_id' = 'calendar_check_in'`.
Confirm delivery through the brief's status and delivery timestamp. Keep
database access inside Cloud Run with `POOL_SIZE=2`; do not query production
PostgreSQL from the laptop.

At `2026-09-23T04:00:58Z`, read-only execution
`maraithon-todo-validation-7f8rp` confirmed zero check-ins created or sent
since deployment. The configured workday is 09:00 to 18:00 in
`America/Toronto`; the check ran at local hour 00, outside that window.
The next eligible workday begins September 23 at 09:00 Toronto time
(`13:00Z`). A check-in still depends on a calendar opening and useful work.
Resume production verification in that window before starting slice 2.

## Remaining slices

2. Restore the People list and person page, without the Fiber references.
   Compile, deploy through CI, and inspect both pages and their logs.
3. Restore Fiber enrichment and per-account calendar polling. Preserve
   today's assistant-account isolation, transport binding, Gmail sync,
   runtime fencing, and token-refresh metadata. Compile, deploy through CI,
   and verify bounded jobs, enrichment progress, calendar interactions,
   meetings, and the People network.

Neither slice has started. Each will use its own worktree from the verified
current `main`, as required by the spec.
