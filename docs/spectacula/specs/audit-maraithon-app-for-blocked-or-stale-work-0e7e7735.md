---
created_at: 2026-05-14T18:40:11Z
created_by: cybrus
cybrus_task_id: 0E7E7735-4107-4A15-BB07-036C6F5767C8
project: Maraithon App
status: specs
---
# Audit Maraithon App for blocked or stale work

Status: Needs spec update
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 0E7E7735-4107-4A15-BB07-036C6F5767C8
- Workflow: WORKFLOW.md

## Dependencies

- None

## Notes

Cybrus PM Summary
Find stale tasks, unclear tickets, and missing next actions in the current board.

Why This Matters
A PM loop should improve backlog quality before generating speculative implementation work.

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

Improve backlog quality on the Maraithon board before any speculative implementation work is generated. The executing agent will enumerate every non-done task in the Maraithon workspace, classify each against a staleness/clarity/blocked rubric, and produce a **committed audit report** that names every problem task with a concrete, ready-to-apply fix (owner, status, acceptance criteria, next action, or dedupe/close recommendation).

The deliverable is the audit document plus a small set of low-risk, additive task corrections — not a sweeping rewrite of the board. Human review (Planned → Approved on the resulting fix tasks) gates anything destructive.

---

## Assumptions and Decisions

- **Board scope**: "The current board" means tasks in the Orchestrator/Cybrus queue associated with the **Maraithon workspace/project**. The agent confirms scope via `workspace_current` / `workspace_list` and records the resolved workspace ID in the report.
- **Task universe**: All tasks **not** in a terminal state (`Done`, `Dismissed`/`Cancelled`). Terminal tasks are excluded except when needed to detect duplicates of open work.
- **Staleness thresholds** (signals, not verdicts — the model makes the final call per Maraithon principle #3):
  - **Stale candidate**: no update in **14+ days** while in `Planned` or `In Progress`.
  - **Definitely stale**: no update in **30+ days**, or `In Progress` with no activity in 14+ days.
- **Clarity rubric** — a task is flagged "unclear" if it is missing any of: a concrete title, a one-line outcome, acceptance criteria, an identifiable owner, or a defined next action.
- **Blocked rubric** — a task is flagged "blocked" if: status is `Blocked`, it has an unmet dependency, or its notes/description reference a blocker that no longer has a tracked resolution path.
- **Decision — propose, don't destroy**: The agent **applies only additive, low-risk corrections** autonomously (e.g., adding a missing acceptance-criteria block, tagging `stale`, setting an obviously-correct owner to the default user). Status changes, closures, merges, and dependency edits are written as **recommendations in the report**, not applied. This respects human PM intent and the "produce proof of work, then human review" handoff model.
- **Cross-reference is light**: For tasks whose described work may already be shipped, the agent does a bounded check against the Maraithon repo (`git log`, relevant files) for evidence and notes "possibly already done" — it does not deep-dive every task.
- **Report location**: `docs/audits/backlog-audit-2026-05-14.md` in `/Users/kent/bliss/maraithon`. A dated file so repeated runs are diffable.

---

## Implementation Plan

1. **Resolve scope and tool access**
   - Confirm the active workspace with `workspace_current`; list alternatives with `workspace_list` if ambiguous.
   - Confirm Orchestrator task MCP tools are reachable from the execution environment. If not, halt and write the access gap into the report (see Risks) rather than producing a partial silent audit.

2. **Enumerate the board**
   - Call `task_statuses` to get the status vocabulary.
   - Call `task_list` (filtered to the Maraithon workspace, all non-terminal statuses) to get the full task set.
   - For each task, pull full detail via `task_find` — description, notes, acceptance criteria, owner, dependencies, created/updated timestamps, status history.

3. **Classify each task against the rubric**
   - Compute the staleness signal from `updated_at` vs. today (2026-05-14).
   - Evaluate the clarity rubric (missing title/outcome/acceptance/owner/next action).
   - Evaluate the blocked rubric (status, dependencies, notes).
   - Run **semantic duplicate detection** across the open set — flag tasks that describe the same open loop (model judgment, not string match).
   - The model assigns each task one or more labels: `stale`, `blocked`, `unclear`, `duplicate`, `possibly-done`, or `healthy`.

4. **Light repo cross-reference**
   - For `possibly-done` candidates only, check the Maraithon repo for shipping evidence (`git log --oneline`, grep for the feature, relevant files) and annotate confidence.

5. **Write a concrete fix per problem task**
   - For each non-`healthy` task, produce: the specific defect, the recommended fix, and the exact field values to apply (proposed owner, proposed status, drafted acceptance criteria, drafted next action, or "merge into TASK-X" / "close as done").

6. **Apply low-risk additive corrections**
   - Using `task_update`, apply only additive, unambiguous fixes (drafted acceptance criteria into an empty field, `stale` tag, default owner where clearly the user). Log every mutation with before/after.
   - Do **not** call `task_move`, `task_delete`, or change statuses/dependencies — those land as recommendations only.

7. **Compile the audit report**
   - Write `docs/audits/backlog-audit-2026-05-14.md` with: run metadata, summary counts, a per-task table (ID, title, labels, defect, recommended fix), the list of applied corrections, and a prioritized "fix queue" the human can convert to approved tasks.

8. **Stage proof of work**
   - Leave the report committed/staged in the repo and emit the summary table to stdout for the Cybrus review packet.

---

## Files and Interfaces

**New file**
- `docs/audits/backlog-audit-2026-05-14.md` — the audit report and proof of work.

**Orchestrator MCP tools consumed**
- `workspace_current`, `workspace_list` — resolve and record board scope.
- `task_statuses` — status vocabulary.
- `task_list` — enumerate non-terminal Maraithon tasks.
- `task_find` — full per-task detail (description, notes, acceptance criteria, owner, deps, timestamps).
- `task_update` — apply **only** additive, low-risk corrections; every call logged.
- `cybrus_state` / `cybrus_task` — optional context on what Cybrus is queued to execute, to prioritize the fix queue.

**Explicitly not used in this run**
- `task_move`, `task_delete`, `task_create` — destructive or board-restructuring; their intent is captured as written recommendations instead.

**Repo touchpoints (read-only)**
- `git log`, targeted `grep`/file reads in `/Users/kent/bliss/maraithon` for `possibly-done` cross-referencing.

---

## Acceptance Checks

- `docs/audits/backlog-audit-2026-05-14.md` exists and contains: resolved workspace ID, run timestamp, total tasks reviewed, and counts per label (`stale`, `blocked`, `unclear`, `duplicate`, `possibly-done`, `healthy`).
- Every non-terminal Maraithon task appears exactly once in the per-task table.
- Every task labeled non-`healthy` has a concrete recommended fix with explicit proposed field values — no vague "needs work" entries.
- The report includes an "Applied corrections" section listing each `task_update` call with before/after values; if none were applied, it says so explicitly.
- No `task_move`, `task_delete`, or status/dependency mutations were performed (verifiable from the tool-call log).
- The report ends with a prioritized fix queue the human can act on directly.
- If task tooling was unreachable, the report clearly states the access gap and the audit is marked incomplete rather than presented as clean.

---

## Proof of Work Expectations

- The committed audit report at `docs/audits/backlog-audit-2026-05-14.md`.
- A stdout summary table for the Cybrus review packet: tasks reviewed, counts per label, number of corrections applied, size of the fix queue.
- The full tool-call log showing enumeration (`task_list` / `task_find`) and every `task_update` mutation with before/after.
- Git diff/status showing the new report file staged.

---

## Risks

- **Task MCP tools unreachable from local Codex CLI** — the highest-likelihood failure. The execution mode is local CLI with workspace access, but the board lives in the Orchestrator queue. *Mitigation*: detect reachability in Step 1; if unavailable, halt and document the access gap, or accept a board snapshot/export placed in the repo, rather than producing a misleadingly "clean" audit.
- **Autonomous board mutation disrupts human PM intent** — *Mitigation*: the propose-don't-destroy decision; only additive, unambiguous corrections are applied, everything else is a recommendation.
- **Staleness heuristic false positives** — a 14-day-old task may be intentionally parked. *Mitigation*: thresholds are signals; the model makes the final call per Maraithon principle #3 and notes "intentionally parked?" where plausible.
- **Board scope ambiguity** — multiple workspaces could match "Maraithon." *Mitigation*: resolve and record the workspace ID explicitly; if ambiguous, audit the most likely one and flag the ambiguity.
- **Semantic duplicate misjudgment** — merging recommendations could collapse genuinely distinct loops. *Mitigation*: duplicates are recommendations only, never applied, and always cite the evidence for the match.
- **Cross-reference scope creep** — checking the repo for every task would blow the run budget. *Mitigation*: repo cross-reference is bounded to `possibly-done` candidates only.
