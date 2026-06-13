# Goals Work Hardening

Status: Done
Purpose: Harden the Goals tab, mobile profile goal capture, and proactive goal-alignment loop after the first production slice.
Audience: Engineering and operator review.

Completion: Implemented and verified on 2026-06-13. Mobile build `20260613032937` was accepted by TestFlight.

## 1. Problem Statement

The first Goals slice created durable goals, a web Goals tab, mobile API support, a mobile profile add-goal flow, assistant tools, and a Chief of Staff `goal_alignment` skill. That shipped the core product direction, but the code is still early in three places that matter for production trust:

- Public mobile/chat goal write surfaces are close to internal persistence fields and should not be able to spoof review state.
- Model-generated goal review output should be partial-safe. One bad generated link or todo candidate should not discard the good parts of a review.
- The mobile profile flow needs focused verification so "add your goals in the profile section" remains true as the API and Swift UI evolve.

This pass is a hardening pass, not a redesign. It should reduce risk while preserving the current product surfaces.

## 2. Current State

| Area | Current behavior | Hardening risk |
|---|---|---|
| `Maraithon.Goals.create_goal/3` and `update_goal/4` | Accept maps and normalize goal fields before schema validation | Public callers can attempt to set `last_reviewed_at`, `next_review_at`, or raw `metadata` unless the caller strips them |
| Mobile goal controller | Sanitizes known fields, currently close to schema fields | Public API should accept product fields, not internal review bookkeeping |
| Telegram/chat goal tools | Use `goal_attrs/1` to pass allowed fields into `Maraithon.Goals` | Tool output should not mutate review timestamps or raw metadata |
| `Goals.apply_review_output/4` | Applies model output in one transaction and rolls back on candidate errors | A stale resource id or malformed todo candidate can make otherwise useful progress/advice fail |
| Mobile profile Goals sheet | Lists active goals and creates goals via `MobileAPIClient.createGoal` | Needs build/test evidence and stable profile entry point |

## 3. Goals

- Public goal creation/update surfaces cannot write internal review state.
- Internal review completion can still update `last_reviewed_at` and `next_review_at`.
- Malformed model output candidates are skipped and recorded as partial review output instead of crashing the whole review.
- Valid progress updates, advice/findings, and concrete todos from the same review still persist when unrelated candidates are invalid.
- The mobile profile menu remains the entry point for adding goals on iOS.
- Focused tests cover the hardened behavior.

## 4. Non-Goals

- Do not change the top-level mobile tab bar.
- Do not add health data integrations.
- Do not introduce a separate Goals sync model in SwiftData in this pass.
- Do not make broad test/precommit runs the default; follow the repo's production-first verification mode.
- Do not rewrite the existing Goals architecture spec.

## 5. Decisions

| Decision | Choice |
|---|---|
| Spec lifecycle | Create a separate `goals-work-hardening` Spectacula spec |
| Public write boundary | Strip internal goal fields in the domain layer by default, then tighten mobile/chat param allowlists |
| Internal write escape hatch | Use an explicit option for internal review timestamp updates |
| Review output error policy | Skip invalid per-candidate output and mark the review run `partial` when anything is skipped |
| Mobile placement | Keep Goals under the account/profile menu |

## 6. Implementation Contract

### 6.1 Domain Write Boundary

`Maraithon.Goals` must reject or strip public writes to:

- `user_id`
- `last_reviewed_at`
- `next_review_at`
- raw `metadata`

Rules:

- Public callers use the default behavior and cannot set those fields.
- Internal callers may pass `allow_internal_fields: true`.
- `update_reviewed_goals!/3` and `maybe_update_goal_review_timestamp/1` must use the internal option.
- Status or cadence updates still recompute `next_review_at` deterministically.

### 6.2 Public Surface Allowlists

Mobile and chat goal create/update params should include only product-editable fields:

- `category`
- `status`
- `title`
- `desired_outcome`
- `why`
- `success_metric`
- `priority`
- `sensitivity`
- `proactive_visibility`
- `review_cadence`
- `starts_on`
- `target_at`

They must not include `last_reviewed_at`, `next_review_at`, or raw `metadata`.

### 6.3 Partial-Safe Review Output

`Goals.apply_review_output/4` should treat each model-generated item independently.

Expected behavior:

- Valid progress updates are inserted.
- Valid resource links are inserted.
- Invalid resource links are skipped.
- Todo candidates missing title, summary, next action, or evidence are skipped.
- Valid todo candidates still create deduped `source: "goals"` todos and goal links.
- The review run result includes skipped-output metadata.
- The review run status is `partial` when any output candidate is skipped, otherwise `completed`.
- Invalid JSON at the skill boundary can still fail the pending review run.

### 6.4 Mobile Profile Goals

The iOS profile/account menu must expose `Goals` for signed-in users. The sheet must:

- Load active goals from `MobileAPIClient.listGoals`.
- Show a compact list with title, category, status, cadence, linked work count, and latest progress when present.
- Provide a `New Goal` form.
- Save through `MobileAPIClient.createGoal`.
- Insert the saved goal into the visible list without requiring a reload.
- Use the existing mobile error copy for failures.

## 7. Verification Plan

Use focused gates:

| Gate | Command |
|---|---|
| Elixir compile | `mix compile` |
| Goals focused tests | `mix test test/maraithon/goals_test.exs test/maraithon_web/controllers/mobile_goal_controller_test.exs test/maraithon/telegram_assistant/goal_toolbox_test.exs test/maraithon/chief_of_staff/skills/goal_alignment_test.exs` |
| Mobile build | `make build-mobile` |
| Diff hygiene | `git diff --check` and `git diff --cached --check` when staging |

Broad `mix test`, `mix precommit`, `make test`, and `make verify` remain out of scope unless Kent re-enables broad test discipline.

## 8. Acceptance Checks

- A mobile create request that includes `last_reviewed_at` or `next_review_at` cannot spoof persisted review timestamps.
- A chat/tool goal create or update cannot pass internal timestamp or raw metadata fields through `goal_attrs/1`.
- Internal review completion still updates `last_reviewed_at` and recomputes `next_review_at`.
- `apply_review_output/4` persists valid output even when another generated output candidate is invalid.
- Partial review runs record skipped-output details.
- The mobile account/profile menu includes `Goals`, and the Goals sheet can save a new goal through the API client.
- Focused tests and `make build-mobile` pass.

## 9. Assumptions

- The current mobile profile sheet implementation from commit `2713785` is the correct placement.
- Goal raw metadata remains an internal extension point for now.
- "Harden" means improve trust boundaries, partial failure handling, and verification coverage before adding new large features.
