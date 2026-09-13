# Prepare the work before asking the user to orchestrate it

Maraithon's todo workspace should answer: what is happening, what would finish
this obligation, what can Maraithon prepare now, and what decision needs the
user. Connected-source research belongs to the assistant. The operator should
receive a concrete result to review or a specific unresolved decision.

## Delivered behavior

- Loading the first list page queues preparation for its first three open,
  actionable todos. The existing brief worker deduplicates current work and
  runs on a dedicated per-user preparation lane within the existing bounded
  model worker pool. Source-analysis backlogs cannot serialize preparation
  behind all other model work. Monitoring items and closed work
  are excluded. This is preparation on list access, not a new periodic agent.
- Web detail preparation now enqueues the same durable job used by native
  clients. Navigating away no longer owns or cancels model execution. The page
  polls the job, shows queued/running/failure states, and stops polling after
  six minutes while the durable worker continues. No automatic force loop.
- Explicit context refresh records the generation it is replacing. A delayed
  job does not force a second generation over a newer result. Refresh cannot
  steal a valid generation lease or generate closed work. Concurrent generation
  defers through the job runner rather than exhausting the attempt budget.
- Web, Mac, and iPhone lead with the brief, an optional source-grounded
  **Done when** outcome, and decisions the user alone can make. **Prepare this
  for me** delegates connected-source investigation and action preparation to
  the existing supervised, durable conversation runner.
- The assistant checks the latest source, people, documents, and calendar facts
  when relevant; it uses the todo browser for website work. It reuses current
  prepared actions and asks for a human decision only when retrieval cannot
  resolve it. Sending, submitting, booking, purchasing, and accepting terms
  still use the existing review pipeline.
- Current brief context accompanies the linked todo in model input. The chat
  primer updates when that context changes and drops the generic introductory
  script. It describes the obligation rather than claiming work happened.
- Mac's action shelf now includes immutable browser reviews alongside editable
  drafts, and preparation controls disable while a run is already active.

The optional `done_when` brief field is backward compatible. Existing briefs
refresh through their normal expiry or explicit refresh; there is no bulk
invalidation or new database/SwiftData migration. It expresses the target
outcome, not independent evidence that the outcome happened. The existing
completion-evidence and approval rules remain authoritative.

## Validation

Phoenix warnings-as-errors compilation, asset build, SwiftPM compilation,
signed Mac build, and iOS simulator build passed. No new files or target changes
required project regeneration for development builds; the distribution archive
regenerated the iPhone project successfully. Tests were intentionally not added or run under
`docs/development-mode.md`. Production and native release results are recorded
below after the manual verification pass.

The first production check observed a 215-second wait/completion interval for
a new todo while the shared model lane drained other work. The read-only Cloud
Run audit (`maraithon-todo-validation-k8f2k`) confirmed completed jobs and no
remaining cooldown. Preparation now uses `runtime_todo_preparation`, handled by
the existing fair model runner with its unchanged global concurrency and LLM
gate. Older queued jobs remain valid and skip generation if a current result
already exists; no database rows, ownership fences, or active tasks were reset.
The brief-generation lease prevents overlapping work on the same todo.

A public website check also exposed a remembered link label absent from its
source. The brief prompt now explicitly treats a URL as a location to inspect,
not evidence of page contents; exact controls still come from the live browser.

## Release and manual verification — September 8, 2026

- Production revision `maraithon-00270-xth` serves 100% of traffic, image
  `dev-afd64a4f9fbd-20260908142041-1`. Cloud Build
  `e8504ecf-ef26-48fc-bae2-49c7dfe9434f` succeeded. No migration was required.
- Signed Mac build installed at `~/Applications/Maraithon.app`; signature
  verification passed. The real Michael/Christina workspace displayed the
  summary, completion outcome, preparation control, calendar/message/email
  suggestions, and people context after its queued brief completed.
- iPhone 1.0.1 build `20260908141130`, delivery
  `5d50abf3-2995-4c8d-b40e-44d3bd812c44`, is `VALID` and
  `IN_BETA_TESTING`. Archive/export/upload and XcodeGen all passed.
- Main checkout integration and warnings-as-errors compilation passed. The
  queue-list merge preserved the unrelated PeopleNetwork worker and read repo.

Production verification used manual todo
`823daa82-3c80-4b54-a58c-4cb41ed9ec20`, explicitly limited to public Example
Domain/IANA pages. Clicking **Prepare this for me** without a custom prompt
opened the actual website on the paired Mac, read the live page, and created an
immutable Chrome review for its real **Learn more** link. The todo stayed open
because the operator's review of the linked explanation remained outstanding.

A context refresh requested just after 14:24:56 UTC started executing at
14:25:02.061 UTC on the final revision. The page was left during execution;
on return at 14:26:10 UTC, both the brief and chat primer displayed the refreshed
content. The unsupported remembered link label was absent. This is one manual
observation, not a controlled performance benchmark or a latency guarantee.

The temporary browser action was cancelled and the verification todo dismissed
after the checks. No real messages, bookings, purchases, or policy acceptances
were executed. Native iPhone interaction was compile/archive verified and
shipped through TestFlight; the live delegation flow was exercised from web.
