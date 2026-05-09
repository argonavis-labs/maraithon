---
created_at: 2026-05-09T17:22:16Z
created_by: cybrus
cybrus_task_id: 2D542828-8045-4751-B6FE-8442B7B5A4FD
project: Maraithon App
status: ready
---
# Decide Maraithon's 6-month path: double down, fold into Runner, or pause

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 2D542828-8045-4751-B6FE-8442B7B5A4FD
- Workflow: WORKFLOW.md

## Dependencies

- None

## Notes

Cybrus PM Summary
Pick one of the three paths laid out in the goals doc and write a decision so all downstream Maraithon work has a target instead of being speculative.

Why This Matters
The goals doc explicitly says 'The next session should pick one of these three. Without a decision, every PM run on Maraithon will keep generating ideas for a project that may not need them.' This is the literal gating ticket. Until it's resolved, every other backlog item is speculative work on a project that's been dormant for 30+ days.

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

Produce a written, defensible decision on which of the three paths Maraithon follows for the next 6 months — **double down**, **fold into Runner**, or **pause** — and update project documentation so all downstream Maraithon planning has a clear target. This ticket is strategic; no application code changes.

---

## Assumptions and Decisions

- **Decision doc location:** `docs/decisions/2026-05-09-maraithon-path.md` in the Maraithon repo. Create `docs/decisions/` if it doesn't exist. ADR-style format (Status, Context, Options Considered, Decision, Consequences, Conditional Plan).
- **Goals doc treatment:** `goals.md` gets a status banner at the top reflecting the decision. If the choice is **fold** or **pause**, the existing goals stay in place but are clearly marked as superseded; nothing is deleted (history matters for the eventual revival/post-mortem).
- **Honest diagnosis is in-scope and lives in the same decision doc** under a "Why April stopped" section — solo dev, no need for a separate private file. Free-write, no sanitization, but ship in the same artifact.
- **Usage inventory data source:** quick `psql` query against the Maraithon production Postgres on Fly for distinct users, sign-in counts, last-active timestamps. If credentials/connection are not handy, fall back to LiveView admin views or the `operator events` log; if neither works, name the gap explicitly in the doc rather than inventing numbers.
- **Runner gap analysis** is a Kent-led judgment call informed by `git log` on `~/bliss/runner` over the last 60 days, not a deep feature-by-feature audit. Goal is "is the structural OTP advantage still real or has Runner closed the gap" — that's a paragraph, not a table.
- **Default lean:** no preset preference. The plan must structurally support all three outcomes equally — output formatting is the same regardless of chosen path.
- **No new code, no schema changes, no agent edits** — markdown deliverables only.
- **Decision is final at end of this ticket.** No "we'll figure it out later." If the answer is "pause," it must include a calendar checkpoint date and what specifically would change Kent's mind.

---

## Implementation Plan

### 1. Diagnosis pass — "Why April stopped" (15–20 min)
Free-write into a scratch section answering, in order:
- What was Kent working on the day of the last commit (2026-04-02)?
- What pulled attention away — Runner work, life, boredom, blocker?
- Is the dormancy a *focus problem* (the runtime works, just no one's pushing it) or a *conviction problem* (Kent stopped believing the bet)?
- Would a single concrete user complaint restart momentum tomorrow? If yes, the answer is closer to "double down with distribution focus." If no, it's closer to "fold."

This section is the honest input to the decision — don't sanitize before deciding.

### 2. Usage inventory (10–15 min)
Run against production Postgres (Fly):
- `SELECT COUNT(DISTINCT user_id) FROM users;`
- `SELECT user_id, last_sign_in_at, sign_in_count FROM users ORDER BY last_sign_in_at DESC;`
- For each non-Kent user: did they connect any service? install any agent? receive any todo cards? return after first session?

Acceptable shortcut: if there are zero non-Kent users, write "Zero external users to date" and move on. That fact alone is decision-relevant.

### 3. Runner gap comparison (15 min)
- `git log --since="60 days ago" --oneline` in `~/bliss/runner`
- Quick scan: has Runner shipped durable agent state, projects-as-context, or always-on workers in the last 60 days?
- Write 1 paragraph: "Maraithon's OTP advantage is still real because X" OR "Runner has closed the gap on Y, leaving Maraithon with Z as the only structural advantage."

### 4. Score the three options (10 min)
For each of {double down, fold, pause}, fill in:
- **What "done" looks like in 6 months**
- **What gets given up**
- **The single biggest risk**
- **Honest probability of execution given current state** (capacity, attention, conviction)

### 5. Make the call and write the conditional plan (20 min)
Pick one path. Then write the 1-page conditional plan for the chosen path only:

- **If double-down:** named first 3 alpha-cohort candidates (real people Kent could ask this week), what they'd use Maraithon for, and what the smallest credible "install Chief of Staff" demo looks like. First-week action and first-month target.
- **If fold:** which Maraithon learnings/code/patterns get ported into Runner, in what order, and what gets frozen vs. archived. What happens to `maraithon.fly.dev` (kept running, sunset date, or shut down).
- **If pause:** calendar checkpoint date (90 days = 2026-08-09), what state Kent expects the world to be in by then, and the specific signal(s) that would flip the answer to double-down or fold. Schedule the checkpoint as a calendar event/cron now so it actually fires.

### 6. Update `goals.md` (10 min)
Add a status banner at the top:
```
> **Status (2026-05-09):** [Active / Folded into Runner / Paused until 2026-08-09]
> See [decision doc](docs/decisions/2026-05-09-maraithon-path.md) for rationale.
```

If the choice is **fold** or **pause**, mark the "Definition of done in 6 months" section clearly as `~~superseded~~` (strikethrough) or move it under a "## Original goals (superseded)" header. Do not delete.

### 7. Commit
Single commit with message: `decide: maraithon 6-month path — [chosen path]`. Include both the new decision doc and the goals.md update.

---

## Files and Interfaces

**New:**
- `docs/decisions/2026-05-09-maraithon-path.md` — the decision doc (ADR-style, see structure below)
- `docs/decisions/README.md` — *only if* the directory is new; one-line index pointing at the decision doc

**Modified:**
- `goals.md` — status banner at top; section marked superseded if applicable

**Decision doc structure (template):**
```markdown
# Maraithon — 6-month Path Decision (2026-05-09)

## Status
[Decided | Pending | Superseded]

## Context
[2–3 paragraphs: where Maraithon stands May 2026, the dormancy, the open question]

## Why April Stopped (Honest Diagnosis)
[Free-write from step 1]

## Usage Inventory
[Numbers from step 2]

## Runner Gap Analysis
[Paragraph from step 3]

## Options Considered
### A. Double down
### B. Fold into Runner
### C. Pause and reassess
[For each: definition of done, what's given up, biggest risk, probability of execution]

## Decision
[The chosen path, in one sentence, with the primary reason]

## Conditional Plan (next 30/90 days)
[The 1-page plan for the chosen path, from step 5]

## Consequences
- What changes in the backlog
- What changes for `maraithon.fly.dev`
- What changes for goals.md
- What the next PM run on Maraithon should optimize for
```

**No code, no migrations, no agent changes.**

---

## Acceptance Checks

- [ ] `docs/decisions/2026-05-09-maraithon-path.md` exists and names exactly one chosen path in its **Decision** section.
- [ ] The doc contains a non-empty "Why April Stopped" section that doesn't read as sanitized PR copy.
- [ ] The doc contains either real usage numbers or an explicit "Zero external users" / "data unavailable because X" statement — no hand-waving.
- [ ] The conditional plan is filled in for the chosen path *only*, not all three, and includes at least one concrete dated action.
- [ ] `goals.md` has a status banner at the top that links to the decision doc.
- [ ] If the chosen path is **pause**, a calendar event or cron exists for the checkpoint date.
- [ ] Single commit on `main` (or a short-lived branch) with both files; commit message names the chosen path.

---

## Proof of Work Expectations

- `git diff` showing the new decision doc and the `goals.md` update.
- The decision doc contents pasted into the review packet so the reviewer (Kent) doesn't have to open the file.
- For "pause," a screenshot or text confirmation of the scheduled checkpoint (calendar event ID or cron entry).
- For "double down," a list of the 3 named alpha-cohort candidates (can be initials if privacy matters in the packet).
- For "fold," the prioritized port-list with at least 3 Maraithon → Runner items.

---

## Risks

- **Decision avoidance.** The most likely failure mode is producing a thoughtful doc that punts to "pause" by default because pause feels safe. Mitigation: pause is only valid if the doc names a *specific signal* that would change the answer — vague "revisit later" fails the acceptance check.
- **Sunk-cost lean toward double-down.** 83 commits, real production deploy, working agents — the doc should explicitly weigh sunk cost as zero. Mitigation: the "honest probability of execution" line in the option scoring forces this.
- **Usage data unreachable.** If Fly DB credentials aren't handy, the inventory step stalls. Mitigation: explicitly allow "data unavailable" as a recorded answer and proceed; don't let DB plumbing block a strategic decision.
- **Goals.md becomes stale either way.** If the answer is double-down, the existing goals are mostly still right but the dormancy diagnosis isn't represented; if fold/pause, the doc shouldn't pretend the original goals are live. Mitigation: the status banner handles both cases cleanly without rewriting the body.
- **The decision quietly gets re-litigated next session.** Without a hard "this is decided" marker, future PM runs may re-open the question. Mitigation: the decision doc's **Status: Decided** field plus the goals.md banner make re-litigation visible and intentional.